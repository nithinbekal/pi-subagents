#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";

const PROTOCOL = Object.freeze({
	protocolId: "pi-subagents",
	packageVersion: "0.3.1",
	cliApiVersion: 1,
	watcherApiVersion: 1,
	stateSchemaVersion: 1,
	eventSchemaVersion: 1,
	lifecycleSchemaVersion: 1,
});

const VALID_STATES = new Set([
	"starting",
	"working",
	"blocked",
	"awaiting-follow-up",
	"cleaned",
	"stopped",
	"exited",
]);
const VALID_OUTCOMES = new Set(["completed", "blocked", "exited"]);
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
];

function fail(message, code = 2) {
	console.error(`subagents state: ${message}`);
	process.exit(code);
}

function fsyncDirectory(directory) {
	const descriptor = fs.openSync(directory, "r");
	try {
		fs.fsyncSync(descriptor);
	} finally {
		fs.closeSync(descriptor);
	}
}

function atomicWrite(target, contents, mode = 0o600) {
	const directory = path.dirname(target);
	fs.mkdirSync(directory, { recursive: true });
	const temporary = path.join(directory, `.${path.basename(target)}.${randomUUID()}.tmp`);
	let descriptor;
	try {
		descriptor = fs.openSync(temporary, "wx", mode);
		fs.writeFileSync(descriptor, contents);
		fs.fsyncSync(descriptor);
		fs.closeSync(descriptor);
		descriptor = undefined;
		fs.renameSync(temporary, target);
		fsyncDirectory(directory);
	} catch (error) {
		if (descriptor !== undefined) {
			try { fs.closeSync(descriptor); } catch {}
		}
		try { fs.unlinkSync(temporary); } catch {}
		throw error;
	}
}

function atomicWriteJson(target, value) {
	atomicWrite(target, `${JSON.stringify(value)}\n`);
}

function atomicSnapshot(source, target, replace = false) {
	if (!fs.statSync(source).isFile()) throw new Error(`snapshot source is not a file: ${source}`);
	const contents = fs.readFileSync(source);
	if (contents.length === 0) throw new Error("refusing to snapshot an empty report");
	if (!replace && fs.existsSync(target)) throw new Error(`snapshot target already exists: ${target}`);
	atomicWrite(target, contents);
}

function nonNegativeInteger(value) {
	return Number.isSafeInteger(value) && value >= 0;
}

function optionalString(value) {
	return value === null || typeof value === "string";
}

function ensureSafeLeaf(value, label) {
	if (typeof value !== "string" || !/^[A-Za-z0-9._-]+$/.test(value) || value === "." || value === "..") {
		throw new Error(`${label} is invalid`);
	}
}

