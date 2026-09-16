#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/skills/subagents/subagents"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pi-subagents-cli.XXXXXX")
SOCKET="pi-subagents-test-$$"
trap 'tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home/.pi/agent" "$TMP/state" "$TMP/bin" "$TMP/old-cache/pi-subagents"
printf 'old-provider\told-model\n' >"$TMP/old-cache/pi-subagents/models.tsv"
cp "$TMP/old-cache/pi-subagents/models.tsv" "$TMP/models.saved"
printf '{not a catalog\n' >"$TMP/home/.pi/agent/models.json"
ln -s "$ROOT/skills/subagents" "$TMP/linked-skill"
LINKED_PROTOCOL=$(HOME="$TMP/home" "$TMP/linked-skill/subagents" protocol)
node -e 'const p=JSON.parse(process.argv[1]); if(p.packageVersion!=="0.3.2")process.exit(1)' "$LINKED_PROTOCOL"
cat >"$TMP/bin/auth-wrapper" <<WRAPPER
#!/bin/sh
printf '%s\n' wrapped >>"$TMP/wrapper-calls"
exec "\$@"
WRAPPER
chmod +x "$TMP/bin/auth-wrapper"

CONFIG=$(HOME="$TMP/home" SUBAGENTS_STATE_DIR="$TMP/state" SUBAGENTS_PI="$TMP/bin/auth-wrapper pi" \
	SUBAGENTS_WINDOW_NAME=helpers "$CLI" config)
grep -Fqx "launcher=$TMP/bin/auth-wrapper pi" <<<"$CONFIG"
grep -Fqx "state_dir=$TMP/state" <<<"$CONFIG"
grep -Fqx 'window_name=helpers' <<<"$CONFIG"
grep -Fqx 'cleanup_mode=on' <<<"$CONFIG"
grep -Fqx 'cleanup_grace_seconds=600' <<<"$CONFIG"
grep -Fqx 'protocol_id=pi-subagents' <<<"$CONFIG"
grep -Fqx 'package_version=0.3.2' <<<"$CONFIG"
[ "$(wc -l <<<"$CONFIG" | tr -d ' ')" = 7 ]

PROTOCOL=$(HOME="$TMP/home" "$CLI" protocol)
node -e 'const p=JSON.parse(process.argv[1]); if(p.protocolId!=="pi-subagents"||p.packageVersion!=="0.3.2"||p.watcherApiVersion!==1)process.exit(1)' "$PROTOCOL"
HELP=$(HOME="$TMP/home" "$CLI" --help)
grep -Fq 'subagents run [-m MODEL] [--effort LEVEL] <task...>' <<<"$HELP"
grep -Fq 'subagents run [-m MODEL] [--effort LEVEL] --task-file PATH' <<<"$HELP"
grep -Fq 'subagents retain <id>' <<<"$HELP"
grep -Fq 'subagents purge <id|--all>' <<<"$HELP"
if grep -Fq 'subagents models' <<<"$HELP"; then exit 1; fi
for removed_alias in list kill models _refresh-model-cache; do
	if HOME="$TMP/home" SUBAGENTS_STATE_DIR="$TMP/state" "$CLI" "$removed_alias" >"$TMP/$removed_alias.out" 2>"$TMP/$removed_alias.err"; then
		echo "removed command '$removed_alias' unexpectedly succeeded" >&2
		exit 1
	fi
	grep -Fq "unknown command '$removed_alias'" "$TMP/$removed_alias.err"
done
if env -u TMUX -u TMUX_PANE HOME="$TMP/home" SUBAGENTS_STATE_DIR="$TMP/state" "$CLI" run "complete brief" >"$TMP/out" 2>"$TMP/err"; then
	echo "expected run outside tmux to fail" >&2
	exit 1
fi
grep -Fq 'subagents requires tmux' "$TMP/err"

# Neither a direct Pi catalog query nor a launcher catalog query is allowed.
cat >"$TMP/bin/pi" <<FAKE_DIRECT
#!/bin/sh
printf '%s\n' direct >>"$TMP/catalog-calls"
exit 2
FAKE_DIRECT
cat >"$TMP/bin/fake-pi" <<FAKE_PI
#!/bin/sh
if [ "\${1:-}" = "--list-models" ]; then
	printf '%s\n' launcher >>"$TMP/catalog-calls"
	exit 2
fi
last=""
protocol=""
next_is_protocol=0
for arg do
	last="\$arg"
	if [ "\$next_is_protocol" = 1 ]; then protocol="\$arg"; next_is_protocol=0
	elif [ "\$arg" = "--append-system-prompt" ]; then next_is_protocol=1
	fi
