#!/usr/bin/env bash
# Tests for nc hooks (the SessionStart compact hook in ~/.claude/settings.json). No network, no keys. Every case has its
# own throwaway $HOME, so the real ~/.claude is never touched.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUN_DIR="$(dirname "$(mise which bun 2>/dev/null || command -v bun)")"
export PATH="$BUN_DIR:$PATH"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID || true
export BUN_RUNTIME_TRANSPILER_CACHE_PATH=0   # no Bun cache anywhere

T="$(mktemp -d)"
T="$(cd "$T" && pwd -P)"
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir "$T/cwd" && cd "$T/cwd"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok   $*"; pass=$((pass + 1)); }
nc()   { "$REPO/bin/nc" "$@"; }
expect() {  # expect <exit code> <pattern on stderr, or ''> <command…>; stdout in $T/out, stderr in $T/err
  local want="$1" pat="$2" code=0; shift 2
  "$@" > "$T/out" 2> "$T/err" < /dev/null || code=$?
  [ "$code" = "$want" ] || fail "exit $code, expected $want: $* – $(cat "$T/err")"
  [ -z "$pat" ] || grep -q -- "$pat" "$T/err" || fail "$*: expected '$pat' on stderr, got: $(cat "$T/err")"
}
outhas() { grep -q -- "$1" "$T/out" || fail "stdout has no '$1': $(cat "$T/out")"; }
home() {  # home <name>: a fresh $HOME with a .claude folder; S is its settings.json
  export HOME="$T/$1"
  mkdir -p "$HOME/.claude"
  S="$HOME/.claude/settings.json"
}
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
backups() { find "$HOME/.nc/backup" -type f 2>/dev/null | wc -l | tr -d ' ' || true; }
js() {  # js <expr>: JSON of an expression on the settings file (s); a link is followed
  bun -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(JSON.stringify(eval(process.argv[2])))' "$S" "$1"
}
jsx() {  # jsx <expr>: exit 0 when it is true. s = the settings now, o = the copy made before (orig.json), CMD = our command
  bun -e 'const r = (f) => JSON.parse(require("fs").readFileSync(f, "utf8"));
    const s = r(process.argv[1]), o = r(process.argv[2]), strip = ({ hooks, ...rest }) => rest;
    const CMD = "\"$HOME/.local/bin/nc\" orchestrator status context";
    if (eval(process.argv[3]) !== true) { console.error("not true: " + process.argv[3]); process.exit(1); }' "$S" "$T/orig.json" "$1"
}
refuses() {  # refuses <name> <stderr pattern> <settings text>: exit 2, file unchanged, no backup
  home "$1"
  printf '%s\n' "$3" > "$S"
  cp "$S" "$T/orig.json"
  expect 2 "$2" nc hooks
  cmp -s "$S" "$T/orig.json" || fail "$1: the file changed"
  [ ! -e "$HOME/.nc" ] || fail "$1: a backup was made"
}

# 1. missing settings.json: created with exactly our entry, mode 600, no backup (there was nothing to back up)
home missing
expect 0 '' nc hooks
outhas '^  added '
[ -f "$S" ] || fail "no settings.json written"
[ "$(mode_of "$S")" = 600 ] || fail "new settings.json mode $(mode_of "$S"), expected 600"
[ "$(js 's')" = '{"hooks":{"SessionStart":[{"matcher":"compact","hooks":[{"type":"command","command":"\"$HOME/.local/bin/nc\" orchestrator status context","timeout":10}]}]}}' ] \
  || fail "content: $(js 's')"
[ ! -e "$HOME/.nc" ] || fail "a backup was made for a missing file"
expect 0 '' nc hooks
outhas '^  ok '
ok "missing settings.json: created with the one SessionStart entry (mode 600), no backup; a second run says ok"

# 2. other keys and other hooks stay as they were; ours comes last; the old file is backed up byte for byte
home other
cat > "$S" <<'EOF'
{
  "model": "opus",
  "env": { "CLAUDE_CODE_EFFORT_LEVEL": "high" },
  "permissions": { "allow": ["Bash(git status:*)"] },
  "statusLine": { "type": "command", "command": "orca statusline" },
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "orca hook session-start", "timeout": 5 } ] },
      { "matcher": "compact", "hooks": [ { "type": "command", "command": "orca compact-note" } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo pre" } ] }
    ]
  }
}
EOF
cp "$S" "$T/orig.json"
expect 0 '' nc hooks
outhas '^  added '
jsx 'JSON.stringify(strip(s)) === JSON.stringify(strip(o))' || fail "a top level key other than hooks changed"
jsx 'JSON.stringify(s.hooks.PreToolUse) === JSON.stringify(o.hooks.PreToolUse)' || fail "PreToolUse changed"
jsx 'JSON.stringify(s.hooks.SessionStart.slice(0, 2)) === JSON.stringify(o.hooks.SessionStart)' \
  || fail "the other SessionStart entries changed or moved"
