#!/usr/bin/env bash
# Tests for nc claude. No network, no keys, throwaway $HOME. Claude Code is a fake that prints its arguments:
# the real claude must never run here (with redirected output it would run without a terminal, which is print mode).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUN_DIR="$(dirname "$(mise which bun 2>/dev/null || command -v bun)")"
unset NC_HOME NC_MACHINE NC_HARNESS_VERSION NC_PROJECT_PATH NC_OPENCODE NC_SECRETS OPENROUTER_API_KEY XDG_CONFIG_HOME OPENCODE_CONFIG_DIR \
  NC_MEMORY_DIR NC_MEMORY_OUTBOX NC_PROJECT GH_TOKEN GITHUB_TOKEN \
  CLAUDE_CODE_EFFORT_LEVEL CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE || true
export BUN_RUNTIME_TRANSPILER_CACHE_PATH=0   # no Bun cache anywhere

T="$(mktemp -d)"                     # two steps: inside one $(…) a failed mktemp would leave T = the start folder
T="$(cd "$T" && pwd -P)"             # real path: on macOS /tmp is itself a link
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir "$T/cwd" && cd "$T/cwd"        # a neutral current folder
export HOME="$T/home"
mkdir -p "$HOME" "$T/fake"
# A PATH without nc-work and without any folder that holds the real claude; the fake comes first.
ALL_PATH="$BUN_DIR:$PATH"
BASE_PATH="$(IFS=:; for d in $ALL_PATH; do [ -x "$d/nc-work" ] || [ -e "$d/claude" ] || printf '%s:' "$d"; done)"
export PATH="$T/fake:${BASE_PATH%:}"
cat > "$T/fake/claude" <<'EOF'
#!/usr/bin/env bash
touch "$HOME/.claude-ran"
printf 'claude:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'
EOF
chmod 755 "$T/fake/claude"
[ "$(command -v claude)" = "$T/fake/claude" ] || { echo "FAIL: claude on the test PATH is not the fake: $(command -v claude)" >&2; exit 1; }
command -v bun > /dev/null || { echo "FAIL: bun not on the test PATH" >&2; exit 1; }

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok   $*"; pass=$((pass + 1)); }
RC="$T/repo"
cp -a "$REPO" "$RC" && rm -rf "$RC/.git"
nc()   { "$RC/bin/nc" "$@"; }
is() { [ "$1" = "$2" ] || fail "$3: got [$1], expected [$2]"; }
runs() {  # runs <expected fake output> <nc claude arguments…>: the fake ran with exactly these arguments, stderr empty
  local want="$1"; shift
  rm -f "$HOME/.claude-ran"
  nc claude "$@" > "$T/out" 2> "$T/err" || fail "nc claude $*: exit $? – $(cat "$T/err")"
  is "$(cat "$T/out")" "$want" "nc claude $*"
  [ ! -s "$T/err" ] || fail "nc claude $*: stderr: $(cat "$T/err")"
}
refused() {  # refused <pattern> <nc claude arguments…>: exit 2, the pattern on stderr, the fake did not run
  local pat="$1" code=0; shift
  rm -f "$HOME/.claude-ran"
  nc claude "$@" > "$T/out" 2> "$T/err" || code=$?
  is "$code" 2 "exit of nc claude $*"
  grep -q -- "$pat" "$T/err" || fail "nc claude $*: expected '$pat', got: $(cat "$T/err")"
  [ ! -e "$HOME/.claude-ran" ] && [ ! -s "$T/out" ] || fail "nc claude $* started claude"
}
ORCH='claude_code:
  orchestrator: { model: opus, effort: high }'
yaml() {  # yaml [extra]: a models.yaml with the given extra blocks
  cat > "$RC/models.yaml" <<EOF
classes:
  frontier: { runtime: claude-code }
roles: { planner: frontier }
policies:
  - match: "~/projects/acme/**"
    isolation: container
  - match: "**"
${1:-}
EOF
}
yaml "$ORCH"

# 1. model and effort go in front of the caller's arguments; the caller's own --model/--effort win
runs "claude: [--model] [opus] [--effort] [high]"
runs "claude: [--model] [opus] [--effort] [high] [-c] [hello world]" -c "hello world"
runs "claude: [--effort] [high] [--model] [x]" --model x
runs "claude: [--effort] [high] [--model=x]" --model=x
runs "claude: [--model] [opus] [--effort] [low]" --effort low
runs "claude: [--model] [opus] [--effort=max]" --effort=max
runs "claude: [--model=sonnet] [--effort=low]" --model=sonnet --effort=low
runs "claude: [--model] [opus] [--effort] [high] [--] [--model x]" -- "--model x"
yaml "claude_code:
  orchestrator: { model: fable, effort: xhigh }"
