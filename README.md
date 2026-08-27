# pi-subagents

A public Pi package for running isolated workers in tmux panes. It provides:

- `skills/subagents/subagents`: the Bash CLI, report publisher, lifecycle manager,
  and conservative completed-worker cleanup;
- `skills/subagents/SKILL.md`: instructions Pi can load on demand;
- `extensions/subagents-watch.ts`: polling, at-least-once report delivery to the
  lead Pi session;
- `protocol.json`: the package, CLI, watcher, event, and state contract.

The package contains no task templates, roles, credentials, model defaults, or
machine-generated state. The spawning agent supplies each complete task brief.

> Pi packages and skills run with your user permissions. Review the extension
> and executable before installing them.

## Requirements and compatibility

- Pi coding agent **0.84 or later**, using the Pi 0.84+ top-level
  `custom_message` session format
- Bash 3.2 or later
- Node 22.6 or later
- tmux; the lead Pi process and CLI commands must share one tmux session
- a local state filesystem with atomic rename, hard links, and `fsync`
- standard Unix tools including `awk`, `cksum`, `grep`, `ps`, and `tail`

Version 0.3.0 supports only its current versioned state and event formats. It
does not read, migrate, or silently brand legacy package state. The package
manifest, `protocol.json`, CLI constants, state helper, watcher handshake,
session state marker, lifecycle records, and completion events identify their
versions. A mismatch fails loudly and preserves the existing state.

## Try or install

Load a checkout for one Pi process:

```bash
pi -e /absolute/path/to/pi-subagents
```

Or install it as a local Pi package:

```bash
pi install /absolute/path/to/pi-subagents
```

Pi package discovery loads the extension and skill. Humans may optionally put
the CLI on `PATH`:

```bash
ln -s /absolute/path/to/pi-subagents/skills/subagents/subagents ~/bin/subagents
```

Run `subagents doctor` inside tmux after installation or configuration changes.

## Configuration

All configuration is environment-based. The CLI and watcher must resolve the
same state directory and package version.

| Variable | Used by | Default | Meaning |
| --- | --- | --- | --- |
| `SUBAGENTS_STATE_DIR` | CLI, watcher | `${XDG_STATE_HOME:-$HOME/.local/state}/subagents` | Exact state root. |
| `XDG_STATE_HOME` | CLI, watcher | `$HOME/.local/state` | Base when `SUBAGENTS_STATE_DIR` is unset. |
| `SUBAGENTS_PI` | CLI | `pi` | Trusted worker launcher command, optionally an authentication wrapper followed by `pi`. |
| `SUBAGENTS_BIN` | watcher | package-local CLI | Explicit executable used for protocol handshake, events, cleanup, and acknowledgements. |
| `SUBAGENTS_WINDOW_NAME` | CLI | `subagents` | tmux window name/prefix. |
| `SUBAGENTS_WAKE` | watcher | `1` | Set to `0` to inject reports without waking an idle lead. |
| `SUBAGENTS_WATCH_MS` | watcher | `3000` | Poll interval in milliseconds. Invalid or non-positive values use 3000. |
| `SUBAGENTS_CLEANUP_MODE` | CLI, watcher-launched CLI | `on` | `on`, `off`, `dry-run`, or `notify`. |
| `SUBAGENTS_CLEANUP_GRACE_SECONDS` | CLI, watcher-launched CLI | `600` | Non-negative grace after a completed worker becomes cleanup-eligible. |

`on` is deliberately useful by default: a durably completed worker that is
awaiting follow-up becomes eligible after ten minutes. The other modes are:

- `off`: do not evaluate or stop candidates;
- `dry-run`: report what would stop, without changing lifecycle or panes;
- `notify`: report each candidate once and keep its pane;
- `on`: perform a locked two-phase eligibility check, stop the pane, and retain
  every report, event record, acknowledgement, and lifecycle file.

Use `subagents config` to show resolved values and `subagents protocol` to show
the exact package contract. Environment used by watcher subprocesses must be
present in the lead Pi process. tmux servers may outlive the shell that created
them.

### Trusted launcher wrappers

`SUBAGENTS_PI` supports providers that inject authentication through a wrapper:

```bash
export SUBAGENTS_PI="$HOME/bin/with-provider-auth pi"
```

