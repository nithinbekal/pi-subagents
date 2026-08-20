import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

export type SubagentsEnvironment = NodeJS.ProcessEnv;

export function resolveAgentDir(
	env: SubagentsEnvironment = process.env,
	home: string = os.homedir(),
): string {
	return env.SUBAGENTS_AGENT_DIR || path.join(home, ".pi", "agent");
}

export function resolveStateDir(
	env: SubagentsEnvironment = process.env,
	home: string = os.homedir(),
): string {
	if (env.SUBAGENTS_STATE_DIR) return path.resolve(env.SUBAGENTS_STATE_DIR);
	const stateHome = env.XDG_STATE_HOME || path.join(home, ".local", "state");
	return path.join(stateHome, "subagents");
}

export function packageCliPath(): string {
	const extensionDir = path.dirname(fileURLToPath(import.meta.url));
	return path.resolve(extensionDir, "..", "skills", "subagents", "subagents");
}

export function subagentsBinCandidates(
	env: SubagentsEnvironment = process.env,
	home: string = os.homedir(),
): string[] {
	const candidates = [
		env.SUBAGENTS_BIN,
		packageCliPath(),
		path.join(resolveAgentDir(env, home), "skills", "subagents", "subagents"),
	].filter((candidate): candidate is string => Boolean(candidate));
	return [...new Set(candidates.map((candidate) => path.resolve(candidate)))];
}

export function findSubagentsBin(
	env: SubagentsEnvironment = process.env,
	home: string = os.homedir(),
): string | null {
	for (const candidate of subagentsBinCandidates(env, home)) {
		try {
			fs.accessSync(candidate, fs.constants.X_OK);
			return candidate;
		} catch {
			// Keep looking. A copied extension may not have the package-local CLI.
		}
	}
	return null;
}
