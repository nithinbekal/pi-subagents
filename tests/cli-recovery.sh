#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/skills/subagents/subagents"
STATE_HELPER="$ROOT/skills/subagents/state.mjs"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pi-subagents-recovery.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export SUBAGENTS_STATE_DIR="$TMP/state"
export TMUX='/tmp/fake-tmux,123,9'
unset TMUX_PANE
mkdir -p "$HOME" "$TMP/state/\$9"
cp "$ROOT/protocol.json" "$TMP/state/\$9/.schema.json"
SESSION_ROOT="$TMP/state/\$9"
SESSION_FILE="$TMP/lead-session.jsonl"

sha() {
	node -e 'const fs=require("fs"), crypto=require("crypto"); process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"
}

field() {
	local file="$1" key="$2"
	node -e 'const fs=require("fs"); const value=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); const out=value[process.argv[2]]; process.stdout.write(out === null ? "null" : String(out));' "$file" "$key"
}

lifecycle_field() { field "$SESSION_ROOT/$1/lifecycle.json" "$2"; }

publish_worker() {
	local id="$1" body="$2" dir="$SESSION_ROOT/$id"
	mkdir -p "$dir"
	node "$STATE_HELPER" init "$dir/lifecycle.json" "$id" 1000
	node "$STATE_HELPER" transition "$dir/lifecycle.json" working 1001 >/dev/null
	printf '%s\n' '%fake-pane' >"$dir/pane"
	printf '%s\n' "$body" >"$dir/report.next.md"
	"$CLI" publish "$id" completed "$dir/report.next.md" 1 >/dev/null
}

ack_worker() {
	local id="$1" event_id spool_name
	event_id=$(lifecycle_field "$id" eventId)
	spool_name=$(lifecycle_field "$id" spoolName)
	"$CLI" ack "$id" "$event_id" "$spool_name.json" >/dev/null
}

write_session_evidence() {
	local id="$1" event_id status report_path
	event_id=$(lifecycle_field "$id" eventId)
	status=done
	report_path=$(lifecycle_field "$id" reportPath)
	printf '%s\n' '{"type":"session","version":3,"id":"fake","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/tmp"}' >"$SESSION_FILE"
	node - "$SESSION_FILE" "$id" "$event_id" "$status" "$report_path" <<'NODE'
const fs = require("fs");
const [file, id, eventId, status, reportPath] = process.argv.slice(2);
const entry = {
	type: "custom_message",
	id: "abcd1234",
	parentId: null,
	timestamp: "2026-01-01T00:00:01.000Z",
	customType: "subagent-report",
	content: "report delivered",
	display: true,
	details: { id, status, reportPath, eventId },
};
fs.appendFileSync(file, `${JSON.stringify(entry)}\n`);
NODE
}

make_duplicate_pending() {
	local id="$1" variant="${2:-valid}" event_id spool_name archive pending report2
	event_id=$(lifecycle_field "$id" eventId)
	spool_name=$(lifecycle_field "$id" spoolName)
	archive="$SESSION_ROOT/$id/events/$event_id.json"
	pending="$SESSION_ROOT/.watcher-pending/$spool_name.json"
	report2="$SESSION_ROOT/$id/reports/2.md"
	cp "$SESSION_ROOT/$id/reports/1.md" "$report2"
	mkdir -p "$SESSION_ROOT/.watcher-pending"
	node - "$archive" "$pending" "$report2" "$variant" <<'NODE'
const fs = require("fs");
const [archivePath, pendingPath, report2, variant] = process.argv.slice(2);
const event = JSON.parse(fs.readFileSync(archivePath, "utf8"));
event.reportPath = report2;
event.createdAt += 7;
if (variant === "body") event.reportBody += "changed\n";
if (variant === "generation") event.generation += 1;
if (variant === "event-id") event.eventId = "0".repeat(64);
fs.writeFileSync(pendingPath, `${JSON.stringify(event)}\n`);
NODE
}

setup_conflict() {
	local id="$1" variant="${2:-valid}"
	publish_worker "$id" "recovery report $id"
	ack_worker "$id"
	write_session_evidence "$id"
	make_duplicate_pending "$id" "$variant"
}

