import { randomUUID } from "node:crypto";
import { closeSync, existsSync, mkdirSync, openSync, readdirSync, realpathSync, statSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

/**
 * Store layout and exclusive ownership.
 *
 * <store>/owner.sqlite      ownership file: storeId, laboratory mark, and the kernel lock of the one live owner
 * <store>/pi.sqlite         Pi Durable storage, opened and written only by the owning service
 * <store>/sq-durable.sock   local command socket of the owning service
 * <store>/executor-ledger.json   laboratory executor ledger (the controlled "outside world")
 *
 * Ownership is an fcntl lock taken by SQLite in `locking_mode=EXCLUSIVE` on the ownership file and held for the life of
 * the process. The kernel releases it when the process dies, SIGKILL included, so there is no stale-lock cleanup. The
 * lock is per inode, so another path to the same file contends for the same lock.
 *
 * Never open the ownership file through any other descriptor while holding it: POSIX drops a process's fcntl locks on a
 * file when any descriptor of that file in the process closes. Everything read from it goes through the one connection.
 */

export type StorePaths = {
	readonly dir: string;
	readonly owner: string;
	readonly pi: string;
	readonly socket: string;
	readonly ledger: string;
};

export function storePaths(dir: string): StorePaths {
	return {
		dir,
		owner: join(dir, "owner.sqlite"),
		pi: join(dir, "pi.sqlite"),
		socket: join(dir, "sq-durable.sock"),
		ledger: join(dir, "executor-ledger.json"),
	};
}

/** Resolve an existing store directory to its canonical path. */
export function resolveStore(dir: string): StorePaths {
	if (!existsSync(dir)) throw new Error(`store ${dir} does not exist; create it with sq-durable init`);
	return storePaths(realpathSync(dir));
}

export type Ownership = {
	readonly storeId: string;
	readonly lab: boolean;
	readonly paths: StorePaths;
	/** True while the ownership path still names the inode this process locked. */
	stillOwned(): boolean;
	release(): void;
};

export class OwnershipRefused extends Error {
	constructor(message: string) {
		super(message);
		this.name = "OwnershipRefused";
	}
}

function lockedConnection(path: string): DatabaseSync {
	const db = new DatabaseSync(path);
	try {
		db.exec("PRAGMA busy_timeout = 0");
		db.exec("PRAGMA journal_mode = DELETE");
		db.exec("PRAGMA locking_mode = EXCLUSIVE");
		db.exec("BEGIN EXCLUSIVE");
	} catch (error) {
		db.close();
		const message = error instanceof Error ? error.message : String(error);
		if (/locked|busy/i.test(message)) {
			throw new OwnershipRefused(`another service owns this store (${path} is locked); at most one owner at a time`);
		}
		throw error;
	}
	return db;
}

/** Take exclusive ownership of an initialized store; refuse when it is missing, foreign, or owned by a live process. */
export function acquireOwnership(paths: StorePaths): Ownership {
	if (!existsSync(paths.owner)) {
		throw new OwnershipRefused(`store ${paths.dir} has no ownership file; it is never recreated, run sq-durable init on a new directory`);
	}
	const before = statSync(paths.owner);
	const db = lockedConnection(paths.owner);
	let row: { store_id: string; lab: number } | undefined;
	try {
		row = db.prepare("SELECT store_id, lab FROM owner WHERE id = 1").get() as typeof row;
		if (row === undefined) throw new OwnershipRefused(`ownership file ${paths.owner} holds no store identity`);
		db.prepare("UPDATE owner SET opened_at = ?, opened_pid = ? WHERE id = 1").run(Date.now(), process.pid);
		db.exec("COMMIT");
	} catch (error) {
		db.close();
		if (error instanceof OwnershipRefused) throw error;
		throw new OwnershipRefused(`ownership file ${paths.owner} is unreadable: ${error instanceof Error ? error.message : String(error)}`);
	}
	const locked = statSync(paths.owner);
	if (locked.ino !== before.ino || locked.dev !== before.dev) {
		db.close();
		throw new OwnershipRefused(`ownership file ${paths.owner} was replaced while locking; refusing`);
	}
	let released = false;
	return {
		storeId: row.store_id,
		lab: row.lab === 1,
		paths,
		stillOwned(): boolean {
			if (released) return false;
			try {
				const now = statSync(paths.owner);
				return now.ino === locked.ino && now.dev === locked.dev;
			} catch {
				return false;
			}
		},
		release(): void {
			if (released) return;
			released = true;
			db.close();
		},
	};
}

/**
 * Create a new store's directory and ownership file. Refuses any directory that already holds a file, so it can never
 * overwrite or reinitialize an existing store. Returns the ownership, still held, for the caller to create Pi storage.
 */
export function createStore(dir: string, options: { readonly lab: boolean }): Ownership {
	mkdirSync(dir, { recursive: true, mode: 0o700 });
	const paths = storePaths(realpathSync(dir));
	if (readdirSync(paths.dir).length > 0) {
		throw new OwnershipRefused(`store directory ${paths.dir} is not empty; init refuses to touch an existing store`);
	}
	// Exclusive create: a concurrent init loses here instead of sharing the file.
	closeSync(openSync(paths.owner, "wx", 0o600));
	const db = lockedConnection(paths.owner);
	const storeId = randomUUID();
	try {
		db.exec(
			"CREATE TABLE owner (id INTEGER PRIMARY KEY CHECK (id = 1), store_id TEXT NOT NULL, lab INTEGER NOT NULL, created_at INTEGER NOT NULL, opened_at INTEGER, opened_pid INTEGER)",
		);
		db.prepare("INSERT INTO owner (id, store_id, lab, created_at) VALUES (1, ?, ?, ?)").run(storeId, options.lab ? 1 : 0, Date.now());
		db.exec("COMMIT");
	} catch (error) {
		db.close();
		throw error;
	}
	db.close();
	return acquireOwnership(paths);
}
