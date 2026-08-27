#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/skills/subagents/subagents"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pi-subagents-lifecycle.XXXXXX")
SOCKET="pi-subagents-lifecycle-$$"
trap 'tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home" "$TMP/state" "$TMP/bin"
cat >"$TMP/bin/fake-pi" <<'FAKE_PI'
#!/bin/sh
printf '%s\n' 'worker ready'
sleep 120
FAKE_PI
chmod +x "$TMP/bin/fake-pi"

cat >"$TMP/lifecycle-inner" <<INNER
#!/usr/bin/env bash
set -euo pipefail
export HOME="$TMP/home"
export SUBAGENTS_STATE_DIR="$TMP/state"
export SUBAGENTS_PI="$TMP/bin/fake-pi"
export SUBAGENTS_WINDOW_NAME=lifecycle-helpers
unset PI_PROVIDER PI_MODEL PI_REASONING_LEVEL
cd "$ROOT"

launch() {
	local expected="\$1"
	"$CLI" run "Lifecycle protection case \$expected" >"$TMP/run.\$expected.out" 2>"$TMP/run.\$expected.err"
	grep -Fq "started subagent #\$expected" "$TMP/run.\$expected.out"
}
publish() {
	local id="\$1" outcome="\$2"
	local root
	root=\$(find "$TMP/state" -mindepth 1 -maxdepth 1 -type d -print -quit)
	printf 'complete lifecycle report for worker %s (%s)\n' "\$id" "\$outcome" >"\$root/\$id/report.next.md"
	"$CLI" publish "\$id" "\$outcome" "\$root/\$id/report.next.md" 1 >"$TMP/publish.\$id.out" 2>"$TMP/publish.\$id.err"
}
pane_alive_for() {
	local id="\$1" root pane
	root=\$(find "$TMP/state" -mindepth 1 -maxdepth 1 -type d -print -quit)
	pane=\$(cat "\$root/\$id/pane")
	tmux list-panes -a -F '#{pane_id} #{pane_dead}' | grep -Fqx "\$pane 0"
}
state_for() {
	local id="\$1" root
	root=\$(find "$TMP/state" -mindepth 1 -maxdepth 1 -type d -print -quit)
	node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).state)' "\$root/\$id/lifecycle.json"
}
ack_worker() {
	local id="\$1" root event spool
	root=\$(find "$TMP/state" -mindepth 1 -maxdepth 1 -type d -print -quit)
	read -r event spool <<<"\$(node -e 'const x=JSON.parse(require("fs").readFileSync(process.argv[1])); console.log(x.eventId, x.spoolName)' "\$root/\$id/lifecycle.json")"
	"$CLI" ack "\$id" "\$event" "\$spool.json"
}

root=""
launch 1
root=\$(find "$TMP/state" -mindepth 1 -maxdepth 1 -type d -print -quit)
publish 1 completed
# The safe default is active but does not ignore its ten-minute grace.
"$CLI" cleanup >"$TMP/cleanup-default.out" 2>"$TMP/cleanup-default.err"
grep -Fqx 'cleanup: no eligible completed workers' "$TMP/cleanup-default.out"
pane_alive_for 1
[ "\$(state_for 1)" = awaiting-follow-up ]
# Age the durable lease past the default grace. Default on-mode now stops the
# queued completed worker while preserving mutable/immutable report state.
node - "\$root/1/lifecycle.json" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, "utf8"));
value.candidateSince -= 601;
fs.writeFileSync(file, JSON.stringify(value) + "\\n");
NODE
"$CLI" cleanup >"$TMP/cleanup-one.out" 2>"$TMP/cleanup-one.err"
grep -Fq 'stopped subagent #1 after completed report and 600s grace; state preserved' "$TMP/cleanup-one.out"
! pane_alive_for 1
[ "\$(state_for 1)" = cleaned ]
[ -s "\$root/1/result.md" ]
[ -s "\$root/1/reports/1.md" ]
[ -f "\$root/.watcher-pending/\$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).spoolName)' "\$root/1/lifecycle.json").json" ]
if "$CLI" purge 1 >"$TMP/purge-before-ack.out" 2>"$TMP/purge-before-ack.err"; then echo 'purge removed an unacknowledged report' >&2; exit 1; fi
[ -d "\$root/1" ]
ack_worker 1
"$CLI" purge 1 >"$TMP/purge-after-ack.out" 2>"$TMP/purge-after-ack.err"
[ ! -e "\$root/1" ]