assert_pending_present() {
	local id="$1" event_id spool_name
	event_id=$(lifecycle_field "$id" eventId)
	spool_name=$(lifecycle_field "$id" spoolName)
	[ -f "$SESSION_ROOT/.watcher-pending/$spool_name.json" ]
}

assert_repair_rejects_without_mutation() {
	local id="$1" before_lifecycle="$2" before_pending="$3" before_archive="$4"
	if "$CLI" repair-duplicate-after-ack "$id" "$(lifecycle_field "$id" eventId)" --session-file "$SESSION_FILE" --apply >"$TMP/reject.$id.out" 2>"$TMP/reject.$id.err"; then
		echo "repair unexpectedly succeeded for worker $id" >&2
		return 1
	fi
	[ "$(sha "$SESSION_ROOT/$id/lifecycle.json")" = "$before_lifecycle" ]
	[ "$(sha "$SESSION_ROOT/.watcher-pending/$(lifecycle_field "$id" spoolName).json")" = "$before_pending" ]
	[ "$(sha "$SESSION_ROOT/$id/events/$(lifecycle_field "$id" eventId).json")" = "$before_archive" ]
}

assert_repair_rejects_path_without_mutation() {
	local id="$1" mode="$2" pending_path="$3" target_path="$4" before_lifecycle="$5" before_archive="$6" before_target="$7"
	local apply_arg=""
	[ "$mode" = apply ] && apply_arg=--apply
	if "$CLI" repair-duplicate-after-ack "$id" "$(lifecycle_field "$id" eventId)" --session-file "$SESSION_FILE" $apply_arg >"$TMP/reject-path.$id.$mode.out" 2>"$TMP/reject-path.$id.$mode.err"; then
		echo "repair unexpectedly accepted unsafe path for worker $id in $mode" >&2
		return 1
	fi
	[ "$(sha "$SESSION_ROOT/$id/lifecycle.json")" = "$before_lifecycle" ]
	[ "$(sha "$SESSION_ROOT/$id/events/$(lifecycle_field "$id" eventId).json")" = "$before_archive" ]
	[ -e "$pending_path" ]
	[ "$(sha "$target_path")" = "$before_target" ]
}

setup_conflict 1 valid
before_lifecycle=$(sha "$SESSION_ROOT/1/lifecycle.json")
before_archive=$(sha "$SESSION_ROOT/1/events/$(lifecycle_field 1 eventId).json")
before_marker=$(sha "$SESSION_ROOT/.watcher-delivered/$(lifecycle_field 1 eventId)")
"$CLI" repair-duplicate-after-ack 1 "$(lifecycle_field 1 eventId)" --session-file "$SESSION_FILE" >"$TMP/dry-run.out" 2>"$TMP/dry-run.err"
assert_pending_present 1
[ "$(sha "$SESSION_ROOT/1/lifecycle.json")" = "$before_lifecycle" ]
"$CLI" repair-duplicate-after-ack 1 "$(lifecycle_field 1 eventId)" --session-file "$SESSION_FILE" --apply >"$TMP/apply.out" 2>"$TMP/apply.err"
[ ! -e "$SESSION_ROOT/.watcher-pending/$(lifecycle_field 1 spoolName).json" ]
[ "$(lifecycle_field 1 retained)" = true ]
[ "$(lifecycle_field 1 candidateSince)" = null ]
[ "$(sha "$SESSION_ROOT/1/events/$(lifecycle_field 1 eventId).json")" = "$before_archive" ]
[ "$(sha "$SESSION_ROOT/.watcher-delivered/$(lifecycle_field 1 eventId)")" = "$before_marker" ]
[ -f "$SESSION_ROOT/1/reports/1.md" ]
[ -f "$SESSION_ROOT/1/reports/2.md" ]
quarantine_file=$(find "$SESSION_ROOT/.recovery-quarantine" -type f -name 'pending.*.json' -print -quit)
[ -n "$quarantine_file" ]
[ -f "$(dirname "$quarantine_file")/manifest.pre.json" ]
[ -f "$(dirname "$quarantine_file")/manifest.post.json" ]
"$CLI" ack 1 "$(lifecycle_field 1 eventId)" "$(lifecycle_field 1 spoolName).json" >/dev/null
[ ! -e "$SESSION_ROOT/.watcher-pending/$(lifecycle_field 1 spoolName).json" ]

