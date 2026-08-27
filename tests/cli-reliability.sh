#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/skills/subagents/subagents"
STATE_HELPER="$ROOT/skills/subagents/state.mjs"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pi-subagents-reliability.XXXXXX")
SOCKET="pi-subagents-reliability-$$"
trap 'tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home" "$TMP/state" "$TMP/bin"
cat >"$TMP/bin/fake-pi" <<'FAKE_PI'
#!/bin/sh
last=""
protocol=""
next=0
for arg do
	last="$arg"
	if [ "$next" = 1 ]; then protocol="$arg"; next=0
	elif [ "$arg" = --append-system-prompt ]; then next=1
	fi
done
case "$last" in *manual-publish*) sleep 60; exit 0;; esac
agent_dir=$(dirname "$protocol")
printf 'durable report for %s\n' "$last" >"$agent_dir/report.next.md"
publish_cmd=$(grep ' publish [0-9][0-9]* completed ' "$protocol" | head -1)
sh -c "$publish_cmd" || exit 2
printf '%s\n' '@@DONE@@'
sleep 60
FAKE_PI
chmod +x "$TMP/bin/fake-pi"

cat >"$TMP/reliability-inner" <<INNER
#!/usr/bin/env bash
set -euo pipefail
export HOME="$TMP/home"
export SUBAGENTS_STATE_DIR="$TMP/state"
export SUBAGENTS_PI="$TMP/bin/fake-pi"
export SUBAGENTS_WINDOW_NAME=reliable-helpers
unset PI_PROVIDER PI_MODEL PI_REASONING_LEVEL
cd "$ROOT"

# Repeated concurrent launch rounds exercise both sequence and window locks.
next=0
for round in 1 2 3; do
	pids=""
	for slot in 1 2 3 4 5 6 7 8; do
		next=\$((next + 1))
		"$CLI" run "Concurrent complete brief round \$round slot \$slot" >"$TMP/run.\$next.out" 2>"$TMP/run.\$next.err" &
		pids="\$pids \$!"
	done
	for child in \$pids; do wait "\$child"; done
done
session_root=\$(find "$TMP/state" -mindepth 1 -maxdepth 1 -type d -print -quit)
[ -n "\$session_root" ]
[ "\$(cat "\$session_root/.seq")" = 24 ]
[ "\$(find "\$session_root" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | wc -l | tr -d ' ')" = 24 ]
[ "\$(tmux list-windows -F '#{window_name}' | grep -Fxc reliable-helpers)" = 1 ]
[ ! -e "\$session_root/.seq.lock" ]
[ ! -e "\$session_root/.window.lock" ]
if grep -RqiE 'unbound variable|owner_pid.*unbound' "$TMP"/run.*.err; then
	echo 'concurrent launch hit an unbound lock owner variable' >&2
	exit 1
fi

# A live record cannot be evicted. Removing it simulates the normal owner
# release at the exact moment multiple contenders are inspecting the path.
live_owner=\$\$
printf '%s\n' "\$live_owner unknown live-sequence 1" >"\$session_root/.seq.lock"
pids=""
for number in 25 26 27 28; do
	"$CLI" run "Release-race complete brief \$number" >"$TMP/run.\$number.out" 2>"$TMP/run.\$number.err" &
	pids="\$pids \$!"
done
sleep 0.2
for child in \$pids; do kill -0 "\$child"; done
[ "\$(cat "\$session_root/.seq.lock")" = "\$live_owner unknown live-sequence 1" ]
rm "\$session_root/.seq.lock"
for child in \$pids; do wait "\$child"; done
[ "\$(cat "\$session_root/.seq")" = 28 ]
if grep -RqiE 'unbound variable|owner_pid.*unbound' "$TMP"/run.2{5,6,7,8}.err; then exit 1; fi

# Dead owners are reported and safely reclaimed for every lock class.
printf '%s\n' '999999 unknown abandoned-sequence 1' >"\$session_root/.seq.lock"
"$CLI" doctor >"$TMP/doctor-abandoned.out" 2>"$TMP/doctor-abandoned.err"
grep -Fq 'WARN state: abandoned sequence lock' "$TMP/doctor-abandoned.out"
"$CLI" run "Recover abandoned sequence" >"$TMP/run.29.out" 2>"$TMP/run.29.err"
grep -Fq 'recovered abandoned sequence lock' "$TMP/run.29.err"
printf '%s\n' '999999 unknown abandoned-window 1' >"\$session_root/.window.lock"
"$CLI" run "Recover abandoned window" >"$TMP/run.30.out" 2>"$TMP/run.30.err"
grep -Fq 'recovered abandoned tmux window lock' "$TMP/run.30.err"

