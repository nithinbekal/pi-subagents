#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/skills/subagents/subagents"
STATE_HELPER="$ROOT/skills/subagents/state.mjs"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pi-subagents-publish-idempotency.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export SUBAGENTS_STATE_DIR="$TMP/state"
export TMUX='/tmp/fake-tmux,123,9'
unset TMUX_PANE
mkdir -p "$HOME" "$TMP/state/\$9"
cp "$ROOT/protocol.json" "$TMP/state/\$9/.schema.json"
SESSION_ROOT="$TMP/state/\$9"

init_worker() {
	local id="$1" body="$2" now="${3:-1000}" dir="$SESSION_ROOT/$id"
	mkdir -p "$dir"
	node "$STATE_HELPER" init "$dir/lifecycle.json" "$id" "$now"
	node "$STATE_HELPER" transition "$dir/lifecycle.json" working "$((now + 1))" >/dev/null
	printf '%s\n' "$body" >"$dir/report.next.md"
}

reports_count() {
	local id="$1" dir="$SESSION_ROOT/$id/reports"
	[ -d "$dir" ] || { printf '0\n'; return; }
	find "$dir" -type f -name '*.md' | wc -l | tr -d ' '
}

pending_count() {
	local id="$1"
	find "$SESSION_ROOT/.watcher-pending" -maxdepth 1 -type f -name "$id-*.json" 2>/dev/null | wc -l | tr -d ' '
}

sha() {
	node -e 'const fs=require("fs"), crypto=require("crypto"); process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"
}

lifecycle_field() {
	local id="$1" field="$2"
	node -e 'const fs=require("fs"); const value=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(String(value[process.argv[2]]));' "$SESSION_ROOT/$id/lifecycle.json" "$field"
}

ack_worker() {
	local id="$1" event_id spool_name
	event_id=$(lifecycle_field "$id" eventId)
	spool_name=$(lifecycle_field "$id" spoolName)
	"$CLI" ack "$id" "$event_id" "$spool_name.json" >/dev/null
}

archive_path() {
	local id="$1" event_id
	event_id=$(lifecycle_field "$id" eventId)
	printf '%s/%s/events/%s.json\n' "$SESSION_ROOT" "$id" "$event_id"
}

publish_expect_success() {
	local id="$1" outcome="$2" generation="${3:-1}"
	"$CLI" publish "$id" "$outcome" "$SESSION_ROOT/$id/report.next.md" "$generation" >/dev/null
}

publish_expect_failure() {
	local id="$1" outcome="$2" generation="${3:-1}"
	if "$CLI" publish "$id" "$outcome" "$SESSION_ROOT/$id/report.next.md" "$generation" >"$TMP/fail.$id.out" 2>"$TMP/fail.$id.err"; then
		echo "publish unexpectedly succeeded for worker $id" >&2
		return 1
	fi
}

assert_no_new_state_after_failure() {
	local id="$1" before_lifecycle="$2" before_archive="$3" before_reports="$4" before_pending="$5"
	[ "$(sha "$SESSION_ROOT/$id/lifecycle.json")" = "$before_lifecycle" ]
	[ "$(sha "$(archive_path "$id")")" = "$before_archive" ]
	[ "$(reports_count "$id")" = "$before_reports" ]
	[ "$(pending_count "$id")" = "$before_pending" ]
}

same_body_after_ack_noop() {
	local id="$1" outcome="$2" body="$3"
	init_worker "$id" "$body"
	publish_expect_success "$id" "$outcome"
	ack_worker "$id"
	local before_lifecycle before_archive
	before_lifecycle=$(sha "$SESSION_ROOT/$id/lifecycle.json")
	before_archive=$(sha "$(archive_path "$id")")
	publish_expect_success "$id" "$outcome"
	[ "$(reports_count "$id")" = 1 ]
	[ "$(pending_count "$id")" = 0 ]
	[ "$(sha "$SESSION_ROOT/$id/lifecycle.json")" = "$before_lifecycle" ]
	[ "$(sha "$(archive_path "$id")")" = "$before_archive" ]
	ack_worker "$id"
	[ "$(reports_count "$id")" = 1 ]
	[ "$(pending_count "$id")" = 0 ]
}

changed_body_after_ack_rejects_without_effects() {
	local id="$1" outcome="$2"
	init_worker "$id" "original $outcome report"
	publish_expect_success "$id" "$outcome"
	ack_worker "$id"
	local before_lifecycle before_archive before_reports before_pending
	before_lifecycle=$(sha "$SESSION_ROOT/$id/lifecycle.json")
	before_archive=$(sha "$(archive_path "$id")")
	before_reports=$(reports_count "$id")
	before_pending=$(pending_count "$id")
	printf 'changed %s report\n' "$outcome" >"$SESSION_ROOT/$id/report.next.md"
	publish_expect_failure "$id" "$outcome"
	assert_no_new_state_after_failure "$id" "$before_lifecycle" "$before_archive" "$before_reports" "$before_pending"
}

same_body_before_ack_reuses_pending() {
	local id="$1"
	init_worker "$id" 'pending retry report'
	publish_expect_success "$id" completed
	publish_expect_success "$id" completed
	[ "$(reports_count "$id")" = 1 ]
	[ "$(pending_count "$id")" = 1 ]
}

