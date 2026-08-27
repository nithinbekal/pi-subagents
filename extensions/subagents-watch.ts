/**
 * Subagents watcher for Pi 0.84+.
 *
 * The CLI snapshots a generation-scoped report, fsyncs a versioned completion
 * record, and only then commits lifecycle completion. This watcher replays that
 * spool at least once. It asks the CLI to acknowledge a record only after the
 * matching Pi custom_message is visible in the persisted session; the CLI then
 * serializes acknowledgement with tell/stop/cleanup and archives the record.
 *
 * Env:
 *   SUBAGENTS_BIN        executable package CLI (default: package-local CLI)
 *   SUBAGENTS_STATE_DIR  state root shared with the CLI
 *   SUBAGENTS_WAKE       "0" to inject without waking an idle lead
 *   SUBAGENTS_WATCH_MS   poll interval in ms (default 3000)
 *
 * Cleanup policy is implemented by `subagents events` in the public package;
 * see SUBAGENTS_CLEANUP_MODE and SUBAGENTS_CLEANUP_GRACE_SECONDS in README.md.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { execFile, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import {
	EVENT_SCHEMA_VERSION,
	EXPECTED_PACKAGE_CONTRACT,
	PACKAGE_VERSION,
	PROTOCOL_ID,
	findSubagentsBin,
	resolveStateDir,
	validatePackageContract,
	type PackageContract,
} from "./config.ts";

const PREVIEW_CHARS = 1500;
const DEFAULT_WATCH_MS = 3000;
const DELIVERY_RETRY_MS = 30 * 60_000;

const EVENT_KEYS = [
	"completionKey",
	"createdAt",
	"eventId",
	"generation",
	"id",
	"outcome",
	"packageVersion",
	"protocolId",
	"reportBody",
	"reportPath",
	"schemaVersion",
	"status",
] as const;

type CompletionStatus = "done" | "blocked" | "exited";
type CompletionOutcome = "completed" | "blocked" | "exited";

type CompletionEvent = {
	protocolId: string;
	packageVersion: string;
	schemaVersion: number;
	id: string;
	generation: number;
	status: CompletionStatus;
	outcome: CompletionOutcome;
	completionKey: string;
	eventId: string;
	reportPath: string;
	reportBody: string;
	createdAt: number;
};

export function resolveWatchInterval(value: string | undefined): number {
	const parsed = Number(value);
	return Number.isFinite(parsed) && parsed >= 1 ? Math.floor(parsed) : DEFAULT_WATCH_MS;
}

function sameContract(actual: unknown, expected: PackageContract = EXPECTED_PACKAGE_CONTRACT): boolean {
	return JSON.stringify(actual) === JSON.stringify(expected);
}

function completionEventId(event: Pick<CompletionEvent, "id" | "generation" | "status" | "completionKey">): string {
	return createHash("sha256")
		.update(JSON.stringify({
			protocolId: PROTOCOL_ID,
			schemaVersion: EVENT_SCHEMA_VERSION,
			id: event.id,
			generation: event.generation,
			status: event.status,
			completionKey: event.completionKey,
		}))
		.digest("hex");
}

function expectedStatus(outcome: CompletionOutcome): CompletionStatus {
	if (outcome === "completed") return "done";
	if (outcome === "blocked") return "blocked";
	return "exited";
}

function parseQueuedEvent(contents: string): CompletionEvent {
	let value: unknown;
	try {
		value = JSON.parse(contents);
	} catch (error) {
		throw new Error(`malformed completion JSON: ${error instanceof Error ? error.message : String(error)}`);
	}
	if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("completion event is not an object");
	const event = value as Partial<CompletionEvent>;
	const keys = Object.keys(event).sort();
	if (JSON.stringify(keys) !== JSON.stringify([...EVENT_KEYS].sort())) throw new Error("completion event has an unexpected shape");
	if (event.protocolId !== PROTOCOL_ID || event.packageVersion !== PACKAGE_VERSION || event.schemaVersion !== EVENT_SCHEMA_VERSION) {
		throw new Error(
			`completion protocol mismatch: found ${String(event.protocolId)}/${String(event.packageVersion)}/${String(event.schemaVersion)}, ` +
			`expected ${PROTOCOL_ID}/${PACKAGE_VERSION}/${EVENT_SCHEMA_VERSION}`,
		);
	}
	if (typeof event.id !== "string" || !/^\d+$/.test(event.id)) throw new Error("completion id is invalid");
	if (!Number.isSafeInteger(event.generation) || (event.generation ?? 0) < 1) throw new Error("completion generation is invalid");
	if (event.outcome !== "completed" && event.outcome !== "blocked" && event.outcome !== "exited") throw new Error("completion outcome is invalid");
	if (event.status !== expectedStatus(event.outcome)) throw new Error("completion status does not match outcome");
	if (typeof event.completionKey !== "string" || event.completionKey.length === 0) throw new Error("completion key is invalid");
	if (typeof event.eventId !== "string" || !/^[a-f0-9]{64}$/.test(event.eventId)) throw new Error("completion eventId is invalid");
	if (typeof event.reportPath !== "string" || typeof event.reportBody !== "string" || event.reportBody.length === 0) {
		throw new Error("completion report is invalid");
	}
	if (!Number.isSafeInteger(event.createdAt) || (event.createdAt ?? -1) < 0) throw new Error("completion timestamp is invalid");
	const complete = event as CompletionEvent;
	if (completionEventId(complete) !== complete.eventId) throw new Error("completion eventId does not match its payload");
	return complete;
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
		const number = tmux.split(",")[2];
		if (number && /^\d+$/.test(number)) return `$${number}`;
	}
	return null;
}

function readCliContract(bin: string): PackageContract {
	let value: unknown;
	try {
		value = JSON.parse(execFileSync(bin, ["protocol"], {
			encoding: "utf8",
			timeout: 5000,
			env: process.env,
		}).trim());
	} catch (error) {
		throw new Error(`could not read CLI protocol: ${error instanceof Error ? error.message : String(error)}`);
	}
	if (!sameContract(value)) {
		throw new Error(`CLI/watcher protocol mismatch: CLI has ${JSON.stringify(value)}, watcher expects ${JSON.stringify(EXPECTED_PACKAGE_CONTRACT)}`);
	}
	return value as PackageContract;
}

export default function subagentsWatch(pi: ExtensionAPI) {
	validatePackageContract();
	const bin = findSubagentsBin();
	if (!bin) throw new Error("subagents watcher cannot find an executable package CLI");
	readCliContract(bin);

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
	let context: ExtensionContext | null = null;
	let active = false;
	let draining = false;
	let pendingDrain = false;
	let timer: ReturnType<typeof setInterval> | null = null;
	let scheduledDrain: ReturnType<typeof setTimeout> | null = null;
	let scheduledDrainAt = 0;
	let drainPromise: Promise<void> | null = null;
	let finishDrain: (() => void) | null = null;

	const persistedEventIds = new Set<string>();
	const deliveryAttempts = new Map<string, number>();
	const queuedEvents = new Map<string, { event: CompletionEvent; queuedPath: string }>();
	const ackPromises = new Map<string, Promise<void>>();
	const reportedErrors = new Set<string>();

	const reportError = (operation: string, error: unknown): void => {
		const message = error instanceof Error ? error.message : String(error);
		const key = `${operation}: ${message}`;
		if (reportedErrors.has(key)) return;
		reportedErrors.add(key);
		console.error(`[subagents-watch] ${key}`);
		if (context?.hasUI) context.ui.notify(`subagents watcher: ${key}`, "error");
	};

	const hasSubagents = (): boolean => {
		if (!sessionDir) return false;
		try {
			return fs.readdirSync(sessionDir, { withFileTypes: true })
				.some((entry) => entry.isDirectory() && /^\d+$/.test(entry.name));
		} catch {
			return false;
		}
	};

	const hasOutstandingEvents = (): boolean => {
		if (!pendingDir) return false;
		try {
			return fs.readdirSync(pendingDir, { withFileTypes: true })
				.some((entry) => entry.isFile() && entry.name.endsWith(".json"));
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "ENOENT") reportError("could not inspect pending events", error);
			return false;
		}
	};

	const stateContractReady = (): boolean => {
		if (!sessionDir) return false;
		const marker = path.join(sessionDir, ".schema.json");
		try {
			const actual = JSON.parse(fs.readFileSync(marker, "utf8"));
			if (!sameContract(actual)) {
				reportError("state protocol mismatch; spool preserved and watcher paused", new Error(
					`state has ${JSON.stringify(actual)}, watcher expects ${JSON.stringify(EXPECTED_PACKAGE_CONTRACT)}`,
				));
				return false;
			}
			return true;
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code === "ENOENT" && !hasSubagents() && !hasOutstandingEvents()) return false;
			reportError("state contract missing or malformed; state preserved and watcher paused", error);
			return false;
		}
	};

	const deliveredMarkerExists = (eventId: string): boolean => {
		if (!deliveredDir) return false;
		try {
			return fs.existsSync(path.join(deliveredDir, eventId));
		} catch {
			return false;
		}
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

	const requestAck = (event: CompletionEvent, queuedPath: string): void => {
		if (ackPromises.has(event.eventId)) return;
		const promise = new Promise<void>((resolve) => {
			execFile(
				bin,
				["ack", event.id, event.eventId, path.basename(queuedPath)],
				{ encoding: "utf8", timeout: 10_000, env: process.env },
				(error, _stdout, stderr) => {
					if (error) reportError(`acknowledgement failed for event ${event.eventId}`, stderr.trim() || error);
					else {
						deliveryAttempts.delete(event.eventId);
						queuedEvents.delete(event.eventId);
					}
					resolve();
				},
			);
		});
		ackPromises.set(event.eventId, promise);
		void promise.finally(() => {
			ackPromises.delete(event.eventId);
			if (active) scheduleDrain(100);
		});
	};

	const reconcilePersistedDeliveries = (): void => {
		if (!sessionFile || !hasOutstandingEvents()) return;
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
			if (length <= 0) return;
			const buffer = Buffer.allocUnsafe(length);
			const bytesRead = fs.readSync(descriptor, buffer, 0, length, sessionReadOffset);
			sessionReadOffset += bytesRead;
			const lines = (sessionReadRemainder + buffer.toString("utf8", 0, bytesRead)).split("\n");
			sessionReadRemainder = lines.pop() ?? "";
			for (const line of lines) {
				if (!line.trim()) continue;
				try {
					const eventId = eventIdFromSessionEntry(JSON.parse(line));
					if (eventId) persistedEventIds.add(eventId);
				} catch {
					/* malformed session entries are Pi's responsibility */
				}
			}
		} catch (error) {
			reportError(`could not reconcile session ${sessionFile}`, error);
		} finally {
			if (descriptor !== null) try { fs.closeSync(descriptor); } catch { /* ignore close failure */ }
		}
	};

	const validateQueuedReport = (event: CompletionEvent): void => {
		if (!sessionDir) throw new Error("watcher has no session directory");
		const reportsDir = path.resolve(sessionDir, event.id, "reports");
		const reportPath = path.resolve(event.reportPath);
		const relative = path.relative(reportsDir, reportPath);
		if (!relative || relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
			throw new Error("completion report path is outside the worker reports directory");
		}
		if (fs.readFileSync(reportPath, "utf8") !== event.reportBody) {
			throw new Error("completion report snapshot does not match its durable event");
		}
	};

	const attemptDelivery = (event: CompletionEvent): void => {
		if (!active) return;
		const lastAttempt = deliveryAttempts.get(event.eventId) ?? 0;
		if (Date.now() - lastAttempt < DELIVERY_RETRY_MS) return;
		const cleanBody = event.reportBody.trim();
		const truncated = cleanBody.length > PREVIEW_CHARS;
		const preview = truncated ? `${cleanBody.slice(0, PREVIEW_CHARS)}\n…(truncated)` : cleanBody;
		const label = event.status === "done"
			? "finished and is awaiting follow-up"
			: event.status === "blocked"
				? "is blocked and needs input"
				: "exited without a valid completion publication";
		const content =
			`📋 subagent #${event.id} ${label}.\n\n` +
			`${preview || "(no report captured)"}\n\n` +
			`(full report: ${event.reportPath}${truncated ? "; preview truncated above" : ""}` +
			` — peek: subagents peek ${event.id}, follow up: subagents tell ${event.id} <msg>)`;
		deliveryAttempts.set(event.eventId, Date.now());
		try {
			pi.sendMessage(
				{
					customType: "subagent-report",
					content,
					display: true,
					details: { id: event.id, status: event.status, reportPath: event.reportPath, eventId: event.eventId },
				},
				{ deliverAs: "steer", triggerTurn: wake },
			);
			scheduleDrain(100);
		} catch (error) {
			deliveryAttempts.delete(event.eventId);
			reportError(`delivery failed for event ${event.eventId}`, error);
		}
	};

	const flushQueuedEvents = (): void => {
		if (!active || !pendingDir) return;
		let files: fs.Dirent[];
		try {
			files = fs.readdirSync(pendingDir, { withFileTypes: true });
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "ENOENT") reportError(`could not list pending events ${pendingDir}`, error);
			return;
		}
		for (const file of files) {
			if (!file.isFile() || !file.name.endsWith(".json")) continue;
			const queuedPath = path.join(pendingDir, file.name);
			let event: CompletionEvent;
			try {
				event = parseQueuedEvent(fs.readFileSync(queuedPath, "utf8"));
				validateQueuedReport(event);
			} catch (error) {
				reportError(`incompatible or malformed queued event preserved at ${queuedPath}`, error);
				continue;
			}
			queuedEvents.set(event.eventId, { event, queuedPath });
			if (deliveredMarkerExists(event.eventId) || persistedEventIds.has(event.eventId)) requestAck(event, queuedPath);
			else attemptDelivery(event);
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
		const ready = stateContractReady();
		if (ready) {
			reconcilePersistedDeliveries();
			flushQueuedEvents();
		}
		if (draining) {
			pendingDrain = true;
			return;
		}
		if (!hasSubagents()) return;
		draining = true;
		drainPromise = new Promise<void>((resolve) => { finishDrain = resolve; });
		try {
			execFile(bin, ["events"], { encoding: "utf8", timeout: 10_000, env: process.env }, (error, _stdout, stderr) => {
				try {
					if (error) reportError("event detection or cleanup failed", stderr.trim() || error);
					else if (stderr.trim()) console.error(`[subagents-watch] ${stderr.trim()}`);
					if (stateContractReady()) {
						reconcilePersistedDeliveries();
						flushQueuedEvents();
					}
				} finally {
					const again = pendingDrain;
					pendingDrain = false;
					completeDrain();
					if (again) scheduleDrain(50);
				}
			});
		} catch (error) {
			reportError("could not start event detection", error);
			completeDrain();
		}
	};

	const start = (_event: unknown, ctx: ExtensionContext): void => {
		if (active) return;
		const session = currentTmuxSession();
		if (!session) return;
		try {
			readCliContract(bin);
		} catch (error) {
			ctx.ui.notify(`subagents watcher disabled: ${error instanceof Error ? error.message : String(error)}`, "error");
			throw error;
		}
		sessionDir = path.join(stateDir, session);
		pendingDir = path.join(sessionDir, ".watcher-pending");
		deliveredDir = path.join(sessionDir, ".watcher-delivered");
		sessionFile = ctx.sessionManager.getSessionFile();
		sessionFileIdentity = null;
		sessionReadOffset = 0;
		sessionReadRemainder = "";
		context = ctx;
		active = true;
		timer = setInterval(() => scheduleDrain(0), intervalMs);
		if (typeof timer.unref === "function") timer.unref();
		scheduleDrain(0);
	};

	const stop = async (): Promise<void> => {
		active = false;
		pendingDrain = false;
		context = null;
		if (timer) { clearInterval(timer); timer = null; }
		if (scheduledDrain) {
			clearTimeout(scheduledDrain);
			scheduledDrain = null;
			scheduledDrainAt = 0;
		}
		const inFlight = drainPromise;
		if (inFlight) await inFlight;
		await Promise.allSettled([...ackPromises.values()]);
		draining = false;
	};

	pi.on("session_start", start);
	pi.on("message_end", (event) => {
		const eventId = eventIdFromRuntimeMessage(event.message);
		if (!eventId || !sessionFile) return;
		// message_end runs immediately before SessionManager persistence. Wake the
		// reconciler, but acknowledge only after it reads the custom_message entry.
		scheduleDrain(100);
	});
	pi.on("session_shutdown", stop);
}
