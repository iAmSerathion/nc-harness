#!/usr/bin/env bash
# nc opencode [ARGS] – start OpenCode with OPENROUTER_API_KEY for this one process.
#
# Direct (host): reads only OPENROUTER_API_KEY from ~/.config/nc-harness/secrets.env. The file is
# parsed, never sourced, and the key is never exported into the calling shell.
# Isolated (nc-work container): there is no secrets.env and no key either.
# `nc-work opencode TASK` starts a key proxy of its own for the run (a container in the task's network that
# got the key on stdin) and gives OpenCode only the placeholder OPENROUTER_API_KEY=nc-keyproxy and, in
# OPENCODE_CONFIG_CONTENT, the proxy's address as provider.openrouter.options.baseURL. This script, called inside a
# container, refuses without OPENROUTER_API_KEY; with the placeholder but without the proxy address (a plain
# `nc opencode` in a container shell) OpenCode starts and OpenRouter rejects the placeholder.
#
# OpenCode 2 would otherwise start a shared background server that outlives this process and keeps
# the key (on the host; in a container only the placeholder and the proxy address, usable while the run lasts).
# adapters/opencode/service.json ({"disabled": true}) turns that off for every opencode call,
# including ones an agent makes from inside the session, so each run gets a private server.
# Not for `opencode service start|restart`: in 2.2.7 they call Service.ensure without looking at service.json and
# start `opencode serve --service` detached, with the whole environment, key included. So `nc opencode service`
# is refused (status and stop work with plain `opencode service …`, no key needed). An agent inside a running
# session on the host has the key in its environment and can still run `opencode service start` itself;
# service.json does not prevent that. (`pair` stops by itself when the service is disabled.)
#
# Before the key is handed over, the service.json in the config dir OpenCode really uses
# (OPENCODE_CONFIG_DIR, else XDG_CONFIG_HOME/opencode, else ~/.config/opencode) must turn it off.
#
# Direct only: before the key is read, `nc models check --host` decides whether OpenCode may start in this
# folder on the host and whether the model named on the command line is allowed there. It is the
# first gate, not a fence: a start without --model, a continued session (--continue, --session), an agent
# with its own model (--agent) and the model picker in the UI all get past it. `acp`, `serve` and `api` are
# refused on the host: they take folder and model from their client, after this check (session.create in
# 2.2.7), so started from a free folder they could work in a restricted folder. This stays: the hard limit
# (the key of the OpenRouter workspace "clients") holds only inside a task container.
#
# Parsing rule, the same in nc doctor and nc-work: trim the line (BOM, CR, ASCII whitespace), optional
# `export `, trim the value, strip one pair of matching quotes; the value must be printable ASCII without
# spaces (no comments, no pasted non-breaking spaces); the last matching line wins.
# Permissions: a regular file without group or other bits.
set -euo pipefail

die() { echo "nc opencode: $*" >&2; exit 1; }
trim() { local LC_ALL=C s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# OpenCode 2 reads service.json from its global config dir; without {"disabled": true} there it starts a
# shared background server that keeps the key after this session.
config_dir="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
grep -Eq '"disabled"[[:space:]]*:[[:space:]]*true' "$config_dir/service.json" 2>/dev/null \
  || die "$config_dir/service.json does not switch off the OpenCode background service – ./install.sh (with your own XDG_CONFIG_HOME/OPENCODE_CONFIG_DIR, link it there)"
[ -f "$config_dir/opencode.json" ] || die "$config_dir/opencode.json missing (only OpenRouter allowed) – ./install.sh"

oc="$(command -v opencode || true)"
[ -n "$oc" ] || die "opencode not found – ./install.sh"

# Lets nc doctor tell a key handed to this session from one exported into the shell.
export NC_OPENCODE=1

if [ -n "${NC_HARNESS_VERSION:-}" ]; then
  [ -n "${OPENROUTER_API_KEY:-}" ] || die "OPENROUTER_API_KEY missing – start it on the host with 'nc-work opencode TASK'"
  exec "$oc" "$@"
fi

# Which folder and which model would this start use? Read from the arguments the way OpenCode 2.2.7 does
# (checked against `opencode --help` and its bundled parser): only the root command takes a folder, only `run`
# and `mini` take --model/-m. Whatever is not clearly understood is refused, never guessed. In 2.2.7:
#   - a switch (--auto, -c, …) takes a following true/yes/on/1/y/false/no/off/0/n as its value, so such a word
#     is never the folder; a real folder of that name can be written ./1
#   - short options can be grouped (-cm ID sets the model), so run/mini refuse any group or attached value
#   - --wizard builds and runs another command, model included
#   - `--` ends the options of run/mini; what follows is the message
refuse() { die "not started: $*"; }
sub="" dir="" dirs=0 model="" models=0 want=""   # want: the next argument is an option's value (skip) or the model
prev=""                                          # run/mini: the previous argument, if it is an option that takes a value
# --wizard anywhere before the first --: the root skips the argument after --session/--prompt/… unseen, but
# OpenCode takes only a value that does not start with -, and runs the wizard before it complains.
for a in "$@"; do
  case "$a" in
    --) break ;;
    --wizard|--wizard=*) refuse "--wizard builds another command with a model and runs it" ;;
  esac