done
agent_dir=\$(dirname "\$protocol")
id=\$(basename "\$agent_dir")
printf '%s' "\$last" >"$TMP/pi-task.\$id"
node - "\$@" >"$TMP/pi-args.\$id.json" <<'NODE'
console.log(JSON.stringify({
	args: process.argv.slice(2),
	provider: process.env.PI_PROVIDER ?? "",
	model: process.env.PI_MODEL ?? "",
	effort: process.env.PI_REASONING_LEVEL ?? "",
	session: process.env.PI_SESSION_ID ?? "",
	sessionFile: process.env.PI_SESSION_FILE ?? "",
}));
NODE
# Match Pi's positional @file boundary, including arguments after --.
case "\$last" in
	@*)
		printf '%s\\n' "\${last#@}" >>"$TMP/file-argument-reads"
		cat -- "\${last#@}" >"$TMP/pi-task.\$id"
		exit 4 ;;
esac
case "\${PI_MODEL:-}" in
	invalid-model) echo 'Pi: selected model is unavailable' >&2; exit 2 ;;
	late-invalid) while [ ! -f "$TMP/late-exit" ]; do sleep 0.05; done; exit 2 ;;
esac
case "\$last" in *blocked-smoke*) outcome=blocked ;; *) outcome=completed ;; esac
printf 'completed report for %s\n' "\$last" >"\$agent_dir/report.next.md"
publish_cmd=\$(grep " publish [0-9][0-9]* \$outcome " "\$protocol" | head -1)
[ -n "\$publish_cmd" ] || exit 2
sh -c "\$publish_cmd" || exit 3
sleep 120
FAKE_PI
chmod +x "$TMP/bin/pi" "$TMP/bin/fake-pi"

# Include trailing newlines and shell syntax that must reach Pi as literal text.
TASK_INPUT="$TMP/brief with 'quotes' and \$dollars.md"
cat >"$TASK_INPUT" <<'BRIEF'
- Complete task-file smoke: café, 日本語, 🐢
Preserve "double quotes", 'single quotes', $HOME and ${PI_MODEL}.
Do not run $(touch "$HOME/task-file-executed") or `touch "$HOME/backtick-executed"`.
Backslashes: \\ and \n; wildcard *; ${not_a_variable}; # not a comment


BRIEF
cp "$TASK_INPUT" "$TMP/literal-input.saved"
printf 'This file must not be loaded into the prompt.\n' >"$TMP/at-reference"
printf '@%s' "$TMP/at-reference" >"$TMP/at-file"
{ printf '@'; cat "$TASK_INPUT"; } >"$TMP/at-multiline"
{ printf '\n'; cat "$TMP/at-multiline"; } >"$TMP/newline-at-file"
printf '\000brief' >"$TMP/nul-prefix"
printf 'before\000after' >"$TMP/nul-middle"
printf 'brief\000' >"$TMP/nul-suffix"
printf '\000' >"$TMP/nul-only"
printf 'invalid UTF-8: \377\n' >"$TMP/invalid-utf8"
for input in "$TMP"/at-* "$TMP/newline-at-file" "$TMP"/nul-* "$TMP/invalid-utf8"; do cp "$input" "$input.saved"; done
: >"$TMP/empty-brief"
printf ' \n\t\n' >"$TMP/blank-brief"
printf 'unreadable brief\n' >"$TMP/unreadable-brief"
chmod 000 "$TMP/unreadable-brief"
TASK_INPUT_Q=$(printf %q "$TASK_INPUT")

cat >"$TMP/tmux-smoke" <<TMUX_SMOKE
#!/usr/bin/env bash
set -euo pipefail
export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
export XDG_CACHE_HOME="$TMP/cache"
export SUBAGENTS_STATE_DIR="$TMP/state"
export SUBAGENTS_PI="$TMP/bin/auth-wrapper $TMP/bin/fake-pi"
export SUBAGENTS_WINDOW_NAME=helpers
export PI_PROVIDER=lead-provider
export PI_MODEL=lead-model
export PI_REASONING_LEVEL=medium
export PI_SESSION_ID=stale-session
export PI_SESSION_FILE=stale-session-file
task_input=$TASK_INPUT_Q
cd "$ROOT"