It is a trusted shell command and is intentionally word-split. Embedded shell
quoting is not a portable argument parser, and executable paths with spaces are
unsupported. Keep wrapper code and credentials outside this repository.
Task text, generated paths, model ids, and effort values are separately quoted.

## Tasks, models, and reasoning inheritance

Start a worker with a complete brief:

```bash
subagents run "Inspect the parser, fix the reported bug, run its focused checks, and report changed files and results."
```

Workers start with Pi's built-in coding tools but with discovered extensions,
skills, prompt templates, context files, and session persistence disabled. The
brief must contain the objective, relevant paths and context, constraints,
verification, and shipping requirements.

Commands launched by Pi's Bash tool receive the lead's effective
`PI_PROVIDER`, `PI_MODEL`, and `PI_REASONING_LEVEL`. When `-m` is absent, the CLI
turns those values into explicit `--model provider/model` and `--thinking`
arguments and also injects the matching variables into the tmux child command.
This avoids stale tmux-server defaults. If the lead metadata is unavailable, the
launcher default is used; a partial or malformed inheritance tuple fails.

Explicit selection remains explicit:

```bash
subagents run -m anthropic/claude-sonnet-4-6 "<complete brief>"
subagents run --model openai/gpt-5.4 --effort high "<complete brief>"
```

A model override must be provider-qualified. `--effort` accepts Pi's supported
levels. An explicit model without `--effort` does not inherit the old model's
reasoning level. An explicit effort overrides inherited reasoning.

## CLI workflow

```bash
subagents doctor
subagents run "Make the requested change, verify it, and report the result"
subagents status
subagents retain 1
subagents release 1
subagents tell 1 "Use the existing parser rather than adding a dependency"
subagents peek 1 60
subagents stop 1
subagents purge 1       # only after every published report is acknowledged
```

`status` and `ls` report ids, lifecycle state, pane liveness, retention,
generation, and cleanup timing. They intentionally do not print task text.
`peek` is the explicit command for inspecting pane content.

### Retain, release, and follow-up

`retain <id>` sets a durable retention flag and cancels any cleanup candidate.
`release <id>` clears retention; an awaiting-follow-up worker receives a fresh
cleanup grace period. `tell <id> ...` takes the worker event lock, preserves any unqueued draft under
`unpublished/`, advances its generation, clears only already-queued mutable
publication state, rewrites its generation-specific protocol, and marks it
working before sending the message. A failed send is
reported as an error and leaves cleanup cancelled rather than claiming success.

Use `retain` before a long review or when follow-up may arrive after the normal
grace. Use `tell` and `retain` rather than typing directly into a worker pane so
the lifecycle lease remains authoritative.

## Atomic completion publication

Each worker receives a generated protocol containing two explicit publication
commands for its current generation: `completed` and `blocked`.

The worker writes a complete report to `report.next.md` and invokes the chosen
`subagents publish` command. Under the worker's event lock, publication does the
following in order:

1. validate the lifecycle and exact generation lease;
2. copy the complete report to a new immutable `reports/<n>.md` snapshot and
   `fsync` it;
3. write and `fsync` a deterministic, versioned completion record in
   `.watcher-pending`, then `fsync` the directory;
4. atomically commit lifecycle state as `awaiting-follow-up` or `blocked`;
5. atomically refresh `result.md` for human inspection.

The report snapshot is therefore complete before the durable event exists, and
the event exists before cleanup eligibility. A crash after spool persistence
but before lifecycle commit is recovered by replaying the same deterministic
publication. Existing snapshots are never overwritten.

A report file by itself, `@@DONE@@`, a quiet pane, or stable screen output is not
a completion signal. Missing, stale, malformed, or unknown lifecycle state is
treated as working/unknown and protected. `blocked` is explicit and never
cleanup-eligible. A worker that exits without publication can produce an
`exited` diagnostic event, but it is not a cleanup candidate.

## Push and pull delivery

### Push mode

With `subagents-watch` loaded, start workers and end the lead turn. The watcher:

1. validates its package and CLI protocol before touching state;
2. validates the session `.schema.json` before reading its spool;
3. replays each strict, versioned completion event with `pi.sendMessage`;
4. waits until the matching Pi 0.84+ `custom_message` entry is observed in the
   persisted session JSONL;
5. asks the CLI to acknowledge the event under the worker event lock.

Acknowledgement writes a durable delivery marker and moves the pending event to
the worker's acknowledgement archive. Malformed or mismatched records are left
in place and reported; the watcher never quarantines or deletes them as if they
were delivered.

