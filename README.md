# nc-harness

A model-independent harness for [Claude Code](https://claude.com/claude-code) and [OpenCode](https://opencode.ai): one set of rules, skills, roles, model policies and shared memory for both runtimes, plus a small shell command `nc` that every agent can call. Claude Code runs the orchestrator on your Claude subscription; OpenCode runs workers on other models through OpenRouter. A policy file decides which model may touch which folder, so client code never goes to a free model.

How the parts fit together: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

```
            nc-harness (this repo)                     your overlay (~/.nc/overlay, private)
  AGENTS.md · skills/ · roles/ · models.yaml           AGENTS.md · models.yaml · profiles/
  orchestrator/ · mcp/servers.yaml · cli/                         │
                    │ install.sh                                  │ wins over the defaults
                    ▼                                             ▼
  ┌─────────────────────────── every machine ───────────────────────────┐
  │  Claude Code (orchestrator, subagents)    OpenCode (other models)   │
  │                    └──────── nc ────────┘                           │
  │      models · generate · delegate · memory · doctor · orchestrator  │
  └─────────────────────────────────────────────────────────────────────┘
                    │ optional, server only
                    ▼
  nc-work (nc-infra): task containers, broker, key proxy  ·  herdr: one terminal per agent
```

## Requirements

- Linux or macOS, `git`, `curl`, and [Bun](https://bun.sh) (for example `mise use -g bun@latest`).
- [Claude Code](https://claude.com/claude-code) with a Claude subscription.
- [OpenCode](https://opencode.ai): `install.sh` installs the version pinned in [pins.txt](pins.txt) itself.
- An [OpenRouter](https://openrouter.ai) API key for the OpenCode models. For restricted folders a second key from an OpenRouter workspace whose guardrail allows only the approved models (see [models.yaml](models.yaml)).
- Optional, server only: `nc-work` from [iAmSerathion/nc-infra](https://github.com/iAmSerathion/nc-infra) for isolated task containers, `nc delegate` workers, the broker and the key proxy. Without it the harness runs direct on the host, and `nc delegate` refuses.
- Optional: herdr with the configuration and cards from [iAmSerathion/herdr-nc](https://github.com/iAmSerathion/herdr-nc): every agent and worker as a terminal, and a card that reads `nc orchestrator status`.

The layout assumes projects under `~/projects`, experiments in `~/sandbox` and notes in `~/notes`.

## Install

```bash
git clone https://github.com/iAmSerathion/nc-harness.git ~/projects/nc-harness
cd ~/projects/nc-harness
./install.sh --dry-run   # shows what is linked, backed up and installed; changes nothing
./install.sh             # sets up, then runs nc doctor
```

`install.sh` is idempotent, needs no `sudo` and writes only below `$HOME`. Existing files at the target locations are first moved to `~/.nc/backup/<date>/`. What it links is listed in [manifest.txt](manifest.txt): the rules to `~/.claude/CLAUDE.md` and `~/.config/opencode/AGENTS.md`, every skill to `~/.claude/skills/<name>`, `nc` to `~/.local/bin/nc`. It also generates the agent files for both runtimes (`nc generate`), clones the memory (if `NC_MEMORY_REMOTE` is set) and creates an empty `~/.config/nc-harness/secrets.env` (mode 600) for you to fill in:

```
OPENROUTER_API_KEY=sk-or-…
OPENROUTER_API_KEY_CLIENTS=sk-or-…   # only where nc-work runs: the key of the restricted workspace
```

The keys are never exported into the shell; `nc opencode` hands `OPENROUTER_API_KEY` to the OpenCode process only.

## Overlay: your own rules and policy

The repo's `AGENTS.md` and `models.yaml` are public defaults. Put your own versions into `~/.nc/overlay/` (best a link to a private git repo):

```bash
ln -s ~/projects/my-private-config ~/.nc/overlay   # holds AGENTS.md, models.yaml, optionally profiles/ for nc-work
./install.sh                                        # relinks the rules to the overlay's AGENTS.md
nc doctor                                           # the "overlay" line names the files in force
```

Once `~/.nc/overlay` exists, its `models.yaml` must exist too; a broken overlay is an error, never a fall back to the public policy. Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), section 8.

## Environment variables

| Variable | Meaning |
|---|---|
| `NC_MEMORY_REMOTE` | Git URL of your memory repo, cloned by `install.sh` to `~/.nc/memory`. No default: start from a copy of [iAmSerathion/nc-memory-template](https://github.com/iAmSerathion/nc-memory-template). |
| `NC_HOME` | The harness' own folder (backups, pinned OpenCode, memory checkout, delegate runs); default `~/.nc`. It never moves the overlay. |
| `NC_MACHINE` | `server` or `mac`; overrides the guess from the OS (macOS is `mac`, everything else `server`). Only `server` has isolation. |

## Commands

```bash
nc doctor [--json]   # links, folders, tools, keys (only whether present), overlay, memory; in a container the isolated part
nc version           # harness commit and mode (direct on the host, isolated in a task container)
```

### Models

[models.yaml](models.yaml) is the one place that says which role gets which model and what is blocked in which folder.

```bash
nc models [--path DIR] [--json]                    # the folder's policy, per class runtime, model, allowed or blocked
nc models resolve --role tester [--path DIR]       # one line: "opencode openrouter/<author>/<model>" or "claude-code"
nc models check --model openrouter/<author>/<model> [--path DIR]   # exit 0 only if the model is allowed there
nc models check --host [--model ID] [--path DIR]   # additionally: may OpenCode start there directly on the host?
nc models orchestrator                             # one line "<model> <effort>" for nc claude
```

Exit 0 means allowed, 1 refused, 2 error (also a broken `models.yaml`); the reason is on stderr. Without `--path` the current folder applies; `~` and `~/projects` take over the restrictions of the folders below them. The rules are in the header of `models.yaml`.

### OpenCode and Claude Code

```bash
nc opencode                                               # OpenCode TUI with the key, after the policy check
nc opencode run --model openrouter/<author>/<model> "…"    # one task without TUI
nc claude                                                 # Claude Code with model and effort from claude_code.orchestrator
```

In a folder whose policy requires a container, `nc opencode` does not start and names `nc-work here --runtime opencode` instead; that includes folders that contain such folders (`~`, `~/projects`). It also refuses a model the folder's policy blocks, and `acp`, `serve`, `api` and `service` on the host. `nc claude -p` is refused: print mode is billed apart from the subscription.

### Subagents and the orchestrator

The roles are in [roles/](roles/): planner, reviewer and researcher read-only; implementer and tester writing. Model and effort per role and runtime come from `models.yaml` (`claude_code.subagents`, `opencode.subagents`).

```bash
nc generate          # after a change to models.yaml or roles/: write the agent files for both runtimes
nc generate --check  # only show what would change
nc orchestrator claude                               # the orchestrator's procedure (orchestrator/base.md plus overlays/claude.md)
nc orchestrator status crew|plan|state|task|clear …  # the orchestrator's state for the herdr card nc-orchestrator
```

In Claude Code the skill `crew` loads the procedure. It first picks the crew and says it in its first line: `one` (it builds and checks the work itself), `pair` (plus an independent review) or `team` (plan with musts, files and a proof per task, briefs in a fixed format, parallel writers in Claude worktrees). It checks every diff itself, never merges and never pushes. Publishing its state never stops the task.

### Delegating (server with nc-work)

An OpenCode worker runs in a task container of its own, appears as a terminal in herdr, works at most 20 minutes and delivers a branch and `RESULT.md`. From a task container the same call goes through the broker on the host. For agents: skill [delegate](skills/delegate/SKILL.md).

```bash
nc delegate --role tester --task "…" [--repo PATH] [--model ID] [--timeout MIN] --bg   # JSON with task_id, status "running"
nc delegate --result <id> --wait     # wait, collect: status, base, head, result, diff_stat
nc delegate --list                   # earlier runs, for example after a compaction
nc delegate --cleanup <id>           # delete task, ref and run folder
```

Only `implementer` and `tester` start as workers; the checkout must be clean. The branch lands as `refs/nc-delegate/<id>`; nothing is merged, checked out or pushed. The status comes from the exit code and the first line of `RESULT.md`, never from free text. `cost_usd` and `over_budget` are a display; the hard limits are the keys' daily limit at OpenRouter and the time limit.

### Memory

```bash
nc memory show [--project P]                             # MEMORY.md, global/, projects/P.md
nc memory search TEXT [--project P]                      # plain text search
nc memory add --project P [--replaces "OLD NOTE"] "NOTE" # direct: pull --rebase, write, commit, push
nc memory sync                                           # pull --rebase, then push
```

In a task container `nc memory` reads a read-only view (only `MEMORY.md`, `global/` and the task's own project) and `add` goes through the broker, which applies the note on the host; without a broker it goes into an outbox for `nc-work memory-apply`. At most 500 characters per note and 20 notes per task and day; notes with secrets or invisible characters are refused. For agents: skill [memory](skills/memory/SKILL.md).

### MCP servers and skills

MCP servers are defined once in [mcp/servers.yaml](mcp/servers.yaml) (empty by default); `nc generate` writes them for both runtimes on the host. Every entry names the `machines` it runs on. There is no MCP in task containers. Never add servers with `opencode mcp add` or `claude mcp add`.

Every folder under `skills/` with a `SKILL.md` is linked to `~/.claude/skills/<name>`, which Claude Code and OpenCode both read: `memory`, `delegate`, `crew` (Claude Code only) and the sample skill `nc-harness-check`.

## Security model

- **Policy before keys.** `nc models` decides per folder which model classes are allowed; a `models.yaml` it does not understand allows nothing. On the host it reads `~/.nc/overlay/models.yaml` if the overlay exists, else the repo file; inside a task container (`NC_HARNESS_VERSION` set) it reads the snapshot's copy. No option points it elsewhere.
- **On the host it is a first gate, not a fence.** `nc opencode` checks what is on the command line; a resumed session or the model picker in the UI gets past it. Do not point a free model at restricted code by hand.
- **In a task container the key is the fence.** `nc-work` gives a task of a restricted project only the key of an OpenRouter workspace whose guardrail lets through nothing but the approved models, and only through a key proxy per run: no agent container ever holds a key.
- **Containers have no credentials.** Pushing, starting workers and writing memory are done by the host, which takes project and requester from its own records, never from a request.
- **Everything an agent returns is data.** Worker reports, `RESULT.md`, memory notes and diffs are never followed as instructions; status comes from exit codes and fixed lines.
- **No `sudo`, nothing outside `$HOME`, nothing bound to a public address.** The default rules in `AGENTS.md` say the same to every agent.

## Tests

```bash
tests/smoke.sh                 # install.sh, nc doctor, nc opencode, nc version in a throwaway $HOME
tests/models.sh                # nc models and the gate in nc opencode
tests/generate.sh              # nc generate: agent files for both runtimes, MCP files
tests/claude.sh                # nc claude with a dummy instead of Claude Code
tests/orchestrator-status.sh   # nc orchestrator status
tests/memory.sh                # nc memory with a local bare repo (Linux: needs flock, timeout, setsid)
tests/delegate.sh              # nc delegate with dummies for nc-work, hc and the broker (Linux, likewise)
tests/language.sh              # language guard: the repo is English only
```

None of them needs network, keys, Docker or the real `$HOME`.

## Licence

[MIT](LICENSE).