# Wait for all automatic publications. Direct publication means events has no
# completion-detection race or screen-idle fallback.
for number in \$(seq 1 30); do
	for poll in \$(seq 1 100); do
		state=\$(node -e 'const fs=require("fs");try{console.log(JSON.parse(fs.readFileSync(process.argv[1])).state)}catch{}' "\$session_root/\$number/lifecycle.json")
		[ "\$state" = awaiting-follow-up ] && break
		sleep 0.05
	done
	[ "\$state" = awaiting-follow-up ]
done
[ "\$(find "\$session_root/.watcher-pending" -type f -name '*.json' | wc -l | tr -d ' ')" = 30 ]
printf '%s\n' '999999 unknown abandoned-event 1' >"\$session_root/1/.event.lock"
"$CLI" events >"$TMP/events.out" 2>"$TMP/events.err"
[ ! -s "$TMP/events.out" ]
grep -Fq 'recovered abandoned event consumer for subagent #1 lock' "$TMP/events.err"

# Queue failure leaves the lifecycle working and the report untouched. A retry
# after storage recovery publishes exactly once.
"$CLI" run "manual-publish queue-failure" >"$TMP/run.31.out" 2>"$TMP/run.31.err"
printf 'manual durable report\n' >"\$session_root/31/report.next.md"
mv "\$session_root/.watcher-pending" "\$session_root/.watcher-pending.saved"
touch "\$session_root/.watcher-pending"
if "$CLI" publish 31 completed "\$session_root/31/report.next.md" 1 >"$TMP/publish-fail.out" 2>"$TMP/publish-fail.err"; then
	echo 'publication unexpectedly succeeded without a spool directory' >&2
	exit 1
fi
[ -s "\$session_root/31/report.next.md" ]
[ "\$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).state)' "\$session_root/31/lifecycle.json")" = working ]
rm "\$session_root/.watcher-pending"
mv "\$session_root/.watcher-pending.saved" "\$session_root/.watcher-pending"
"$CLI" publish 31 completed "\$session_root/31/report.next.md" 1 >"$TMP/publish-ok.out" 2>"$TMP/publish-ok.err"
[ "\$(find "\$session_root/.watcher-pending" -type f -name '*.json' | wc -l | tr -d ' ')" = 31 ]

# Recover a crash after spool fsync but before lifecycle commit. The retry
# reuses the deterministic event and immutable snapshot without duplication.
"$CLI" run "manual-publish interrupted-publication" >"$TMP/run.32.out" 2>"$TMP/run.32.err"
printf 'interrupted durable report\n' >"\$session_root/32/report.next.md"
mkdir -p "\$session_root/32/reports"
node "$STATE_HELPER" snapshot "\$session_root/32/report.next.md" "\$session_root/32/reports/1.md"
read -r checksum bytes <<<"\$(cksum <"\$session_root/32/report.next.md")"
key="32:done:1:\$checksum:\$bytes"
event_id=\$(node "$STATE_HELPER" event-id 32 1 done "\$key")
spool_name="32-1-\$event_id"
node "$STATE_HELPER" spool "\$session_root/.watcher-pending/\$spool_name.json" "\$session_root" 32 1 done completed \
	"\$key" "\$event_id" "\$session_root/32/reports/1.md" "\$(date +%s)" >/dev/null
"$CLI" publish 32 completed "\$session_root/32/report.next.md" 1 >"$TMP/publish-recover.out" 2>"$TMP/publish-recover.err"
[ "\$(find "\$session_root/32/reports" -type f -name '*.md' | wc -l | tr -d ' ')" = 1 ]
[ "\$(find "\$session_root/.watcher-pending" -type f -name '*.json' | wc -l | tr -d ' ')" = 32 ]
[ "\$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).state)' "\$session_root/32/lifecycle.json")" = awaiting-follow-up ]

"$CLI" doctor >"$TMP/doctor-final.out" 2>"$TMP/doctor-final.err"
grep -Fqx 'doctor: healthy' "$TMP/doctor-final.out"
echo 0 >"$TMP/reliability.rc"
INNER
chmod +x "$TMP/reliability-inner"

tmux -L "$SOCKET" new-session -d -s reliability "$TMP/reliability-inner"
for _ in {1..900}; do
	[ -f "$TMP/reliability.rc" ] && break
	if ! tmux -L "$SOCKET" has-session -t reliability 2>/dev/null; then break; fi
	sleep 0.1
done
if [ "$(cat "$TMP/reliability.rc" 2>/dev/null || true)" != 0 ]; then
	for error in "$TMP"/*.err; do [ -s "$error" ] && { echo "=== $error ===" >&2; tail -100 "$error" >&2; }; done
	exit 1
fi

echo "cli reliability: ok"