# Explicit blocked and ordinary working workers are protected regardless of
# grace. Screen stability and an unpublished report are not completion.
launch 2
publish 2 blocked
launch 3
printf 'written but deliberately unpublished\n' >"\$root/3/report.next.md"
SUBAGENTS_CLEANUP_GRACE_SECONDS=0 "$CLI" cleanup >"$TMP/cleanup-protected.out" 2>"$TMP/cleanup-protected.err"
pane_alive_for 2
pane_alive_for 3
[ "\$(state_for 2)" = blocked ]
[ "\$(state_for 3)" = working ]
"$CLI" tell 3 "Replace the unpublished draft with a new task" >"$TMP/tell-draft.out" 2>"$TMP/tell-draft.err"
[ "\$(state_for 3)" = working ]
[ -n "\$(find "\$root/3/unpublished" -type f -name '*.md' -print -quit)" ]

# Retain is durable and cancels a candidate. Release starts a fresh grace lease;
# after release, a zero-grace cleanup can stop only the completed worker.
launch 4
"$CLI" retain 4 >"$TMP/retain-four.out"
publish 4 completed
SUBAGENTS_CLEANUP_GRACE_SECONDS=0 "$CLI" cleanup >"$TMP/cleanup-retained.out" 2>"$TMP/cleanup-retained.err"
pane_alive_for 4
[ "\$(state_for 4)" = awaiting-follow-up ]
"$CLI" release 4 >"$TMP/release-four.out"
SUBAGENTS_CLEANUP_GRACE_SECONDS=0 "$CLI" cleanup >"$TMP/cleanup-released.out" 2>"$TMP/cleanup-released.err"
! pane_alive_for 4
[ "\$(state_for 4)" = cleaned ]

# tell also cancels cleanup, advances the generation, and leaves the prior
# immutable report/spool available for acknowledgement.
launch 5
publish 5 completed
pending_before=\$(find "\$root/.watcher-pending" -type f -name '5-*.json' -print -quit)
[ -n "\$pending_before" ]
"$CLI" tell 5 "Continue with a follow-up" >"$TMP/tell-five.out" 2>"$TMP/tell-five.err"
SUBAGENTS_CLEANUP_GRACE_SECONDS=0 "$CLI" cleanup >"$TMP/cleanup-told.out" 2>"$TMP/cleanup-told.err"
pane_alive_for 5
[ "\$(state_for 5)" = working ]
[ -f "\$pending_before" ]
[ "\$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).generation)' "\$root/5/lifecycle.json")" = 2 ]

# Dry-run, off, and notify are non-destructive. Retain their candidates before
# later on-mode checks so each assertion remains isolated.
launch 6
publish 6 completed
SUBAGENTS_CLEANUP_MODE=dry-run SUBAGENTS_CLEANUP_GRACE_SECONDS=0 "$CLI" cleanup >"$TMP/cleanup-dry.out" 2>"$TMP/cleanup-dry.err"
grep -Fq 'would stop subagent #6' "$TMP/cleanup-dry.out"
pane_alive_for 6
"$CLI" retain 6 >/dev/null
launch 7
publish 7 completed
SUBAGENTS_CLEANUP_MODE=off SUBAGENTS_CLEANUP_GRACE_SECONDS=0 "$CLI" cleanup >"$TMP/cleanup-off.out" 2>"$TMP/cleanup-off.err"
grep -Fqx 'cleanup: disabled (SUBAGENTS_CLEANUP_MODE=off)' "$TMP/cleanup-off.out"
pane_alive_for 7
"$CLI" retain 7 >/dev/null
launch 8
publish 8 completed
SUBAGENTS_CLEANUP_MODE=notify SUBAGENTS_CLEANUP_GRACE_SECONDS=0 "$CLI" cleanup >"$TMP/cleanup-notify.out" 2>"$TMP/cleanup-notify.err"
grep -Fq 'subagent #8 is eligible for cleanup (notify mode; no pane stopped)' "$TMP/cleanup-notify.out"
pane_alive_for 8
"$CLI" retain 8 >/dev/null

