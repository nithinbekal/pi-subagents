# pi-subagents

A public Pi package for running isolated workers in tmux panes. The lead supplies
complete task briefs; workers publish durable reports that the watcher pushes
back to the lead session.

- [`skills/subagents/subagents`](skills/subagents/subagents): Bash CLI and lifecycle manager.
- [`skills/subagents/SKILL.md`](skills/subagents/SKILL.md): on-demand agent instructions.
- [`extensions/subagents-watch.ts`](extensions/subagents-watch.ts): report delivery and cleanup scheduling.
- [`protocol.json`](protocol.json): package, CLI, watcher, event, and state contract.

The package contains no task templates, roles, credentials, model defaults, or
machine-generated state.

> Pi packages and skills run with your user permissions. Review the extension
> and executable before installing them. Worker isolation is not a security sandbox.

## Requirements and compatibility

- Pi coding agent **0.84 or later**, using the Pi 0.84+ top-level
  `custom_message` session format
- Bash 3.2 or later
- Node 22.6 or later
- tmux; the lead Pi process and CLI commands must share one tmux session
- a local state filesystem with atomic rename, hard links, and `fsync`
- standard Unix tools including `awk`, `cksum`, `grep`, `ps`, and `tail`

Version 0.3.2 supports only its current versioned state and event formats. It
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

Pi package discovery loads the extension and skill. Invoke the package-local
CLI by absolute path. Examples below use `subagents` for readability:

```bash
/absolute/path/to/pi-subagents/skills/subagents/subagents doctor
```

Run `doctor` inside tmux after installation, upgrades, or configuration changes.
Fix every `FAIL` before launching workers. For optional `PATH` setup and
configuration, see the [operator guide](docs/operators.md#configuration).

After changing package files, coordinate a normal Pi `/reload` or restart to
activate watcher changes. Running watchers use the on-disk CLI immediately, but
keep their loaded extension code until reload/restart. `doctor` checks the disk
package and state, not the extension revision loaded in a running Pi process.

## Delegate a task

Write the complete brief to a file using your editor or Pi's write tool. Include
the objective, repository/worktree and expected branch/HEAD, relevant facts and
instruction paths, allowed writes, verification, and commit/push permissions.
Workers do not inherit the lead conversation or discovered context files.

For a long brief, launch from the file:

```bash
subagents run --task-file /tmp/parser-brief.md
```

`--task-file PATH` reads literal text from a readable, nonempty UTF-8 file,
without executing shell expressions or expanding templates. It is mutually exclusive
with the positional brief; there is no stdin input mode.
The file must contain the full task brief, not a task name or a role selection.

For either brief input, if its first character is `@`, the launcher prefixes one
newline only to the prompt sent to Pi, preventing Pi from treating the brief as
a file reference. This transport framing does not modify the source task file
or the saved `task` bytes.

Positional briefs remain supported:

```bash
subagents run "In the current checkout, read README.md and report broken relative Markdown links. Do not edit files, change repository or remote state, or delegate. Include the paths checked and findings in your report."
```

Workers start with Pi's built-in coding tools, but discovered extensions, skills,
prompt templates, context files, and session persistence are disabled. Include
any instructions they need to read in the brief.

### Models and effort

For an explicit selection, use a provider-qualified model and an effort level:

```bash
subagents run -m anthropic/claude-sonnet-4-6 --effort high --task-file /tmp/parser-brief.md
```

`--model` is an alias for `-m`. Without a model override, commands launched by
Pi's Bash tool carry the lead's effective `PI_PROVIDER`, `PI_MODEL`, and
`PI_REASONING_LEVEL` explicitly through tmux. Without lead metadata, the
launcher default applies. An explicit effort overrides inherited reasoning; an
explicit model without `--effort` does not inherit the lead model's effort.
Use explicit flags when your task or local instructions require them.

Discover models with Pi's `/model` picker or `pi --list-models`. Model validity
and availability are delegated to worker Pi: an invalid selection can fail
after pane creation. A successful launch is not proof of model acceptance or
authentication. See [model selection and wrappers](docs/operators.md#models-and-launcher-wrappers).

## Receive and follow up

1. Launch independent workers, then **end the lead turn**. The watcher pushes
   reports and wakes an idle lead by default; do not poll for completion.
2. Read the immutable `reports/<n>.md` path in each pushed report. The message
   contains a preview, not necessarily the full report. A `completed` worker
   awaits follow-up; a `blocked` worker needs input and is protected from cleanup.
3. Before a lengthy review or delayed follow-up, use `subagents retain <id>` to
   keep the pane. Use `subagents release <id>` only to undo that retention.
4. Send follow-ups with `subagents tell <id> "<follow-up>"`, then end the turn
   again. `tell` cancels cleanup and advances the generation before sending.
   Use it instead of typing directly into a worker pane.

Workers keep working until complete or blocked, write `report.next.md`, and use
their generated `publish` command for the current generation. Only successful
explicit publication establishes the outcome. A report file, quiet pane, stable
output, or final chat reply does not establish completion. After publication,
the worker waits for follow-up.

Use `subagents status` for lifecycle, pane liveness, retention, generation, and
cleanup timing without task text. Use `subagents peek <id> [lines]` for diagnosis.
If pane shutdown is requested, `subagents stop <id>` stops that pane and preserves
state. Do not stop workers just because they reported.

## Reports and automatic cleanup

Publication saves and fsyncs an immutable report, then fsyncs the queued event,
then commits lifecycle completion. The watcher delivers **at least once** and
acknowledges only after the matching custom message appears in the persisted
lead session. A crash can replay a duplicate; pending reports are not silently
discarded. Delivery and acknowledgement failures remain visible.

Automatic cleanup defaults to `on` with a **600-second grace**. It stops only
unretained, durably completed workers awaiting follow-up with valid queued or
acknowledged reports. It rechecks the generation and completion lease under the
worker lock. Working, starting, blocked, exited, retained, unknown, missing, and
malformed workers are protected. Successful automatic stops are log-only;
failures remain visible, and explicit commands still print their results.

Cleanup stops panes without deleting reports or delivery evidence. `result.md`
remains a mutable convenience copy: it is empty at launch and reset by `tell`.
Read the event's immutable report for published work; `report.next.md` is the
staging file, and a draft there is not proof of publication.

For [pull delivery](docs/operators.md#pull-delivery-without-the-watcher),
[cleanup modes and explicit state deletion](docs/operators.md#cleanup-and-state-deletion),
[logs and state paths](docs/operators.md#state-and-diagnosis), or
[publication details](docs/operators.md#publication-and-delivery-protocol),
read the operator guide. The [state protocol](docs/state.md) describes lifecycle
transitions, validation, locks, and crash boundaries.

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

`pnpm test` runs the syntax, watcher, CLI, and public-safety checks listed above.
Behavioral tests exercise isolated temporary state and tmux fixtures.

## License

MIT. See [LICENSE](LICENSE).
