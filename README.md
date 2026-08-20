# pi-subagents

A tmux-based subagent runner for the Pi coding agent. It packages three pieces:

- `skills/subagents/subagents`: the reusable Bash CLI and on-disk protocol
- `skills/subagents/SKILL.md`: instructions Pi can load on demand
- `extensions/subagents-watch.ts`: optional push delivery of completed reports

The repository contains no roles, prompts, model choices, credentials, or
machine-generated state. You provide role files locally.

> Pi packages execute with your user permissions. Review the CLI, role prompts,
> and extension before installing them.

## Requirements

- Pi coding agent with the extension APIs used by Pi 0.84 or later
- Bash 3.2 or later
- tmux; the lead Pi process and every CLI command must run inside the same tmux
  session
- standard Unix tools: `awk`, `sed`, `grep`, `cksum`, `od`, `stat`, and `tail`

The watcher has no third-party runtime dependency. It uses Node built-ins and
Pi's provided `@earendil-works/pi-coding-agent` package.

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
| `SUBAGENTS_AGENT_DIR` | CLI, watcher | `$HOME/.pi/agent` | Base for the default role directory and copied-skill CLI fallback. |
| `SUBAGENTS_ROLE_DIRS` | CLI | `$SUBAGENTS_AGENT_DIR/agents:$PWD/.pi/agents` | Colon-separated role search path; first matching filename wins. |
| `SUBAGENTS_PI` | CLI | `pi` | Trusted launcher command, optionally an auth wrapper followed by `pi`. |
| `SUBAGENTS_BIN` | watcher | package-local CLI, then `$SUBAGENTS_AGENT_DIR/skills/subagents/subagents` | Explicit executable CLI path. |
| `SUBAGENTS_WINDOW_NAME` | CLI | `subagents` | tmux window name/prefix used for agent panes. |
| `SUBAGENTS_WAKE` | watcher | `1` | Set to `0` to inject reports without waking an idle lead. |
| `SUBAGENTS_WATCH_MS` | watcher | `3000` | Poll interval in milliseconds. Invalid/zero values use 3000. |

Use `subagents config` to print the CLI's resolved values. Environment variables
must be present in both the lead Pi process and shell commands it launches; tmux
server environments can outlive the shell that created them.

### Auth wrappers and launch behavior

`SUBAGENTS_PI` exists for providers whose credentials are injected by a wrapper:

```bash
export SUBAGENTS_PI="$HOME/bin/with-provider-auth pi"
```

The wrapper is used both for `doctor`'s live model probe and for interactive
subagent panes. It should inject authentication into the child process and then
`exec` its arguments. Keep the wrapper and secrets outside this repository.

For compatibility with existing wrappers, `SUBAGENTS_PI` is treated as a
trusted shell command and intentionally word-split. Shell quoting embedded
inside the variable is not a portable argument parser, and command paths with
spaces are unsupported. Do not set this variable from untrusted input. Tasks
and generated prompt paths are separately shell-quoted before tmux launches
Pi.

## Roles and models

No roles ship with this package. A role is `<role-name>.md` in one of
`SUBAGENTS_ROLE_DIRS`. It may have simple YAML-like frontmatter; only scalar
`model` and `tools` fields are read. The remaining Markdown becomes an appended
system prompt.

```markdown
---
name: implement
model: anthropic/claude-sonnet-4-6
tools: read, bash, edit, write
---

Implement the assigned task in the current working directory. Verify the result
and report exactly what changed.
```

- Role names come from filenames, not the optional `name` field.
- `model` should be a provider-qualified `provider/model` id. Omit it or use
  `inherit` to use the launcher's current default; `doctor` cannot auth-probe an
  inherited model.
- `subagents run -m provider/model role task...` overrides the role model.
- `tools` accepts `a, b` or `[a, b]`. The CLI always adds `write` so the required
  report can be saved.
