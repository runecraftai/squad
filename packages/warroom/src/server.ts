import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { Server } from "bun";
import { type Command, Warroom } from "./core.ts";

const indexHtml = readFileSync(join(import.meta.dir, "web", "index.html"), "utf8");

function json(data: unknown, status = 200): Response {
	return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

function decodePathSegment(pathname: string, prefix: string): string | null {
	try {
		return decodeURIComponent(pathname.slice(prefix.length));
	} catch {
		return null;
	}
}

function isLoopbackOrigin(origin: string): boolean {
	try {
		const { hostname } = new URL(origin);
		return hostname === "127.0.0.1" || hostname === "localhost" || hostname === "[::1]";
	} catch {
		return false;
	}
}

export interface ServerOptions {
	dbPath?: string;
	port?: number;
	actorId?: string;
}

/** Builds the Warroom instance and request handler for the planning surface. Exported separately from `serve()` so tests can exercise routing without binding a socket. */
export function createApp(options: ServerOptions = {}): { warroom: Warroom; fetch: (request: Request) => Response | Promise<Response> } {
	const warroom = new Warroom(options.dbPath ?? ":memory:", { id: options.actorId ?? "operator" });

	function initiativeSummaries(): Array<{ id: string; title: string; workingName: string; phase: string; createdAt: string; updatedAt: string }> {
		return warroom.db
			.query("SELECT id, title, working_name as workingName, phase, created_at as createdAt, updated_at as updatedAt FROM initiatives ORDER BY updated_at DESC")
			.all() as any;
	}

	function fetch(request: Request): Response | Promise<Response> {
		const url = new URL(request.url);

		if (request.method === "GET" && url.pathname === "/") {
			return new Response(indexHtml, { headers: { "content-type": "text/html; charset=utf-8" } });
		}

		if (request.method === "GET" && url.pathname === "/api/initiatives") {
			return json(initiativeSummaries());
		}

		if (request.method === "GET" && url.pathname.startsWith("/api/initiative/")) {
			const id = decodePathSegment(url.pathname, "/api/initiative/");
			if (id === null) return json({ error: "invalid initiative id" }, 400);
			const state = warroom.state(id);
			if (!state.initiative) return json({ error: "initiative does not exist" }, 404);
			return json({ ...state, timeline: warroom.timeline(id) });
		}

		if (request.method === "GET" && url.pathname.startsWith("/api/compare/")) {
			const initiativeId = decodePathSegment(url.pathname, "/api/compare/");
			if (initiativeId === null) return json({ error: "invalid initiative id" }, 400);
			const a = url.searchParams.get("a");
			const b = url.searchParams.get("b");
			if (!a || !b) return json({ error: "query params 'a' and 'b' are required" }, 400);
			try {
				return json(warroom.compare(initiativeId, a, b));
			} catch (error) {
				return json({ error: (error as Error).message }, 400);
			}
		}

		if (request.method === "POST" && url.pathname === "/api/command") {
			const contentType = request.headers.get("content-type") ?? "";
			if (!/^application\/json\b/i.test(contentType)) {
				return json({ error: "content-type must be application/json" }, 415);
			}
			const origin = request.headers.get("origin");
			if (origin !== null && !isLoopbackOrigin(origin)) {
				return json({ error: "cross-origin requests are not allowed" }, 403);
			}
			return request.json().then(
				(command: Command) => {
					try {
						const event = warroom.command(command);
						return json(event, 201);
					} catch (error) {
						return json({ error: (error as Error).message }, 400);
					}
				},
				() => json({ error: "request body must be JSON" }, 400),
			);
		}

		return json({ error: "not found" }, 404);
	}

	return { warroom, fetch };
}

export function serve(options: ServerOptions = {}): Server<undefined> {
	const app = createApp(options);
	const server = Bun.serve({ port: options.port ?? 4600, hostname: "127.0.0.1", fetch: app.fetch });
	console.log(`Runecraft Warroom planning surface at http://127.0.0.1:${server.port} (db: ${options.dbPath ?? ":memory:"})`);
	return server;
}

if (import.meta.main) {
	serve({
		dbPath: process.argv[2] ?? process.env.WARROOM_DB ?? "warroom.db",
		port: Number(process.argv[3] ?? process.env.WARROOM_PORT ?? 4600),
		actorId: process.env.WARROOM_ACTOR ?? "operator",
	});
}
