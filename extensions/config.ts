import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

export type SubagentsEnvironment = NodeJS.ProcessEnv;

export const PROTOCOL_ID = "pi-subagents";
export const PACKAGE_VERSION = "0.3.0";
export const CLI_API_VERSION = 1;
export const WATCHER_API_VERSION = 1;
export const STATE_SCHEMA_VERSION = 1;
export const EVENT_SCHEMA_VERSION = 1;
export const LIFECYCLE_SCHEMA_VERSION = 1;

export type PackageContract = {
	protocolId: string;
	packageVersion: string;
	cliApiVersion: number;
	watcherApiVersion: number;
	stateSchemaVersion: number;
	eventSchemaVersion: number;
	lifecycleSchemaVersion: number;
};

export const EXPECTED_PACKAGE_CONTRACT: PackageContract = {
	protocolId: PROTOCOL_ID,
	packageVersion: PACKAGE_VERSION,
	cliApiVersion: CLI_API_VERSION,
	watcherApiVersion: WATCHER_API_VERSION,
	stateSchemaVersion: STATE_SCHEMA_VERSION,
	eventSchemaVersion: EVENT_SCHEMA_VERSION,
	lifecycleSchemaVersion: LIFECYCLE_SCHEMA_VERSION,
};

export function resolveStateDir(
	env: SubagentsEnvironment = process.env,
	home: string = os.homedir(),
): string {
	if (env.SUBAGENTS_STATE_DIR) return path.resolve(env.SUBAGENTS_STATE_DIR);
	const stateHome = env.XDG_STATE_HOME || path.join(home, ".local", "state");
	return path.join(stateHome, "subagents");
}

export function packageRoot(): string {
	return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
}

export function packageCliPath(): string {
	return path.join(packageRoot(), "skills", "subagents", "subagents");
}

export function validatePackageContract(root: string = packageRoot()): PackageContract {
	const manifestPath = path.join(root, "package.json");
	const protocolPath = path.join(root, "protocol.json");
	let manifest: { version?: unknown };
	let protocol: unknown;
	try {
		manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8")) as { version?: unknown };
		protocol = JSON.parse(fs.readFileSync(protocolPath, "utf8"));
	} catch (error) {
		throw new Error(`cannot read package contract: ${error instanceof Error ? error.message : String(error)}`);
	}
	if (manifest.version !== PACKAGE_VERSION) {
		throw new Error(`package/watcher version mismatch: package is ${String(manifest.version)}, watcher expects ${PACKAGE_VERSION}`);
	}
	if (JSON.stringify(protocol) !== JSON.stringify(EXPECTED_PACKAGE_CONTRACT)) {
		throw new Error(
			`package/watcher protocol mismatch: package has ${JSON.stringify(protocol)}, watcher expects ${JSON.stringify(EXPECTED_PACKAGE_CONTRACT)}`,
		);
	}
	return protocol as PackageContract;
}

export function subagentsBinCandidates(env: SubagentsEnvironment = process.env): string[] {
	const candidates = [env.SUBAGENTS_BIN, packageCliPath()]
		.filter((candidate): candidate is string => Boolean(candidate));
	return [...new Set(candidates.map((candidate) => path.resolve(candidate)))];
}

export function findSubagentsBin(env: SubagentsEnvironment = process.env): string | null {
	for (const candidate of subagentsBinCandidates(env)) {
		try {
			fs.accessSync(candidate, fs.constants.X_OK);
			return candidate;
		} catch {
			// Keep looking. A copied extension may not have the package-local CLI.
		}
	}
	return null;
}