setup_conflict 2 body
assert_repair_rejects_without_mutation 2 "$(sha "$SESSION_ROOT/2/lifecycle.json")" "$(sha "$SESSION_ROOT/.watcher-pending/$(lifecycle_field 2 spoolName).json")" "$(sha "$SESSION_ROOT/2/events/$(lifecycle_field 2 eventId).json")"

setup_conflict 3 generation
assert_repair_rejects_without_mutation 3 "$(sha "$SESSION_ROOT/3/lifecycle.json")" "$(sha "$SESSION_ROOT/.watcher-pending/$(lifecycle_field 3 spoolName).json")" "$(sha "$SESSION_ROOT/3/events/$(lifecycle_field 3 eventId).json")"

setup_conflict 4 valid
node - "$SESSION_ROOT/4/events/$(lifecycle_field 4 eventId).json" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const event = JSON.parse(fs.readFileSync(file, "utf8"));
event.reportBody += "archive changed\n";
fs.writeFileSync(file, `${JSON.stringify(event)}\n`);
NODE
assert_repair_rejects_without_mutation 4 "$(sha "$SESSION_ROOT/4/lifecycle.json")" "$(sha "$SESSION_ROOT/.watcher-pending/$(lifecycle_field 4 spoolName).json")" "$(sha "$SESSION_ROOT/4/events/$(lifecycle_field 4 eventId).json")"

setup_conflict 5 valid
rm "$SESSION_ROOT/.watcher-delivered/$(lifecycle_field 5 eventId)"
assert_repair_rejects_without_mutation 5 "$(sha "$SESSION_ROOT/5/lifecycle.json")" "$(sha "$SESSION_ROOT/.watcher-pending/$(lifecycle_field 5 spoolName).json")" "$(sha "$SESSION_ROOT/5/events/$(lifecycle_field 5 eventId).json")"

setup_conflict 6 valid
printf '%s\n' '{"type":"session","version":3,"id":"fake","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/tmp"}' >"$SESSION_FILE"
assert_repair_rejects_without_mutation 6 "$(sha "$SESSION_ROOT/6/lifecycle.json")" "$(sha "$SESSION_ROOT/.watcher-pending/$(lifecycle_field 6 spoolName).json")" "$(sha "$SESSION_ROOT/6/events/$(lifecycle_field 6 eventId).json")"

setup_conflict 7 valid
pending7="$SESSION_ROOT/.watcher-pending/$(lifecycle_field 7 spoolName).json"
target7="$TMP/pending-target-7.json"
mv "$pending7" "$target7"
ln -s "$target7" "$pending7"
assert_repair_rejects_path_without_mutation 7 dry-run "$pending7" "$target7" "$(sha "$SESSION_ROOT/7/lifecycle.json")" "$(sha "$SESSION_ROOT/7/events/$(lifecycle_field 7 eventId).json")" "$(sha "$target7")"
[ -L "$pending7" ]
assert_repair_rejects_path_without_mutation 7 apply "$pending7" "$target7" "$(sha "$SESSION_ROOT/7/lifecycle.json")" "$(sha "$SESSION_ROOT/7/events/$(lifecycle_field 7 eventId).json")" "$(sha "$target7")"
[ -L "$pending7" ]

setup_conflict 8 valid
pending8="$SESSION_ROOT/.watcher-pending/$(lifecycle_field 8 spoolName).json"
archive8_sha=$(sha "$SESSION_ROOT/8/events/$(lifecycle_field 8 eventId).json")
rm "$pending8"
mkdir "$pending8"
for mode in dry-run apply; do
	apply_arg=""
	[ "$mode" = apply ] && apply_arg=--apply
	if "$CLI" repair-duplicate-after-ack 8 "$(lifecycle_field 8 eventId)" --session-file "$SESSION_FILE" $apply_arg >"$TMP/reject-path.8.$mode.out" 2>"$TMP/reject-path.8.$mode.err"; then
		echo "repair unexpectedly accepted directory pending event in $mode" >&2
		exit 1
	fi
	[ -d "$pending8" ]
	[ "$(sha "$SESSION_ROOT/8/events/$(lifecycle_field 8 eventId).json")" = "$archive8_sha" ]
	[ "$(lifecycle_field 8 retained)" = false ]
