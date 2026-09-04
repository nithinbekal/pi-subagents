#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/skills/subagents/subagents"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pi-subagents-cli.XXXXXX")
SOCKET="pi-subagents-test-$$"
trap 'tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home/.pi/agent" "$TMP/state" "$TMP/bin"
cat >"$TMP/home/.pi/agent/models.json" <<'MODELS_JSON'
{
  "providers": {
    "custom-provider": {
      "models": [{ "id": "custom-model" }]
    }
  }
}
MODELS_JSON
ln -s "$ROOT/skills/subagents" "$TMP/linked-skill"
LINKED_PROTOCOL=$(HOME="$TMP/home" "$TMP/linked-skill/subagents" protocol)
node -e 'const p=JSON.parse(process.argv[1]); if(p.packageVersion!=="0.3.2")process.exit(1)' "$LINKED_PROTOCOL"
cat >"$TMP/bin/auth-wrapper" <<'WRAPPER'
#!/bin/sh
exec "$@"
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
grep -Fq 'subagents models [--refresh]' <<<"$HELP"
grep -Fq 'subagents retain <id>' <<<"$HELP"
grep -Fq 'subagents purge <id|--all>' <<<"$HELP"
for removed_alias in list kill; do
	if HOME="$TMP/home" SUBAGENTS_STATE_DIR="$TMP/state" "$CLI" "$removed_alias" >"$TMP/$removed_alias.out" 2>"$TMP/$removed_alias.err"; then
		echo "removed alias '$removed_alias' unexpectedly succeeded" >&2
		exit 1
	fi
	grep -Fq "unknown command '$removed_alias'" "$TMP/$removed_alias.err"
done
if env -u TMUX -u TMUX_PANE HOME="$TMP/home" SUBAGENTS_STATE_DIR="$TMP/state" "$CLI" run "complete brief" >"$TMP/out" 2>"$TMP/err"; then
	echo "expected run outside tmux to fail" >&2
	exit 1
fi
grep -Fq 'subagents requires tmux' "$TMP/err"

cat >"$TMP/bin/pi" <<FAKE_CATALOG
#!/bin/sh
printf '%s\n' direct >>"$TMP/catalog-calls"
[ "\${FAKE_PI_CATALOG_UNAVAILABLE:-}" != 1 ] || exit 2
printf '%s\n' \
	'provider model context max-out thinking images' \
	'lead-provider lead-model 1M 128K yes yes' \
	'example-provider example-model 1M 128K yes yes' \
	'example-provider no-effort 1M 128K yes yes' \
	'anthropic claude-fable-5-1 1M 128K yes yes'
FAKE_CATALOG
chmod +x "$TMP/bin/pi"

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
case "\$last" in
	*inherit-smoke*) out="$TMP/pi-args.inherit"; outcome=completed ;;
	*override-smoke*) out="$TMP/pi-args.override"; outcome=completed ;;
	*blocked-smoke*) out="$TMP/pi-args.blocked"; outcome=blocked ;;
	*) out="$TMP/pi-args.unknown"; outcome=completed ;;
esac
{
	printf 'PI_PROVIDER=%s\n' "\${PI_PROVIDER:-}"
	printf 'PI_MODEL=%s\n' "\${PI_MODEL:-}"
	printf 'PI_REASONING_LEVEL=%s\n' "\${PI_REASONING_LEVEL:-}"
	printf '%s\n' "\$@"
} >"\$out"
agent_dir=\$(dirname "\$protocol")
printf 'completed report for %s\n' "\$last" >"\$agent_dir/report.next.md"
publish_cmd=\$(grep " publish [0-9][0-9]* \$outcome " "\$protocol" | head -1)
[ -n "\$publish_cmd" ] || exit 2
sh -c "\$publish_cmd" || exit 3
printf '%s\n' '@@DONE@@'
sleep 30
FAKE_PI
chmod +x "$TMP/bin/fake-pi"