jsx 'Object.keys(s.hooks).join() === "SessionStart,PreToolUse"' || fail "keys of hooks changed"
jsx 's.hooks.SessionStart.length === 3 && s.hooks.SessionStart[2].matcher === "compact" && s.hooks.SessionStart[2].hooks.length === 1 && s.hooks.SessionStart[2].hooks[0].command === CMD && s.hooks.SessionStart[2].hooks[0].timeout === 10 && s.hooks.SessionStart[2].hooks[0].type === "command"' \
  || fail "our entry is not last or not exact: $(js 's.hooks.SessionStart')"
bk="$(find "$HOME/.nc/backup" -type f)"
[ "$(echo "$bk" | wc -l | tr -d ' ')" = 1 ] || fail "backups: $bk"
echo "$bk" | grep -Eq '/\.nc/backup/[0-9]{4}-[0-9]{2}-[0-9]{2}/\.claude/settings\.json$' || fail "backup path: $bk"
cmp -s "$bk" "$T/orig.json" || fail "the backup differs from the old file"
ok "other keys, PreToolUse, the Orca hook and the other compact entry stay as they were; ours comes last; backup = old file"

# 3. idempotence: a second run changes nothing, makes no second backup; --check says ok with exit 0
cp "$S" "$T/after1.json"
n1="$(backups)"
expect 0 '' nc hooks
outhas '^  ok '
cmp -s "$S" "$T/after1.json" || fail "a second run changed the file"
[ "$(backups)" = "$n1" ] || fail "a second run made a backup"
expect 0 '' nc hooks --check
outhas '^  ok '
ok "second run: ok, file byte-identical, no second backup; --check on an up-to-date file: ok, exit 0"

# 4. --check: exit 1 and nothing written when there is work to do; unknown arguments exit 2
home check
expect 1 '' nc hooks --check
outhas '^  add '
[ ! -e "$S" ] || fail "--check wrote settings.json"
[ ! -e "$HOME/.nc" ] || fail "--check made a backup"
expect 2 'unknown argument "--bogus"' nc hooks --bogus
expect 2 'usage: nc hooks' nc hooks --check --bogus
cat > "$S" <<'EOF'
{"hooks":{"SessionStart":[{"matcher":"compact","hooks":[{"type":"command","command":"\"$HOME/.local/bin/nc\" orchestrator status context","timeout":5}]}]}}
EOF
cp "$S" "$T/orig.json"
expect 1 '' nc hooks --check
outhas '^  update '
cmp -s "$S" "$T/orig.json" || fail "--check changed an outdated file"
ok "--check: exit 1 and nothing written for a missing (add) or outdated (update) entry; unknown arguments exit 2"

# 5. an outdated entry (timeout 5) is replaced, duplicates (other matcher, same command) collapse to one; others stay
home dupes
cat > "$S" <<'EOF'
{"hooks":{"SessionStart":[
  {"matcher":"compact","hooks":[{"type":"command","command":"\"$HOME/.local/bin/nc\" orchestrator status context","timeout":5}]},
  {"matcher":"startup","hooks":[{"type":"command","command":"\"$HOME/.local/bin/nc\" orchestrator status context","timeout":10}]},
  {"hooks":[{"type":"command","command":"orca hook session-start"}]}
]}}
EOF
cp "$S" "$T/orig.json"
expect 0 '' nc hooks
outhas '^  updated '
jsx 's.hooks.SessionStart.length === 2 && JSON.stringify(s.hooks.SessionStart[0]) === JSON.stringify(o.hooks.SessionStart[2])' \
  || fail "the other entry changed or moved: $(js 's.hooks.SessionStart')"
jsx 's.hooks.SessionStart[1].matcher === "compact" && s.hooks.SessionStart[1].hooks.length === 1 && s.hooks.SessionStart[1].hooks[0].command === CMD && s.hooks.SessionStart[1].hooks[0].timeout === 10' \
  || fail "our entry is not the exact one: $(js 's.hooks.SessionStart[1]')"
jsx 'JSON.stringify(s).split("orchestrator status context").length === 2' || fail "our command is in the file more than once"
expect 0 '' nc hooks
outhas '^  ok '
ok "outdated entry replaced (timeout 10); duplicates with another matcher collapse to one entry; the Orca entry stays first"

# 6. invalid JSON, a top level that is not an object, hooks not an object, SessionStart not a list: exit 2, file unchanged
refuses bad-json 'not valid JSON' '{ "hooks": '
home bad-json-check
printf '%s\n' '{ "hooks": ' > "$S"
expect 2 'not valid JSON' nc hooks --check
refuses trailing-comma 'not valid JSON' '{"model": "opus",}'
refuses top-array 'not a JSON object' '[]'
refuses top-string 'not a JSON object' '"x"'
refuses hooks-array 'hooks" is not an object' '{"hooks": []}'
refuses hooks-string 'hooks" is not an object' '{"hooks": "x"}'
refuses hooks-null 'hooks" is not an object' '{"hooks": null}'
refuses sessionstart-object 'SessionStart" is not a list' '{"hooks": {"SessionStart": {}}}'
ok "invalid JSON (also for --check), a top level that is not an object, hooks not an object, SessionStart not a list: exit 2, file unchanged, no backup"

