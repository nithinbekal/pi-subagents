---
name: subagents
description: >-
  Delegate complete task briefs to isolated Pi workers in tmux panes, send
  lifecycle-safe follow-ups, and receive durable completion reports.
compatibility: Requires Bash, Node 22.6+, tmux, and Pi 0.84+.
---

# Subagents

Run focused Pi workers in a dedicated tmux window. Each worker has an isolated
context and a pane title such as `subagent#1`. Resolve the executable beside this
file and invoke it by absolute path; examples use `subagents` for readability.

## Before delegating

1. Run `subagents doctor` after installation, upgrades, or configuration
   changes. Fix every `FAIL`. Protocol/state mismatches are intentionally not
   migrated or ignored.
2. Write a complete worker brief with the objective, relevant paths and facts,
   constraints, verification, and shipping requirements. Workers do not inherit
   the lead conversation or discovered context files.
3. Usually omit `-m`. Commands launched by Pi expose the effective
   `PI_PROVIDER`, `PI_MODEL`, and `PI_REASONING_LEVEL`; the CLI carries those
   values explicitly through tmux. Use `-m provider/model` or `--effort LEVEL`
   only for a deliberate override.

## Commands

```bash
subagents protocol
subagents config
subagents doctor
subagents run [-m provider/model] [--effort LEVEL] "<complete task brief>"
subagents tell <id> "<follow-up>"
subagents retain <id>
subagents release <id>
subagents status
subagents peek <id> [lines]
subagents ls
subagents cleanup
subagents stop <id|--all>
subagents purge <id|--all>
subagents wait <id> [seconds]
subagents reap
```

`retain` durably cancels cleanup until `release`. `tell` also cancels cleanup,
advances the worker generation, and sends generation-specific publication
instructions before reporting success. Use these commands instead of typing
into the pane.

## Push workflow

1. Start independent workers with `subagents run`.
2. End the lead turn instead of polling. The watcher validates the CLI and state
   protocol, runs `subagents events`, replays the durable report spool, and
   wakes an idle lead unless `SUBAGENTS_WAKE=0`.
3. A `completed` report leaves the worker awaiting follow-up. A `blocked` report
   requests input and is never an automatic cleanup candidate.
4. Use `subagents tell <id> ...` for follow-up, then end the lead turn again.
5. Use `peek` only for diagnosis. Screen stability is not completion.

Delivery is at least once. The watcher acknowledges only after the matching Pi
0.84+ custom message is present in the persisted lead session. A crash can
produce a duplicate, but a queued report is not silently lost.

## Pull fallback

Without the watcher, use `subagents wait <id>` or `subagents reap`. Pull commands
print an immutable queued report before acknowledging it. Do not intentionally
mix push and pull consumers for the same lead session.

## Publication and cleanup guarantees

The generated worker protocol supplies explicit `completed` and `blocked`
publication commands for the current lifecycle generation. The CLI snapshots
and fsyncs the complete report, fsyncs a versioned spool event, and only then
commits lifecycle completion. A report file, `@@DONE@@`, quiet output, or a
stable pane is not sufficient.

Automatic cleanup defaults to `on` with a 600-second grace. It can stop only a
durably completed, unretained `awaiting-follow-up` worker whose complete report
is queued or acknowledged. It performs a second lease check under the worker
event lock. Working, blocked, retained, exited, unknown, missing, malformed, and
screen-stable workers are protected.

Configure cleanup with:

- `SUBAGENTS_CLEANUP_MODE=on|off|dry-run|notify`
- `SUBAGENTS_CLEANUP_GRACE_SECONDS=<non-negative seconds>`

Cleanup and `stop` preserve reports, spool, acknowledgements, and lifecycle
state. `purge` is separate and refuses to delete unacknowledged or unpublished
reports.

## Operational notes

- Every command and watcher instance is scoped to the current tmux session.
- Workers start with `--no-extensions --no-skills --no-prompt-templates
  --no-context-files --no-session`; Pi's built-in coding tools remain available.
- `SUBAGENTS_PI` may be a trusted authentication wrapper plus `pi`. Keep
  credentials outside task briefs, configuration committed to the package, and
  package state.
- `status` and `ls` avoid task text. State and reports can still contain
  sensitive project data; protect the state directory.
- Pi 0.84+ and package state schema 1 are the only supported formats. See the
  package README and `docs/state.md` for exact durability and lifecycle details.
