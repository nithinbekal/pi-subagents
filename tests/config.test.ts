import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { access, appendFile, mkdir, mkdtemp, readFile, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import test from "node:test";

import {
	EVENT_SCHEMA_VERSION,
	EXPECTED_PACKAGE_CONTRACT,
	PROTOCOL_ID,
	findSubagentsBin,
	packageCliPath,
	packageRoot,
	resolveStateDir,
	subagentsBinCandidates,
	validatePackageContract,
} from "../extensions/config.ts";
import subagentsWatch, { resolveWatchInterval } from "../extensions/subagents-watch.ts";

function eventId(id: string, generation: number, status: string, completionKey: string): string {
	return createHash("sha256")
		.update(JSON.stringify({ protocolId: PROTOCOL_ID, schemaVersion: EVENT_SCHEMA_VERSION, id, generation, status, completionKey }))
		.digest("hex");
}

function saveEnv(keys: readonly string[]): Map<string, string | undefined> {
	return new Map(keys.map((key) => [key, process.env[key]]));
}

function restoreEnv(previous: Map<string, string | undefined>): void {
	for (const [key, value] of previous) {
		if (value === undefined) delete process.env[key];
		else process.env[key] = value;
	}
}

test("state directory honors explicit and XDG configuration", () => {
	const home = "/tmp/example-home";
	assert.equal(resolveStateDir({ XDG_STATE_HOME: "/srv/state" }, home), "/srv/state/subagents");
	assert.equal(resolveStateDir({ SUBAGENTS_STATE_DIR: "/srv/custom-subagents" }, home), "/srv/custom-subagents");
});

test("package-local CLI and package contract are internally consistent", async () => {
	const explicit = "/tmp/custom-subagents-bin";
	assert.deepEqual(subagentsBinCandidates({ SUBAGENTS_BIN: explicit }), [explicit, packageCliPath()]);
	await access(packageCliPath(), fsConstants.X_OK);
	assert.equal(findSubagentsBin({}), packageCliPath());
	assert.equal(packageRoot(), path.resolve(import.meta.dirname, ".."));
	assert.deepEqual(validatePackageContract(), EXPECTED_PACKAGE_CONTRACT);
});

test("package contract mismatches fail loudly", async () => {
	const root = await mkdtemp(path.join(tmpdir(), "pi-subagents-package-mismatch-"));
	await writeFile(path.join(root, "package.json"), JSON.stringify({ version: "0.2.0" }));
	await writeFile(path.join(root, "protocol.json"), JSON.stringify(EXPECTED_PACKAGE_CONTRACT));
	assert.throws(() => validatePackageContract(root), /package\/watcher version mismatch/);
});

test("watch interval accepts only positive finite values", () => {
	assert.equal(resolveWatchInterval("25"), 25);
	assert.equal(resolveWatchInterval("25.9"), 25);
	for (const value of [undefined, "", "0", "0.5", "-1", "nope", "Infinity"]) {
		assert.equal(resolveWatchInterval(value), 3000);
	}
});

test("watcher registers Pi lifecycle handlers after a matching CLI handshake", async () => {
	const root = await mkdtemp(path.join(tmpdir(), "pi-subagents-extension-"));
	const bin = path.join(root, "subagents");
	await writeFile(bin, `#!/bin/sh\n[ "$1" = protocol ] || exit 1\nprintf '%s\\n' '${JSON.stringify(EXPECTED_PACKAGE_CONTRACT)}'\n`, { mode: 0o755 });
	const previous = process.env.SUBAGENTS_BIN;
	process.env.SUBAGENTS_BIN = bin;
	try {
		const handlers = new Map<string, Function>();
		subagentsWatch({ on(name: string, handler: Function) { handlers.set(name, handler); } } as never);
		assert.deepEqual([...handlers.keys()], ["session_start", "message_end", "session_shutdown"]);
	} finally {
		if (previous === undefined) delete process.env.SUBAGENTS_BIN;
		else process.env.SUBAGENTS_BIN = previous;
	}
});

test("watcher rejects a mismatched CLI protocol before reading state", async () => {
	const root = await mkdtemp(path.join(tmpdir(), "pi-subagents-cli-mismatch-"));
	const bin = path.join(root, "subagents");
	await writeFile(bin, "#!/bin/sh\nprintf '%s\\n' '{\"packageVersion\":\"old\"}'\n", { mode: 0o755 });
	const previous = process.env.SUBAGENTS_BIN;
	process.env.SUBAGENTS_BIN = bin;
	try {
		assert.throws(() => subagentsWatch({ on() {} } as never), /CLI\/watcher protocol mismatch/);
	} finally {
		if (previous === undefined) delete process.env.SUBAGENTS_BIN;
		else process.env.SUBAGENTS_BIN = previous;
	}
});

test("watcher replays a versioned spool and delegates acknowledgement to the CLI", async () => {
	const root = await mkdtemp(path.join(tmpdir(), "pi-subagents-delivery-"));
	const stateDir = path.join(root, "state");
	const sessionDir = path.join(stateDir, "$9");
	const pendingDir = path.join(sessionDir, ".watcher-pending");
	const deliveredDir = path.join(sessionDir, ".watcher-delivered");
	const archiveDir = path.join(sessionDir, "7", "events");
	const queuedName = "7-1-event.json";
	const queuedPath = path.join(pendingDir, queuedName);
	const report = path.join(sessionDir, "7", "reports", "1.md");
	const sessionFile = path.join(root, "session.jsonl");
	const bin = path.join(root, "subagents");
	const completionKey = "7:done:1:123:16";
	const id = eventId("7", 1, "done", completionKey);
	await mkdir(path.dirname(report), { recursive: true });
	await mkdir(pendingDir, { recursive: true });
	await writeFile(path.join(sessionDir, ".schema.json"), `${JSON.stringify(EXPECTED_PACKAGE_CONTRACT)}\n`);
	await writeFile(report, "complete report\n");
	await writeFile(sessionFile, "");
	await writeFile(queuedPath, JSON.stringify({
		protocolId: PROTOCOL_ID,
		packageVersion: EXPECTED_PACKAGE_CONTRACT.packageVersion,
		schemaVersion: EVENT_SCHEMA_VERSION,
		id: "7",
		generation: 1,
		status: "done",
		outcome: "completed",
		completionKey,
		eventId: id,
		reportPath: report,
		reportBody: "complete report\n",
		createdAt: 1,
	}));
	await writeFile(bin, `#!/bin/sh
case "$1" in
  protocol) printf '%s\\n' '${JSON.stringify(EXPECTED_PACKAGE_CONTRACT)}' ;;
  events) exit 0 ;;
  ack)
    mkdir -p '${deliveredDir}' '${archiveDir}'
    printf '%s\\n' ack >'${deliveredDir}'/"$3"
    mv '${pendingDir}'/"$4" '${archiveDir}'/"$3.json"
    ;;
  *) exit 1 ;;
esac
`, { mode: 0o755 });

	const envKeys = ["SUBAGENTS_BIN", "SUBAGENTS_STATE_DIR", "SUBAGENTS_WATCH_MS", "TMUX", "TMUX_PANE"] as const;
	const previous = saveEnv(envKeys);
	process.env.SUBAGENTS_BIN = bin;
	process.env.SUBAGENTS_STATE_DIR = stateDir;
	process.env.SUBAGENTS_WATCH_MS = "20";
	process.env.TMUX = "/tmp/fake-tmux,123,9";
	delete process.env.TMUX_PANE;
	const handlers = new Map<string, Function>();
	const sent: Array<{ message: Record<string, unknown>; options: Record<string, unknown> }> = [];
	try {
		subagentsWatch({
			on(name: string, handler: Function) { handlers.set(name, handler); },
			sendMessage(message: Record<string, unknown>, options: Record<string, unknown>) { sent.push({ message, options }); },
		} as never);
		handlers.get("session_start")?.({}, {
			hasUI: false,
			sessionManager: { getSessionFile: () => sessionFile },
			ui: { notify() {} },
		});
		for (let i = 0; i < 500 && sent.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
		assert.equal(sent.length, 1);
		assert.match(String(sent[0].message.content), /subagent #7 finished/);
		assert.match(String(sent[0].message.content), /complete report/);
		assert.deepEqual(sent[0].options, { deliverAs: "steer", triggerTurn: true });
		assert.deepEqual(sent[0].message.details, { id: "7", status: "done", reportPath: report, eventId: id });
		await access(queuedPath);
		await appendFile(sessionFile, `${JSON.stringify({ type: "custom_message", customType: "subagent-report", details: { eventId: id } })}\n`);
		for (let i = 0; i < 500; i += 1) {
			try { await access(queuedPath); await new Promise((resolve) => setTimeout(resolve, 10)); }
			catch { break; }
		}
		await assert.rejects(access(queuedPath));
		assert.deepEqual(await readdir(deliveredDir), [id]);
		assert.deepEqual(await readdir(archiveDir), [`${id}.json`]);
		assert.equal(JSON.parse(await readFile(path.join(archiveDir, `${id}.json`), "utf8")).eventId, id);
		assert.equal(sent.length, 1);
	} finally {
		await handlers.get("session_shutdown")?.();
		restoreEnv(previous);
	}
});

test("watcher reports subprocess facts for events and acknowledgement failures", async (t) => {
	const failures = [
		{ name: "silent exit", script: "exit 17", code: "17", signal: "null", killed: "false" },
		{ name: "TERM-trapped deadline", script: "trap 'exit 19' TERM; while :; do sleep 0.05; done", code: "19", signal: "null", killed: "true" },
		{ name: "external signal", script: 'kill -TERM "$$"', code: "null", signal: "SIGTERM", killed: "false" },
		{ name: "stderr", script: "printf '%s\\n' 'specific child failure' >&2; exit 23", code: "23", signal: "null", killed: "false" },
	];
	for (const command of ["events", "ack"]) {
		for (const failure of failures) {
			await t.test(`${command}: ${failure.name}`, { timeout: 25_000 }, async () => {
				const root = await mkdtemp(path.join(tmpdir(), "pi-subagents-command-failure-"));
				const stateDir = path.join(root, "state");
				const sessionDir = path.join(stateDir, "$9");
				const pendingDir = path.join(sessionDir, ".watcher-pending");
				const report = path.join(sessionDir, "7", "reports", "1.md");
				const queuedPath = path.join(pendingDir, "7-1-event.json");
				const sessionFile = path.join(root, "session.jsonl");
				const bin = path.join(root, "subagents");
				const completionKey = "7:done:1:123:16";
				const id = eventId("7", 1, "done", completionKey);
				await mkdir(path.dirname(report), { recursive: true });
				await mkdir(pendingDir, { recursive: true });
				await writeFile(path.join(sessionDir, ".schema.json"), JSON.stringify(EXPECTED_PACKAGE_CONTRACT));
				await writeFile(report, "complete report\n");
				await writeFile(sessionFile, command === "ack"
					? `${JSON.stringify({ type: "custom_message", customType: "subagent-report", details: { eventId: id } })}\n`
					: "");
				const queuedContents = JSON.stringify({
					protocolId: PROTOCOL_ID, packageVersion: EXPECTED_PACKAGE_CONTRACT.packageVersion,
					schemaVersion: EVENT_SCHEMA_VERSION, id: "7", generation: 1, status: "done", outcome: "completed",
					completionKey, eventId: id, reportPath: report, reportBody: "complete report\n", createdAt: 1,
				});
				if (command === "ack") await writeFile(queuedPath, queuedContents);
				await writeFile(bin, `#!/bin/sh
case "$1" in
  protocol) printf '%s\\n' '${JSON.stringify(EXPECTED_PACKAGE_CONTRACT)}' ;;
  ${command}) ${failure.script} ;;
  *) exit 0 ;;
esac
`, { mode: 0o755 });
				const previous = saveEnv(["SUBAGENTS_BIN", "SUBAGENTS_STATE_DIR", "SUBAGENTS_WATCH_MS", "TMUX", "TMUX_PANE"]);
				process.env.SUBAGENTS_BIN = bin;
				process.env.SUBAGENTS_STATE_DIR = stateDir;
				process.env.SUBAGENTS_WATCH_MS = "60000";
				process.env.TMUX = "/tmp/fake-tmux,123,9";
				delete process.env.TMUX_PANE;
				const handlers = new Map<string, Function>();
				let notify: (message: string) => void = () => {};
				let deadline: ReturnType<typeof setTimeout> | undefined;
				const diagnostic = new Promise<string>((resolve, reject) => {
					notify = resolve;
					deadline = setTimeout(() => reject(new Error("missing subprocess failure diagnostic")), 20_000);
				});
				try {
					subagentsWatch({
						on(name: string, handler: Function) { handlers.set(name, handler); },
						sendMessage() { assert.fail("an already persisted report must not be resent"); },
					} as never);
					handlers.get("session_start")?.({}, {
						hasUI: true, sessionManager: { getSessionFile: () => sessionFile }, ui: { notify },
					});
					const message = await diagnostic;
					assert.match(message, command === "events" ? /event detection or cleanup failed/ : /acknowledgement failed/);
					assert.match(message, new RegExp(`code=${failure.code}, signal=${failure.signal}, killed=${failure.killed}`));
					assert.match(message, /elapsed=\d+ms, budget=10000ms/);
					assert.doesNotMatch(message, /timed out|timeout confirmed/i);
					if (failure.name === "stderr") assert.match(message, /specific child failure/);
					if (failure.name === "TERM-trapped deadline") {
						assert.ok(Number(message.match(/elapsed=(\d+)ms/)?.[1]) >= 10_000);
					}
					if (command === "ack") {
						assert.equal(await readFile(queuedPath, "utf8"), queuedContents);
						await assert.rejects(access(path.join(sessionDir, ".watcher-delivered", id)));
					}
				} finally {
					if (deadline) clearTimeout(deadline);
					await handlers.get("session_shutdown")?.();
					restoreEnv(previous);
				}
			});
		}
	}
});

test("watcher logs automatic cleanup successes without hiding failures or eligibility notices", async (t) => {
	const success = "subagents cleanup: stopped subagent #7 after completed report and 600s grace; state preserved";
	const zeroGraceSuccess = "subagents cleanup: stopped subagent #18 after completed report and 0s grace; state preserved";
	const failedStop = "subagents cleanup: could not stop pane for subagent #8; lifecycle preserved";
	const failedCommit = "subagents cleanup: pane for subagent #9 stopped but cleanup lifecycle commit failed";
	const failureDetails = `state helper: cannot rename lifecycle.json: EACCES\n\tpath=/isolated/state/9/lifecycle.json\n\n${failedCommit}\n${failedStop}`;
	const notice = "subagents cleanup: subagent #7 is eligible for cleanup (notify mode; no pane stopped)";
	const preview = "subagents cleanup: would stop subagent #7 (completed, grace 600s elapsed)";
	const nearMatches = [
		`${success}; cleanup lifecycle commit failed`,
		`error: ${success}`,
		success.replace("#7", "#unknown"),
		success.replace("600s", "-1s"),
	];
	const scenarios = [
		{
			name: "successful batch", code: 0,
			batches: [{ stderr: `${success}\n${zeroGraceSuccess}`, entries: 2 }],
			successes: [success, zeroGraceSuccess], visible: [],
		},
		{
			name: "ordinary warning", code: 0,
			batches: [{ stderr: "specific CLI warning", entries: 1 }],
			successes: [], visible: ["specific CLI warning"],
		},
		{
			name: "ordinary error", code: 23,
			batches: [{ stderr: "specific child failure\n  original detail", entries: 1 }, { stderr: "specific child failure\n  original detail", entries: 1 }],
			successes: [], visible: ["specific child failure\n  original detail"],
		},
		{
			name: "failed stop", code: 1,
			batches: [{ stderr: failedStop, entries: 1 }, { stderr: failedStop, entries: 1 }],
			successes: [], visible: [failedStop],
		},
		{
			name: "stopped pane with failed lifecycle commit", code: 1,
			batches: [{ stderr: failureDetails, entries: 1 }],
			successes: [], visible: [failureDetails],
		},
		{
			name: "mixed batches deduplicate failures independently of successes", code: 1,
			batches: [{ stderr: `${success}\n${failureDetails}\n${zeroGraceSuccess}`, entries: 3 }, { stderr: `${zeroGraceSuccess}\n${failureDetails}`, entries: 2 }],
			successes: [success, zeroGraceSuccess], visible: [failureDetails],
		},
		{
			name: "unsuccessful exit after only success diagnostics", code: 17,
			batches: [{ stderr: `\n${success}\n \n`, entries: 2 }],
			successes: [success], visible: ["CLI command failed"],
		},
		{
			name: "notify-only eligibility", code: 0, mode: "notify",
			batches: [{ stderr: notice, entries: 1 }],
			successes: [], visible: [notice],
		},
		{
			name: "dry-run eligibility", code: 0, mode: "dry-run",
			batches: [{ stderr: preview, entries: 1 }],
			successes: [], visible: [preview],
		},
		{
			name: "near matches remain visible", code: 0,
			batches: [{ stderr: nearMatches.join("\n"), entries: nearMatches.length }],
			successes: [], visible: nearMatches,
		},
	];
	for (const hasUI of [true, false]) {
		for (const scenario of scenarios) {
			await t.test(`${hasUI ? "UI" : "headless"}: ${scenario.name}`, async (t) => {
				const root = await mkdtemp(path.join(tmpdir(), "pi-subagents-cleanup-diagnostic-"));
				const stateDir = path.join(root, "state");
				const sessionDir = path.join(stateDir, "$9");
				const sessionFile = path.join(root, "session.jsonl");
				const bin = path.join(root, "subagents");
				const logPath = path.join(stateDir, "watcher.log");
				await mkdir(path.join(sessionDir, "7"), { recursive: true });
				await writeFile(path.join(sessionDir, ".schema.json"), JSON.stringify(EXPECTED_PACKAGE_CONTRACT));
				await writeFile(sessionFile, "");
				const quote = (text: string): string => `'${text.replaceAll("'", "'\\''")}'`;
				const first = scenario.batches[0].stderr;
				const next = scenario.batches[1]?.stderr ?? first;
				await writeFile(bin, `#!/bin/sh
case "$1" in
  protocol) printf '%s\\n' '${JSON.stringify(EXPECTED_PACKAGE_CONTRACT)}' ;;
  events)
    [ "$SUBAGENTS_CLEANUP_MODE" = '${scenario.mode ?? "on"}' ] || exit 99
    if [ -f '${root}/invoked' ]; then
      printf '%s\\n' ${quote(next)} >&2
    else
      : >'${root}/invoked'
      printf '%s\\n' ${quote(first)} >&2
    fi
    exit ${scenario.code}
    ;;
  *) exit 98 ;;
esac
`, { mode: 0o755 });
				const previous = saveEnv(["SUBAGENTS_BIN", "SUBAGENTS_STATE_DIR", "SUBAGENTS_WATCH_MS", "SUBAGENTS_CLEANUP_MODE", "TMUX", "TMUX_PANE"]);
				process.env.SUBAGENTS_BIN = bin;
				process.env.SUBAGENTS_STATE_DIR = stateDir;
				process.env.SUBAGENTS_WATCH_MS = "60000";
				process.env.SUBAGENTS_CLEANUP_MODE = scenario.mode ?? "on";
				process.env.TMUX = "/tmp/fake-tmux,123,9";
				delete process.env.TMUX_PANE;
				const handlers = new Map<string, Function>();
				const notifications: Array<{ message: string; level: string }> = [];
				const terminal: string[] = [];
				t.mock.method(console, "error", (...args: unknown[]) => { terminal.push(args.join(" ")); });
				let log = "";
				try {
					subagentsWatch({
						on(name: string, handler: Function) { handlers.set(name, handler); },
						sendMessage() { assert.fail("diagnostics must not inject report messages"); },
					} as never);
					handlers.get("session_start")?.({}, {
						hasUI, sessionManager: { getSessionFile: () => sessionFile },
						ui: { notify(message: string, level: string) { notifications.push({ message, level }); } },
					});
					let expectedEntries = 0;
					for (const [index, batch] of scenario.batches.entries()) {
						if (index > 0) handlers.get("message_end")?.({
							message: { role: "custom", customType: "subagent-report", details: { eventId: "test-wakeup" } },
						});
						expectedEntries += batch.entries;
						for (let i = 0; i < 500; i += 1) {
							try { log = await readFile(logPath, "utf8"); }
							catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
							if ((log.match(/^\d{4}-\S+ (?:INFO|WARNING|ERROR) \$9 /gm)?.length ?? 0) >= expectedEntries) break;
							await new Promise((resolve) => setTimeout(resolve, 10));
						}
						assert.equal(log.match(/^\d{4}-\S+ (?:INFO|WARNING|ERROR) \$9 /gm)?.length, expectedEntries, log);
					}
				} finally {
					await handlers.get("session_shutdown")?.();
					restoreEnv(previous);
				}
				const visible = hasUI ? notifications.map(({ message }) => message) : terminal;
				assert.equal(visible.length, scenario.visible.length);
				assert.deepEqual(hasUI ? terminal : notifications, []);
				for (const [index, detail] of scenario.visible.entries()) {
					assert.ok(visible[index].includes(detail), visible[index]);
					assert.ok(log.includes(detail), log);
					if (hasUI) assert.equal(notifications[index].level, scenario.code ? "error" : "warning");
					if (scenario.code) {
						assert.match(visible[index], /event detection or cleanup failed/);
						assert.ok(visible[index].includes(`code=${scenario.code}, signal=null, killed=false`), visible[index]);
						assert.match(visible[index], /elapsed=\d+ms, budget=10000ms/);
					}
				}
				for (const detail of scenario.successes) {
					assert.ok(log.includes(` INFO $9 ${detail}\n`), log);
					assert.ok(visible.every((message) => !message.includes(detail)), visible.join("\n"));
				}
			});
		}
	}
});

test("watcher preserves malformed spool records instead of mixing or deleting them", async () => {
	const root = await mkdtemp(path.join(tmpdir(), "pi-subagents-malformed-event-"));
	const stateDir = path.join(root, "state");
	const sessionDir = path.join(stateDir, "$8");
	const pendingDir = path.join(sessionDir, ".watcher-pending");
	const queuedPath = path.join(pendingDir, "bad.json");
	const sessionFile = path.join(root, "session.jsonl");
	const bin = path.join(root, "subagents");
	await mkdir(path.join(sessionDir, "1"), { recursive: true });
	await mkdir(pendingDir, { recursive: true });
	await writeFile(path.join(sessionDir, ".schema.json"), `${JSON.stringify(EXPECTED_PACKAGE_CONTRACT)}\n`);
	await writeFile(queuedPath, "{not-json\n");
	await writeFile(sessionFile, "");
	await writeFile(bin, `#!/bin/sh\ncase "$1" in protocol) printf '%s\\n' '${JSON.stringify(EXPECTED_PACKAGE_CONTRACT)}';; events) exit 0;; *) exit 1;; esac\n`, { mode: 0o755 });
	const keys = ["SUBAGENTS_BIN", "SUBAGENTS_STATE_DIR", "SUBAGENTS_WATCH_MS", "TMUX", "TMUX_PANE"] as const;
	const previous = saveEnv(keys);
	process.env.SUBAGENTS_BIN = bin;
	process.env.SUBAGENTS_STATE_DIR = stateDir;
	process.env.SUBAGENTS_WATCH_MS = "20";
	process.env.TMUX = "/tmp/fake-tmux,123,8";
	delete process.env.TMUX_PANE;
	const handlers = new Map<string, Function>();
	let sent = 0;
	try {
		subagentsWatch({ on(name: string, handler: Function) { handlers.set(name, handler); }, sendMessage() { sent += 1; } } as never);
		handlers.get("session_start")?.({}, { hasUI: false, sessionManager: { getSessionFile: () => sessionFile }, ui: { notify() {} } });
		await new Promise((resolve) => setTimeout(resolve, 100));
		await access(queuedPath);
		assert.equal(sent, 0);
	} finally {
		await handlers.get("session_shutdown")?.();
		restoreEnv(previous);
	}
});