# Missing and malformed lifecycle records fail closed as unknown. They cause a
# loud cleanup failure but their panes and unpublished reports remain intact.
launch 9
cp "\$root/9/lifecycle.json" "\$root/9/lifecycle.saved"
printf '{malformed\n' >"\$root/9/lifecycle.json"
launch 10
cp "\$root/10/lifecycle.json" "\$root/10/lifecycle.saved"
rm "\$root/10/lifecycle.json"
if SUBAGENTS_CLEANUP_GRACE_SECONDS=0 "$CLI" cleanup >"$TMP/cleanup-unknown.out" 2>"$TMP/cleanup-unknown.err"; then
	echo 'cleanup unexpectedly accepted unknown lifecycle state' >&2
	exit 1
fi
grep -Fq 'subagent #9 has invalid lifecycle or delivery state; protected' "$TMP/cleanup-unknown.out"
grep -Fq 'subagent #10 has invalid lifecycle or delivery state; protected' "$TMP/cleanup-unknown.out"
pane_alive_for 9
pane_alive_for 10
"$CLI" status >"$TMP/status-unknown.out" 2>"$TMP/status-unknown.err"
grep -Eq '^#9[[:space:]]+unknown.*cleanup=protected' "$TMP/status-unknown.out"
grep -Eq '^#10[[:space:]]+unknown.*cleanup=protected' "$TMP/status-unknown.out"
if grep -Fq 'Lifecycle protection case' "$TMP/status-unknown.out"; then echo 'status leaked task text' >&2; exit 1; fi
mv "\$root/9/lifecycle.saved" "\$root/9/lifecycle.json"
mv "\$root/10/lifecycle.saved" "\$root/10/lifecycle.json"

# Session schema mismatch and unversioned legacy-looking roots fail loudly
# before any worker or spool state is consumed.
cp "\$root/.schema.json" "\$root/.schema.saved"
node - "\$root/.schema.json" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, "utf8"));
value.packageVersion = "mismatched";
fs.writeFileSync(file, JSON.stringify(value) + "\\n");
NODE
if "$CLI" status >"$TMP/status-schema-mismatch.out" 2>"$TMP/status-schema-mismatch.err"; then exit 1; fi
grep -Fq 'state schema/version mismatch' "$TMP/status-schema-mismatch.err"
mv "\$root/.schema.saved" "\$root/.schema.json"
session_name=\$(basename "\$root")
mkdir -p "$TMP/legacy-state/\$session_name/1"
if SUBAGENTS_STATE_DIR="$TMP/legacy-state" "$CLI" status >"$TMP/status-unversioned.out" 2>"$TMP/status-unversioned.err"; then exit 1; fi
grep -Fq 'unversioned state' "$TMP/status-unversioned.err"

# stop uses the event lock and preserves blocked delivery state. Purge refuses
# until acknowledgement, then removes only this terminal worker's state.
"$CLI" stop 2 >"$TMP/stop-blocked.out" 2>"$TMP/stop-blocked.err"
[ -s "\$root/2/result.md" ]
[ -s "\$root/2/reports/1.md" ]
if "$CLI" purge 2 >"$TMP/purge-blocked-before.out" 2>"$TMP/purge-blocked-before.err"; then exit 1; fi
ack_worker 2
"$CLI" purge 2 >"$TMP/purge-blocked-after.out" 2>"$TMP/purge-blocked-after.err"
[ ! -e "\$root/2" ]

# An unpublished report is never silently purged.
"$CLI" stop 3 >"$TMP/stop-working.out" 2>"$TMP/stop-working.err"
if "$CLI" purge 3 >"$TMP/purge-unpublished.out" 2>"$TMP/purge-unpublished.err"; then
	echo 'purge removed an unpublished report' >&2
	exit 1
fi
[ -n "\$(find "\$root/3/unpublished" -type f -name '*.md' -print -quit)" ]

"$CLI" stop --all >"$TMP/stop-all.out" 2>"$TMP/stop-all.err" || true
echo 0 >"$TMP/lifecycle.rc"
INNER
chmod +x "$TMP/lifecycle-inner"

tmux -L "$SOCKET" new-session -d -s lifecycle "$TMP/lifecycle-inner"
for _ in {1..900}; do
	[ -f "$TMP/lifecycle.rc" ] && break
	if ! tmux -L "$SOCKET" has-session -t lifecycle 2>/dev/null; then break; fi
	sleep 0.1
done
if [ "$(cat "$TMP/lifecycle.rc" 2>/dev/null || true)" != 0 ]; then
	for output in "$TMP"/*.err "$TMP"/cleanup-*.out; do [ -s "$output" ] && { echo "=== $output ===" >&2; tail -120 "$output" >&2; }; done
	exit 1
fi

echo "cli lifecycle: ok"
