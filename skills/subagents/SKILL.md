---
name: subagents
description: >-
  Delegate complete task briefs to isolated Pi workers in tmux panes, send
  lifecycle-safe follow-ups, and receive durable completion reports.
compatibility: Requires Bash, Node 22.6+, tmux, and Pi 0.84+.
---

# Subagents

Resolve [`subagents`](subagents) beside this file and invoke it by absolute path;
examples use `subagents` for readability. The lead Pi process and CLI commands
must share a tmux session.

## Brief and launch

Run `subagents doctor` after setup or configuration changes; fix every `FAIL`.
Incompatible state is not migrated or ignored.

Write a complete brief: objective, worktree and expected branch/HEAD, facts and
instruction paths, allowed writes, checks, and shipping permissions. Workers
have Pi's built-in tools but no lead conversation, discovered extensions, skills,
prompt templates, context files, or session persistence.

For long briefs, use Pi's write tool to create a file, then launch:

```bash
subagents run -m anthropic/claude-sonnet-4-6 --effort high --task-file /tmp/task-brief.md
```

`--task-file PATH` reads literal text from a readable, nonempty UTF-8 file.
Alternatively use `subagents run "<complete task brief>"`. Never combine these
inputs. There is no stdin mode or template expansion; a full brief is required.

Use explicit `-m provider/model --effort LEVEL` when required by your instructions.
Otherwise the lead's effective model and reasoning are inherited through Pi's
Bash-tool environment, falling back to launcher defaults when absent. Explicit
effort overrides inheritance; an explicit model alone does not inherit effort.
Discover models with Pi's `/model` or `pi --list-models`. Worker Pi validates the
selection, so failure can occur after pane creation.

## Receive and follow up

1. Launch independent workers, then **end the lead turn**. Receive pushed reports
   from the watcher instead of polling or running a waiting worker.
2. Read each message's immutable `reports/<n>.md` path; previews can be truncated.
   A `completed` worker awaits follow-up. A `blocked` report requests input.
3. Use `subagents retain <id>` **before lengthy review** or delayed follow-up.
   Use `subagents release <id>` only to undo retention, not after every report.
4. Use `subagents tell <id> "<follow-up>"`, then end the turn again. It cancels
   cleanup, preserves unqueued drafts, advances the generation, and supplies new
   publication instructions before sending. Failed sends leave cleanup cancelled
   and report an error. Do not type directly into the pane.

Workers keep working until complete or blocked. Write `report.next.md`, invoke
the generated `publish` command with the current generation, then wait for
follow-up after success. Publish `blocked`, not `completed`, if input or approval
is needed. A chat reply, report file, quiet pane, or stable output is not completion.

Publication fsyncs the immutable report and queued event before committing the
outcome. Push delivery is at least once; acknowledgement requires the matching
custom message persisted in the lead session. Crashes can replay duplicates;
delivery and acknowledgement failures remain visible.

## Review window and diagnosis

Automatic cleanup defaults to a 600-second grace for unretained, durably completed
workers awaiting follow-up with valid queued or acknowledged reports. It
rechecks the generation and completion lease under the worker lock. Working,
starting, blocked, retained, exited, unknown, missing, and malformed workers are
protected. Successful automatic stops are log-only; failures remain visible.
Cleanup preserves reports and delivery evidence.

Use `subagents status` to diagnose lifecycle, pane liveness, retention, generation,
and cleanup timing without task text. Use `subagents peek <id> [lines]` to inspect
a pane, never to infer completion. Use `subagents stop <id>` only when pane
shutdown is requested, not after every report. It preserves state.

See the [operator guide](../../docs/operators.md) for pull delivery, cleanup modes,
state deletion, configuration, `SUBAGENTS_PI` wrappers, and diagnosis; the
[README](../../README.md) for installation; and the [state protocol](../../docs/state.md)
for durability. Protect sensitive state and reports. Isolation is not a security sandbox.