Delivery is **at least once**. A crash after Pi persists the message but before
the acknowledgement may replay a duplicate. This is preferred to silent loss.
The watcher surfaces CLI detection, delivery, and acknowledgement failures.

### Pull mode

Without the watcher, use:

```bash
subagents wait <id> [seconds]
subagents reap
```

Pull commands replay a still-pending durable event, print its immutable report,
and acknowledge only after printing succeeds. Do not intentionally mix push and
pull consumers for the same lead session.

## Cleanup safety model

Automatic cleanup considers only a lifecycle that is all of the following:

- explicitly `completed` and `awaiting-follow-up`;
- not retained and not superseded by `tell`;
- past the configured grace period;
- tied to a non-empty immutable report inside that worker's `reports/` folder;
- backed by a strict completion record that is still queued or durably
  acknowledged.

Candidate discovery is followed by a second eligibility check while holding the
same event lock used by publication, `tell`, `retain`, `release`, stop, and
acknowledgement. The generation and event lease must still match. Cleanup never
uses pane stability.

Automatic cleanup never stops `starting`, `working`, `blocked`, `exited`,
retained, unknown, missing, malformed, or merely screen-stable workers. It stops
only the pane and marks lifecycle `cleaned`; it does not delete worker state,
spool records, reports, or acknowledgement evidence.

`subagents stop` is an explicit manual pane stop. It uses the event lock and
preserves state. `subagents purge` is a separate explicit operation and refuses
to proceed while a pane is alive, an event is pending, a report snapshot lacks
acknowledgement evidence, or a non-empty current/unpublished report was never
queued and acknowledged.

## State layout

State is partitioned by tmux's stable session id (`$1`, `$2`, and so on):

```text
$SUBAGENTS_STATE_DIR/
└── $1/
    ├── .schema.json                 # exact protocol.json contract
    ├── .seq                         # monotonic worker id
    ├── .seq.lock                    # transient hard-link lock
    ├── .window.lock                 # transient hard-link lock
    ├── .watcher-pending/            # strict durable completion spool
    ├── .watcher-delivered/          # durable acknowledgement markers
    └── 1/
        ├── .event.lock              # publish/tell/stop/cleanup/ack lock
        ├── lifecycle.json           # generation, state, retention, candidate lease
        ├── pane                     # tmux pane id
        ├── .launch-ready            # parent setup gate released before Pi starts
        ├── protocol.md              # generated publication instructions
        ├── task                     # original complete brief; not shown by status
        ├── report.next.md           # generation report source
        ├── result.md                # latest published report
        ├── reports/                 # immutable report snapshots
        └── events/                  # acknowledged completion records
```

See [`docs/state.md`](docs/state.md) for lifecycle transitions, validation
invariants, lock behavior, and crash boundaries.

Tasks and reports can contain sensitive project information. Protect the state
directory accordingly. State for an old tmux session is not automatically
migrated into a new session.

## Locking and failure behavior

All critical sections use one hard-link lock protocol. Owner metadata is fully
written before publication. Contenders pin the published inode with a temporary
hard link before inspection. Every lock read initializes and guards owner
fields, so a normal owner can unlink between checks without producing an
unbound-variable failure. A live owner is never evicted by age. Dead-owner
recovery verifies the same inode through a recovery link before unlinking it.

If a process dies inside takeover, residue fails closed. `doctor` reports the
path; remove it only after confirming no CLI process is active. Launch and tmux
send failures are errors, not success messages. Partial launch state is kept
when it may aid recovery.

## Development checks

```bash
pnpm test
bash -n skills/subagents/subagents tests/*.sh
node --check skills/subagents/state.mjs
node --experimental-strip-types --test tests/config.test.ts
bash tests/cli-smoke.sh
bash tests/cli-reliability.sh
bash tests/cli-lifecycle.sh
bash tests/public-safety.sh
git diff --check
```

The suite covers repeated concurrent launch contention, abandoned locks,
protocol and state mismatches, effective model/reasoning inheritance, atomic
publication recovery, at-least-once watcher acknowledgement, lifecycle
transitions, report preservation, cleanup defaults and grace, dry-run/off/notify,
retain/release/tell cancellation, and protection for blocked, working, unknown,
malformed, and unpublished workers.

## License

MIT. See [LICENSE](LICENSE).