done

setup_conflict 11 valid
duplicate11="$SESSION_ROOT/11/reports/2.md"
target11="$TMP/duplicate-report-target-11.md"
mv "$duplicate11" "$target11"
ln -s "$target11" "$duplicate11"
assert_repair_rejects_path_without_mutation 11 dry-run "$duplicate11" "$target11" "$(sha "$SESSION_ROOT/11/lifecycle.json")" "$(sha "$SESSION_ROOT/11/events/$(lifecycle_field 11 eventId).json")" "$(sha "$target11")"
[ -L "$duplicate11" ]
assert_repair_rejects_path_without_mutation 11 apply "$duplicate11" "$target11" "$(sha "$SESSION_ROOT/11/lifecycle.json")" "$(sha "$SESSION_ROOT/11/events/$(lifecycle_field 11 eventId).json")" "$(sha "$target11")"
[ -L "$duplicate11" ]
[ "$(lifecycle_field 11 retained)" = false ]

setup_conflict 9 valid
pending9="$SESSION_ROOT/.watcher-pending/$(lifecycle_field 9 spoolName).json"
pending9_sha=$(sha "$pending9")
"$CLI" repair-duplicate-after-ack 9 "$(lifecycle_field 9 eventId)" --session-file "$SESSION_FILE" --apply >"$TMP/apply9.out" 2>"$TMP/apply9.err"
quarantine9=$(find "$SESSION_ROOT/.recovery-quarantine" -type f -name "pending.$(basename "$pending9")" -print -quit)
[ -n "$quarantine9" ]
[ ! -L "$quarantine9" ]
[ -f "$quarantine9" ]
[ "$(sha "$quarantine9")" = "$pending9_sha" ]

setup_conflict 12 valid
pending12="$SESSION_ROOT/.watcher-pending/$(lifecycle_field 12 spoolName).json"
pending12_sha=$(sha "$pending12")
session12_target="$TMP/session-evidence-target-12.jsonl"
mv "$SESSION_FILE" "$session12_target"
ln -s "$session12_target" "$SESSION_FILE"
for mode in dry-run apply; do
	apply_arg=""
	[ "$mode" = apply ] && apply_arg=--apply
	if "$CLI" repair-duplicate-after-ack 12 "$(lifecycle_field 12 eventId)" --session-file "$SESSION_FILE" $apply_arg >"$TMP/reject-session.12.$mode.out" 2>"$TMP/reject-session.12.$mode.err"; then
		echo "repair unexpectedly accepted symlinked session evidence in $mode" >&2
		exit 1
	fi
	[ -L "$SESSION_FILE" ]
	[ "$(sha "$pending12")" = "$pending12_sha" ]
	[ "$(lifecycle_field 12 retained)" = false ]
done
rm "$SESSION_FILE"
mv "$session12_target" "$SESSION_FILE"

setup_conflict 10 valid
pending10_dir="$SESSION_ROOT/.watcher-pending"
pending10_target="$TMP/pending-dir-target"
pending10_name="$(lifecycle_field 10 spoolName).json"
mv "$pending10_dir" "$pending10_target"
ln -s "$pending10_target" "$pending10_dir"
for mode in dry-run apply; do
	apply_arg=""
	[ "$mode" = apply ] && apply_arg=--apply
	if "$CLI" repair-duplicate-after-ack 10 "$(lifecycle_field 10 eventId)" --session-file "$SESSION_FILE" $apply_arg >"$TMP/reject-parent.10.$mode.out" 2>"$TMP/reject-parent.10.$mode.err"; then
		echo "repair unexpectedly accepted symlinked pending directory in $mode" >&2
		exit 1
	fi
	[ -L "$pending10_dir" ]
	[ -f "$pending10_target/$pending10_name" ]
	[ "$(lifecycle_field 10 retained)" = false ]
done

echo "duplicate recovery: ok"
