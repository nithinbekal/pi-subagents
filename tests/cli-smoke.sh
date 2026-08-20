#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/skills/subagents/subagents"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pi-subagents-cli.XXXXXX")
SOCKET="pi-subagents-test-$$"
trap 'tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home" "$TMP/state" "$TMP/bin"
cat >"$TMP/bin/auth-wrapper" <<'WRAPPER'
#!/bin/sh
exec "$@"
WRAPPER
chmod +x "$TMP/bin/auth-wrapper"

CONFIG=$(
	HOME="$TMP/home" \
	SUBAGENTS_STATE_DIR="$TMP/state" \
	SUBAGENTS_PI="$TMP/bin/auth-wrapper pi" \
	SUBAGENTS_WINDOW_NAME="helpers" \
	"$CLI" config
)

grep -Fqx "launcher=$TMP/bin/auth-wrapper pi" <<<"$CONFIG"
grep -Fqx "state_dir=$TMP/state" <<<"$CONFIG"
grep -Fqx "window_name=helpers" <<<"$CONFIG"
[ "$(wc -l <<<"$CONFIG" | tr -d ' ')" = 3 ]

HELP=$(HOME="$TMP/home" SUBAGENTS_STATE_DIR="$TMP/state" "$CLI" --help)
grep -Fq 'subagents config' <<<"$HELP"
grep -Fq 'subagents run [-m MODEL] [--effort LEVEL] <task...>' <<<"$HELP"
if grep -Eq 'subagents (list|kill)([[:space:]]|$)' <<<"$HELP"; then
	echo "help exposed a removed command alias" >&2
	exit 1
fi
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

cat >"$TMP/bin/fake-pi" <<FAKE_PI
#!/bin/sh
last=""
protocol=""
next_is_protocol=0
for arg do
	last="\$arg"
	if [ "\$next_is_protocol" = 1 ]; then
		protocol="\$arg"
		next_is_protocol=0
	elif [ "\$arg" = "--append-system-prompt" ]; then
		next_is_protocol=1
	fi
done
case "\$last" in
	*inherit-smoke*) out="$TMP/pi-args.inherit" ;;
	*override-smoke*) out="$TMP/pi-args.override" ;;
	*) out="$TMP/pi-args.unknown" ;;
esac
printf '%s\n' "\$@" >"\$out"
result=\$(grep '/result\.md\$' "\$protocol" | head -1 | sed 's/^[[:space:]]*//')
printf 'completed report for %s\n' "\$last" >"\$result"
printf '%s\n' '@@DONE@@'
sleep 10
FAKE_PI
chmod +x "$TMP/bin/fake-pi"
cat >"$TMP/tmux-smoke" <<TMUX_SMOKE
#!/bin/sh
export HOME="$TMP/home"
export SUBAGENTS_STATE_DIR="$TMP/state"
export SUBAGENTS_PI="$TMP/bin/fake-pi"
export SUBAGENTS_WINDOW_NAME="helpers"
cd "$ROOT"
"$CLI" run "Inspect the target, implement safely, verify, and report for inherit-smoke" >"$TMP/run-inherit.out" 2>"$TMP/run-inherit.err" || exit 1
"$CLI" run --model example-provider/example-model --effort high "Implement and verify the complete brief for override-smoke" >"$TMP/run-override.out" 2>"$TMP/run-override.err" || exit 1
if "$CLI" run -m unqualified "invalid model must fail" >"$TMP/run-invalid.out" 2>"$TMP/run-invalid.err"; then
	exit 1
fi
"$CLI" doctor >"$TMP/doctor.out" 2>"$TMP/doctor.err" || exit 1
"$CLI" wait 1 10 >"$TMP/wait.out" 2>"$TMP/wait.err" || exit 1
for _ in 1 2 3 4 5; do
	result=\$(find "$TMP/state" -type f -path '*/2/result.md' -print -quit)
	[ -n "\$result" ] && [ -s "\$result" ] && break
	sleep 0.1
