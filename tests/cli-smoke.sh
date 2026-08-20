#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/skills/subagents/subagents"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pi-subagents-cli.XXXXXX")
SOCKET="pi-subagents-test-$$"
trap 'tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home" "$TMP/roles" "$TMP/state" "$TMP/bin"
cat >"$TMP/roles/example.md" <<'ROLE'
---
name: example
model: example-provider/example-model
tools: [read, bash]
---

Perform the assigned task and report the result.
ROLE
cat >"$TMP/bin/auth-wrapper" <<'WRAPPER'
#!/bin/sh
exec "$@"
WRAPPER
chmod +x "$TMP/bin/auth-wrapper"

CONFIG=$(
	HOME="$TMP/home" \
	SUBAGENTS_AGENT_DIR="$TMP/agent" \
	SUBAGENTS_STATE_DIR="$TMP/state" \
	SUBAGENTS_ROLE_DIRS="$TMP/roles" \
	SUBAGENTS_PI="$TMP/bin/auth-wrapper pi" \
	SUBAGENTS_WINDOW_NAME="helpers" \
	"$CLI" config
)

grep -Fqx "launcher=$TMP/bin/auth-wrapper pi" <<<"$CONFIG"
grep -Fqx "state_dir=$TMP/state" <<<"$CONFIG"
grep -Fqx "role_dirs=$TMP/roles" <<<"$CONFIG"
grep -Fqx "agent_dir=$TMP/agent" <<<"$CONFIG"
grep -Fqx "window_name=helpers" <<<"$CONFIG"

ROLES=$(HOME="$TMP/home" SUBAGENTS_STATE_DIR="$TMP/state" SUBAGENTS_ROLE_DIRS="$TMP/roles" "$CLI" roles)
grep -Fqx "# $TMP/roles" <<<"$ROLES"
grep -Eq '^  example +\(example-provider/example-model\)$' <<<"$ROLES"

HELP=$(HOME="$TMP/home" SUBAGENTS_STATE_DIR="$TMP/state" "$CLI" --help)
grep -Fq 'subagents config' <<<"$HELP"

if env -u TMUX -u TMUX_PANE HOME="$TMP/home" SUBAGENTS_STATE_DIR="$TMP/state" SUBAGENTS_ROLE_DIRS="$TMP/roles" "$CLI" run missing-role task >"$TMP/out" 2>"$TMP/err"; then
	echo "expected run outside tmux to fail" >&2
	exit 1
fi
grep -Fq 'subagents requires tmux' "$TMP/err"

cat >"$TMP/bin/fake-pi" <<FAKE_PI
#!/bin/sh
printf '%s\n' "\$@" >"$TMP/pi-args"
sleep 10
FAKE_PI
chmod +x "$TMP/bin/fake-pi"
cat >"$TMP/tmux-smoke" <<TMUX_SMOKE
#!/bin/sh
export HOME="$TMP/home"
export SUBAGENTS_STATE_DIR="$TMP/state"
export SUBAGENTS_ROLE_DIRS="$TMP/roles"
export SUBAGENTS_PI="$TMP/bin/fake-pi"
cd "$ROOT"
"$CLI" run example "tmux smoke task" >"$TMP/run.out" 2>"$TMP/run.err"
echo \$? >"$TMP/run.rc"
TMUX_SMOKE
chmod +x "$TMP/tmux-smoke"
tmux -L "$SOCKET" new-session -d -s smoke "$TMP/tmux-smoke"
for _ in {1..50}; do
	[ -f "$TMP/run.rc" ] && break
	sleep 0.1
done
[ "$(cat "$TMP/run.rc" 2>/dev/null)" = 0 ]
grep -Fq 'started subagent #1 (example)' "$TMP/run.out"
TASK_FILE=$(find "$TMP/state" -type f -path '*/1/task' -print -quit)
[ -n "$TASK_FILE" ]
AGENT_DIR=${TASK_FILE%/task}
grep -Fqx 'tmux smoke task' "$AGENT_DIR/task"
grep -Fqx 'example' "$AGENT_DIR/role"
grep -Fq '@@DONE@@' "$AGENT_DIR/protocol.md"
for _ in {1..50}; do
	[ -f "$TMP/pi-args" ] && break
	sleep 0.1
done
grep -Fqx -- '--no-extensions' "$TMP/pi-args"
grep -Fqx -- '--append-system-prompt' "$TMP/pi-args"

echo "cli smoke: ok"