done
for a in "$@"; do
  case "$want" in
    skip)  want=""; continue ;;
    model) want=""; model="$a"; models=$((models + 1)); continue ;;
  esac
  if [ -z "$sub" ]; then
    case "$a" in
      --standalone|--auto|--continue|-c|--print-logs|--help|-h|--version|-v) ;;
      --server|--session|-s|--prompt|--log-level|--completions) want=skip ;;
      --server=*|--session=*|--prompt=*|--log-level=*|--completions=*) ;;
      -*) refuse "option $a is not known before a folder or subcommand (only run and mini know --model and -m); so it is not certain in which folder OpenCode starts" ;;
      acp|serve|api)
        refuse "opencode $a takes folder and model from its client, only after this check; blocked on the host (the hard limit of the key holds only in the container)" ;;
      service)
        refuse "opencode service start/restart starts the shared background service with the key, whatever service.json says, and it keeps running after the session; status and stop work with plain 'opencode service …' without a key" ;;
      upgrade|update|uninstall|debug|auth|mcp|plugin|models|stats|mini|run|session|reload|pair)
        [ "$dirs" -eq 0 ] || refuse "a folder and the subcommand $a together; so it is not certain in which folder OpenCode starts"
        sub="$a" ;;
      *) dir="$a"; dirs=$((dirs + 1)) ;;
    esac
  elif [ "$sub" = run ] || [ "$sub" = mini ]; then
    case "$a" in
      --) [ -z "$prev" ] || refuse "-- right after $prev: it is not certain whether it is its value or ends the options"
          break ;;   # the rest is the message
      --model|-m) want=model ;;
      --model=*) model="${a#--model=}"; models=$((models + 1)) ;;
      --wizard|--wizard=*) refuse "--wizard builds another command with a model and runs it" ;;
      -[!-]?*) refuse "give short options one by one and without an attached value, not as $a (the model: --model ID, --model=ID or -m ID)" ;;
    esac
    case "$a" in
      --session|-s|--title|--agent|--format|--file|-f|--worktree|-w|--prompt|--replay-limit|--server|--log-level|--completions) prev="$a" ;;
      *) prev="" ;;
    esac
  else
    case "$a" in --wizard|--wizard=*) refuse "--wizard builds another command with a model and runs it" ;; esac
  fi
done
[ "$want" != model ] || refuse "--model without a value"
[ "$models" -le 1 ] || refuse "several models given; it is not certain which one applies"
[ "$dirs" -le 1 ] || refuse "more than one folder; it is not certain in which one OpenCode starts"
if [ "$dirs" -eq 1 ]; then
  case "$dir" in ""|"~"*) refuse "the folder is empty or starts with ~ (not filled in by the shell); it is not certain in which folder OpenCode starts" ;; esac
  case "$(printf '%s' "$dir" | tr '[:upper:]' '[:lower:]')" in   # bash 3.2 on macOS has no ${dir,,}
    true|yes|on|1|y|false|no|off|0|n)
      refuse "\"${dir}\" is taken by OpenCode as the value of a switch before it, not as a folder; write a folder of that name as ./$dir" ;;
  esac
fi

# Exactly one question, before secrets.env is touched. Allowed (exit 0) prints nothing; otherwise the reason
# comes from nc models on stderr and its exit code is passed on.
nc="${NC_REPO:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/bin/nc"
gate() {
  if [ "$models" -eq 1 ]; then "$nc" models check --host --model "$model"
  elif [ "$dirs" -eq 1 ]; then "$nc" models check --host --path "$dir"
  else "$nc" models check --host
  fi
}
gate || exit $?

secrets="${NC_SECRETS:-$HOME/.config/nc-harness/secrets.env}"
[ -f "$secrets" ] && [ ! -L "$secrets" ] || die "$secrets missing – ./install.sh creates a template"
perm="$(stat -c %a "$secrets" 2>/dev/null || stat -f %Lp "$secrets")"
[ $(( 8#$perm & 8#077 )) -eq 0 ] || die "$secrets has permissions $perm, expected 600 (chmod 600 $secrets)"

read_key() {
local LC_ALL=C line value key=""
while IFS= read -r line || [ -n "$line" ]; do
  line="${line#$'\xef\xbb\xbf'}"
  line="$(trim "${line//$'\r'/}")"
  case "$line" in export[[:space:]]*) line="$(trim "${line#export}")" ;; esac
  case "$line" in OPENROUTER_API_KEY=*) ;; *) continue ;; esac
  value="$(trim "${line#OPENROUTER_API_KEY=}")"
  if [ "${#value}" -ge 2 ]; then
    case "$value" in \"*\"|\'*\') [ "${value:0:1}" = "${value: -1}" ] && value="${value:1:${#value}-2}" ;; esac
  fi
  key="$value"
done < "$1"
[ -n "$key" ] || die "OPENROUTER_API_KEY is empty in $1"
case "$key" in *[!\!-\~]*) die "OPENROUTER_API_KEY in $1 is invalid (space, comment or special character in the value); value not printed" ;; esac
printf '%s' "$key"
}
key="$(read_key "$secrets")" || exit 1   # die inside $(...) only ends the subshell

export OPENROUTER_API_KEY="$key"
exec "$oc" "$@"
