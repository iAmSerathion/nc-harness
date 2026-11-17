#!/usr/bin/env bash
# nc claude [ARGS] – start Claude Code with model and effort from claude_code.orchestrator in models.yaml.
#
# Host only. The setting is a default, not a guard: whatever goes wrong while reading it, Claude still starts
# (it is the tool that repairs models.yaml), only without --model/--effort and with a warning. In the session
# /model and /effort keep working; a start parameter does not override them, CLAUDE_CODE_EFFORT_LEVEL would.
#
# Rules, in this order:
#   1. inside a task container: refused (there it is `nc-work claude TASK`, on the host)
#   2. a subcommand of claude, --version/-v, --help/-h as the first argument: passed on unchanged. --model and
#      --effort in front of attach, logs, respawn, rm, stop, kill, daemon and self-hosted-runner would turn the
#      subcommand into the prompt (checked with 2.1.325; rc stays in the list as the task asked)
#   3. print mode is refused (billed apart from the subscription): -p, --print, --print=…, any group of short options (-cp is
#      -c -p) before the first --. Some harmless forms are refused too
#   4. ask `nc models orchestrator` through bin/nc (never bun directly: bunfig.toml, .env and tsconfig.json of
#      the current folder would have a say). Only stdout is the answer: a line on stderr (shell-init in a deleted
#      folder, a mise shim) does not spoil it. Exit 0 with "<model> <effort>": both parameters; exit 1 (not set):
#      neither, silently; anything else: neither, with a warning
#   5. exec claude --model M --effort S [--mcp-config=~/.nc/mcp/claude.json] "$@"; a --model/--effort of the caller
#      wins for its own parameter. The MCP file (nc generate, from mcp/servers.yaml) only when it exists, and only
#      with `=`: --mcp-config takes several values and would swallow a bare prompt behind it
set -uo pipefail   # no -e: a failing nc models must not stop the start

# Subcommands of Claude Code 2.1.325: `claude --help`, plus hidden ones (from remote-control on) that do not
# take options in front. Hidden ones that do (edit-permission-rules, worktree-hook) are not listed.
SUBCOMMANDS=(agents attach auth auto-mode doctor gateway import install logs mcp plugin plugins purge respawn rm
  setup-token stop kill ultrareview update upgrade remote-control rc daemon self-hosted-runner project sandbox
  workspace-trust edit-hook design-login import-conversations)

warn() { echo "nc claude: warning: $*" >&2; }

if [ -n "${NC_HARNESS_VERSION:-}" ]; then
  echo "nc claude: not in a task container – there Claude starts on the host with 'nc-work claude TASK'" >&2
  exit 2
fi

first="${1:-}"
case "$first" in
  --version|-v|--help|-h) exec claude "$@" ;;
esac
for s in "${SUBCOMMANDS[@]}"; do
  [ "$first" != "$s" ] || exec claude "$@"
done

has_model=0 has_effort=0
for a in "$@"; do
  case "$a" in
    --) break ;;
    -p|--print|--print=*|-[!-]?*)
      echo "nc claude: $a – nc claude does not start print mode (claude -p): it is billed apart from the subscription. Give short options one by one (-c instead of -cp)." >&2
      exit 2 ;;
    --model|--model=*) has_model=1 ;;
    --effort|--effort=*) has_effort=1 ;;
  esac
done

[ -z "${CLAUDE_CODE_EFFORT_LEVEL:-}" ] \
  || warn "CLAUDE_CODE_EFFORT_LEVEL is set and overrides --effort, /effort and the effort field of the subagents"
# Claude Code reads 0, false, no and off (any case) as off. The shell's environment only: the env block of
# ~/.claude/settings.json is not seen here.
case "$(printf '%s' "${CLAUDE_CODE_SUBAGENT_MODEL_FORCE:-}" | tr '[:upper:]' '[:lower:]')" in
  ""|0|false|no|off) ;;
  *) warn "CLAUDE_CODE_SUBAGENT_MODEL_FORCE is set: subagents do not run with the model from models.yaml, and a model per call does not apply either" ;;
esac

nc="${NC_REPO:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/bin/nc"
errf="$(mktemp 2>/dev/null)" || errf=/dev/null
out="$("$nc" models orchestrator 2>"$errf")"
rc=$?
err=""
[ "$errf" = /dev/null ] || { err="$(cat "$errf")"; rm -f "$errf"; }
params=()
if [ "$rc" -eq 0 ] && [[ "$out" =~ ^(opus|fable)\ (low|medium|high|xhigh|max)$ ]]; then
  [ "$has_model" = 1 ] || params+=(--model "${BASH_REMATCH[1]}")
  [ "$has_effort" = 1 ] || params+=(--effort "${BASH_REMATCH[2]}")
elif [ "$rc" -ne 1 ]; then
  if [ -n "$err" ]; then detail="${err##*$'\n'}"; else detail="${out%%$'\n'*}"; fi   # last line of stderr: after a shell-init line
  warn "orchestrator setting not read (nc models orchestrator: exit $rc${detail:+, $detail}) – starting without --model and --effort"
fi

mcp="${HOME:-}/.nc/mcp/claude.json"   # without HOME (env -i): no MCP file, claude still starts
[ -z "${HOME:-}" ] || [ ! -f "$mcp" ] || params+=("--mcp-config=$mcp")

exec claude ${params[@]+"${params[@]}"} "$@"   # bash 3.2 (macOS): an empty array is "unbound" under set -u