function inside(candidate, parent) {
	const relative = path.relative(path.resolve(parent), path.resolve(candidate));
	return relative !== "" && relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function readJson(file, label = file) {
	try {
		return JSON.parse(fs.readFileSync(file, "utf8"));
	} catch (error) {
		throw new Error(`cannot read ${label}: ${error.message}`);
	}
}

function validateLifecycle(value, expectedId) {
	if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("lifecycle record is not an object");
	if (value.protocolId !== PROTOCOL.protocolId) throw new Error(`lifecycle protocolId must be ${PROTOCOL.protocolId}`);
	if (value.packageVersion !== PROTOCOL.packageVersion) throw new Error(`lifecycle packageVersion must be ${PROTOCOL.packageVersion}`);
	if (value.schemaVersion !== PROTOCOL.lifecycleSchemaVersion) {
		throw new Error(`lifecycle schemaVersion must be ${PROTOCOL.lifecycleSchemaVersion}`);
	}
	if (typeof value.id !== "string" || !/^\d+$/.test(value.id)) throw new Error("lifecycle id is invalid");
	if (expectedId !== undefined && value.id !== expectedId) throw new Error(`lifecycle id ${value.id} does not match ${expectedId}`);
	if (!VALID_STATES.has(value.state)) throw new Error(`lifecycle state ${String(value.state)} is invalid`);
	if (!Number.isSafeInteger(value.generation) || value.generation < 1) throw new Error("lifecycle generation is invalid");
	if (typeof value.retained !== "boolean") throw new Error("lifecycle retained flag is invalid");
	if (!nonNegativeInteger(value.createdAt) || !nonNegativeInteger(value.updatedAt)) throw new Error("lifecycle timestamps are invalid");
	if (value.candidateSince !== null && !nonNegativeInteger(value.candidateSince)) throw new Error("lifecycle candidateSince is invalid");
	const publicationKeys = ["completionKey", "spoolName", "eventId", "reportPath", "outcome"];
	for (const key of [...publicationKeys, "noticeKey"]) {
		if (!optionalString(value[key])) throw new Error(`lifecycle ${key} is invalid`);
	}
	if (value.outcome !== null && !VALID_OUTCOMES.has(value.outcome)) throw new Error("lifecycle outcome is invalid");
	const hasPublication = publicationKeys.every((key) => typeof value[key] === "string" && value[key].length > 0);
	const hasNoPublication = publicationKeys.every((key) => value[key] === null);
	if (!hasPublication && !hasNoPublication) throw new Error("lifecycle publication fields are incomplete");
	if (hasPublication) {
		ensureSafeLeaf(value.spoolName, "lifecycle spoolName");
		if (!/^[a-f0-9]{64}$/.test(value.eventId)) throw new Error("lifecycle eventId is invalid");
	}
	if (["starting", "working"].includes(value.state) && !hasNoPublication) throw new Error(`${value.state} lifecycle contains completion state`);
	if (value.state === "awaiting-follow-up" && (value.outcome !== "completed" || !hasPublication)) {
		throw new Error("awaiting-follow-up lifecycle lacks a completed publication");
	}
	if (value.state === "blocked" && (value.outcome !== "blocked" || !hasPublication)) throw new Error("blocked lifecycle lacks a blocked publication");
	if (value.state === "cleaned" && (value.outcome !== "completed" || !hasPublication)) throw new Error("cleaned lifecycle lacks a completed publication");
	if (value.state === "exited" && (value.outcome !== "exited" || !hasPublication)) throw new Error("exited lifecycle lacks an exit publication");
	if (value.state === "awaiting-follow-up" && !value.retained && value.candidateSince === null) {
		throw new Error("unretained awaiting-follow-up lifecycle lacks a cleanup lease");
	}
	if (value.state !== "awaiting-follow-up" && value.candidateSince !== null) throw new Error("non-completed lifecycle has a cleanup lease");
	if (value.retained && value.candidateSince !== null) throw new Error("retained lifecycle has a cleanup lease");
	if (value.noticeKey !== null && value.state !== "awaiting-follow-up") throw new Error("cleanup notice is attached to a protected lifecycle");
	return value;
}

function readLifecycle(file) {
	const expectedId = path.basename(path.dirname(file));
	return validateLifecycle(readJson(file, `lifecycle ${file}`), expectedId);
}

function completionEventId(id, generation, status, completionKey) {
	return createHash("sha256")
		.update(JSON.stringify({
			protocolId: PROTOCOL.protocolId,
			schemaVersion: PROTOCOL.eventSchemaVersion,
			id,
			generation,
			status,
			completionKey,
		}))
		.digest("hex");
}

function expectedStatus(outcome) {
	if (outcome === "completed") return "done";
	if (outcome === "blocked") return "blocked";
	if (outcome === "exited") return "exited";
	throw new Error(`unsupported outcome ${String(outcome)}`);
}

function validateEvent(value, expected = {}) {
	if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("completion event is not an object");
	const keys = Object.keys(value).sort();
	if (JSON.stringify(keys) !== JSON.stringify([...EVENT_KEYS].sort())) throw new Error("completion event has an unexpected shape");
	if (value.protocolId !== PROTOCOL.protocolId) throw new Error(`event protocolId must be ${PROTOCOL.protocolId}`);
	if (value.packageVersion !== PROTOCOL.packageVersion) throw new Error(`event packageVersion must be ${PROTOCOL.packageVersion}`);
	if (value.schemaVersion !== PROTOCOL.eventSchemaVersion) throw new Error(`event schemaVersion must be ${PROTOCOL.eventSchemaVersion}`);
	if (typeof value.id !== "string" || !/^\d+$/.test(value.id)) throw new Error("event id is invalid");
	if (!Number.isSafeInteger(value.generation) || value.generation < 1) throw new Error("event generation is invalid");
	if (!VALID_OUTCOMES.has(value.outcome)) throw new Error("event outcome is invalid");
	if (value.status !== expectedStatus(value.outcome)) throw new Error("event status does not match outcome");
	if (typeof value.completionKey !== "string" || value.completionKey.length === 0) throw new Error("event completionKey is invalid");
	if (typeof value.eventId !== "string" || !/^[a-f0-9]{64}$/.test(value.eventId)) throw new Error("event eventId is invalid");
	if (value.eventId !== completionEventId(value.id, value.generation, value.status, value.completionKey)) {
		throw new Error("eventId does not match the completion event");
	}
	if (typeof value.reportPath !== "string" || typeof value.reportBody !== "string") throw new Error("event report is invalid");
	if (value.reportBody.length === 0) throw new Error("event report is empty");
	if (!nonNegativeInteger(value.createdAt)) throw new Error("event createdAt is invalid");
	for (const [key, wanted] of Object.entries(expected)) {
		if (wanted !== undefined && value[key] !== wanted) throw new Error(`event ${key} does not match`);
	}
	return value;
}

function readEvent(file, expected = {}) {
	return validateEvent(readJson(file, `completion event ${file}`), expected);
}

function initialRecord(id, now) {
	return {
		protocolId: PROTOCOL.protocolId,
		packageVersion: PROTOCOL.packageVersion,
		schemaVersion: PROTOCOL.lifecycleSchemaVersion,
		id,
		state: "starting",
		generation: 1,
		retained: false,
		createdAt: now,
		updatedAt: now,
		candidateSince: null,
		completionKey: null,
		spoolName: null,
		eventId: null,
		reportPath: null,
		outcome: null,
		noticeKey: null,
	};
}

function clearPublication(next) {
	next.candidateSince = null;
	next.completionKey = null;
	next.spoolName = null;
	next.eventId = null;
	next.reportPath = null;
	next.outcome = null;
	next.noticeKey = null;
}

function writeLifecycle(file, value) {
	atomicWriteJson(file, validateLifecycle(value, value.id));
}

function transition(file, operation, now, args) {
	const current = readLifecycle(file);
	const next = { ...current, updatedAt: now };
	switch (operation) {
		case "working":
			if (current.state !== "starting") throw new Error(`cannot mark ${current.state} lifecycle working`);
			next.state = "working";
			break;
		case "tell":
			if (["cleaned", "stopped", "exited"].includes(current.state)) throw new Error(`cannot tell a ${current.state} worker`);
			next.state = "working";
			next.generation += 1;
			clearPublication(next);
			break;
		case "retain":
			if (["cleaned", "stopped", "exited"].includes(current.state)) throw new Error(`cannot retain a ${current.state} worker`);
			next.retained = true;
			next.candidateSince = null;
			next.noticeKey = null;
			break;
		case "release":
			if (["cleaned", "stopped", "exited"].includes(current.state)) throw new Error(`cannot release a ${current.state} worker`);
			next.retained = false;
			next.candidateSince = current.state === "awaiting-follow-up" ? now : null;
			next.noticeKey = null;
			break;
		case "stopped":
			if (current.state === "cleaned") return current;
			next.state = "stopped";
			next.candidateSince = null;
			next.noticeKey = null;
			break;
		case "cleaned": {
			const [rawGeneration, eventId] = args;
			const generation = Number(rawGeneration);
			if (current.state !== "awaiting-follow-up" || current.retained) throw new Error("worker is not cleanup eligible");
			if (current.generation !== generation || current.eventId !== eventId) throw new Error("worker lease changed during cleanup");
			next.state = "cleaned";
			next.candidateSince = null;
			next.noticeKey = null;
			break;
		}
		case "notified": {
			const [rawGeneration, eventId, noticeKey] = args;
			const generation = Number(rawGeneration);
			if (current.state !== "awaiting-follow-up" || current.retained) throw new Error("worker is not cleanup eligible");
			if (current.generation !== generation || current.eventId !== eventId) throw new Error("worker lease changed during notification");
			next.noticeKey = noticeKey;
			break;
		}
		default:
			throw new Error(`unknown lifecycle transition ${operation}`);
	}
	writeLifecycle(file, next);
	return next;
}

function finishPublish(file, outcome, now, generation, completionKey, spoolName, eventId, reportPath) {
	const current = readLifecycle(file);
	if (current.generation !== generation) throw new Error("worker lease changed during report publication");
	ensureSafeLeaf(spoolName, "spoolName");
	const targetState = outcome === "blocked" ? "blocked" : "awaiting-follow-up";
	if (
		current.state === targetState &&
		current.outcome === outcome &&
		current.completionKey === completionKey &&
		current.spoolName === spoolName &&
		current.eventId === eventId &&
		current.reportPath === reportPath
	) return;
	if (current.state !== "working") throw new Error(`cannot publish from ${current.state}`);
	if (!/^[a-f0-9]{64}$/.test(eventId)) throw new Error("eventId is invalid");
	const next = {
		...current,
		state: targetState,
		updatedAt: now,
		candidateSince: outcome === "completed" && !current.retained ? now : null,
		completionKey,
		spoolName,
		eventId,
		reportPath,
		outcome,
		noticeKey: null,
	};
	writeLifecycle(file, next);
}

function finishExit(file, now, generation, completionKey, spoolName, eventId, reportPath) {
	const current = readLifecycle(file);
	if (current.generation !== generation) throw new Error("worker lease changed during exit publication");
	if (current.state !== "working") throw new Error(`cannot publish exit from ${current.state}`);
	const next = {
		...current,
		state: "exited",
		updatedAt: now,
		candidateSince: null,
		completionKey,
		spoolName,
		eventId,
		reportPath,
		outcome: "exited",
		noticeKey: null,
	};
	writeLifecycle(file, next);
}

function agentDirectories(sessionRoot, id) {
	const agentDir = path.join(sessionRoot, id);
	return {
		agentDir,
		reportsDir: path.join(agentDir, "reports"),
		archiveDir: path.join(agentDir, "events"),
		pendingDir: path.join(sessionRoot, ".watcher-pending"),
		deliveredDir: path.join(sessionRoot, ".watcher-delivered"),
	};
}

function validateEventReport(event, sessionRoot) {
	const { reportsDir } = agentDirectories(sessionRoot, event.id);
	if (!inside(event.reportPath, reportsDir)) throw new Error("event report path is outside the worker reports directory");
	const body = fs.readFileSync(event.reportPath, "utf8");
	if (body !== event.reportBody) throw new Error("event report snapshot no longer matches its durable record");
}

function completionRecord(sessionRoot, lifecycle) {
	if (!lifecycle.spoolName || !lifecycle.eventId || !lifecycle.completionKey || !lifecycle.reportPath || !lifecycle.outcome) return null;
	ensureSafeLeaf(lifecycle.spoolName, "spoolName");
	const dirs = agentDirectories(sessionRoot, lifecycle.id);
	const expected = {
		id: lifecycle.id,
		generation: lifecycle.generation,
		status: expectedStatus(lifecycle.outcome),
		outcome: lifecycle.outcome,
		completionKey: lifecycle.completionKey,
		eventId: lifecycle.eventId,
		reportPath: lifecycle.reportPath,
	};
	const pendingPath = path.join(dirs.pendingDir, `${lifecycle.spoolName}.json`);
	if (fs.existsSync(pendingPath)) {
		const event = readEvent(pendingPath, expected);
		validateEventReport(event, sessionRoot);
		return { event, recordPath: pendingPath, acknowledged: false };
	}
	const archivePath = path.join(dirs.archiveDir, `${lifecycle.eventId}.json`);
	if (fs.existsSync(archivePath)) {
		const event = readEvent(archivePath, expected);
		validateEventReport(event, sessionRoot);
		const deliveredPath = path.join(dirs.deliveredDir, lifecycle.eventId);
		if (!fs.existsSync(deliveredPath)) throw new Error("acknowledged event is missing its delivery marker");
		return { event, recordPath: archivePath, acknowledged: true };
	}
	return null;
}

function ensureSpool(target, expected, reportPath, createdAt, sessionRoot) {
	if (fs.existsSync(target)) {
		const event = readEvent(target, expected);
		validateEventReport(event, sessionRoot);
		return event;
	}
	if (!reportPath) throw new Error("durable completion record is missing after an interrupted publication");
	const reportBody = fs.readFileSync(reportPath, "utf8");
	const event = validateEvent({
		protocolId: PROTOCOL.protocolId,
		packageVersion: PROTOCOL.packageVersion,
		schemaVersion: PROTOCOL.eventSchemaVersion,
		id: expected.id,
		generation: expected.generation,
		status: expected.status,
		outcome: expected.outcome,
		completionKey: expected.completionKey,
		eventId: expected.eventId,
		reportPath,
		reportBody,
		createdAt,
	}, expected);
	validateEventReport(event, sessionRoot);
	atomicWriteJson(target, event);
	return event;
}

function acknowledge(sessionRoot, id, eventId, pendingPath, now) {
	const dirs = agentDirectories(sessionRoot, id);
	if (!inside(pendingPath, dirs.pendingDir)) throw new Error("pending path is outside the completion spool");
	const pendingName = path.basename(pendingPath);
	ensureSafeLeaf(pendingName, "pending filename");
	const archivePath = path.join(dirs.archiveDir, `${eventId}.json`);
	let event;
	if (fs.existsSync(pendingPath)) {
		event = readEvent(pendingPath, { id, eventId });
		validateEventReport(event, sessionRoot);
	} else if (fs.existsSync(archivePath)) {
		event = readEvent(archivePath, { id, eventId });
		validateEventReport(event, sessionRoot);
	} else {
		throw new Error("completion is neither pending nor archived");
	}

	fs.mkdirSync(dirs.deliveredDir, { recursive: true });
	const marker = path.join(dirs.deliveredDir, eventId);
	if (!fs.existsSync(marker)) atomicWrite(marker, `${now}\n`);

	fs.mkdirSync(dirs.archiveDir, { recursive: true });
	if (fs.existsSync(archivePath)) {
		const archived = readEvent(archivePath, { id, eventId });
		if (JSON.stringify(archived) !== JSON.stringify(event)) throw new Error("archived event conflicts with pending event");
		if (fs.existsSync(pendingPath)) {
			fs.unlinkSync(pendingPath);
			fsyncDirectory(dirs.pendingDir);
		}
	} else {
		fs.renameSync(pendingPath, archivePath);
		fsyncDirectory(dirs.pendingDir);
		fsyncDirectory(dirs.archiveDir);
	}
}

function purgeCheck(agentDir, sessionRoot) {
	const id = path.basename(agentDir);
	const lifecycle = readLifecycle(path.join(agentDir, "lifecycle.json"));
	if (!["cleaned", "stopped", "exited"].includes(lifecycle.state)) throw new Error(`worker lifecycle is ${lifecycle.state}, not stopped`);
	const dirs = agentDirectories(sessionRoot, id);
	const pendingNames = fs.existsSync(dirs.pendingDir) ? fs.readdirSync(dirs.pendingDir) : [];
	for (const name of pendingNames) {
		if (!name.endsWith(".json")) continue;
		const event = readEvent(path.join(dirs.pendingDir, name));
		if (event.id === id) throw new Error(`worker still has pending completion ${event.eventId}`);
	}

	const referencedReports = new Set();
	const eventIds = [];
	const reportBodies = new Set();
	if (fs.existsSync(dirs.archiveDir)) {
		for (const name of fs.readdirSync(dirs.archiveDir)) {
			if (!name.endsWith(".json")) throw new Error(`unexpected event archive entry ${name}`);
			const event = readEvent(path.join(dirs.archiveDir, name), { id });
			validateEventReport(event, sessionRoot);
			if (!fs.existsSync(path.join(dirs.deliveredDir, event.eventId))) throw new Error(`event ${event.eventId} is not acknowledged`);
			referencedReports.add(path.resolve(event.reportPath));
			reportBodies.add(event.reportBody);
			eventIds.push(event.eventId);
		}
	}
	if (fs.existsSync(dirs.reportsDir)) {
		for (const name of fs.readdirSync(dirs.reportsDir)) {
			if (!/^\d+\.md$/.test(name)) throw new Error(`unexpected report snapshot entry ${name}`);
			const report = path.resolve(dirs.reportsDir, name);
			if (!referencedReports.has(report)) throw new Error(`report snapshot ${name} was never queued and acknowledged`);
		}
	}
	const mutableResult = path.join(agentDir, "result.md");
	if (fs.existsSync(mutableResult)) {
		const body = fs.readFileSync(mutableResult, "utf8");
		if (body.length > 0 && !reportBodies.has(body)) throw new Error("current report was never queued and acknowledged");
	}
	const unpublishedResult = path.join(agentDir, "report.next.md");
	if (fs.existsSync(unpublishedResult) && fs.statSync(unpublishedResult).size > 0) {
		const body = fs.readFileSync(unpublishedResult, "utf8");
		if (!reportBodies.has(body)) throw new Error("unpublished report.next.md is preserved; publish or recover it before purge");
	}
	const unpublishedDir = path.join(agentDir, "unpublished");
	if (fs.existsSync(unpublishedDir) && fs.readdirSync(unpublishedDir).some((name) => fs.statSync(path.join(unpublishedDir, name)).size > 0)) {
		throw new Error("unpublished draft reports are preserved; recover them before purge");
	}
	return [...new Set(eventIds)];
}

const [command, ...args] = process.argv.slice(2);
try {
	switch (command) {
		case "protocol":
			process.stdout.write(`${JSON.stringify(PROTOCOL)}\n`);
			break;
		case "init": {
			const [file, id, rawNow] = args;
			if (!file || !/^\d+$/.test(id ?? "")) throw new Error("usage: init FILE ID NOW");
			const now = Number(rawNow);
			if (!nonNegativeInteger(now)) throw new Error("NOW is invalid");
			if (fs.existsSync(file)) throw new Error(`lifecycle already exists at ${file}`);
			atomicWriteJson(file, initialRecord(id, now));
			break;
		}
		case "validate":
			readLifecycle(args[0]);
			break;
		case "status": {
			const record = readLifecycle(args[0]);
			process.stdout.write(`${JSON.stringify(record)}\n`);
			break;
		}
		case "lease": {
			const record = readLifecycle(args[0]);
			process.stdout.write(`${record.state}\t${record.generation}\n`);
			break;
		}
		case "event-id": {
			const [id, rawGeneration, status, completionKey] = args;
			const generation = Number(rawGeneration);
			if (!/^\d+$/.test(id ?? "") || !Number.isSafeInteger(generation) || generation < 1 || !["done", "blocked", "exited"].includes(status) || !completionKey) {
				throw new Error("invalid event id input");
			}
			process.stdout.write(`${completionEventId(id, generation, status, completionKey)}\n`);
			break;
		}
		case "transition": {
			const [file, operation, rawNow, ...rest] = args;
			const now = Number(rawNow);
			if (!file || !operation || !nonNegativeInteger(now)) throw new Error("invalid transition input");
			const next = transition(file, operation, now, rest);
			process.stdout.write(`${JSON.stringify(next)}\n`);
			break;
		}
		case "finish-publish": {
			const [file, outcome, rawNow, rawGeneration, completionKey, spoolName, eventId, reportPath] = args;
			const now = Number(rawNow);
			const generation = Number(rawGeneration);
			if (!["completed", "blocked"].includes(outcome) || !nonNegativeInteger(now) || !Number.isSafeInteger(generation)) {
				throw new Error("invalid publish transition input");
			}
			finishPublish(file, outcome, now, generation, completionKey, spoolName, eventId, reportPath);
			break;
		}
		case "finish-exit": {
			const [file, rawNow, rawGeneration, completionKey, spoolName, eventId, reportPath] = args;
			const now = Number(rawNow);
			const generation = Number(rawGeneration);
			if (!nonNegativeInteger(now) || !Number.isSafeInteger(generation)) throw new Error("invalid exit transition input");
			finishExit(file, now, generation, completionKey, spoolName, eventId, reportPath);
			break;
		}
		case "snapshot":
			atomicSnapshot(args[0], args[1]);
			break;
		case "replace-snapshot":
			atomicSnapshot(args[0], args[1], true);
			break;
		case "spool": {
			const [target, sessionRoot, id, rawGeneration, status, outcome, completionKey, eventId, reportPath = "", rawNow] = args;
			const generation = Number(rawGeneration);
			const now = Number(rawNow);
			if (!/^\d+$/.test(id ?? "") || !Number.isSafeInteger(generation) || generation < 1 || !nonNegativeInteger(now)) {
				throw new Error("invalid spool input");
			}
			const event = ensureSpool(target, { id, generation, status, outcome, completionKey, eventId }, reportPath, now, sessionRoot);
			process.stdout.write(`${event.reportPath}\n`);
			break;
		}
		case "validate-event":
			validateEventReport(readEvent(args[0]), args[1]);
			break;
		case "eligible": {
			const [file, sessionRoot, rawNow, rawGrace] = args;
			const now = Number(rawNow);
			const grace = Number(rawGrace);
			if (!nonNegativeInteger(now) || !nonNegativeInteger(grace)) throw new Error("invalid cleanup time");
			const lifecycle = readLifecycle(file);
			if (lifecycle.state !== "awaiting-follow-up" || lifecycle.retained || lifecycle.candidateSince === null) process.exit(1);
			if (now - lifecycle.candidateSince < grace) process.exit(1);
			const completion = completionRecord(sessionRoot, lifecycle);
			if (!completion) throw new Error("completion is neither durably queued nor acknowledged");
			process.stdout.write(`${lifecycle.generation}\t${lifecycle.candidateSince}\t${lifecycle.eventId}\n`);
			break;
		}
		case "pending": {
			const [file, sessionRoot] = args;
			const lifecycle = readLifecycle(file);
			const completion = completionRecord(sessionRoot, lifecycle);
			if (!completion || completion.acknowledged) process.exit(1);
			process.stdout.write(`${completion.event.status}\t${completion.event.reportPath}\t${completion.event.eventId}\t${completion.recordPath}\n`);
			break;
		}
		case "notice-needed": {
			const lifecycle = readLifecycle(args[0]);
			if (lifecycle.noticeKey === args[1]) process.exit(1);
			break;
		}
		case "ack": {
			const [sessionRoot, id, eventId, pendingPath, rawNow] = args;
			const now = Number(rawNow);
			if (!/^\d+$/.test(id ?? "") || !/^[a-f0-9]{64}$/.test(eventId ?? "") || !nonNegativeInteger(now)) {
				throw new Error("invalid acknowledgement input");
			}
			acknowledge(sessionRoot, id, eventId, pendingPath, now);
			break;
		}
		case "purge-check": {
			const eventIds = purgeCheck(args[0], args[1]);
			if (eventIds.length > 0) process.stdout.write(`${eventIds.join("\n")}\n`);
			break;
		}
		default:
			throw new Error(`unknown command ${String(command)}`);
	}
} catch (error) {
	fail(error instanceof Error ? error.message : String(error));
}
