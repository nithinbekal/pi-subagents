/**
 * Subagents Watcher (lead-side, push-async)
 *
 * Polls the session-scoped subagent state, asks the CLI to detect completions,
 * and injects durably queued reports into the lead conversation. The CLI writes
 * each immutable completion to the watcher spool before advancing its detection
 * marker, so a watcher or callback crash cannot create a loss window.
 *
 * Delivery is at least once. A spool record is removed only after the matching
 * Pi 0.84+ custom_message entry is observed in the persisted session and a
 * durable acknowledgement marker has been written.
 *
 * Env:
 *   SUBAGENTS_BIN        path to the subagents script (else package-local)
 *   SUBAGENTS_STATE_DIR  state root shared with the CLI
 *   SUBAGENTS_WAKE       "0" to inject without waking an idle lead (default: wake)
 *   SUBAGENTS_WATCH_MS   poll interval in ms (default 3000)
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { execFile, execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import { findSubagentsBin, resolveStateDir } from "./config.ts";

const PREVIEW_CHARS = 1500;
const DEFAULT_WATCH_MS = 3000;
// Long enough that a queued steer can survive an unusually long turn without
// same-instance retry spam. Reload still retries immediately from the spool.
const DELIVERY_RETRY_MS = 30 * 60_000;
const DELIVERED_RETENTION_MS = 7 * 24 * 60 * 60_000;

type CompletionEvent = {
	id: string;
	status: "done" | "idle" | "exited";
	reportPath: string;
	reportBody: string;
	completionKey: string;
};

export function resolveWatchInterval(value: string | undefined): number {
	const parsed = Number(value);
	return Number.isFinite(parsed) && parsed >= 1 ? Math.floor(parsed) : DEFAULT_WATCH_MS;
}

function completionEventId({ id, status, completionKey }: CompletionEvent): string {
	return createHash("sha256")
		.update(JSON.stringify({ id, status, completionKey }))
		.digest("hex");
}

// Prefer the exact pane, then parse tmux's stable session number from $TMUX.
function currentTmuxSession(): string | null {
	const pane = process.env.TMUX_PANE;
	if (pane) {
		try {
			const session = execFileSync("tmux", ["display-message", "-pt", pane, "#{session_id}"], {
				encoding: "utf-8",
				timeout: 2000,
			}).trim();
			if (session) return session;
		} catch {
			/* fall through to $TMUX parsing */
		}
	}
	const tmux = process.env.TMUX;
	if (tmux) {
		const parts = tmux.split(",");
		const num = parts[2];
		if (num && /^\d+$/.test(num)) return "$" + num;
	}
	return null;
}

function fsyncDirectory(directory: string): void {
	const descriptor = fs.openSync(directory, "r");
	try {
		fs.fsyncSync(descriptor);
	} finally {
		fs.closeSync(descriptor);
	}
}

