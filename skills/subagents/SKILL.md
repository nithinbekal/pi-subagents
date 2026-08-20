---
name: subagents
description: >-
  Delegate complete task briefs to isolated Pi agents in tmux panes, send
  follow-up messages, and collect completion reports. Use for parallel or
  context-heavy work when Pi is running inside tmux.
compatibility: Requires bash, tmux, and the Pi coding-agent CLI.
---

# Subagents

Run focused Pi agents in a dedicated tmux window. Each agent has an isolated
context and a pane title of `subagent#<id>`. The lead communicates through the
CLI and receives reports through the watcher extension or pull commands.

Resolve the executable beside this file and invoke it by absolute path. The
examples below use `subagents` for readability.

## Before delegating

1. Run `subagents doctor` after installation or configuration changes. Fix each
   `FAIL`; warnings identify stale state.
2. Write the task as a complete worker brief. Include the objective, relevant
   paths and context, constraints, expected verification, and reporting or
   shipping requirements. Workers do not inherit the lead's conversation or
   discovered context files.
3. Usually omit `-m` so the new Pi process uses the launcher's current/default
   model. Pass `-m provider/model` only when the spawning agent deliberately
   chooses another model.

## Commands

```bash
subagents config
subagents doctor
subagents run [-m provider/model] [--effort LEVEL] "<complete task brief>"
subagents tell <id> "<message>"
subagents status
subagents peek <id> [lines]
subagents ls
subagents stop <id|--all>
subagents wait <id> [seconds]
subagents reap
```

`--effort` accepts Pi's thinking levels. Model ids must be provider-qualified.
When `-m`/`--model` is absent, the CLI deliberately passes no model flag.

## Push workflow (watcher loaded)

1. Start one or more independent agents with `subagents run`.
2. End the lead turn instead of polling. The watcher calls `subagents events`,
   injects each new report, and can wake an idle lead.
3. If a report requests input, use `subagents tell <id> ...`, then end the lead
   turn again.
4. Use `peek` only to diagnose a reported stall. Stop agents that will not be
   reused.

Do not combine watcher mode with `wait` or `reap`: those pull commands consume
the same completion events.

## Pull fallback (watcher not loaded)

Use `subagents wait <id>` for one agent or `subagents reap` for all newly
finished agents. On timeout or idle, inspect once with `peek`, answer with
`tell`, and wait again.

## Operational notes

- Every command and watcher instance is scoped to the current tmux session.
- The CLI starts subagents with `--no-extensions --no-skills
  --no-prompt-templates --no-context-files --no-session`; Pi's built-in tools
  remain available.
- The report protocol requires the subagent to overwrite its assigned
  `result.md`, print `@@DONE@@`, and wait for follow-up work.
- `SUBAGENTS_PI` may name a trusted auth wrapper plus `pi`. Never put credentials
  directly in task briefs, package configuration, or state.
- See the package README for all environment variables, state layout, tmux
  requirements, and known Pi coupling.
