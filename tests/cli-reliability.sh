#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/skills/subagents/subagents"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pi-subagents-reliability.XXXXXX")
SOCKET="pi-subagents-reliability-$$"
trap 'tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home" "$TMP/state" "$TMP/bin"
cat >"$TMP/bin/fake-pi" <<'FAKE_PI'
#!/bin/sh
last=""
protocol=""
next_is_protocol=0
for arg do
	last="$arg"
	if [ "$next_is_protocol" = 1 ]; then
		protocol="$arg"
		next_is_protocol=0
	elif [ "$arg" = "--append-system-prompt" ]; then
		next_is_protocol=1
	fi
done
result=$(grep '/result\.md$' "$protocol" | head -1 | sed 's/^[[:space:]]*//')
printf 'durable report for %s\n' "$last" >"$result"
printf '%s\n' '@@DONE@@'
sleep 30
FAKE_PI
chmod +x "$TMP/bin/fake-pi"

cat >"$TMP/reliability-inner" <<INNER
#!/usr/bin/env bash
set -euo pipefail
export HOME="$TMP/home"
export SUBAGENTS_STATE_DIR="$TMP/state"
export SUBAGENTS_PI="$TMP/bin/fake-pi"
export SUBAGENTS_WINDOW_NAME="reliable-helpers"
cd "$ROOT"

pids=""
for number in 1 2 3 4 5 6 7 8; do
	"$CLI" run "Concurrent complete brief number \$number" >"$TMP/run.\$number.out" 2>"$TMP/run.\$number.err" &
	pids="\$pids \$!"
done
for child in \$pids; do wait "\$child"; done

session_root=\$(find "$TMP/state" -mindepth 1 -maxdepth 1 -type d -print -quit)
[ -n "\$session_root" ]
[ "\$(cat "\$session_root/.seq")" = 8 ]
[ "\$(find "\$session_root" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | wc -l | tr -d ' ')" = 8 ]
[ "\$(tmux list-windows -F '#{window_name}' | grep -Fxc 'reliable-helpers')" = 1 ]
[ ! -e "\$session_root/.seq.lock" ]
[ ! -e "\$session_root/.window.lock" ]

# Every current lock record is complete before publication. A live owner is
# never evicted based on age; once released, its waiter proceeds normally.
live_owner=\$\$
printf '%s\n' "\$live_owner unknown live-sequence 1" >"\$session_root/.seq.lock"
"$CLI" run "Wait for the live sequence lock" >"$TMP/run.9.out" 2>"$TMP/run.9.err" &
blocked_pid=\$!
sleep 0.3
kill -0 "\$blocked_pid"
[ "\$(cat "\$session_root/.seq.lock")" = "\$live_owner unknown live-sequence 1" ]
rm "\$session_root/.seq.lock"
wait "\$blocked_pid"
grep -Fq 'started subagent #9' "$TMP/run.9.out"

# A dead owner can be reclaimed, and both doctor and recovery report it.
printf '%s\n' '999999 unknown abandoned-sequence 1' >"\$session_root/.seq.lock"
"$CLI" doctor >"$TMP/doctor-abandoned.out" 2>"$TMP/doctor-abandoned.err"
grep -Fq 'WARN state: abandoned sequence lock' "$TMP/doctor-abandoned.out"
grep -Fqx 'doctor: healthy, 1 warning(s)' "$TMP/doctor-abandoned.out"
"$CLI" run "Recover the abandoned sequence lock" >"$TMP/run.10.out" 2>"$TMP/run.10.err"
grep -Fq 'recovered abandoned sequence lock' "$TMP/run.10.err"
printf '%s\n' '999999 unknown abandoned-window 1' >"\$session_root/.window.lock"
"$CLI" run "Recover the abandoned window lock" >"$TMP/run.11.out" 2>"$TMP/run.11.err"
grep -Fq 'recovered abandoned tmux window lock' "$TMP/run.11.err"
[ "\$(cat "\$session_root/.seq")" = 11 ]
[ "\$(tmux list-windows -F '#{window_name}' | grep -Fxc 'reliable-helpers')" = 1 ]