export default function (pi: ExtensionAPI) {
	const bin = findSubagentsBin();
	if (!bin) return;

	const stateDir = resolveStateDir();
	const wake = process.env.SUBAGENTS_WAKE !== "0";
	const intervalMs = resolveWatchInterval(process.env.SUBAGENTS_WATCH_MS);

	let sessionDir: string | null = null;
	let pendingDir: string | null = null;
	let deliveredDir: string | null = null;
	let sessionFile: string | undefined;
	let sessionFileIdentity: string | null = null;
	let sessionReadOffset = 0;
	let sessionReadRemainder = "";
	let active = false;
	let draining = false;
	let pending = false;
	let timer: ReturnType<typeof setInterval> | null = null;
	let scheduledDrain: ReturnType<typeof setTimeout> | null = null;
	let scheduledDrainAt = 0;
	let drainPromise: Promise<void> | null = null;
	let finishDrain: (() => void) | null = null;
	const confirmedEventIds = new Set<string>();
	const deliveryAttempts = new Map<string, number>();
	const queuedPaths = new Map<string, Set<string>>();
	const reportedErrors = new Set<string>();

	const reportError = (operation: string, error: unknown): void => {
		const message = error instanceof Error ? error.message : String(error);
		const key = `${operation}: ${message}`;
		if (reportedErrors.has(key)) return;
		reportedErrors.add(key);
		console.error(`[subagents-watch] ${key}`);
	};

	const hasSubagents = (): boolean => {
		if (!sessionDir) return false;
		try {
			return fs
				.readdirSync(sessionDir, { withFileTypes: true })
				.some((entry) => entry.isDirectory() && /^\d+$/.test(entry.name));
		} catch {
			return false;
		}
	};

	const deliveredPath = (eventId: string): string | null =>
		deliveredDir ? path.join(deliveredDir, eventId) : null;

	const isDelivered = (eventId: string): boolean => {
		if (confirmedEventIds.has(eventId)) return true;
		const marker = deliveredPath(eventId);
		if (!marker) return false;
		try {
			if (!fs.existsSync(marker)) return false;
			confirmedEventIds.add(eventId);
			return true;
		} catch {
			return false;
		}
	};

	const markDelivered = (eventId: string): boolean => {
		const marker = deliveredPath(eventId);
		if (!marker || !deliveredDir) return false;
		let descriptor: number | null = null;
		try {
			fs.mkdirSync(deliveredDir, { recursive: true });
			try {
				descriptor = fs.openSync(marker, "wx", 0o600);
				fs.writeFileSync(descriptor, `${Date.now()}\n`, "utf-8");
				fs.fsyncSync(descriptor);
				fs.closeSync(descriptor);
				descriptor = null;
				fsyncDirectory(deliveredDir);
			} catch (error) {
				if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
			}
			confirmedEventIds.add(eventId);
			return true;
		} catch (error) {
			if (descriptor !== null) {
				try { fs.closeSync(descriptor); } catch { /* ignore close errors */ }
			}
			reportError(`could not record delivered event ${eventId}`, error);
			return false;
		}
	};

	const rememberQueuedPath = (eventId: string, queuedPath: string): void => {
		const paths = queuedPaths.get(eventId) ?? new Set<string>();
		paths.add(queuedPath);
		queuedPaths.set(eventId, paths);
	};

	const removeQueuedPaths = (eventId: string): void => {
		const paths = queuedPaths.get(eventId);
		if (!paths) return;
		let allRemoved = true;
		for (const queuedPath of paths) {
			try {
				fs.unlinkSync(queuedPath);
			} catch (error) {
				if ((error as NodeJS.ErrnoException).code !== "ENOENT") allRemoved = false;
			}
		}
		if (allRemoved) queuedPaths.delete(eventId);
	};

	const confirmDelivery = (eventId: string): void => {
		if (!markDelivered(eventId)) return;
		deliveryAttempts.delete(eventId);
		removeQueuedPaths(eventId);
	};

	const eventIdFromSessionEntry = (entry: unknown): string | null => {
		if (!entry || typeof entry !== "object") return null;
		const record = entry as { type?: unknown; customType?: unknown; details?: unknown };
		if (record.type !== "custom_message" || record.customType !== "subagent-report") return null;
		const details = record.details as { eventId?: unknown } | undefined;
		return typeof details?.eventId === "string" ? details.eventId : null;
	};

	const eventIdFromRuntimeMessage = (message: unknown): string | null => {
		if (!message || typeof message !== "object") return null;
		const record = message as { role?: unknown; customType?: unknown; details?: unknown };
		if (record.role !== "custom" || record.customType !== "subagent-report") return null;
		const details = record.details as { eventId?: unknown } | undefined;
		return typeof details?.eventId === "string" ? details.eventId : null;
	};

	const hasOutstandingEvents = (): boolean => {
		if (!pendingDir) return false;
		try {
			return fs.readdirSync(pendingDir, { withFileTypes: true })
				.some((file) => file.isFile() && file.name.endsWith(".json"));
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
				reportError(`could not inspect pending events ${pendingDir}`, error);
			}
			return false;
		}
	};

	// Read only appended JSONL bytes while events are outstanding. Pi 0.84+
	// persists extension messages as top-level custom_message entries. A crash
	// after session append but before ledger fsync may replay once, which is safer
	// than acknowledging a message that was never persisted.
	const reconcilePersistedDeliveries = (): boolean => {
		if (!sessionFile || !hasOutstandingEvents()) return false;
		let descriptor: number | null = null;
		try {
			descriptor = fs.openSync(sessionFile, "r");
			const stat = fs.fstatSync(descriptor);
			const identity = `${stat.dev}:${stat.ino}`;
			if (identity !== sessionFileIdentity || stat.size < sessionReadOffset) {
				sessionFileIdentity = identity;
				sessionReadOffset = 0;
				sessionReadRemainder = "";
			}

			const length = stat.size - sessionReadOffset;
			if (length > 0) {
				const buffer = Buffer.allocUnsafe(length);
				const bytesRead = fs.readSync(descriptor, buffer, 0, length, sessionReadOffset);
				sessionReadOffset += bytesRead;
				const lines = (sessionReadRemainder + buffer.toString("utf-8", 0, bytesRead)).split("\n");
				sessionReadRemainder = lines.pop() ?? "";
				for (const line of lines) {
					if (!line.trim()) continue;
					try {
						const eventId = eventIdFromSessionEntry(JSON.parse(line));
						if (eventId) confirmDelivery(eventId);
					} catch {
						/* malformed session entries are Pi's responsibility */
					}
				}
			}
			return true;
		} catch (error) {
			reportError(`could not reconcile session ${sessionFile}`, error);
			return false;
		} finally {
			if (descriptor !== null) {
				try { fs.closeSync(descriptor); } catch { /* ignore close errors */ }
			}
		}
	};

	const scheduleDrain = (delayMs: number): void => {
		if (!active) return;
		const runAt = Date.now() + delayMs;
		if (scheduledDrain && runAt >= scheduledDrainAt) return;
		if (scheduledDrain) clearTimeout(scheduledDrain);
		scheduledDrainAt = runAt;
		scheduledDrain = setTimeout(() => {
			scheduledDrain = null;
			scheduledDrainAt = 0;
			if (active) drain();
		}, delayMs);
		if (typeof scheduledDrain.unref === "function") scheduledDrain.unref();
	};

	const attemptDelivery = (event: CompletionEvent): void => {
		if (!active) return;
		const { id, status, reportPath, reportBody } = event;
		const eventId = completionEventId(event);
		if (isDelivered(eventId)) {
			removeQueuedPaths(eventId);
			return;
		}
		const lastAttempt = deliveryAttempts.get(eventId) ?? 0;
		if (Date.now() - lastAttempt < DELIVERY_RETRY_MS) return;

		const truncated = reportBody.length > PREVIEW_CHARS;
		const preview = truncated ? `${reportBody.slice(0, PREVIEW_CHARS)}\n…(truncated)` : reportBody;
		const label =
			status === "done" ? "finished"
			: status === "exited" ? "exited"
			: "is idle — may have answered inline or need input";
		const content =
			`📋 subagent #${id} ${label}.\n\n` +
			`${preview || "(no report captured)"}\n\n` +
			`(full report: ${reportPath}${truncated ? "; preview truncated above" : ""}` +
			` — peek: subagents peek ${id}, follow up: subagents tell ${id} <msg>)`;

		deliveryAttempts.set(eventId, Date.now());
		try {
			pi.sendMessage(
				{
					customType: "subagent-report",
					content,
					display: true,
					details: { id, status, reportPath, eventId },
				},
				{ deliverAs: "steer", triggerTurn: wake },
			);
			scheduleDrain(100);
		} catch {
			deliveryAttempts.delete(eventId);
		}
	};

	const quarantineCorruptEvent = (queuedPath: string): void => {
		let corruptPath = `${queuedPath}.corrupt`;
		if (fs.existsSync(corruptPath)) corruptPath += `.${randomUUID()}`;
		try {
			fs.renameSync(queuedPath, corruptPath);
		} catch (error) {
			reportError(`could not quarantine corrupt event ${queuedPath}`, error);
		}
	};

	const parseQueuedEvent = (contents: string): CompletionEvent | null => {
		let parsed: Partial<CompletionEvent>;
		try {
			parsed = JSON.parse(contents) as Partial<CompletionEvent>;
		} catch {
			return null;
		}
		if (
			typeof parsed.id !== "string" ||
			(parsed.status !== "done" && parsed.status !== "idle" && parsed.status !== "exited") ||
			typeof parsed.reportPath !== "string" ||
			typeof parsed.reportBody !== "string" ||
			typeof parsed.completionKey !== "string"
		) return null;
		return parsed as CompletionEvent;
	};

	const flushQueuedEvents = (): void => {
		if (!active || !pendingDir) return;
		let files: fs.Dirent[];
		try {
			files = fs.readdirSync(pendingDir, { withFileTypes: true });
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
				reportError(`could not list pending events ${pendingDir}`, error);
			}
			return;
		}

		for (const file of files) {
			if (!file.isFile() || !file.name.endsWith(".json")) continue;
			const queuedPath = path.join(pendingDir, file.name);
			let contents: string;
			try {
				contents = fs.readFileSync(queuedPath, "utf-8");
			} catch (error) {
				reportError(`could not read pending event ${queuedPath}`, error);
				continue;
			}

			const event = parseQueuedEvent(contents);
			if (!event) {
				quarantineCorruptEvent(queuedPath);
				continue;
			}
			const eventId = completionEventId(event);
			rememberQueuedPath(eventId, queuedPath);
			if (isDelivered(eventId)) {
				removeQueuedPaths(eventId);
				continue;
			}
			attemptDelivery(event);
		}
	};

	const completeDrain = (): void => {
		draining = false;
		const finish = finishDrain;
		finishDrain = null;
		drainPromise = null;
		finish?.();
	};

	const drain = (): void => {
		if (!active) return;
		reconcilePersistedDeliveries();
		flushQueuedEvents();
		if (draining) {
			pending = true;
			return;
		}
		if (!hasSubagents()) return;
		draining = true;
		drainPromise = new Promise<void>((resolve) => {
			finishDrain = resolve;
		});
		try {
			execFile(bin, ["events"], { encoding: "utf-8", timeout: 10_000 }, (error) => {
				try {
					if (error) reportError("event detection failed", error);
					flushQueuedEvents();
				} finally {
					const shouldDrainAgain = pending;
					pending = false;
					completeDrain();
					if (shouldDrainAgain) scheduleDrain(50);
				}
			});
		} catch (error) {
			reportError("could not start event detection", error);
			completeDrain();
		}
	};

	const pruneDeliveredLedger = (): void => {
		if (!deliveredDir) return;
		let files: fs.Dirent[];
		try {
			files = fs.readdirSync(deliveredDir, { withFileTypes: true });
		} catch {
			return;
		}
		const cutoff = Date.now() - DELIVERED_RETENTION_MS;
		for (const file of files) {
			if (!file.isFile()) continue;
			const marker = path.join(deliveredDir, file.name);
			try {
				if (fs.statSync(marker).mtimeMs < cutoff) {
					fs.unlinkSync(marker);
					confirmedEventIds.delete(file.name);
				}
			} catch {
				/* best-effort pruning; delivery safety does not depend on it */
			}
		}
	};

	const start = (_event: unknown, ctx: ExtensionContext): void => {
		if (active) return;
		const session = currentTmuxSession();
		if (!session) return;
		sessionDir = path.join(stateDir, session);
		pendingDir = path.join(sessionDir, ".watcher-pending");
		deliveredDir = path.join(sessionDir, ".watcher-delivered");
		sessionFile = ctx.sessionManager.getSessionFile();
		sessionFileIdentity = null;
		sessionReadOffset = 0;
		sessionReadRemainder = "";
		active = true;
		try { fs.mkdirSync(sessionDir, { recursive: true }); } catch { /* later drains retry */ }
		pruneDeliveredLedger();

		timer = setInterval(() => scheduleDrain(0), intervalMs);
		if (typeof timer.unref === "function") timer.unref();
		scheduleDrain(0);
	};

	const stop = async (): Promise<void> => {
		active = false;
		pending = false;
		if (timer) {
			clearInterval(timer);
			timer = null;
		}
		if (scheduledDrain) {
			clearTimeout(scheduledDrain);
			scheduledDrain = null;
			scheduledDrainAt = 0;
		}
		// Let an in-flight CLI process finish queueing before this runtime exits.
		const inFlight = drainPromise;
		if (inFlight) await inFlight;
		draining = false;
	};

	pi.on("session_start", start);
	pi.on("message_end", (event) => {
		const eventId = eventIdFromRuntimeMessage(event.message);
		if (!eventId || !sessionFile) return;
		// The hook runs immediately before SessionManager persistence.
		scheduleDrain(0);
	});
	pi.on("session_shutdown", stop);
}