# 7. a symlinked settings.json: the target is written, the link is kept, the backup is the old target
home link
mkdir -p "$HOME/dotfiles"
printf '%s\n' '{"model":"opus"}' > "$HOME/dotfiles/settings.json"
chmod 640 "$HOME/dotfiles/settings.json"
ln -s "$HOME/dotfiles/settings.json" "$S"
cp "$HOME/dotfiles/settings.json" "$T/orig.json"
expect 0 '' nc hooks
[ -L "$S" ] || fail "the link was replaced"
[ "$(readlink "$S")" = "$HOME/dotfiles/settings.json" ] || fail "the link points elsewhere: $(readlink "$S")"
jsx 'strip(s).model === "opus" && s.hooks.SessionStart.length === 1 && s.hooks.SessionStart[0].hooks[0].command === CMD' \
  || fail "the target does not hold the hook"
[ "$(mode_of "$HOME/dotfiles/settings.json")" = 640 ] || fail "target mode $(mode_of "$HOME/dotfiles/settings.json"), expected 640"
[ "$(ls -A "$HOME/dotfiles")" = settings.json ] || fail "a tmp file was left next to the target: $(ls -A "$HOME/dotfiles")"
bk="$(find "$HOME/.nc/backup" -type f)"
cmp -s "$bk" "$T/orig.json" || fail "the backup is not the old target"
ok "symlinked settings.json: the target gets the hook (mode 640 kept), the link stays, the backup is the old target, no tmp file"

# 8. the mode of a plain file is kept
home mode
printf '%s\n' '{"model":"opus"}' > "$S"
chmod 640 "$S"
expect 0 '' nc hooks
[ "$(mode_of "$S")" = 640 ] || fail "mode $(mode_of "$S"), expected 640"
ok "mode of an existing settings.json is kept (640)"

# 9. a second change on the same day: the new backup gets a time suffix, the first backup is not overwritten
home backup2
printf '%s\n' '{"model":"opus"}' > "$S"
cp "$S" "$T/first.json"
expect 0 '' nc hooks
cat > "$S" <<'EOF'
{"hooks":{"SessionStart":[{"matcher":"compact","hooks":[{"type":"command","command":"\"$HOME/.local/bin/nc\" orchestrator status context","timeout":5}]}]}}
EOF
cp "$S" "$T/third.json"
expect 0 '' nc hooks
[ "$(backups)" = 2 ] || fail "backups: $(backups)"
found1=0; found3=0
while IFS= read -r f; do
  cmp -s "$f" "$T/first.json" && found1=1
  cmp -s "$f" "$T/third.json" && found3=1
done < <(find "$HOME/.nc/backup" -type f)
[ "$found1" = 1 ] && [ "$found3" = 1 ] || fail "the backups do not hold both old versions"
ok "a second change on the same day keeps the first backup and adds one with a time suffix"

# Our command in an entry that also holds another hook: only our hook leaves that entry, the other one stays.
home shared
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"orca hook session-start"},{"type":"command","command":"\"$HOME/.local/bin/nc\" orchestrator status context","timeout":10}]}]}}' > "$S"
expect 0 '' nc hooks
[ "$(js 's.hooks.SessionStart.map((e) => e.hooks.length + ":" + (e.matcher ?? "-") + ":" + (e.hooks[0].command.includes("orca") ? "orca" : "nc")).join(" ")')" = '"1:-:orca 1:compact:nc"' ] \
  || fail "shared entry not split: $(js 's.hooks')"
expect 0 '' nc hooks --check
ok "shared entry: the other hook stays, ours moves to its own entry"

# --check agrees with the real run on a hooks shape the write refuses.
home check-shape
printf '%s\n' '{"hooks": []}' > "$S"
expect 2 '"hooks" is not an object' nc hooks --check
printf '%s\n' '{"hooks": {"SessionStart": {}}}' > "$S"
expect 2 '"hooks.SessionStart" is not a list' nc hooks --check
ok "--check: a hooks shape the write refuses is exit 2 too"

# A dangling link is refused and left as it is.
home dangling
ln -s "$HOME/dotfiles/missing.json" "$S"
expect 2 'link to a missing file' nc hooks
[ -L "$S" ] && [ "$(readlink "$S")" = "$HOME/dotfiles/missing.json" ] || fail "the dangling link was changed"
[ ! -e "$HOME/dotfiles/missing.json" ] || fail "the target was created"
ok "dangling link: refused (exit 2), link unchanged"

# A UTF-8 BOM (some editors write one) is read; the file is written back without it.
home bom
printf '\357\273\277{"model":"opus"}\n' > "$S"
expect 0 '' nc hooks
[ "$(head -c 1 "$S")" = "{" ] && [ "$(js 's.model')" = '"opus"' ] || fail "BOM file not handled: $(head -c 20 "$S" | od -c | head -2)"
ok "a settings.json with a BOM is read and written back without it"

echo "all $pass tests passed"