MODELS=$(PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_CACHE_HOME="$TMP/cache" SUBAGENTS_PI="$TMP/bin/fake-pi" "$CLI" models --refresh)
grep -Fqx $'provider\tmodel' <<<"$MODELS"
grep -Fqx $'anthropic\tclaude-fable-5-1' <<<"$MODELS"
grep -Fqx $'custom-provider\tcustom-model' <<<"$MODELS"
grep -Fqx direct "$TMP/catalog-calls"
if grep -Fqx launcher "$TMP/catalog-calls"; then echo 'launcher wrapper was used despite pi on PATH' >&2; exit 1; fi
CACHED_MODELS=$(PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_CACHE_HOME="$TMP/cache" FAKE_PI_CATALOG_UNAVAILABLE=1 "$CLI" models)
grep -Fqx $'anthropic\tclaude-fable-5-1' <<<"$CACHED_MODELS"

mkdir -p "$TMP/no-pi-bin"
for dependency in bash node dirname stat date; do ln -s "$(command -v "$dependency")" "$TMP/no-pi-bin/$dependency"; done
cat >"$TMP/bin/fallback-pi" <<FAKE_FALLBACK
#!/bin/sh
printf '%s\n' fallback >"$TMP/fallback-call"
printf '%s\n' \
	'provider model context max-out thinking images' \
	'fallback-provider fallback-model 1M 128K yes yes'
FAKE_FALLBACK
chmod +x "$TMP/bin/fallback-pi"
FALLBACK_MODELS=$(PATH="$TMP/no-pi-bin" HOME="$TMP/home" XDG_CACHE_HOME="$TMP/fallback-cache" SUBAGENTS_PI="$TMP/bin/fallback-pi" "$CLI" models --refresh)
grep -Fqx $'fallback-provider\tfallback-model' <<<"$FALLBACK_MODELS"
grep -Fqx fallback "$TMP/fallback-call"

