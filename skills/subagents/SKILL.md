---
name: subagents
description: >-
  Delegate focused tasks to isolated Pi agents in tmux panes, send follow-up
  messages, and collect completion reports. Use for parallel or context-heavy
  work when tmux and at least one local role file are configured.
compatibility: Requires bash, tmux, and the Pi coding-agent CLI.
---

# Subagents

Run focused Pi agents in a dedicated tmux window. Each agent has an isolated
context and a pane title of `subagent#<id> <role>`. The lead communicates through
the CLI and receives reports through the watcher extension or pull commands.

Resolve the executable beside this file and invoke it by absolute path. The
examples below use `subagents` for readability.

## Before delegating

1. Run `subagents roles`; role names are filenames from the configured role
   directories. Do not invent a role name.
2. Run `subagents doctor` after installation or configuration changes. Fix each
   `FAIL`; warnings usually identify inherited models or stale state.
3. Choose a role whose prompt and tools fit the task. `run -m provider/model`
   may override its configured model.

This package intentionally supplies no roles or model defaults. See the package
README for role format and `SUBAGENTS_ROLE_DIRS` configuration.

## Commands

```bash
subagents config
subagents doctor
subagents roles
subagents run [-m provider/model] [--effort LEVEL] <role> "<task>"
subagents tell <id> "<message>"
subagents status
subagents peek <id> [lines]
subagents ls
subagents stop <id|--all>
subagents wait <id> [seconds]
subagents reap
```

`--effort` accepts Pi's thinking levels. Use provider-qualified model ids to
avoid ambiguity.

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
  --no-prompt-templates --no-session`; role tools and the built-in Pi tools are
  the available capabilities.
- The role protocol requires the subagent to overwrite its assigned
  `result.md`, print `@@DONE@@`, and wait for follow-up work.
- `SUBAGENTS_PI` may name a trusted auth wrapper plus `pi`. Never put credentials
  directly in role files, tasks, package configuration, or state.
- See the package README for all environment variables, state layout, tmux
  requirements, and known Pi coupling.