runs "claude: [--model] [fable] [--effort] [xhigh]"
yaml "$ORCH"
ok "--model and --effort from models.yaml in front, a --model/--effort of the caller wins for its own parameter"

# 2. subcommands, --version and --help are passed on unchanged
runs "claude: [stop] [abc]" stop abc
runs "claude: [attach] [x]" attach x
runs "claude: [rc]" rc
runs "claude: [--version]" --version
runs "claude: [-v]" -v
runs "claude: [--help]" --help
runs "claude: [mcp] [list]" mcp list
runs "claude: [--model] [opus] [--effort] [high] [stops]" stops
ok "subcommands, --version, -v and --help unchanged; a word that is no subcommand is the prompt"

# 3. print mode is refused before -- and allowed after it
for a in -p --print --print=text -cp -pc; do refused "print mode" "$a" hi; done
refused "billed apart from the subscription" -c --print
refused "print mode" --resume abc -p
runs "claude: [--model] [opus] [--effort] [high] [--] [-p]" -- -p
ok "-p, --print, --print=x, -cp and -pc are exit 2 without starting claude; -p after -- is fine"

# 4. missing block: no parameters, silently; broken models.yaml or another exit code: no parameters, with a warning
yaml
runs "claude:"
runs "claude: [-c]" -c
printf 'classes: [a, b\n' > "$RC/models.yaml"
rm -f "$HOME/.claude-ran"
nc claude -c > "$T/out" 2> "$T/err" || fail "nc claude with a broken models.yaml: exit $?"
is "$(cat "$T/out")" "claude: [-c]" "start with a broken models.yaml"
grep -q "warning: orchestrator setting not read (nc models orchestrator: exit 2, nc models: models.yaml: not valid YAML" "$T/err" \
  || fail "no warning for a broken models.yaml: $(cat "$T/err")"
yaml "claude-code:
  orchestrator: { model: opus, effort: high }"
nc claude > "$T/out" 2> "$T/err" || fail "nc claude with a misspelt block"
is "$(cat "$T/out")" "claude:" "start with a misspelt block"
grep -q 'unknown key "claude-code"' "$T/err" || fail "misspelt block not reported: $(cat "$T/err")"
yaml "$ORCH"
# without Bun: bin/nc exits 127
NOBUN="$(IFS=:; for d in $PATH; do [ -x "$d/bun" ] || printf '%s:' "$d"; done)"
if ! PATH="${NOBUN%:}" command -v bun > /dev/null; then
  PATH="${NOBUN%:}" "$RC/bin/nc" claude -c > "$T/out" 2> "$T/err" || fail "nc claude without bun: exit $?"
  is "$(cat "$T/out")" "claude: [-c]" "start without bun"
  grep -q "exit 127" "$T/err" || fail "no warning without bun: $(cat "$T/err")"
fi
# only stdout is the answer: a stub bin/nc (NC_REPO, so cli/claude.sh runs directly) with a line on stderr, or with a line that does not fit
mkdir -p "$T/stub/bin"
cat > "$T/stub/bin/nc" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "models orchestrator" ] || { echo "stub: unexpected call: $*" >&2; exit 9; }
printf '%s\n' "$STUB_OUT"
[ -z "${STUB_ERR:-}" ] || printf '%s\n' "$STUB_ERR" >&2
exit 0
STUB
chmod 755 "$T/stub/bin/nc"
stub() { NC_REPO="$T/stub" STUB_OUT="$1" STUB_ERR="$2" "$RC/cli/claude.sh" > "$T/out" 2> "$T/err" || fail "stub run ($1): exit $?"; }
stub "opus high" "bash: shell-init: error retrieving current directory"
is "$(cat "$T/out")" "claude: [--model] [opus] [--effort] [high]" "a line on stderr with exit 0"
[ ! -s "$T/err" ] || fail "warning for a line on stderr: $(cat "$T/err")"
stub "sonnet high" ""
is "$(cat "$T/out")" "claude:" "a line that does not fit, exit 0"
grep -q "warning: orchestrator setting not read (nc models orchestrator: exit 0, sonnet high)" "$T/err" || fail "no warning for sonnet high: $(cat "$T/err")"
ok "missing block: start without parameters and silent; broken or misspelt models.yaml, exit 127 (no bun) or a line that does not fit: start without parameters, with a warning; a line on stderr does not spoil a valid answer"