cat >"$TMP/tmux-smoke" <<TMUX_SMOKE
#!/bin/sh
set -eu
export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
export XDG_CACHE_HOME="$TMP/cache"
export SUBAGENTS_STATE_DIR="$TMP/state"
export SUBAGENTS_PI="$TMP/bin/fake-pi"
export SUBAGENTS_WINDOW_NAME=helpers
export PI_PROVIDER=lead-provider
export PI_MODEL=lead-model
export PI_REASONING_LEVEL=medium
cd "$ROOT"
"$CLI" run "Inspect, implement, verify, and report for inherit-smoke" >"$TMP/run-inherit.out" 2>"$TMP/run-inherit.err"
"$CLI" run --model example-provider/example-model --effort high "Implement and verify override-smoke" >"$TMP/run-override.out" 2>"$TMP/run-override.err"
"$CLI" run --model example-provider/no-effort "Investigate and request input for blocked-smoke" >"$TMP/run-blocked.out" 2>"$TMP/run-blocked.err"
if "$CLI" run -m unqualified "invalid model" >"$TMP/run-invalid.out" 2>"$TMP/run-invalid.err"; then exit 1; fi
if "$CLI" run -m openai/gpt-5.6-fable "unknown qualified model" >"$TMP/run-unknown-model.out" 2>"$TMP/run-unknown-model.err"; then exit 1; fi
"$CLI" doctor >"$TMP/doctor.out" 2>"$TMP/doctor.err"
if SUBAGENTS_PI="$TMP/bin/missing-pi" "$CLI" run "launcher failure must be surfaced" >"$TMP/run-launch-fail.out" 2>"$TMP/run-launch-fail.err"; then exit 1; fi
grep -Fq 'doctor preflight failed: launcher command not found' "$TMP/run-launch-fail.err"
panes_before=\$(tmux list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')
if XDG_CACHE_HOME="$TMP/unavailable-explicit-cache" FAKE_PI_CATALOG_UNAVAILABLE=1 "$CLI" run -m openai/gpt-5.6-fable "must reject without a catalog" >"$TMP/run-catalog-explicit.out" 2>"$TMP/run-catalog-explicit.err"; then exit 1; fi
panes_after=\$(tmux list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')
[ "\$panes_before" = "\$panes_after" ]
XDG_CACHE_HOME="$TMP/unavailable-custom-cache" FAKE_PI_CATALOG_UNAVAILABLE=1 "$CLI" run -m custom-provider/custom-model "custom model smoke" >"$TMP/run-custom-model.out" 2>"$TMP/run-custom-model.err"
XDG_CACHE_HOME="$TMP/unavailable-inherited-cache" FAKE_PI_CATALOG_UNAVAILABLE=1 "$CLI" run "Catalog unavailable warning-smoke" >"$TMP/run-catalog-warning.out" 2>"$TMP/run-catalog-warning.err"
"$CLI" wait 1 10 >"$TMP/wait.out" 2>"$TMP/wait.err"
"$CLI" events >"$TMP/events.out" 2>"$TMP/events.err"
"$CLI" reap >"$TMP/reap.out" 2>"$TMP/reap.err"
"$CLI" status >"$TMP/status-before.out" 2>"$TMP/status-before.err"
"$CLI" ls >"$TMP/ls.out" 2>"$TMP/ls.err"
"$CLI" peek 1 10 >"$TMP/peek.out" 2>"$TMP/peek.err"
"$CLI" retain 2 >"$TMP/retain.out" 2>"$TMP/retain.err"
"$CLI" release 2 >"$TMP/release.out" 2>"$TMP/release.err"
"$CLI" tell 1 "Follow-up smoke message" >"$TMP/tell.out" 2>"$TMP/tell.err"
"$CLI" stop 2 >"$TMP/stop.out" 2>"$TMP/stop.err"
"$CLI" purge 2 >"$TMP/purge.out" 2>"$TMP/purge.err"
"$CLI" stop 1 >"$TMP/stop1.out" 2>"$TMP/stop1.err"
"$CLI" stop 3 >"$TMP/stop3.out" 2>"$TMP/stop3.err"
"$CLI" stop 4 >"$TMP/stop4.out" 2>"$TMP/stop4.err"
"$CLI" stop 5 >"$TMP/stop5.out" 2>"$TMP/stop5.err"
echo 0 >"$TMP/run.rc"
TMUX_SMOKE
chmod +x "$TMP/tmux-smoke"
tmux -L "$SOCKET" new-session -d -s smoke "$TMP/tmux-smoke"
for _ in {1..300}; do
	[ -f "$TMP/run.rc" ] && break
	if ! tmux -L "$SOCKET" has-session -t smoke 2>/dev/null; then break; fi
	sleep 0.1
done
if [ "$(cat "$TMP/run.rc" 2>/dev/null || true)" != 0 ]; then
	for error in "$TMP"/*.err; do [ -s "$error" ] && { echo "=== $error ===" >&2; tail -100 "$error" >&2; }; done
	exit 1
fi

grep -Fq 'started subagent #1 —' "$TMP/run-inherit.out"
grep -Fq 'model lead-provider/lead-model, effort medium' "$TMP/run-inherit.out"
grep -Fq 'model example-provider/example-model, effort high' "$TMP/run-override.out"
grep -Fq 'model example-provider/no-effort' "$TMP/run-blocked.out"
grep -Fq "model 'unqualified' is not provider-qualified" "$TMP/run-invalid.err"
grep -Fq "model 'openai/gpt-5.6-fable' was not found in Pi's model catalog" "$TMP/run-unknown-model.err"
grep -Fq 'Closest matches: anthropic/claude-fable-5-1' "$TMP/run-unknown-model.err"
grep -Fq 'doctor preflight failed: launcher command not found' "$TMP/run-launch-fail.err"
grep -Fq "could not validate explicit model 'openai/gpt-5.6-fable' because Pi's model catalog is unavailable" "$TMP/run-catalog-explicit.err"
grep -Fq "subagents models --refresh" "$TMP/run-catalog-explicit.err"
grep -Fq "Pi model catalog unavailable; continuing with inherited model 'lead-provider/lead-model'" "$TMP/run-catalog-warning.err"
grep -Fq 'model custom-provider/custom-model' "$TMP/run-custom-model.out"
grep -Fq 'started subagent #5' "$TMP/run-catalog-warning.out"
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
grep -Eq '^sent to subagent #1 \(generation 2; cleanup cancelled\)$' "$TMP/tell.out"
grep -Fqx 'stopped subagent #2; reports and delivery state preserved (use purge after acknowledgement)' "$TMP/stop.out"
grep -Fqx 'purged subagent #2 after report acknowledgement' "$TMP/purge.out"

TASK_FILE=$(find "$TMP/state" -type f -path '*/1/task' -print -quit)
[ -n "$TASK_FILE" ]
AGENT_DIR=${TASK_FILE%/task}
grep -Fqx 'Inspect, implement, verify, and report for inherit-smoke' "$AGENT_DIR/task"
grep -Fq 'complete' "$AGENT_DIR/protocol.md"
grep -Fq 'Keep routine reports to 25 lines or fewer' "$AGENT_DIR/protocol.md"
grep -Fq 'what changed, checks run with results, and artifact paths' "$AGENT_DIR/protocol.md"
grep -Fq 'publish 1 completed' "$AGENT_DIR/protocol.md"
grep -Fq 'publish 1 blocked' "$AGENT_DIR/protocol.md"
grep -Fq '@@DONE@@' "$AGENT_DIR/protocol.md"
for state_file in pane protocol.md result.md task lifecycle.json; do [ -e "$AGENT_DIR/$state_file" ]; done

ARCHIVED_EVENT=$(find "$TMP/state" -type f -path '*/1/events/*.json' -print -quit)
[ -n "$ARCHIVED_EVENT" ]
node - "$ARCHIVED_EVENT" <<'NODE'
const fs = require("node:fs");
const event = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (event.protocolId !== "pi-subagents" || event.packageVersion !== "0.3.2" || event.schemaVersion !== 1) process.exit(1);
if (event.id !== "1" || event.generation !== 1 || event.status !== "done" || event.outcome !== "completed") process.exit(1);
if (!event.reportBody.includes("completed report")) process.exit(1);
NODE

for args in "$TMP/pi-args.inherit" "$TMP/pi-args.override" "$TMP/pi-args.blocked"; do
	grep -Fqx -- '--no-extensions' "$args"
	grep -Fqx -- '--no-skills' "$args"
	grep -Fqx -- '--no-prompt-templates' "$args"
	grep -Fqx -- '--no-context-files' "$args"
	grep -Fqx -- '--no-session' "$args"
	[ "$(grep -Fxc -- '--append-system-prompt' "$args")" = 1 ]
done
grep -Fqx 'PI_PROVIDER=lead-provider' "$TMP/pi-args.inherit"
grep -Fqx 'PI_MODEL=lead-model' "$TMP/pi-args.inherit"
grep -Fqx 'PI_REASONING_LEVEL=medium' "$TMP/pi-args.inherit"
grep -Fqx 'lead-provider/lead-model' "$TMP/pi-args.inherit"
grep -Fqx 'medium' "$TMP/pi-args.inherit"
grep -Fqx 'PI_PROVIDER=example-provider' "$TMP/pi-args.override"
grep -Fqx 'PI_MODEL=example-model' "$TMP/pi-args.override"
grep -Fqx 'PI_REASONING_LEVEL=high' "$TMP/pi-args.override"
grep -Fqx 'example-provider/example-model' "$TMP/pi-args.override"
grep -Fqx 'high' "$TMP/pi-args.override"
grep -Fqx 'PI_PROVIDER=example-provider' "$TMP/pi-args.blocked"
grep -Fqx 'PI_MODEL=no-effort' "$TMP/pi-args.blocked"
grep -Fqx 'PI_REASONING_LEVEL=' "$TMP/pi-args.blocked"
if grep -Fqx -- '--thinking' "$TMP/pi-args.blocked"; then echo 'explicit model inherited effort unexpectedly' >&2; exit 1; fi

echo "cli smoke: ok"