done
"$CLI" events >"$TMP/events.out" 2>"$TMP/events.err" || exit 1
"$CLI" reap >"$TMP/reap.out" 2>"$TMP/reap.err" || exit 1
"$CLI" status >"$TMP/status.out" 2>"$TMP/status.err" || exit 1
"$CLI" ls >"$TMP/ls.out" 2>"$TMP/ls.err" || exit 1
"$CLI" peek 1 10 >"$TMP/peek.out" 2>"$TMP/peek.err" || exit 1
"$CLI" tell 1 "Follow-up smoke message" >"$TMP/tell.out" 2>"$TMP/tell.err" || exit 1
"$CLI" stop 2 >"$TMP/stop.out" 2>"$TMP/stop.err" || exit 1
echo 0 >"$TMP/run.rc"
TMUX_SMOKE
chmod +x "$TMP/tmux-smoke"
tmux -L "$SOCKET" new-session -d -s smoke "$TMP/tmux-smoke"
for _ in {1..100}; do
	[ -f "$TMP/run.rc" ] && [ -f "$TMP/pi-args.inherit" ] && [ -f "$TMP/pi-args.override" ] && break
	sleep 0.1
done
[ "$(cat "$TMP/run.rc" 2>/dev/null)" = 0 ]

grep -Fq 'started subagent #1 —' "$TMP/run-inherit.out"
grep -Fq 'model inherited' "$TMP/run-inherit.out"
grep -Fq 'started subagent #2 —' "$TMP/run-override.out"
grep -Fq 'model example-provider/example-model, effort high' "$TMP/run-override.out"
grep -Fq "model 'unqualified' is not provider-qualified" "$TMP/run-invalid.err"
grep -Fqx 'doctor: healthy' "$TMP/doctor.out"
grep -Fq '=== subagent #1 report (done) ===' "$TMP/wait.out"
grep -Fq 'completed report for Inspect the target' "$TMP/wait.out"
awk -F '\t' 'NF != 3 || $1 != "2" || $2 != "done" { exit 1 } END { if (NR != 1) exit 1 }' "$TMP/events.out"
grep -Fq '/2/reports/1.md' "$TMP/events.out"
grep -Fqx 'no new reports' "$TMP/reap.out"
grep -Eq '^#1[[:space:]]+idle$' "$TMP/status.out"
grep -Eq '^#2[[:space:]]+idle$' "$TMP/status.out"
grep -Eq '^#1[[:space:]]+alive' "$TMP/ls.out"
[ -s "$TMP/peek.out" ]
grep -Fqx 'sent to subagent #1' "$TMP/tell.out"
grep -Fqx 'stopped subagent #2' "$TMP/stop.out"

TASK_FILE=$(find "$TMP/state" -type f -path '*/1/task' -print -quit)
[ -n "$TASK_FILE" ]
AGENT_DIR=${TASK_FILE%/task}
grep -Fqx 'Inspect the target, implement safely, verify, and report for inherit-smoke' "$AGENT_DIR/task"
grep -Fq 'complete worker brief' "$AGENT_DIR/protocol.md"
grep -Fq '@@DONE@@' "$AGENT_DIR/protocol.md"
for state_file in pane protocol.md result.md task; do
	[ -e "$AGENT_DIR/$state_file" ]
done

QUEUED_EVENT=$(find "$TMP/state" -type f -path '*/.watcher-pending/*.json' -print -quit)
[ -n "$QUEUED_EVENT" ]
node - "$QUEUED_EVENT" <<'NODE'
const fs = require("node:fs");
const event = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (event.id !== "2" || event.status !== "done") process.exit(1);
if (!event.reportBody.includes("completed report")) process.exit(1);
if (!event.completionKey.startsWith("2:done:")) process.exit(1);
NODE

for args in "$TMP/pi-args.inherit" "$TMP/pi-args.override"; do
	grep -Fqx -- '--no-extensions' "$args"
	grep -Fqx -- '--no-skills' "$args"
	grep -Fqx -- '--no-prompt-templates' "$args"
	grep -Fqx -- '--no-context-files' "$args"
	grep -Fqx -- '--no-session' "$args"
	[ "$(grep -Fxc -- '--append-system-prompt' "$args")" = 1 ]
done
if grep -Fqx -- '--model' "$TMP/pi-args.inherit"; then
	echo "inherited launch unexpectedly passed a model override" >&2
	exit 1
fi
grep -Fqx -- '--model' "$TMP/pi-args.override"
grep -Fqx -- 'example-provider/example-model' "$TMP/pi-args.override"
grep -Fqx -- '--thinking' "$TMP/pi-args.override"
grep -Fqx -- 'high' "$TMP/pi-args.override"
grep -Fqx -- 'Inspect the target, implement safely, verify, and report for inherit-smoke' "$TMP/pi-args.inherit"
grep -Fqx -- 'Implement and verify the complete brief for override-smoke' "$TMP/pi-args.override"

echo "cli smoke: ok"