reject() {
	local label="\$1"; shift
	local before after
	before=\$(tmux list-panes -a -F '#{pane_id}' | sort)
	if "\$@" >"$TMP/reject.\$label.out" 2>"$TMP/reject.\$label.err"; then
		echo "unexpected success: \$label" >&2; exit 1
	fi
	after=\$(tmux list-panes -a -F '#{pane_id}' | sort)
	[ "\$before" = "\$after" ]
	[ -z "\$(find "$TMP/state" -mindepth 1 -print -quit)" ]
	[ ! -e "$TMP/wrapper-calls" ]
}
reject no-task "$CLI" run
reject missing-path "$CLI" run --task-file
reject empty-path "$CLI" run --task-file ''
reject absent-file "$CLI" run --task-file "$TMP/absent-brief"
reject directory "$CLI" run --task-file "$TMP/home"
reject empty-file "$CLI" run --task-file "$TMP/empty-brief"
reject blank-file "$CLI" run --task-file "$TMP/blank-brief"
reject unreadable-file "$CLI" run --task-file "$TMP/unreadable-brief"
for input in nul-prefix nul-middle nul-suffix nul-only invalid-utf8; do
	reject "\$input" "$CLI" run --task-file "$TMP/\$input"
done
reject conflict "$CLI" run --task-file "\$task_input" 'positional brief'
reject empty-conflict "$CLI" run --task-file "\$task_input" ''
reject reverse-conflict "$CLI" run 'positional brief' --task-file "\$task_input"
reject duplicate "$CLI" run --task-file "\$task_input" --task-file "\$task_input"
reject model "$CLI" run -m unqualified 'invalid model'
reject provider "$CLI" run -m /model 'empty provider'
reject model-id "$CLI" run -m provider/ 'empty model'
reject effort "$CLI" run --effort bogus 'invalid effort'
reject inherited-model env -u PI_MODEL "$CLI" run 'incomplete inheritance'
reject inherited-effort env PI_REASONING_LEVEL=bogus "$CLI" run 'invalid inherited effort'
reject launcher env SUBAGENTS_PI="$TMP/bin/missing-pi" "$CLI" run 'launcher missing'

"$CLI" run 'Inspect, implement, verify, and report for inherit-smoke' >"$TMP/run-inherit.out" 2>"$TMP/run-inherit.err"
"$CLI" run --model example-provider/example-model --effort high 'Implement and verify override-smoke' >"$TMP/run-override.out" 2>"$TMP/run-override.err"
"$CLI" run --model example-provider/no-effort 'Investigate and request input for blocked-smoke' >"$TMP/run-blocked.out" 2>"$TMP/run-blocked.err"
"$CLI" run --effort max --task-file "\$task_input" >"$TMP/run-file.out" 2>"$TMP/run-file.err"
env -u PI_PROVIDER -u PI_MODEL -u PI_REASONING_LEVEL "$CLI" run -- '--task-file is literal after --' >"$TMP/run-default.out" 2>"$TMP/run-default.err"
XDG_CACHE_HOME="$TMP/old-cache" "$CLI" run -m custom-provider/model/with/slashes 'Custom model smoke' >"$TMP/run-custom.out" 2>"$TMP/run-custom.err"
"$CLI" doctor >"$TMP/doctor.out" 2>"$TMP/doctor.err"
"$CLI" wait 1 10 >"$TMP/wait.out" 2>"$TMP/wait.err"
"$CLI" events >"$TMP/events.out" 2>"$TMP/events.err"
"$CLI" reap >"$TMP/reap.out" 2>"$TMP/reap.err"
"$CLI" status >"$TMP/status-before.out" 2>"$TMP/status-before.err"
"$CLI" ls >"$TMP/ls.out" 2>"$TMP/ls.err"
"$CLI" peek 1 10 >"$TMP/peek.out" 2>"$TMP/peek.err"
"$CLI" retain 2 >"$TMP/retain.out" 2>"$TMP/retain.err"
"$CLI" release 2 >"$TMP/release.out" 2>"$TMP/release.err"
"$CLI" tell 1 'Follow-up smoke message' >"$TMP/tell.out" 2>"$TMP/tell.err"
"$CLI" stop 2 >"$TMP/stop.out" 2>"$TMP/stop.err"
"$CLI" purge 2 >"$TMP/purge.out" 2>"$TMP/purge.err"

