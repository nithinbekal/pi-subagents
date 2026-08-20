import assert from "node:assert/strict";
import { access, mkdir, mkdtemp, writeFile } from "node:fs/promises";
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
import subagentsWatch from "../extensions/subagents-watch.ts";

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

test("watcher consumes generic completion events", async () => {
	const root = await mkdtemp(path.join(tmpdir(), "pi-subagents-delivery-"));
	const stateDir = path.join(root, "state");
	const sessionDir = path.join(stateDir, "$9");
	const report = path.join(root, "report.md");
	const sessionFile = path.join(root, "session.jsonl");
	const bin = path.join(root, "subagents");
	await mkdir(path.join(sessionDir, "7"), { recursive: true });
	await writeFile(report, "complete report\n");
	await writeFile(sessionFile, "");
	await writeFile(bin, `#!/bin/sh\nprintf '7\\tdone\\t%s\\n' '${report}'\n`, { mode: 0o755 });

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
	} finally {
		await handlers.get("session_shutdown")?.();
		for (const key of envKeys) {
			const value = previous.get(key);
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
	}
});
