import assert from "node:assert/strict";
import { access, appendFile, mkdir, mkdtemp, readdir, writeFile } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";
import test from "node:test";

import {
	findSubagentsBin,
	packageCliPath,
	resolveStateDir,
	subagentsBinCandidates,
} from "../extensions/config.ts";
import subagentsWatch, { resolveWatchInterval } from "../extensions/subagents-watch.ts";

test("state directory honors explicit and XDG configuration", () => {
	const home = "/tmp/example-home";
	assert.equal(
		resolveStateDir({ XDG_STATE_HOME: "/srv/state" }, home),
		"/srv/state/subagents",
	);
	assert.equal(
		resolveStateDir({ SUBAGENTS_STATE_DIR: "/srv/custom-subagents" }, home),
		"/srv/custom-subagents",
	);
});

test("bin candidates prefer the explicit path and include this package's CLI", async () => {
	const explicit = "/tmp/custom-subagents-bin";
	const candidates = subagentsBinCandidates({ SUBAGENTS_BIN: explicit });
	assert.deepEqual(candidates, [explicit, packageCliPath()]);
	await access(packageCliPath(), fsConstants.X_OK);
	assert.equal(findSubagentsBin({}), packageCliPath());
});

test("watch interval accepts only positive finite values", () => {
	assert.equal(resolveWatchInterval("25"), 25);
	assert.equal(resolveWatchInterval("25.9"), 25);
	for (const value of [undefined, "", "0", "0.5", "-1", "nope", "Infinity"]) {
		assert.equal(resolveWatchInterval(value), 3000);
	}
});

test("watcher extension loads and registers lifecycle handlers", async () => {
	const root = await mkdtemp(path.join(tmpdir(), "pi-subagents-extension-"));
	const bin = path.join(root, "subagents");
	await writeFile(bin, "#!/bin/sh\nexit 0\n", { mode: 0o755 });

	const previous = process.env.SUBAGENTS_BIN;
	process.env.SUBAGENTS_BIN = bin;
	try {
		const handlers = new Map<string, Function>();
		const fakePi = {
			on(name: string, handler: Function) {
				handlers.set(name, handler);
			},
		};
		subagentsWatch(fakePi as never);
		assert.deepEqual([...handlers.keys()], [
			"session_start",
			"message_end",
			"session_shutdown",
		]);
	} finally {
		if (previous === undefined) delete process.env.SUBAGENTS_BIN;
		else process.env.SUBAGENTS_BIN = previous;
	}
});

test("watcher replays the durable CLI spool and acknowledges only Pi 0.84 entries", async () => {
	const root = await mkdtemp(path.join(tmpdir(), "pi-subagents-delivery-"));
	const stateDir = path.join(root, "state");
	const sessionDir = path.join(stateDir, "$9");
	const pendingDir = path.join(sessionDir, ".watcher-pending");
	const queuedPath = path.join(pendingDir, "7-done.json");
	const report = path.join(root, "report.md");
	const sessionFile = path.join(root, "session.jsonl");
	const bin = path.join(root, "subagents");
	await mkdir(path.join(sessionDir, "7"), { recursive: true });
	await mkdir(pendingDir, { recursive: true });
	await writeFile(report, "complete report\n");
	await writeFile(sessionFile, "");
	await writeFile(queuedPath, JSON.stringify({
		id: "7",
		status: "done",
		reportPath: report,
		reportBody: "complete report",
		completionKey: "7:done:123:16",
	}));
	// This simulates a watcher crash after the CLI queued and marked an event but
	// before the exec callback observed stdout. Replay must come from disk alone.
	await writeFile(bin, "#!/bin/sh\nexit 0\n", { mode: 0o755 });

	const envKeys = ["SUBAGENTS_BIN", "SUBAGENTS_STATE_DIR", "SUBAGENTS_WATCH_MS", "TMUX", "TMUX_PANE"] as const;
	const previous = new Map(envKeys.map((key) => [key, process.env[key]]));
	process.env.SUBAGENTS_BIN = bin;
	process.env.SUBAGENTS_STATE_DIR = stateDir;
	process.env.SUBAGENTS_WATCH_MS = "20";
	process.env.TMUX = "/tmp/fake-tmux,123,9";
	delete process.env.TMUX_PANE;

	const handlers = new Map<string, Function>();
	const sent: Array<{ message: Record<string, unknown>; options: Record<string, unknown> }> = [];
	try {
		subagentsWatch({
			on(name: string, handler: Function) {
				handlers.set(name, handler);
			},
			sendMessage(message: Record<string, unknown>, options: Record<string, unknown>) {
				sent.push({ message, options });
			},
		} as never);
		handlers.get("session_start")?.({}, {
			sessionManager: { getSessionFile: () => sessionFile },
		});

		for (let i = 0; i < 500 && sent.length === 0; i += 1) {
			await new Promise((resolve) => setTimeout(resolve, 10));
		}
		assert.equal(sent.length, 1);
		assert.match(String(sent[0].message.content), /subagent #7 finished/);
		assert.match(String(sent[0].message.content), /complete report/);
		assert.deepEqual(sent[0].options, { deliverAs: "steer", triggerTurn: true });
		assert.deepEqual(
			Object.keys(sent[0].message.details as Record<string, unknown>).sort(),
			["eventId", "id", "reportPath", "status"],
		);

		const eventId = (sent[0].message.details as { eventId: string }).eventId;
		await access(queuedPath);
		await appendFile(sessionFile, `${JSON.stringify({
			type: "custom_message",
			customType: "subagent-report",
			details: { eventId },
		})}\n`);
		for (let i = 0; i < 500; i += 1) {
			try {
				await access(queuedPath);
				await new Promise((resolve) => setTimeout(resolve, 10));
			} catch {
				break;
			}
		}
		await assert.rejects(access(queuedPath));
		assert.deepEqual(await readdir(path.join(sessionDir, ".watcher-delivered")), [eventId]);
		assert.equal(sent.length, 1);
	} finally {
		await handlers.get("session_shutdown")?.();
		for (const key of envKeys) {
			const value = previous.get(key);
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
	}
});
