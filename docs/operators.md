# Operator guide

For normal delegation, use the [subagents skill](../skills/subagents/SKILL.md):
launch a complete brief, end the lead turn, read the pushed immutable report, and
send follow-up with `tell`. This guide covers setup, fallback delivery, cleanup
policy, and diagnosis. Examples use `subagents` for the package-local executable
at `skills/subagents/subagents`.

## Configuration

All configuration is environment-based. The CLI and watcher must resolve the
same state directory and package version. For a human shell, optionally add the
CLI's containing directory to `PATH`:

```bash
export PATH="/absolute/path/to/pi-subagents/skills/subagents:$PATH"
```

Agents should resolve and invoke the executable by absolute path as instructed
in the skill.

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

```bash
subagents config
subagents protocol
subagents doctor
```

`config` prints the resolved launcher, state root, window name, cleanup settings,
and protocol/package identity. Watcher-only settings are not included in that
output. `protocol` prints the exact package contract. Run `doctor` inside tmux
after installation, upgrades, or configuration changes and fix every `FAIL`.
These are operational commands, not a promise of side-effect-free inspection:
state-scoped commands can initialize state and acquire or recover locks.

When updating package files, follow the [activation guidance](../README.md#try-or-install):
the on-disk CLI changes take effect immediately, but loaded watcher code requires
a coordinated normal Pi `/reload` or restart. `doctor` does not verify which
extension revision is loaded in memory.

Environment used by watcher subprocesses must be present in the lead Pi process.
A one-command environment override affects that command, not the running watcher.
tmux servers can outlive the shell that created them.

### Models and launcher wrappers

Discover models with Pi's `/model` picker or `pi --list-models`. The worker starts
with discovered extensions disabled, so a provider loaded only by a discovered
lead extension is not automatically available to it. Pi owns model validity and
availability; invalid selections and authentication failures can appear after
pane creation. Launch success is not a readiness or authentication guarantee.

Both brief inputs support explicit selection:

```bash
subagents run -m anthropic/claude-sonnet-4-6 --effort high --task-file /tmp/task-brief.md
subagents run --model openai/gpt-5.4 --effort high "<complete task brief>"
```

`--task-file PATH` and a positional brief are mutually exclusive. The file must
be readable UTF-8 text containing the full brief. Empty or whitespace-only files,
invalid UTF-8, and NUL bytes are rejected. Text is read literally; there is no
stdin variant. See the [launch guide](../README.md#delegate-a-task).

Pi treats a prompt argument starting with `@` as a file reference. For either
brief input, the launcher checks its first character and, only when it is `@`,
prefixes one newline to the prompt sent to Pi. Other prompts receive no prefix.
This is transport framing, not a new input mode: it leaves the source task file
and saved `task` bytes unchanged. Task-file text, including trailing newlines,
is preserved in the saved `task`.

A model override must use `provider/model`. `--effort` accepts `off`, `minimal`,
`low`, `medium`, `high`, `xhigh`, and `max`; worker Pi applies model capabilities.
`run` still performs a lightweight launcher/tmux preflight and argument checks.
It does not reject unknown model IDs before creating the pane.

Without `-m`, the CLI carries the lead's effective `PI_PROVIDER` and `PI_MODEL`
into explicit `--model provider/model` arguments and the tmux child environment.
Unless overridden, `PI_REASONING_LEVEL` becomes `--thinking` and a matching
child variable. Pi's Bash tool resolves these values when each command starts,
avoiding stale tmux-server defaults. If metadata is absent, the launcher default
applies. A partial provider/model pair or malformed inherited value fails.
Explicit `--effort` overrides inherited reasoning. An explicit model without an
effort override does not inherit reasoning from the lead model. Task-specific or
personal requirements to choose model and effort explicitly do not disable
inheritance for other launches.

`SUBAGENTS_PI` supports providers that inject authentication through a wrapper:

```bash
export SUBAGENTS_PI="$HOME/bin/with-provider-auth pi"
```

It is a trusted shell command and is intentionally word-split. Embedded shell
quoting is not a portable argument parser, and executable paths with spaces are
unsupported. Keep wrapper code and credentials outside this repository. Task
text, generated paths, model ids, and effort values are separately quoted.

## Pull delivery without the watcher

Push delivery is the default workflow. Without the watcher, the CLI retains
these pull commands:

```text
subagents wait <id> [seconds]
subagents reap
```

`wait` waits for a worker's published report, with a default timeout of 120
seconds. A timeout is not completion. `reap` checks workers for available
reports in one pass. These commands print an immutable queued report before
acknowledging it; printing or acknowledgement failures are reported. They are
consumers, not read-only status commands.

Do not intentionally mix push and pull consumers for the same lead session.
Reading an immutable report directly does not acknowledge it and is the normal
way to inspect the complete body after a push. Pull commands are not a general
archive browser; older generations and terminal workers need direct report
inspection. Keep pending events intact when diagnosing delivery trouble.

## Cleanup and state deletion

### Modes and eligibility

| Mode | Behavior |
| --- | --- |
| `on` | Stop eligible completed panes after the grace period; preserve state and reports. This is the default. |
| `off` | Do not evaluate or stop cleanup candidates. |
| `dry-run` | Report what would stop without changing lifecycle or panes. |
| `notify` | Report eligibility once per candidate and leave the pane running. This does not stop panes. |

`SUBAGENTS_CLEANUP_GRACE_SECONDS` defaults to 600 seconds. For an unretained
completed publication, the grace starts at the lifecycle commit, not when the
lead reads the report. Use `retain <id>` before a lengthy review or delayed
follow-up. It durably cancels the cleanup candidate. Use `release <id>` only to
undo retention; for a worker awaiting follow-up it starts a fresh grace period.
A `tell` cancels cleanup and advances the generation before sending its message.
Use lifecycle commands rather than typing directly into a pane.

Automatic cleanup requires all of the following:

- explicitly completed lifecycle in `awaiting-follow-up`;
- no retention and no superseding follow-up;
- elapsed grace period;
- a nonempty immutable report under that worker's `reports/` directory;
- a valid matching completion event, either pending or durably acknowledged.

Candidate discovery is followed by a second check under the same event lock
used by publication, `tell`, retention, stop, and acknowledgement. The generation,
candidate timestamp, and event lease must still match. Quiet or stable panes are
never evidence of completion. Starting, working, blocked, exited, retained,
unknown, missing, and malformed workers are protected.

The watcher schedules cleanup automatically. To apply the configured policy
explicitly, use `subagents cleanup`. To preview eligibility for one invocation:

```bash
SUBAGENTS_CLEANUP_MODE=dry-run subagents cleanup
```

That override does not change a running watcher's policy. Successful automatic
stops are written only to `watcher.log`, without an inline success notification.
Failures remain visible, including failures in batches that also stopped panes
successfully. Explicit `stop` and `cleanup` commands still print their results.
`notify` mode continues to report eligibility and keep panes alive; it is not
an alias for `on`.

### Explicit pane shutdown

Use `subagents stop <id>` only when pane shutdown is requested. It stops the pane
under the event lock and preserves mutable reports, immutable reports, pending
events, acknowledgements, and lifecycle state. If lifecycle is malformed, it can
still stop the pane but reports the failed state transition. `stop --all` targets
every worker in the current tmux session, including working workers; use it only
when shutdown of all those panes is intended.

Stopping is not state deletion. Leave report history in place after completion.
Neither release nor purge is a routine post-report step.

### Explicit state deletion

`subagents purge <id>` is a separate destructive maintenance operation.
`purge --all` attempts it for all workers in the current tmux session. Purge
requires terminal lifecycle (`cleaned`, `stopped`, or `exited`) and a dead pane,
and refuses deletion if any of these remain:

- a pending event;
- an immutable report without a valid archived event and delivery marker;
- a nonempty mutable report or `report.next.md` body without acknowledgement;
- a preserved unqueued draft under `unpublished/`.

Do not bypass a refusal by deleting reports, drafts, or delivery evidence.
Acknowledgement proves delivery, not that the history is no longer needed.
Choose deletion only when it is intended. Cleanup and stop never require purge.

## State and diagnosis

State is partitioned by tmux's stable session id (`$1`, `$2`, and so on), not by
Pi session id. Commands and the watcher operate in the current tmux session.
State for an old tmux session is not automatically migrated into a new one.

```text
$SUBAGENTS_STATE_DIR/
├── watcher.log                      # all sessions; rotated to watcher.log.1 at 1 MB
└── $1/
    ├── .schema.json                 # exact protocol.json contract
    ├── .seq                         # monotonic worker id
    ├── .seq.lock                    # transient hard-link lock
    ├── .window.lock                 # transient hard-link lock
    ├── .watcher-pending/             # durable completion spool
    ├── .watcher-delivered/           # durable acknowledgement markers
    └── 1/
        ├── .event.lock              # worker publication and lifecycle lock
        ├── lifecycle.json           # generation, state, retention, cleanup lease
        ├── pane                     # tmux pane id
        ├── .launch-ready            # startup gate
        ├── protocol.md              # current generation publication instructions
        ├── task                     # original complete brief
        ├── report.next.md           # staging file; a draft alone is not published
        ├── result.md                # mutable convenience copy, reset by tell
        ├── reports/                 # immutable report snapshots
        ├── unpublished/             # unqueued drafts preserved by tell, if any
        └── events/                  # acknowledged completion records
```

Read the exact immutable report path named by the event. Snapshot numbers need
not equal lifecycle generations. `result.md` is retained for compatibility and
human inspection; it starts empty and is cleared by `tell`, then updated after
publication. It is not a completion signal or an archive. `report.next.md` is
staging input and can contain unpublished work. Its existence does not establish
publication; preserve it and any `unpublished/` drafts during diagnosis.

Use `status` for lifecycle, pane liveness, retention, generation, and cleanup
timing. `ls` remains a compatibility alias. Both omit task text. Use `peek <id>
[lines]` for explicit pane inspection. An `exited` diagnostic means the worker
exited without completing its current publication; it is not completed work.
A dead pane cannot receive `tell`. If further work is needed, inspect preserved
reports and drafts and launch a new worker with a complete brief; there is no
automatic restart or context restoration.

The watcher appends diagnostics to `watcher.log` with timestamp, level, tmux
session, and message. It does not write to the terminal while Pi has a UI. The
first occurrence of each distinct error is also shown as a Pi notification;
repeats and routine lock recoveries stay in the log. Known successful automatic
stops are log-only. Malformed events and package mismatches remain visible and
are preserved in place.

Critical sections use hard-link locks. A live owner is never evicted by age.
Dead-owner recovery verifies inode identity before unlinking the lock. If a
process dies during takeover, residue fails closed. `doctor` reports the path;
remove residue only after confirming that no CLI process is active. Do not
assume `status` or `doctor` is a non-mutating repair tool, or remove locks just
because a command is slow. Launch/send failures are errors, and partial launch
state is retained when it can aid diagnosis.

Tasks, pane output, and reports can contain sensitive project information.
Protect the state directory and keep credentials out of briefs and reports.
Worker resource isolation does not restrict filesystem or network permissions.

## Publication and delivery protocol

The generated `protocol.md` supplies explicit `completed` and `blocked`
publication commands for the worker's current generation:

```text
subagents publish <id> <completed|blocked> <report.next.md> <generation>
```

The report source must be that worker's fixed `report.next.md` path. Workers
keep working until complete or blocked, write the full report, invoke the chosen
command, and wait for follow-up after success. If input or approval is still
needed, use `blocked`. A report file or final chat reply alone is not completion.

Under the worker event lock, publication:

1. validates the lifecycle and exact generation lease;
2. saves a new immutable `reports/<n>.md` snapshot and fsyncs it;
3. writes and fsyncs a deterministic versioned event in `.watcher-pending`, then
   fsyncs that directory;
4. commits lifecycle `awaiting-follow-up` or `blocked` atomically;
5. refreshes the mutable `result.md` convenience copy atomically.

The report precedes the event, and the event precedes cleanup eligibility. A
crash after spool persistence but before lifecycle commit can be recovered by
replaying the same deterministic publication. Existing snapshots are never
overwritten. A file alone cannot establish completion; missing, malformed, or
unknown lifecycle state is treated as working/unknown and protected.

The watcher uses filesystem events plus periodic polling to reconcile the spool.
It validates the package/CLI protocol and session `.schema.json`, then validates
each completion event and immutable report. It sends a custom message to Pi,
waits for the matching Pi 0.84+ top-level `custom_message` in persisted session
JSONL, and only then asks the CLI to acknowledge under the worker event lock.

Acknowledgement durably writes a delivery marker and moves the pending event to
the worker's event archive. Delivery is at least once: a crash after Pi persists
a message but before acknowledgement can replay a duplicate. Malformed or
mismatched records remain in place and are reported, not deleted or quarantined
as if delivered. CLI detection, delivery, and acknowledgement failures surface.

`events` and `ack` are internal watcher operations. `events` can queue exit
diagnostics and apply cleanup; it is not a read-only event listing. Do not call
`ack` manually to clear a delivery failure.

Version 0.3.2 supports only its current versioned formats. Package, CLI, watcher,
state, event, and lifecycle identities must agree. There is no legacy state
migration or automatic rebranding. See the [state protocol](state.md)
for exact validation fields, transitions, acknowledgement evidence, lock
ownership, and crash boundaries, and the [README](../README.md#requirements-and-compatibility)
for requirements.
