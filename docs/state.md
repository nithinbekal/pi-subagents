# State, event, and lifecycle protocol

This document describes pi-subagents 0.3.1. The authoritative identity is
`protocol.json`:

- protocol: `pi-subagents`
- package: `0.3.1`
- CLI API: `1`
- watcher API: `1`
- session state schema: `1`
- completion event schema: `1`
- lifecycle schema: `1`

The package does not migrate older or unversioned state. Every session root has
an exact `.schema.json` copy of this contract. The CLI refuses an existing
non-empty session root without that marker, and both CLI and watcher refuse a
mismatch.

## Lifecycle record

Each numeric worker directory contains `lifecycle.json`. Required fields are:

- protocol/package/schema identity;
- numeric string `id`;
- `state` and positive `generation`;
- durable `retained` flag;
- creation/update timestamps;
- nullable cleanup `candidateSince`;
- nullable completion key, spool name, event id, report path, outcome, and
  notification key.

The helper validates the complete record before every transition. A missing or
malformed record is `unknown`: event detection does not reinterpret it as idle,
and automatic cleanup fails closed.

## States and transitions

```text
starting ──launch persisted──> working
working ──publish completed──> awaiting-follow-up
working ──publish blocked────> blocked
working ──pane exits─────────> exited
blocked ──tell───────────────> working (generation + 1)
awaiting-follow-up ──tell────> working (generation + 1)
awaiting-follow-up ──cleanup─> cleaned
any nonterminal ──stop───────> stopped
```

`tell` clears current completion fields but does not remove prior immutable
reports or pending/acknowledged events. A non-empty unqueued `report.next.md`
from a working generation is moved under `unpublished/` rather than deleted.
`retain` can be set in any live
nonterminal state. It clears `candidateSince`. `release` clears retention and,
for an awaiting-follow-up worker, starts a fresh cleanup grace at the release
time.

`blocked`, `working`, `starting`, `exited`, `stopped`, `cleaned`, retained, and
unknown records are never automatic cleanup candidates.

## Publication boundary

The generated protocol tells a worker to write `report.next.md`, then call:

```text
subagents publish <id> <completed|blocked> <report.next.md> <generation>
```

Publication holds `.event.lock` and verifies the exact lifecycle generation and
fixed report source path. It then:

1. creates a new immutable `reports/<n>.md` using temporary-file write, file
   `fsync`, atomic rename, and reports-directory `fsync`;
2. computes a completion key and deterministic event id;
3. writes the strict event to `.watcher-pending/<spool>.json` using file `fsync`,
   atomic rename, and pending-directory `fsync`;
4. atomically writes lifecycle `awaiting-follow-up` or `blocked`;
5. atomically refreshes `result.md` from the immutable snapshot.

The complete report therefore precedes the durable completion record, and the
record precedes lifecycle cleanup eligibility. A crash after step 3 can be
retried: the deterministic event is validated and reused before the lifecycle
transition. Snapshot names are never overwritten. An orphan snapshot from a
crash before queue persistence remains visible and blocks purge.

`@@DONE@@` is a behavioral signal for the worker transcript, not a state
transition. A non-empty `result.md`, non-empty `report.next.md`, quiet pane, or
stable pane capture cannot create completion state.

## Completion event

A schema-1 event has exactly these fields:

- `protocolId`, `packageVersion`, `schemaVersion`
- worker `id` and lifecycle `generation`
- `status`: `done`, `blocked`, or `exited`
- `outcome`: `completed`, `blocked`, or `exited`
- deterministic `completionKey` and SHA-256 `eventId`
- immutable `reportPath` and complete `reportBody`
- `createdAt`

Status and outcome must agree. The event id hashes protocol id, event schema,
worker id, generation, status, and completion key. The report path must be a
non-empty file under that worker's `reports/` directory, and its contents must
still equal `reportBody`.

The watcher requires the exact event shape. An incompatible or malformed record
is reported and preserved in place. It is not delivered, acknowledged,
quarantined, or used for cleanup.

## Delivery and acknowledgement

The watcher may inject the same event more than once, but it does not
acknowledge on `sendMessage` return. It scans the Pi 0.84+ session JSONL until it
observes a top-level `custom_message` with custom type `subagent-report` and the
matching event id.

The watcher then invokes the CLI `ack` operation. Under `.event.lock`, the CLI:

1. revalidates the pending event and immutable report;
2. durably writes `.watcher-delivered/<eventId>`;
3. moves the pending event into `<worker>/events/<eventId>.json`;
4. fsyncs the pending and archive directories.

The archive is acknowledgement evidence and remains until explicit purge. There
is no time-based acknowledgement pruning. If a crash occurs after Pi persistence
but before acknowledgement, replay can duplicate delivery; it cannot silently
lose the pending event.

Pull delivery uses the same event and acknowledgement operation. `wait` and
`reap` acknowledge only after printing the immutable report succeeds.

## Cleanup lease

For an unretained completed publication, `candidateSince` is the lifecycle
commit time. Release sets a fresh value. Cleanup phase one validates:

- state is `awaiting-follow-up`;
- retention is false;
- grace has elapsed;
- lifecycle completion fields are complete;
- immutable report path/body are valid;
- the matching event is pending, or archived with a delivery marker.

Cleanup then acquires `.event.lock`, repeats the full check, and requires the
same generation, candidate timestamp, and event id. Only then can `on` mode stop
the pane and transition to `cleaned`. `dry-run` does not mutate. `notify` stores
a notice key to avoid repeated notices. `off` skips evaluation.

Stopping a pane never deletes state. Cleanup can stop an already-dead eligible
pane by committing `cleaned`, but an ordinary unexplained exit has state
`exited`, not a cleanup candidate.

## Stop and purge

Manual `stop` holds `.event.lock`, stops the pane, and records `stopped` when the
lifecycle is valid. It preserves mutable reports, immutable reports, pending
events, archives, and delivery markers. If lifecycle is malformed, manual stop
can still stop the pane but reports the failed state transition.

`purge` is separate and requires:

- terminal lifecycle (`cleaned`, `stopped`, or `exited`);
- dead pane;
- no pending event for the worker;
- a valid archived event and delivery marker for every referenced report;
- no immutable snapshot that lacks an archived acknowledgement;
- no non-empty mutable or next report whose exact body lacks acknowledgement;
- no preserved unqueued draft under `unpublished/`.

The worker directory is removed while holding its event lock. Only then are its
global delivered markers removed.

## Lock protocol

`.schema.lock`, `.seq.lock`, `.window.lock`, and every `.event.lock` use the same
hard-link algorithm:

1. write owner PID, process identity, random token, and timestamp to a private
   candidate;
2. publish by hard-linking the complete candidate to the lock path;
3. contenders hard-link the published inode to a private inspection name before
   reading it;
4. initialized locals and guarded reads treat path disappearance as contention;
5. reclaim only after owner death/reuse is established and a recovery hard link
   proves the same inode is still published.

Lock age never evicts a live owner. Recovery residue fails closed and is
reported by `doctor`.
