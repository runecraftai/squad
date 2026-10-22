import { randomUUID } from "node:crypto";
import { createConnection, createServer, type Server } from "node:net";
import { incompatibility, PROTOCOL_VERSION, type Request, type Response, refuse } from "./protocol.js";

/** Unix socket paths are limited by `sun_path`; refuse early with a clear message instead of an opaque EINVAL. */
export const MAX_SOCKET_PATH = 100;

export function assertSocketPath(path: string): void {
	if (Buffer.byteLength(path) > MAX_SOCKET_PATH) {
		throw new Error(`socket path ${path} is longer than ${MAX_SOCKET_PATH} bytes; use a shorter store directory`);
	}
}

/** Serve newline-delimited JSON requests; each line gets exactly one response line. */
export function serveSocket(path: string, handle: (request: Request) => Promise<Response>): Promise<Server> {
	assertSocketPath(path);
	const server = createServer((socket) => {
		socket.setEncoding("utf8");
		let buffer = "";
		socket.on("data", (chunk: string) => {
			buffer += chunk;
			let newline = buffer.indexOf("\n");
			while (newline >= 0) {
				const line = buffer.slice(0, newline);
				buffer = buffer.slice(newline + 1);
				newline = buffer.indexOf("\n");
				if (line.trim() === "") continue;
				void respond(line).then((response) => {
					if (!socket.destroyed) socket.write(`${JSON.stringify(response)}\n`);
				});
			}
		});
		socket.on("error", () => {});
	});
	async function respond(line: string): Promise<Response> {
		let request: Request;
		try {
			request = JSON.parse(line) as Request;
		} catch {
			return refuse("", "bad_request", "request is not valid JSON");
		}
		const id = typeof request.id === "string" ? request.id : "";
		const mismatch = incompatibility(request.protocol, "client");
		if (mismatch !== undefined) return refuse(id, "protocol_mismatch", mismatch);
		try {
			return await handle(request);
		} catch (error) {
			return refuse(id, "internal", error instanceof Error ? error.message : String(error));
		}
	}
	return new Promise((resolve, reject) => {
		server.once("error", reject);
		server.listen(path, () => {
			server.off("error", reject);
			resolve(server);
		});
	});
}

/** Raised when no service answers on the socket: stopped, not yet listening, or killed. */
export class ServiceUnavailable extends Error {
	constructor(message: string) {
		super(message);
		this.name = "ServiceUnavailable";
	}
}

/** Send one request and wait for its response line. */
export function callSocket(
	path: string,
	command: string,
	args: Record<string, unknown> = {},
	options: { readonly timeoutMs?: number; readonly protocol?: string } = {},
): Promise<Response> {
	const request: Request = { protocol: options.protocol ?? PROTOCOL_VERSION, id: randomUUID(), command, args };
	return new Promise((resolve, reject) => {
		const socket = createConnection(path);
		socket.setEncoding("utf8");
		let buffer = "";
		let settled = false;
		const timer = setTimeout(() => finish(new ServiceUnavailable(`no response from ${path} within ${options.timeoutMs ?? 10_000} ms`)), options.timeoutMs ?? 10_000);
		function finish(result: Response | Error): void {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			socket.destroy();
			if (result instanceof Error) reject(result);
			else resolve(result);
		}
		socket.on("connect", () => socket.write(`${JSON.stringify(request)}\n`));
		socket.on("data", (chunk: string) => {
			buffer += chunk;
			const newline = buffer.indexOf("\n");
			if (newline < 0) return;
			try {
				const response = JSON.parse(buffer.slice(0, newline)) as Response;
				const mismatch = incompatibility(response.protocol, "service");
				if (mismatch !== undefined && response.ok) {
					finish(refuse(request.id, "protocol_mismatch", mismatch));
					return;
				}
				finish(response);
			} catch (error) {
				finish(error instanceof Error ? error : new Error(String(error)));
			}
		});
		socket.on("error", (error: NodeJS.ErrnoException) => {
			const stopped = error.code === "ENOENT" || error.code === "ECONNREFUSED" || error.code === "ECONNRESET";
			finish(stopped ? new ServiceUnavailable(`service stopped: nothing answers on ${path} (${error.code})`) : error);
		});
		socket.on("close", () => finish(new ServiceUnavailable(`service closed the connection on ${path} before answering`)));
	});
}
