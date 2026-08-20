# pi-subagents

A tmux-based worker runner for the Pi coding agent. It packages three pieces:

- `skills/subagents/subagents`: the reusable Bash CLI and on-disk protocol
- `skills/subagents/SKILL.md`: instructions Pi can load on demand
- `extensions/subagents-watch.ts`: optional push delivery of completed reports

The repository contains no worker prompts, model defaults, credentials, or
machine-generated state. The spawning agent chooses a model when needed and
supplies the complete worker brief directly as the task text.

> Pi packages execute with your user permissions. Review the CLI, skill, and
> extension before installing them.

## Requirements

- Pi coding agent with the extension APIs used by Pi 0.84 or later
- Bash 3.2 or later
- tmux; the lead Pi process and every CLI command must run inside the same tmux
  session
- Node 22.6 or later
- a state-directory filesystem that supports atomic rename, hard links, and fsync
- standard Unix tools: `awk`, `grep`, `cksum`, `ps`, and `tail`

The watcher has no third-party runtime dependency. It uses Node built-ins and
Pi's provided `@earendil-works/pi-coding-agent` package. Delivery is polling-only
and does not depend on platform-specific filesystem notification behavior.

## Try or install

From a checkout, Pi can load the package temporarily:

```bash
pi -e /absolute/path/to/pi-subagents
```

Or install it as a local Pi package:

```bash
pi install /absolute/path/to/pi-subagents
```

The latter updates Pi's package settings. This source extraction does not do
that automatically. Package discovery loads the watcher from `extensions/` and
the skill from `skills/`.

The skill calls the executable next to `SKILL.md`. Humans can optionally expose
it on `PATH`:

```bash
ln -s /absolute/path/to/pi-subagents/skills/subagents/subagents ~/bin/subagents
```

## Configuration

All configuration is environment-based so a public checkout has no local paths
or credentials. The CLI and watcher must resolve the same state directory.

| Variable | Used by | Default | Meaning |
| --- | --- | --- | --- |
| `SUBAGENTS_STATE_DIR` | CLI, watcher | `${XDG_STATE_HOME:-$HOME/.local/state}/subagents` | Exact state root. Prefer this when moving state. |
| `XDG_STATE_HOME` | CLI, watcher | `$HOME/.local/state` | Base used only when `SUBAGENTS_STATE_DIR` is unset. |
| `SUBAGENTS_PI` | CLI | `pi` | Trusted launcher command, optionally an auth wrapper followed by `pi`. |
| `SUBAGENTS_BIN` | watcher | package-local CLI | Explicit executable CLI path. |
| `SUBAGENTS_WINDOW_NAME` | CLI | `subagents` | tmux window name/prefix used for worker panes. |
| `SUBAGENTS_WAKE` | watcher | `1` | Set to `0` to inject reports without waking an idle lead. |
| `SUBAGENTS_WATCH_MS` | watcher | `3000` | Poll interval in milliseconds. Non-positive or invalid values use 3000. |

Use `subagents config` to print the CLI's resolved values. Environment variables
must be present in both the lead Pi process and shell commands it launches; tmux
server environments can outlive the shell that created them.

### Auth wrappers and launch behavior

`SUBAGENTS_PI` exists for providers whose credentials are injected by a wrapper:

```bash
export SUBAGENTS_PI="$HOME/bin/with-provider-auth pi"
```

The wrapper is used for interactive worker panes. It should inject
authentication into the child process and then `exec` its arguments. Keep the
wrapper and secrets outside this repository.

To support auth wrappers, `SUBAGENTS_PI` is treated as a trusted shell command
and intentionally word-split. Shell quoting embedded
inside the variable is not a portable argument parser, and command paths with
spaces are unsupported. Do not set this variable from untrusted input. Tasks,
model ids, effort values, and generated prompt paths are separately shell-quoted
before tmux launches Pi.

## Tasks and models

Start a worker with a complete brief:

```bash
subagents run "Inspect the parser, fix the reported bug, run its focused tests, and report changed files and results."
```

The brief must include all context the worker needs: the objective, relevant
paths and facts, constraints, expected verification, and any shipping
requirements. Workers start with discovery of context files, extensions,
skills, and prompt templates disabled. They still receive Pi's normal coding
prompt, built-in tools, the task text, and the generated report protocol.

By default, the CLI omits a model flag so the new Pi process uses the launcher's
current/default model. The spawning agent can choose a provider-qualified model
explicitly:

```bash
subagents run -m anthropic/claude-sonnet-4-6 "<complete task brief>"
subagents run --model openai/gpt-5.4 --effort high "<complete task brief>"
```

## CLI workflow

```bash
subagents doctor
subagents run "Make the requested change, verify it, and report the result"
subagents tell 1 "Use the existing parser rather than adding a dependency"
subagents status
subagents peek 1 60
subagents stop 1
```