for attempt in 1 2 3 4 5 6 7 8 9 10 11; do
	for poll in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		[ -s "\$session_root/\$attempt/result.md" ] && break
		sleep 0.05
	done
	[ -s "\$session_root/\$attempt/result.md" ]
done

# If durable queue creation fails, events fails and no completion hash advances.
touch "\$session_root/.watcher-pending"
if "$CLI" events >"$TMP/events-blocked.out" 2>"$TMP/events-blocked.err"; then
	echo 'events unexpectedly succeeded without durable spool storage' >&2
	exit 1
fi
[ ! -s "$TMP/events-blocked.out" ]
[ "\$(find "\$session_root" -name rhash -type f | wc -l | tr -d ' ')" = 0 ]
[ -f "\$session_root/1/reports/1.md" ]
rm "\$session_root/.watcher-pending"

# Event consumption uses the same abandoned-lock recovery as ids and windows.
printf '%s\n' '999999 unknown abandoned-event 1' >"\$session_root/1/.event.lock"
"$CLI" events >"$TMP/events.out" 2>"$TMP/events.err"
grep -Fq 'recovered abandoned event consumer for subagent #1 lock' "$TMP/events.err"
[ "\$(wc -l <"$TMP/events.out" | tr -d ' ')" = 11 ]
awk -F '\t' 'NF != 3 || \$2 != "done" { exit 1 }' "$TMP/events.out"
[ "\$(find "\$session_root/.watcher-pending" -type f -name '*.json' | wc -l | tr -d ' ')" = 11 ]
[ "\$(find "\$session_root" -name rhash -type f | wc -l | tr -d ' ')" = 11 ]

# Snapshots from the failed attempt were not overwritten; successful events got
# a second immutable file after the queue became writable.
for number in 1 2 3 4 5 6 7 8 9 10 11; do
	[ -f "\$session_root/\$number/reports/1.md" ]
	[ -f "\$session_root/\$number/reports/2.md" ]
	[ "\$(cksum <"\$session_root/\$number/reports/1.md")" = "\$(cksum <"\$session_root/\$number/reports/2.md")" ]
done

# Simulate a crash after queue fsync but before the marker write. The stable
# completion key reuses the spool, restores the marker, and emits no duplicate.
rm "\$session_root/1/rhash"
"$CLI" events >"$TMP/events-replay.out" 2>"$TMP/events-replay.err"
[ ! -s "$TMP/events-replay.out" ]
[ -s "\$session_root/1/rhash" ]
[ "\$(find "\$session_root/1/reports" -type f -name '*.md' | wc -l | tr -d ' ')" = 2 ]
[ "\$(find "\$session_root/.watcher-pending" -type f -name '*.json' | wc -l | tr -d ' ')" = 11 ]

"$CLI" doctor >"$TMP/doctor-reliability.out" 2>"$TMP/doctor-reliability.err"
grep -Fqx 'doctor: healthy' "$TMP/doctor-reliability.out"
echo 0 >"$TMP/reliability.rc"
INNER
chmod +x "$TMP/reliability-inner"

tmux -L "$SOCKET" new-session -d -s reliability "$TMP/reliability-inner"
for _ in {1..300}; do
	[ -f "$TMP/reliability.rc" ] && break
	if ! tmux -L "$SOCKET" has-session -t reliability 2>/dev/null; then break; fi
	sleep 0.1
done
if [ "$(cat "$TMP/reliability.rc" 2>/dev/null || true)" != 0 ]; then
	for error in "$TMP"/*.err; do
		[ -s "$error" ] && { echo "=== $error ===" >&2; tail -100 "$error" >&2; }
	done
	[ -f "$TMP/events-blocked.err" ] && tail -100 "$TMP/events-blocked.err" >&2
	exit 1
fi

echo "cli reliability: ok"