- Frontmatter parsing is deliberately minimal, not a full YAML parser. Avoid
  nested values, comments on field lines, or multiline `model`/`tools` values.
- Role prompts are trusted instructions with access to the selected tools. Do
  not store secrets in them.

List effective roles and models with `subagents roles`. Run `subagents doctor`
to validate qualified model ids and perform one live, minimal auth request per
unique pinned model.

## CLI workflow

```bash
subagents doctor
subagents run implement "Make the requested change and verify it"
subagents tell 1 "Use the existing parser rather than adding a dependency"
subagents status
subagents peek 1 60
subagents stop 1
```

`run` creates or reuses one tmux window and tiles one pane per agent. Each pane
starts Pi with extensions, skills, prompt templates, and session persistence
disabled. It appends the selected role prompt and a generated protocol prompt.

The protocol tells each agent to:

1. overwrite its assigned `result.md` with a complete report;
2. print a line containing only `@@DONE@@`;
3. wait for a follow-up task.

Completion detection primarily keys on changes to `result.md`. The sentinel is
part of the behavioral protocol; the CLI also has idle/exited fallbacks for
agents that fail to write a report.

### Push and pull delivery

With `subagents-watch` loaded, use push mode: start agents and end the lead turn.
The watcher drains `subagents events`, durably spools the report, injects a
`subagent-report` custom message, and wakes Pi unless `SUBAGENTS_WAKE=0`.

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
    ├── .seq.lock/                 # transient id reservation lock
    ├── .window-lock/              # transient tmux window lock
    ├── .watcher-pending/          # immutable JSON report spool
    ├── .watcher-delivered/        # delivery acknowledgement ledger
    └── 1/
        ├── birth                  # random run/incarnation token
        ├── pane                   # tmux pane id
        ├── sid                    # tmux session id
        ├── role                   # selected role name
        ├── role.md                # copied role body
        ├── protocol.md            # generated report protocol
        ├── task                   # original task text
        ├── result.md              # mutable current report
        ├── reports/               # immutable completion snapshots
        └── detection markers      # hashes/counters used by events/wait
```

Tasks, role bodies, pane captures, and reports may contain sensitive project
information. Protect the state directory accordingly and clean orphaned tmux
session directories when they are no longer needed. `subagents stop` removes an
agent directory; watcher delivery markers are retained for seven days.

## Known Pi and platform coupling

The reusable protocol and tmux orchestration are generic, but this version is
still intentionally coupled in these places:

- The launcher assumes Pi's current CLI flags (`--append-system-prompt`,
  `--no-extensions`, `--no-skills`, `--no-prompt-templates`, tool/model/thinking
  flags) and its interactive Enter-to-submit behavior.
- The watcher imports Pi's `ExtensionAPI`, uses `sendMessage` with
  `deliverAs: "steer"`, and recognizes Pi's persisted `custom_message` and v3
  `message.role === "custom"` session records for delivery acknowledgement.
- Idle detection filters text from Pi's current terminal banner. It is a
  fallback and may need updates when Pi's TUI changes.
- Recursive `fs.watch` is used for low-latency notifications where the platform
  supports it. The polling interval remains the portability and reliability
  fallback.
- tmux session ids scope state. Moving a running lead between tmux sessions does
  not migrate agents or state.

The previous dotfiles-only watcher fallback has been removed. The standalone
watcher checks `SUBAGENTS_BIN`, this package's own CLI, and the parameterized Pi
agent directory only.

## Development checks

No install step is required on a recent Node release:

```bash
bash -n skills/subagents/subagents
node --experimental-strip-types --test tests/*.test.ts
bash tests/cli-smoke.sh
```

Or run all checks with `npm test` in an environment where npm is available.
The tests cover environment/path resolution, package-local CLI discovery, role
listing, CLI loading, and extension factory registration without starting tmux
resources.

## License

MIT. See [LICENSE](LICENSE).