interrupted_publish_recovery_reuses_spool() {
	local id="$1" dir checksum bytes key event_id spool_name target report_path
	dir="$SESSION_ROOT/$id"
	init_worker "$id" 'interrupted report'
	mkdir -p "$dir/reports" "$SESSION_ROOT/.watcher-pending"
	report_path="$dir/reports/1.md"
	node "$STATE_HELPER" snapshot "$dir/report.next.md" "$report_path"
	read -r checksum bytes <<<"$(cksum <"$dir/report.next.md")"
	key="$id:done:1:$checksum:$bytes"
	event_id=$(node "$STATE_HELPER" event-id "$id" 1 done "$key")
	spool_name="$id-1-$event_id"
	target="$SESSION_ROOT/.watcher-pending/$spool_name.json"
	node "$STATE_HELPER" spool "$target" "$SESSION_ROOT" "$id" 1 done completed "$key" "$event_id" "$report_path" 2000 >/dev/null
	publish_expect_success "$id" completed
	[ "$(reports_count "$id")" = 1 ]
	[ "$(pending_count "$id")" = 1 ]
	[ "$(lifecycle_field "$id" state)" = awaiting-follow-up ]
	[ "$(lifecycle_field "$id" reportPath)" = "$report_path" ]
}

interrupted_publish_recovery_reuses_acknowledged_archive() {
	local id="$1" dir checksum bytes key event_id spool_name target report_path
	dir="$SESSION_ROOT/$id"
	init_worker "$id" 'interrupted acknowledged report'
	mkdir -p "$dir/reports" "$SESSION_ROOT/.watcher-pending"
	report_path="$dir/reports/1.md"
	node "$STATE_HELPER" snapshot "$dir/report.next.md" "$report_path"
	read -r checksum bytes <<<"$(cksum <"$dir/report.next.md")"
	key="$id:done:1:$checksum:$bytes"
	event_id=$(node "$STATE_HELPER" event-id "$id" 1 done "$key")
	spool_name="$id-1-$event_id"
	target="$SESSION_ROOT/.watcher-pending/$spool_name.json"
	node "$STATE_HELPER" spool "$target" "$SESSION_ROOT" "$id" 1 done completed "$key" "$event_id" "$report_path" 2000 >/dev/null
	"$CLI" ack "$id" "$event_id" "$spool_name.json" >/dev/null
	publish_expect_success "$id" completed
	[ "$(reports_count "$id")" = 1 ]
	[ "$(pending_count "$id")" = 0 ]
	[ "$(lifecycle_field "$id" state)" = awaiting-follow-up ]
	[ "$(lifecycle_field "$id" reportPath)" = "$report_path" ]
}

stale_generation_rejects_without_effects() {
	local id="$1"
	init_worker "$id" 'stale report'
	node "$STATE_HELPER" transition "$SESSION_ROOT/$id/lifecycle.json" tell 2000 >/dev/null
	local before_lifecycle
	before_lifecycle=$(sha "$SESSION_ROOT/$id/lifecycle.json")
	publish_expect_failure "$id" completed 1
	[ "$(sha "$SESSION_ROOT/$id/lifecycle.json")" = "$before_lifecycle" ]
	[ "$(reports_count "$id")" = 0 ]
	[ "$(pending_count "$id")" = 0 ]
}

terminal_state_rejects_without_effects() {
	local id="$1" state="$2" dir before_lifecycle before_reports before_pending
	dir="$SESSION_ROOT/$id"
	case "$state" in
		stopped)
			init_worker "$id" 'stopped report'
			node "$STATE_HELPER" transition "$dir/lifecycle.json" stopped 2000 >/dev/null
			;;
		cleaned)
			init_worker "$id" 'cleaned report'
			publish_expect_success "$id" completed
			ack_worker "$id"
			node "$STATE_HELPER" transition "$dir/lifecycle.json" cleaned 2000 1 "$(lifecycle_field "$id" eventId)" >/dev/null
			;;
		exited)
			init_worker "$id" 'publish after exit report'
			local report_path checksum bytes key event_id spool_name target
			mkdir -p "$dir/reports" "$SESSION_ROOT/.watcher-pending"
			printf 'exit report\n' >"$dir/exit.tmp"
			report_path="$dir/reports/1.md"
			node "$STATE_HELPER" snapshot "$dir/exit.tmp" "$report_path"
			read -r checksum bytes <<<"$(cksum <"$dir/exit.tmp")"
			key="$id:exited:1:$checksum:$bytes"
			event_id=$(node "$STATE_HELPER" event-id "$id" 1 exited "$key")
			spool_name="$id-1-$event_id"
			target="$SESSION_ROOT/.watcher-pending/$spool_name.json"
			node "$STATE_HELPER" spool "$target" "$SESSION_ROOT" "$id" 1 exited exited "$key" "$event_id" "$report_path" 2000 >/dev/null
			node "$STATE_HELPER" finish-exit "$dir/lifecycle.json" 2000 1 "$key" "$spool_name" "$event_id" "$report_path"
			;;
		*) echo "unknown terminal fixture $state" >&2; return 1 ;;
	esac
	before_lifecycle=$(sha "$dir/lifecycle.json")
	before_reports=$(reports_count "$id")
	before_pending=$(pending_count "$id")
	publish_expect_failure "$id" completed 1
	[ "$(sha "$dir/lifecycle.json")" = "$before_lifecycle" ]
	[ "$(reports_count "$id")" = "$before_reports" ]
	[ "$(pending_count "$id")" = "$before_pending" ]
}

same_body_after_ack_noop 1 completed 'completed duplicate report'
same_body_after_ack_noop 2 blocked 'blocked duplicate report'
changed_body_after_ack_rejects_without_effects 3 completed
changed_body_after_ack_rejects_without_effects 4 blocked
same_body_before_ack_reuses_pending 5
interrupted_publish_recovery_reuses_spool 6
interrupted_publish_recovery_reuses_acknowledged_archive 7
stale_generation_rejects_without_effects 8
terminal_state_rejects_without_effects 9 stopped
terminal_state_rejects_without_effects 10 cleaned
terminal_state_rejects_without_effects 11 exited

echo "publish idempotency: ok"