# Pi may reject a model after pane creation, either during or after startup.
if "$CLI" run -m invalid-provider/invalid-model 'Pi rejects this selection' >"$TMP/run-invalid.out" 2>"$TMP/run-invalid.err"; then exit 1; fi
"$CLI" run -m invalid-provider/late-invalid 'Pi exits later' >"$TMP/run-late.out" 2>"$TMP/run-late.err"
root=\$(find "$TMP/state" -mindepth 1 -maxdepth 1 -type d -print -quit)
touch "$TMP/late-exit"
pane=\$(cat "\$root/8/pane")
for poll in {1..100}; do
	if ! tmux list-panes -a -F '#{pane_id} #{pane_dead}' | grep -Fqx "\$pane 0"; then break; fi
	sleep 0.05
done
"$CLI" events >"$TMP/events-exit.out" 2>"$TMP/events-exit.err"
[ -s "\$root/7/task" ]
[ -s "\$root/7/protocol.md" ]
[ "\$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).state)' "\$root/7/lifecycle.json")" = stopped ]
[ "\$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).state)' "\$root/8/lifecycle.json")" = exited ]
# Escape only an initial @, for both input modes. Keep the source bytes intact.
"$CLI" run --task-file "$TMP/at-file" >"$TMP/run-at-file.out" 2>"$TMP/run-at-file.err"
"$CLI" run --task-file "$TMP/at-multiline" >"$TMP/run-at-multiline.out" 2>"$TMP/run-at-multiline.err"
at_task=\$(cat "$TMP/at-multiline"; printf '.')
at_task=\${at_task%.}
"$CLI" run "\$at_task" >"$TMP/run-at-positional.out" 2>"$TMP/run-at-positional.err"
"$CLI" run --task-file "$TMP/newline-at-file" >"$TMP/run-newline-at.out" 2>"$TMP/run-newline-at.err"
"$CLI" run "@$TMP/at-reference" >"$TMP/run-at-reference.out" 2>"$TMP/run-at-reference.err"
for id in 1 3 4 5 6 9 10 11 12 13; do "$CLI" stop "\$id" >"$TMP/stop\$id.out" 2>"$TMP/stop\$id.err"; done
echo 0 >"$TMP/run.rc"
TMUX_SMOKE
chmod +x "$TMP/tmux-smoke"
tmux -L "$SOCKET" new-session -d -s smoke "$TMP/tmux-smoke"
for _ in {1..600}; do
	[ -f "$TMP/run.rc" ] && break
	if ! tmux -L "$SOCKET" has-session -t smoke 2>/dev/null; then break; fi
	sleep 0.1
