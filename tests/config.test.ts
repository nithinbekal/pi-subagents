import assert from "node:assert/strict";
import { access, mkdtemp, writeFile } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";
import test from "node:test";

import {
	findSubagentsBin,
	packageCliPath,
	resolveAgentDir,
	resolveStateDir,
	subagentsBinCandidates,
} from "../extensions/config.ts";
import subagentsWatch from "../extensions/subagents-watch.ts";

test("state and agent directories honor explicit and XDG configuration", () => {
	const home = "/tmp/example-home";
	assert.equal(resolveAgentDir({}, home), "/tmp/example-home/.pi/agent");
	assert.equal(
		resolveAgentDir({ SUBAGENTS_AGENT_DIR: "/srv/pi-agent" }, home),
		"/srv/pi-agent",
	);
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
	const candidates = subagentsBinCandidates(
		{ SUBAGENTS_BIN: explicit, SUBAGENTS_AGENT_DIR: "/srv/pi-agent" },
		"/unused",
	);
	assert.equal(candidates[0], explicit);
	assert.equal(candidates[1], packageCliPath());
	assert.equal(candidates[2], "/srv/pi-agent/skills/subagents/subagents");
	await access(packageCliPath(), fsConstants.X_OK);
	assert.equal(findSubagentsBin({}, "/home/without-pi"), packageCliPath());
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