# 5. variables that override models.yaml: a warning, and claude still starts
CLAUDE_CODE_EFFORT_LEVEL=low nc claude > "$T/out" 2> "$T/err"
is "$(cat "$T/out")" "claude: [--model] [opus] [--effort] [high]" "start with CLAUDE_CODE_EFFORT_LEVEL"
grep -q "warning: CLAUDE_CODE_EFFORT_LEVEL is set" "$T/err" || fail "no warning for CLAUDE_CODE_EFFORT_LEVEL: $(cat "$T/err")"
CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 nc claude > "$T/out" 2> "$T/err"
grep -q "warning: CLAUDE_CODE_SUBAGENT_MODEL_FORCE is set" "$T/err" || fail "no warning for CLAUDE_CODE_SUBAGENT_MODEL_FORCE"
CLAUDE_CODE_SUBAGENT_MODEL=haiku runs "claude: [--model] [opus] [--effort] [high]"
for v in 0 false No OFF ""; do CLAUDE_CODE_SUBAGENT_MODEL_FORCE="$v" runs "claude: [--model] [opus] [--effort] [high]"; done
ok "CLAUDE_CODE_EFFORT_LEVEL and CLAUDE_CODE_SUBAGENT_MODEL_FORCE warn and start; FORCE=0/false/no/off/empty and CLAUDE_CODE_SUBAGENT_MODEL alone do not warn"

# 6. a bunfig.toml with a preload in the current folder has no say
mkdir -p "$T/evil"
printf 'preload = ["./pre.ts"]\n' > "$T/evil/bunfig.toml"
printf 'await Bun.write(process.env.HOME + "/.preload-ran", "x");\n' > "$T/evil/pre.ts"
(cd "$T/evil" && runs "claude: [--model] [opus] [--effort] [high]")
[ ! -e "$HOME/.preload-ran" ] || fail "the preload of the current folder ran"
ok "bunfig.toml (preload) of the current folder changes nothing"

# 7. inside a task container: exit 2
NC_HARNESS_VERSION=0123456789abcdef refused "nc-work claude TASK"
NC_HARNESS_VERSION=0123456789abcdef refused "nc-work claude TASK" --version
ok "inside a task container nc claude is exit 2 and names nc-work claude"

# 8. --mcp-config=~/.nc/mcp/claude.json only on the session path, in front of a bare prompt, only when it exists
M="--mcp-config=$HOME/.nc/mcp/claude.json"
runs "claude: [--model] [opus] [--effort] [high] [hello]" hello                  # no file: nothing added
mkdir -p "$HOME/.nc/mcp" && echo '{"mcpServers": {}}' > "$HOME/.nc/mcp/claude.json"
runs "claude: [--model] [opus] [--effort] [high] [$M] [hello]" hello
runs "claude: [--model] [opus] [--effort] [high] [$M]"
runs "claude: [--effort] [high] [$M] [--model] [x] [-c]" --model x -c
runs "claude: [mcp] [list]" mcp list
runs "claude: [--version]" --version
yaml ""
runs "claude: [$M] [hello]" hello                                                  # without the orchestrator block too
yaml "$ORCH"
rm "$HOME/.nc/mcp/claude.json" && mkdir "$HOME/.nc/mcp/claude.json"              # not a file: not added
runs "claude: [--model] [opus] [--effort] [high] [hello]" hello
rmdir "$HOME/.nc/mcp/claude.json"
echo '{}' > "$HOME/.nc/mcp/claude.json"
out="$(env -u HOME PATH="$PATH" "$RC/bin/nc" claude hello 2>&1)" || fail "nc claude without HOME: $out"
grep -q "^claude: .*\[hello\]" <<<"$out" && ! grep -q "mcp-config" <<<"$out" || fail "nc claude without HOME: $out"
rm "$HOME/.nc/mcp/claude.json"
ok "--mcp-config=~/.nc/mcp/claude.json (one argument with =) only on the session path and only when the file exists; subcommands and --version unchanged"

echo "$pass tests passed"