done
if [ "$(cat "$TMP/run.rc" 2>/dev/null || true)" != 0 ]; then
	for error in "$TMP"/*.err; do [ -s "$error" ] && { echo "=== $error ===" >&2; tail -100 "$error" >&2; }; done
	exit 1
fi

grep -Fq 'model lead-provider/lead-model, effort medium' "$TMP/run-inherit.out"
grep -Fq 'model example-provider/example-model, effort high' "$TMP/run-override.out"
grep -Fq 'model example-provider/no-effort' "$TMP/run-blocked.out"
grep -Fq 'model lead-provider/lead-model, effort max' "$TMP/run-file.out"
grep -Fq 'model launcher default' "$TMP/run-default.out"
grep -Fq 'model custom-provider/model/with/slashes' "$TMP/run-custom.out"
grep -Fq 'worker launcher exited during startup for subagent #7 (model invalid-provider/invalid-model)' "$TMP/run-invalid.err"
grep -Fq "Check Pi's model/auth configuration and SUBAGENTS_PI" "$TMP/run-invalid.err"
grep -Fq 'state preserved at ' "$TMP/run-invalid.err"
grep -Eq '^8[[:space:]]+exited[[:space:]]+' "$TMP/events-exit.out"
grep -Fq 'needs a path' "$TMP/reject.missing-path.err" "$TMP/reject.empty-path.err"
for reason in absent-file directory unreadable-file; do grep -Fq 'missing or unreadable' "$TMP/reject.$reason.err"; done
for reason in empty-file blank-file; do grep -Fq 'task file is empty' "$TMP/reject.$reason.err"; done
for reason in nul-prefix nul-middle nul-suffix nul-only; do grep -Fq 'NUL bytes are not supported' "$TMP/reject.$reason.err"; done
grep -Fq 'could not read task file as UTF-8 text' "$TMP/reject.invalid-utf8.err"
for reason in conflict empty-conflict reverse-conflict; do grep -Fq 'cannot combine a positional task with --task-file' "$TMP/reject.$reason.err"; done
grep -Fq 'may only be supplied once' "$TMP/reject.duplicate.err"
grep -Fq 'is not provider-qualified' "$TMP/reject.model.err"
grep -Fq 'invalid effort' "$TMP/reject.effort.err"
grep -Fq 'inheritance is incomplete' "$TMP/reject.inherited-model.err"
grep -Fq 'PI_REASONING_LEVEL' "$TMP/reject.inherited-effort.err"
grep -Fq 'doctor preflight failed: launcher command not found' "$TMP/reject.launcher.err"
grep -Fqx 'doctor: healthy' "$TMP/doctor.out"
grep -Fq '=== subagent #1 report (done) ===' "$TMP/wait.out"
grep -Fq 'completed report for Inspect' "$TMP/wait.out"
[ ! -s "$TMP/events.out" ]
grep -Fq '=== subagent #2 — done ===' "$TMP/reap.out"
grep -Fq '=== subagent #3 — blocked ===' "$TMP/reap.out"
grep -Eq '^#1[[:space:]]+awaiting-follow-up[[:space:]]+pane=alive' "$TMP/status-before.out"
grep -Eq '^#2[[:space:]]+awaiting-follow-up[[:space:]]+pane=alive' "$TMP/status-before.out"
grep -Eq '^#3[[:space:]]+blocked[[:space:]]+pane=alive' "$TMP/status-before.out"
if grep -Fq 'Inspect, implement' "$TMP/status-before.out" "$TMP/ls.out"; then echo 'status leaked task text' >&2; exit 1; fi
[ -s "$TMP/peek.out" ]
grep -Fqx 'retained subagent #2; cleanup cancelled' "$TMP/retain.out"
grep -Fqx 'released subagent #2; normal cleanup grace applies' "$TMP/release.out"
grep -Fqx 'sent to subagent #1 (generation 2; cleanup cancelled)' "$TMP/tell.out"
grep -Fqx 'stopped subagent #2; reports and delivery state preserved' "$TMP/stop.out"
if grep -Fq purge "$TMP"/stop*.out; then echo 'stop suggested purge' >&2; exit 1; fi
grep -Fqx 'purged subagent #2 after report acknowledgement' "$TMP/purge.out"
[ ! -e "$TMP/catalog-calls" ]
[ ! -e "$TMP/file-argument-reads" ]
[ ! -e "$TMP/cache" ]
[ "$(wc -l <"$TMP/wrapper-calls" | tr -d ' ')" = 13 ]
cmp "$TMP/models.saved" "$TMP/old-cache/pi-subagents/models.tsv"
[ "$(find "$TMP/old-cache" -type f | wc -l | tr -d ' ')" = 1 ]
[ ! -e "$TMP/home/task-file-executed" ]
[ ! -e "$TMP/home/backtick-executed" ]

TASK_FILE=$(find "$TMP/state" -type f -path '*/1/task' -print -quit)
[ -n "$TASK_FILE" ]
AGENT_DIR=${TASK_FILE%/task}
SESSION_ROOT=${AGENT_DIR%/1}
grep -Fqx 'Inspect, implement, verify, and report for inherit-smoke' "$AGENT_DIR/task"
cmp "$TMP/literal-input.saved" "$TASK_INPUT"
cmp "$TASK_INPUT" "$SESSION_ROOT/4/task"
cmp "$TASK_INPUT" "$TMP/pi-task.4"
for saved in "$TMP"/at-*.saved "$TMP/newline-at-file.saved" "$TMP"/nul-*.saved "$TMP/invalid-utf8.saved"; do cmp "$saved" "${saved%.saved}"; done
node - "$TMP" "$SESSION_ROOT" <<'NODE'
const fs = require("node:fs");
const assert = require("node:assert/strict");
const [tmp, root] = process.argv.slice(2);
const read = (path) => fs.readFileSync(path);
const newline = Buffer.from("\n");
for (const [id, fixture, positional, escaped] of [
	[9, "at-file", false, true],
	[10, "at-multiline", false, true],
	[11, "at-multiline", true, true],
	[12, "newline-at-file", false, false],
	[13, "at-file", true, true],
]) {
	const original = read(`${tmp}/${fixture}.saved`);
	const prompt = read(`${tmp}/pi-task.${id}`);
	assert.deepEqual(prompt, escaped ? Buffer.concat([newline, original]) : original);
	// Positional task storage retains its existing trailing newline convention.
	assert.deepEqual(read(`${root}/${id}/task`), positional ? Buffer.concat([original, newline]) : original);
	assert.equal(prompt.toString("utf8").startsWith("@"), false);
	assert.equal(prompt.includes(read(`${tmp}/at-reference.saved`)), false);
}
assert.equal(read(`${tmp}/pi-task.1`).toString("utf8"), "Inspect, implement, verify, and report for inherit-smoke");
NODE
grep -Fq 'Keep routine reports to 25 lines or fewer' "$AGENT_DIR/protocol.md"
grep -Fq 'what changed, checks run with results, and artifact paths' "$AGENT_DIR/protocol.md"
grep -Fq 'publish 1 completed' "$AGENT_DIR/protocol.md"
grep -Fq 'publish 1 blocked' "$AGENT_DIR/protocol.md"
if grep -Fq '@@DONE@@' "$SESSION_ROOT"/*/protocol.md; then echo 'new protocol contains the retired sentinel' >&2; exit 1; fi
for state_file in pane protocol.md result.md task lifecycle.json; do [ -e "$AGENT_DIR/$state_file" ]; done

ARCHIVED_EVENT=$(find "$TMP/state" -type f -path '*/1/events/*.json' -print -quit)
[ -n "$ARCHIVED_EVENT" ]
node - "$ARCHIVED_EVENT" "$TMP" <<'NODE'
const fs = require("node:fs");
const assert = require("node:assert/strict");
const event = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
assert.equal(event.protocolId, "pi-subagents");
assert.equal(event.packageVersion, "0.3.2");
assert.equal(event.schemaVersion, 1);
assert.equal(event.id, "1");
assert.equal(event.generation, 1);
assert.equal(event.status, "done");
assert.equal(event.outcome, "completed");
assert.match(event.reportBody, /completed report/);
const selections = [
	["lead-provider", "lead-model", "medium"],
	["example-provider", "example-model", "high"],
	["example-provider", "no-effort", ""],
	["lead-provider", "lead-model", "max"],
	["", "", ""],
	["custom-provider", "model/with/slashes", ""],
	["invalid-provider", "invalid-model", ""],
	["invalid-provider", "late-invalid", ""],
	["lead-provider", "lead-model", "medium"],
	["lead-provider", "lead-model", "medium"],
	["lead-provider", "lead-model", "medium"],
	["lead-provider", "lead-model", "medium"],
	["lead-provider", "lead-model", "medium"],
];
for (const [index, [provider, model, effort]] of selections.entries()) {
	const launch = JSON.parse(fs.readFileSync(`${process.argv[3]}/pi-args.${index + 1}.json`, "utf8"));
	assert.equal(launch.provider, provider);
	assert.equal(launch.model, model);
	assert.equal(launch.effort, effort);
	assert.equal(launch.session, "");
	assert.equal(launch.sessionFile, "");
	for (const flag of ["--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-session", "--append-system-prompt", "--"]) {
		assert.equal(launch.args.filter((arg) => arg === flag).length, 1);
	}
	const value = (flag) => launch.args.includes(flag) ? launch.args[launch.args.indexOf(flag) + 1] : "";
	assert.equal(value("--model"), model ? `${provider}/${model}` : "");
	assert.equal(value("--thinking"), effort);
}
NODE

# Optional integration check: supply an installed Pi cli/args.js module, without
# requiring Pi or an SDK dependency for the portable suite.
if [ -n "${SUBAGENTS_TEST_PI_ARGS_MODULE:-}" ]; then
	node --input-type=module - "$SUBAGENTS_TEST_PI_ARGS_MODULE" "$TMP" <<'NODE'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const [modulePath, tmp] = process.argv.slice(2);
const { parseArgs } = await import(pathToFileURL(modulePath).href);
assert.equal(typeof parseArgs, "function");
const control = parseArgs(["--", "@must-not-be-loaded"]);
assert.deepEqual(control.messages, []);
assert.deepEqual(control.fileArgs, ["must-not-be-loaded"]);
for (let id = 1; id <= 13; id += 1) {
	const { args } = JSON.parse(readFileSync(`${tmp}/pi-args.${id}.json`, "utf8"));
	const parsed = parseArgs(args);
	assert.deepEqual(parsed.fileArgs, [], `worker ${id} must not load a file argument`);
	assert.deepEqual(parsed.messages, [readFileSync(`${tmp}/pi-task.${id}`, "utf8")]);
	assert.deepEqual(parsed.diagnostics, []);
	assert.equal(parsed.unknownFlags.size, 0);
}
console.log("installed Pi parseArgs: ok (13 launch argv sets and leading-@ control)");
NODE
fi

echo "cli smoke: ok"