`run` creates or reuses one tmux window and tiles one pane per worker. Each pane
starts an ephemeral Pi session with external resources and discovered context
files disabled. The task is the initial user message; a generated system-prompt
appendix contains only the report protocol.

The protocol tells each worker to:

1. treat the launch task as its complete brief and follow later messages as
   additional or replacement instructions;
2. overwrite its assigned `result.md` with a complete report;
3. print a line containing only `@@DONE@@`;
4. wait for a follow-up task.

Completion detection primarily keys on changes to `result.md`. The sentinel is
part of the behavioral protocol; the CLI also has idle/exited fallbacks for
workers that fail to write a report.

### Push and pull delivery

With `subagents-watch` loaded, use push mode: start workers and end the lead
turn. `subagents events` first snapshots and durably queues each report, then
advances its detection marker. The polling watcher injects each queued report as
a `subagent-report` custom message and wakes Pi unless `SUBAGENTS_WAKE=0`.

This ordering closes the CLI-to-watcher crash window: once a completion is
marked as seen, its immutable report body is already fsynced in the spool. A
stable completion key deduplicates replay even if the CLI crashes between the
queue rename and marker write. The watcher retains a spool record until the
matching Pi session entry is observed and a delivery acknowledgement is fsynced.
A crash between Pi persistence and acknowledgement can produce a duplicate,
which is the intentional at-least-once tradeoff; it cannot silently lose the
report.

Without the watcher, use `subagents wait <id>` or `subagents reap`. Do not run
those pull consumers while expecting watcher delivery because completion events
are intentionally emitted once.

One lead Pi watcher per tmux session is supported. Multiple leads in the same
session share a spool and may display duplicate replays; the ledger prioritizes
not losing reports.

## State layout

State is session-scoped by tmux's stable session id (`$1`, `$2`, ...):

```text
$SUBAGENTS_STATE_DIR/
└── $1/
    ├── .seq
    ├── .seq.lock                  # transient id reservation lock file
    ├── .window.lock               # transient tmux window lock file
    ├── .watcher-pending/          # immutable JSON report spool
    ├── .watcher-delivered/        # delivery acknowledgement ledger
    └── 1/
        ├── .event.lock            # transient completion-consumer lock file
        ├── pane                   # tmux pane id
        ├── protocol.md            # generated report protocol
        ├── task                   # original complete task brief
        ├── result.md              # mutable current report
        ├── reports/               # immutable completion snapshots
        └── detection markers      # hashes/counters used by events/wait
```

The three lock sites use one hard-link lock protocol. Owner metadata is
published atomically, live owners are never evicted based on age, and a recovery
link serializes abandoned-lock takeover. Recovery is reported on stderr;
`doctor` also reports abandoned or unsupported lock state. If a process dies
inside the takeover itself, the recovery link is left in place and later callers
fail closed rather than risk concurrent ownership; after confirming no CLI is
running, remove that reported recovery link manually.

Tasks, pane captures, and reports may contain sensitive project information.
Protect the state directory accordingly and clean orphaned tmux session
directories when they are no longer needed. `subagents stop` removes a worker
directory; watcher delivery markers are retained for seven days.

## Compatibility window and coupling

This release supports Pi 0.84 and later, the state layout shown above, and the
Pi v3 top-level `custom_message` session entry written by Pi 0.84+. State layouts
from earlier package releases and pre-0.84 Pi/session message shapes are not
supported or migrated. Stop the affected workers and clear their package state
before upgrading across that boundary.

The reusable protocol and tmux orchestration are generic, but this version is
intentionally coupled in these places:

- The launcher assumes Pi's current CLI flags (`--append-system-prompt`,
  `--no-extensions`, `--no-skills`, `--no-prompt-templates`,
  `--no-context-files`, model/thinking flags) and its interactive
  Enter-to-submit behavior.
- The watcher imports Pi's `ExtensionAPI`, uses `sendMessage` with
  `deliverAs: "steer"`, and acknowledges the persisted Pi 0.84+ v3
  `custom_message` shape.
- Idle detection filters text from Pi's current terminal banner. It is a
  fallback and may need updates when Pi's TUI changes.
- tmux session ids scope state. Moving a running lead between tmux sessions does
  not migrate workers or state.

The watcher checks `SUBAGENTS_BIN` first, then this package's own CLI. A copied
watcher without the package-local CLI must set `SUBAGENTS_BIN` explicitly.

## Development checks

No install step is required on a recent Node release:

```bash
bash -n skills/subagents/subagents tests/*.sh
node --experimental-strip-types --test tests/*.test.ts
bash tests/cli-smoke.sh
bash tests/cli-reliability.sh
bash tests/public-safety.sh
```

Or run all checks with `pnpm test`. The tests cover environment/path resolution,
package-local CLI discovery, direct task launching with inherited and explicit
models, polling watcher replay and acknowledgement, concurrent lock ownership
and abandoned-lock recovery, queue-before-marker crash ordering, tmux command
smoke behavior, and public-package safety.

## License

MIT. See [LICENSE](LICENSE).
