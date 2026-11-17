#!/usr/bin/env bash
# Tests for nc models, its gate in nc opencode and its nc doctor checks. No network, no keys, throwaway $HOME.
# Tests with their own models.yaml run against a copy of the repo; OpenCode is a fake that prints what it got.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUN_DIR="$(dirname "$(mise which bun 2>/dev/null || command -v bun)")"
unset NC_HOME NC_MACHINE NC_HARNESS_VERSION NC_PROJECT_PATH NC_OPENCODE NC_SECRETS OPENROUTER_API_KEY XDG_CONFIG_HOME OPENCODE_CONFIG_DIR \
  NC_MEMORY_DIR NC_MEMORY_OUTBOX NC_PROJECT GH_TOKEN GITHUB_TOKEN \
  CLAUDE_CODE_EFFORT_LEVEL CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE || true
export BUN_RUNTIME_TRANSPILER_CACHE_PATH=0   # no Bun cache anywhere, also with HOME=/ (macOS: /Library/Caches/bun)

T="$(mktemp -d)"                     # two steps: inside one $(…) a failed mktemp would leave T = the start folder
T="$(cd "$T" && pwd -P)"             # real path: on macOS /tmp is itself a link
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
# A neutral current folder: results must not depend on where the tests start (from / or /tmp the throwaway
# HOME would lie below it), and Bun puts its cache into the current folder when HOME is empty or relative.
mkdir "$T/cwd" && cd "$T/cwd"
export HOME="$T/home"
# A PATH without nc-work, so the tests decide whether this machine "has containers".
ALL_PATH="$BUN_DIR:$PATH"
BASE_PATH="$(IFS=:; for d in $ALL_PATH; do [ -x "$d/nc-work" ] || printf '%s:' "$d"; done)"
export PATH="$HOME/.local/bin:${BASE_PATH%:}"
command -v bun > /dev/null || { echo "FAIL: bun not on the test PATH" >&2; exit 1; }
! command -v nc-work > /dev/null || { echo "FAIL: nc-work still on the test PATH" >&2; exit 1; }
SYNTH="sk-or-v1-synthetic-test-value-0000"   # never a real key

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok   $*"; pass=$((pass + 1)); }
RC="$T/repo"                                  # copy of the repo whose models.yaml the tests replace
cp -a "$REPO" "$RC" && rm -rf "$RC/.git"
nc()   { "$RC/bin/nc" "$@"; }
expect() {  # expect <exit code> <pattern on stderr, or ''> <command…>; leaves stdout in $T/out, stderr in $T/err
  local want="$1" pat="$2" code=0; shift 2
  "$@" > "$T/out" 2> "$T/err" || code=$?
  [ "$code" = "$want" ] || fail "exit $code, expected $want: $* – $(cat "$T/err")"
  [ -z "$pat" ] || grep -q -- "$pat" "$T/err" || fail "$*: expected '$pat' on stderr, got: $(cat "$T/err")"
}
field() {  # field <js expression on r> <nc models arguments…>: one value from nc models --json
  local expr="$1" json; shift
  json="$(nc models --json "$@")" || fail "nc models --json $* failed"
  bun -e 'const r = JSON.parse(process.argv[1]); console.log(JSON.stringify(eval(process.argv[2])))' "$json" "$expr"
}
is() { [ "$1" = "$2" ] || fail "$3: got $1, expected $2"; }

CLASSES='classes:
  frontier: { runtime: claude-code }
  standard: { runtime: opencode, model: "openrouter/acme/big-1" }
  cheap:    { runtime: opencode, model: "openrouter/acme/small-1" }
  free:     { runtime: opencode, model: "TODO: openrouter/<provider>/<model>:free" }
  open:     { runtime: opencode, model: "TODO: openrouter/<provider>/<model>" }
roles: { planner: frontier, implementer: standard, tester: cheap, researcher: free, scout: open }
isolation: { classes: [cheap, free] }
budgets: { per_task_usd: 1.00 }'
yaml() { printf '%s\npolicies:\n%s\n' "$CLASSES" "$1" > "$RC/models.yaml"; }
# A: two restricted folders, one nested below a folder of its own (agency), one at the top (acme).
A='  - match: "~/projects/agency/clients/**"
    deny_classes: [free]
    require: no-training
    isolation: container
  - match: "~/projects/acme/**"
    deny_classes: [free]
    require: no-training
    isolation: container
  - match: "**"
    deny_classes: []'
# B: two different rules below one folder; ~/work/a denies free but asks for no container.
B='  - match: "~/work/a/**"
    deny_classes: [free]
  - match: "~/work/b/**"
    deny_classes: [cheap]
    require: no-training
    isolation: container
  - match: "**"'

P="$HOME/projects"
mkdir -p "$P/acme/website" "$P/acme/platform" "$P/acme-x" "$P/agency/clients/globex" "$P/personal/site" \
  "$HOME/sandbox" "$HOME/work/a" "$HOME/work/b" "$HOME/.local/bin"
ACME='"~/projects/acme/**"'
yaml "$A"

# 1. the public models.yaml of the repo: ~/projects/clients denies free and asks for a container, the rest does not
mkdir -p "$P/clients/globex"
got="$("$REPO/bin/nc" models --json --path "$P/clients/globex" | bun -e 'const r = await Bun.stdin.json(); console.log(r.policy.deny_classes.includes("free"), r.policy.isolation, r.classes.free.allowed)')"
is "$got" "true container false" "public models.yaml in clients/globex"
got="$("$REPO/bin/nc" models --json --path "$P/personal/site" | bun -e 'const r = await Bun.stdin.json(); console.log(r.policy.match, r.policy.deny_classes.length)')"
is "$got" "** 0" "public models.yaml in personal/site"
rmdir "$P/clients/globex" "$P/clients"
ok "the public models.yaml denies free and asks for a container in client folders only"

# 2. which rule: Acme, clients, the rest; the folder itself; a similar name; a folder that does not exist
is "$(field r.policy.match --path "$P/acme/website")" "$ACME" "Acme folder"
is "$(field r.policy.match --path "$P/agency/clients/globex")" '"~/projects/agency/clients/**"' "client folder"
is "$(field r.policy.match --path "$P/personal/site")" '"**"' "other folder"
is "$(field r.policy.match --path "$P/acme")" "$ACME" "~/projects/acme itself"
is "$(field r.policy.below --path "$P/acme")" "[]" "below of ~/projects/acme"
is "$(field r.policy.match --path "$P/acme-x")" '"**"' "~/projects/acme-x"
is "$(field r.policy.match --path "$P/acme/not/there")" "$ACME" "missing folder below Acme"
is "$(field r.path --path "$P/acme/not/there")" "\"$P/acme/not/there\"" "path of a missing folder"
is "$(field r.policy.match --path "$HOME/not/there")" '"**"' "missing folder elsewhere"
is "$(field 'r.policy.match' --path '~/projects/acme')" "$ACME" "--path '~/projects/acme'"
is "$(cd "$P/personal" && field r.policy.match --path ../acme/website)" "$ACME" "relative --path"
ok "first matching rule by whole path parts: Acme, clients, rest, the folder itself, acme-x, missing folders, ~ in --path"

# 3. ~/projects and ~ take over the restrictions of the rules below them
for d in "$P" "$HOME"; do
  is "$(field 'r.policy.match + " " + r.policy.below.join(",")' --path "$d")" '"** ~/projects/agency/clients/**,~/projects/acme/**"' "match and below of $d"
  is "$(field '[r.policy.deny_classes, r.policy.require, r.policy.isolation, r.classes.free.allowed]' --path "$d")" '[["free"],["no-training"],"container",false]' "restrictions of $d"
  expect 1 "plus from below: ~/projects/agency/clients/\*\*, ~/projects/acme/\*\*" nc models check --model openrouter/x/y:free --path "$d"
done
is "$(field r.policy.below --path "$P/agency")" '["~/projects/agency/clients/**"]' "below of ~/projects/agency"
ok "~/projects and ~ count as restricted and name policy.below"

# 4. symlinks: into an Acme folder, `..` behind a link, cd through a link, a link without a target
ln -s "$P/acme/website" "$HOME/sandbox/link"
ln -s nowhere "$HOME/sandbox/dangling"
is "$(field r.policy.match --path "$HOME/sandbox/link")" "$ACME" "symlink into an Acme folder"
is "$(field r.path --path "$HOME/sandbox/link/..")" "\"$P/acme\"" "'..' behind a symlink is the real parent"
is "$(cd "$HOME/sandbox/link" && field r.path)" "\"$P/acme/website\"" "no --path after cd through a symlink"
is "$(cd "$HOME/sandbox/link" && field r.policy.match)" "$ACME" "policy after cd through a symlink"
expect 2 "symlink without a target" nc models --path "$HOME/sandbox/dangling"
expect 2 "symlink without a target" nc models check --model openrouter/a/b --path "$HOME/sandbox/dangling/x"
ok "symlinks are resolved (also '..' and the current folder); a symlink without a target is exit 2"

# 5. ~/projects/acme as a symlink to the outside; a HOME only reached through a symlink; empty HOME
H2="$T/home2"
mkdir -p "$H2/projects" "$T/outside/acme-real/website"
ln -s "$T/outside/acme-real" "$H2/projects/acme"
is "$(HOME="$H2" field r.policy.match --path "$T/outside/acme-real/website")" "$ACME" "real folder behind ~/projects/acme"
is "$(HOME="$H2" field r.policy.match --path "$H2/projects/acme/website")" "$ACME" "through the link ~/projects/acme"
is "$(HOME="$H2" field r.policy.below --path "$T/outside")" "[$ACME]" "the folder above the link target"
ln -s "$HOME" "$T/homelink"
is "$(HOME="$T/homelink" field r.policy.match --path "$P/acme/website")" "$ACME" "HOME through a symlink, real --path"
is "$(HOME="$T/homelink" field r.path --path '~/projects/acme')" "\"$P/acme\"" "HOME through a symlink, ~ in --path"
HOME="" expect 2 "HOME is empty" nc models
HOME="" expect 2 "HOME is empty" nc models check --model openrouter/a/b --path "$P/personal/site"
HOME="relative/home" expect 2 "not an absolute path" nc models
ok "a linked ~/projects/acme and a HOME behind a symlink match; empty or relative HOME is exit 2"

# 6. a broken models.yaml is exit 2 for every command, never a permission
broken() {  # broken <pattern>: the current models.yaml must be refused
  expect 2 "$1" nc models
  expect 2 "$1" nc models check --model openrouter/a/b --path "$P/personal/site"
  expect 2 "$1" nc models check --host --path "$P/personal/site"
  expect 2 "$1" nc models resolve --class frontier
}
rm "$RC/models.yaml";                                    broken "missing or not readable"
: > "$RC/models.yaml";                                   broken "the content missing"
printf '%s\n' "$CLASSES" > "$RC/models.yaml";            broken "policies missing"
yaml '  - match: "**"'
if [ "$(id -u)" != 0 ]; then                             # root reads it anyway
  chmod 000 "$RC/models.yaml";                           broken "missing or not readable (EACCES)"
  chmod 644 "$RC/models.yaml"
fi
printf '%s\npolicies:\n  - match: "**"\n' "${CLASSES/openrouter\/acme\/big-1/acme/big-1}" > "$RC/models.yaml"
broken 'classes.standard.model "acme/big-1" is neither a placeholder'
yaml '  - match: "**"'
expect 2 "path cannot be resolved (ENOTDIR)" nc models --path "$RC/models.yaml/x"
expect 2 "path cannot be resolved (ENOTDIR)" nc models check --model openrouter/a/b --path "$RC/models.yaml/x"
printf 'classes: [a, b\n' > "$RC/models.yaml";           broken "not valid YAML"
yaml '  - match: "~/projects/acme/**"';                  broken 'needs match: "\*\*" as its last rule'
yaml '  - match: "**"
  - match: "~/projects/acme/**"';                        broken "not the last rule"
yaml '  - match: "**"
  - match: "**"';                                        broken "more than once"
yaml '  - match: "~/projects/acme/**"
    deny_classes: [fre]
  - match: "**"';                                        broken '"fre", which is not a class'
yaml '  - match: "~/projects/acme"
  - match: "**"';                                        broken "neither"
yaml '  - match: "projects/acme/**"
  - match: "**"';                                        broken "neither"
yaml '  - match: "~/projects/*/x/**"
  - match: "**"';                                        broken "neither"
yaml '  - match: "~/projects/acme/**"
    isolation: containers
  - match: "**"';                                        broken 'isolation is "containers"'
yaml '  - match: "~/projects/acme/**"
    deny_class: [free]
  - match: "**"';                                        broken 'unknown field "deny_class"'
ok "missing, empty or unreadable file, no YAML, no policies, ** missing/first/twice, unknown class, bad match, isolation: containers, unknown field, invalid class model, --path <file>/x: exit 2"

# 7. two different rules below one folder are merged
yaml "$B"
is "$(field '[r.policy.match, r.policy.below, r.policy.deny_classes, r.policy.require, r.policy.isolation]' --path "$HOME/work")" \
  '["**",["~/work/a/**","~/work/b/**"],["free","cheap"],["no-training"],"container"]' "merged policy of ~/work"
is "$(field '[r.policy.deny_classes, r.policy.isolation]' --path "$HOME/work/a")" '[["free"],null]' "~/work/a alone"
ok "two rules below one folder: deny_classes merged, require and isolation apply"

# 8. model IDs: each in an Acme folder and in a free folder, without --host
yaml "$A"
while read -r id acme other; do
  [ "$id" != "''" ] || id=""
  expect "$acme" "" nc models check --model "$id" --path "$P/acme/website"
  [ "$acme" = 0 ] || grep -qE "policy ~/projects/acme/\*\*|not a model ID|not approved" "$T/err" || fail "no reason for [$id]: $(cat "$T/err")"
  expect "$other" "" nc models check --model "$id" --path "$P/personal/site"
  expect "$other" "" nc models check --model="$id" --path="$P/personal/site"
done <<'EOF'
openrouter/x/y:free 1 0
openrouter/x/y:free:nitro 1 0
openrouter/x/y:nitro:free 1 0
openrouter/x/y:free#high 1 0
openrouter/x/y:FREE 1 0
openrouter/openrouter/free 1 0
openrouter/openrouter/auto 1 0
openrouter/~anthropic/claude-haiku-latest 1 0
openrouter/@preset/x 1 0
openrouter/a/b/c 1 0
openrouter/x 1 0
openrouter/nvidia/switchyard 1 0
openrouter/typesafe/jev-router:nitro 1 0
anthropic/claude 1 1
openrouter/ 1 1
'' 1 1
openrouter/x/y 1 0
openrouter/x/y:nitro 1 0
openrouter/x/y#high 1 0
openrouter/acme/big-1 0 0
openrouter/acme/big-1#high 0 0
openrouter/acme/small-1#low 0 0
openrouter/acme/big-1:nitro 1 0
openrouter/ACME/big-1 1 0
EOF
expect 1 "a free model" nc models check --model openrouter/x/y:nitro:free --path "$P/acme/website"
expect 1 "a router or alias" nc models check --model openrouter/openrouter/auto --path "$P/acme/website"
expect 1 "not a model ID" nc models check --model anthropic/claude --path "$P/personal/site"
expect 1 "not approved: in $P/acme/website only the models of the allowed classes apply (standard: openrouter/acme/big-1, cheap: openrouter/acme/small-1)" \
  nc models check --model openrouter/x/y --path "$P/acme/website"
expect 1 "not approved" nc models check --model "openrouter/x/y#high" --path "$P/acme/website"
expect 1 "not approved" nc models check --model openrouter/acme/big-1:nitro --path "$P/acme/website"
ok "24 model IDs: free, routers and aliases are refused where free is denied; other paid models only as the exact class model; without openrouter/ everywhere"

# 9. classes: the model of a denied class, policy before placeholder, frontier, the fields of --json
yaml "$B"
expect 1 "model of class cheap" nc models check --model openrouter/acme/small-1 --path "$HOME/work/b"
expect 1 "model of class cheap" nc models check --model "openrouter/acme/small-1#high" --path "$HOME/work/b"
expect 0 "" nc models check --model openrouter/acme/small-1 --path "$HOME/work/a"
expect 1 "not approved" nc models check --model openrouter/acme/small-1:nitro --path "$HOME/work/b"
is "$(field '[r.classes.cheap.allowed, r.classes.cheap.model]' --path "$HOME/work/b")" '[false,"openrouter/acme/small-1"]' "denied class with a model"
yaml "$A"
reason="$(field r.classes.free.reason --path "$P/acme/website")"
grep -q "policy ~/projects/acme/\*\* denies the class free" <<<"$reason" || fail "denied placeholder class: $reason"
grep -q "placeholder" <<<"$reason" && fail "placeholder named before the policy: $reason"
is "$(field r.classes.free --path "$P/personal/site")" '{"runtime":"opencode","model":null,"allowed":false,"reason":"the model is a placeholder (TODO in models.yaml)","isolation":"container"}' "placeholder class in a free folder"
is "$(field r.classes.frontier --path "$P/acme/website")" '{"runtime":"claude-code","model":null,"allowed":true,"reason":null,"isolation":"container"}' "frontier"
is "$(field r.classes.standard --path "$P/acme/website")" '{"runtime":"opencode","model":"openrouter/acme/big-1","allowed":true,"reason":null,"isolation":"container"}' "standard"
is "$(field r.classes.standard --path "$P/personal/site")" '{"runtime":"opencode","model":"openrouter/acme/big-1","allowed":true,"reason":null,"isolation":null}' "standard in a free folder"
is "$(field '[Object.keys(r), Object.keys(r.policy), r.budgets]' --path "$P/acme/website")" \
  '[["path","file","policy","classes","roles","isolation","budgets"],["match","below","deny_classes","require","isolation"],{"per_task_usd":1}]' "fields of --json"
nc models --path "$P/acme/website" > "$T/out"
# the old "(not evaluated yet)" and "(not enforced yet)" stay out; the pattern matches them (positive control)
stale="not (evaluated|enforced) yet"
grep -qE "$stale" <<<"isolation.classes: cheap (not evaluated yet)" || fail "the pattern for the old texts matches nothing"
grep -q "^policy: ~/projects/acme/\*\*$" "$T/out" && grep -q "free .*not set .*denied: the policy" "$T/out" \
  && grep -q "frontier .*claude-code .*allowed · only in a container$" "$T/out" && grep -q "isolation .*container" "$T/out" && grep -q "per_task_usd 1 (display only" "$T/out" \
  && ! grep -qE "$stale" "$T/out" || fail "text output: $(cat "$T/out")"
nc models --path "$P/personal/site" > "$T/out"
grep -q "standard .*allowed$" "$T/out" && grep -q "cheap .*allowed · only in a container$" "$T/out" || fail "text output in a free folder: $(cat "$T/out")"
ok "a denied class's model is refused without :free; the policy is named before the placeholder; frontier is no placeholder; --json fields"

# 9b. a class whose model is a free one but which is not called free: refused where free is denied (rule 3)
printf '%s\n  sly: { runtime: opencode, model: "openrouter/x/y:free" }\npolicies:\n%s\n' "$(sed -n '1,6p' <<<"$CLASSES")" "$A" > "$RC/models.yaml"
printf 'roles: { sneaky: sly }\n' >> "$RC/models.yaml"
reason="$(field r.classes.sly.allowed --path "$P/acme/website")"
is "$reason" "false" "class sly in an Acme folder"
field r.classes.sly.reason --path "$P/acme/website" | grep -q "a free model" || fail "reason for sly: $(field r.classes.sly.reason --path "$P/acme/website")"
expect 1 "a free model" nc models resolve --class sly --path "$P/acme/website"
expect 1 "a free model" nc models resolve --role sneaky --path "$P/acme/website"
[ ! -s "$T/out" ] || fail "resolve printed the free model: $(cat "$T/out")"
is "$(nc models resolve --class sly --path "$P/personal/site")" "opencode openrouter/x/y:free" "class sly in a free folder"
yaml "$A"
ok "a class with a free model under another name is refused in an Acme folder, resolve exit 1"

# 9c. a deleted current folder is an error (exit 2), not a refusal and not a stack trace
mkdir "$T/gone"
code=0; (cd "$T/gone" && rmdir "$T/gone" && nc models check --model openrouter/a/b) > "$T/out" 2> "$T/err" || code=$?
is "$code" 2 "check in a deleted current folder"
grep -q "^nc models: current folder cannot be resolved" "$T/err" || fail "deleted current folder: $(cat "$T/err")"
grep -qE "    at |error:" "$T/err" && fail "stack trace: $(cat "$T/err")"
# an unexpected error elsewhere (here: a YAML alias pointing at itself, which the message cannot write) is exit 2 too
{ sed 's/^budgets: .*/budgets: \&b { per_task_usd: *b }/' <<<"$CLASSES"; printf 'policies:\n%s\n' "$A"; } > "$RC/models.yaml"
grep -q '&b' "$RC/models.yaml" || fail "fixture: cyclic budgets not written"
expect 2 "^nc models: unexpected error: JSON.stringify" nc models --json --path "$P/personal/site"
grep -q "    at " "$T/err" && fail "stack trace: $(cat "$T/err")"
yaml "$A"
ok "a deleted current folder and any other unexpected error are exit 2 with one line"

# 10. check: asks nothing without --model and --host; silent when it allows; wrong calls are exit 2
expect 2 "asks nothing" nc models check
expect 2 "asks nothing" nc models check --path "$P/personal/site"
expect 0 "" nc models check --model openrouter/acme/big-1 --path "$P/acme/website"
[ ! -s "$T/out" ] && [ ! -s "$T/err" ] || fail "check printed something on exit 0"
expect 2 "needs a value" nc models check --model
expect 2 "given more than once" nc models check --model openrouter/a/b --model openrouter/x/y:free
expect 2 "unknown option" nc models check --model openrouter/a/b --file "$T/other.yaml"
expect 2 "unknown option" nc models check --model openrouter/a/b --json
expect 2 "unknown option" nc models --host
expect 2 "unknown command" nc models chek --model openrouter/a/b
NC_MODELS="$T/other.yaml" NC_MODELS_FILE="$T/other.yaml" expect 1 "" nc models check --model openrouter/x/y:free --path "$P/acme/website"
ok "check without a question is exit 2, prints nothing on exit 0, and there is no way to name another file"

# 11. --host: a folder with isolation: container, with and without a model; free and paid elsewhere
expect 1 "isolation: container" nc models check --host --path "$P/acme/website"
grep -q "only in a container, and this machine has none" "$T/err" || fail "no nc-work: $(cat "$T/err")"
grep -q "nc-work here" "$T/err" && fail "nc-work here named although nc-work is not on PATH"
expect 1 "isolation: container" nc models check --host --model openrouter/x/y --path "$P/acme/website"
expect 1 "isolation: container" nc models check --host --model openrouter/x/y:free --path "$P"
expect 0 "" nc models check --host --model openrouter/x/y:free --path "$P/personal/site"
expect 0 "" nc models check --host --model openrouter/x/y --path "$P/personal/site"
expect 0 "" nc models check --host --path "$P/personal/site"
[ ! -s "$T/out" ] && [ ! -s "$T/err" ] || fail "check --host printed something on exit 0"
mkdir -p "$T/ncwork" && printf '#!/bin/sh\nexit 0\n' > "$T/ncwork/nc-work" && chmod 755 "$T/ncwork/nc-work"
PATH="$T/ncwork:$PATH" expect 1 "nc-work here --runtime opencode" nc models check --host --path "$P/acme/website"
yaml "$B"
expect 1 "a free model" nc models check --host --model openrouter/x/y:free --path "$HOME/work/a"
grep -q "isolation" "$T/err" && fail "~/work/a asks for no container: $(cat "$T/err")"
expect 1 "not approved" nc models check --host --model openrouter/x/y --path "$HOME/work/a"
grep -q "isolation" "$T/err" && fail "~/work/a asks for no container: $(cat "$T/err")"
expect 0 "" nc models check --host --model openrouter/acme/big-1 --path "$HOME/work/a"
ok "--host refuses where isolation: container holds, allows free and paid elsewhere, refuses free and other models than the class models where free is denied"

# 12. resolve: one line, never another class
line() { nc models resolve "$@" 2> /dev/null || true; }
is "$(nc models resolve --role implementer)" "opencode openrouter/acme/big-1" "role implementer"
is "$(nc models resolve --class standard --path "$HOME/work/a")" "opencode openrouter/acme/big-1" "class standard"
is "$(nc models resolve --class frontier)" "claude-code" "class frontier"
is "$(nc models resolve --role planner --path "$HOME/work/b")" "claude-code" "role planner"
is "$(nc models resolve --role tester --json)" '{"class":"cheap","role":"tester","runtime":"opencode","model":"openrouter/acme/small-1","isolation":"container","require":[]}' "resolve --json"
expect 1 "placeholder" nc models resolve --class open
expect 1 "placeholder" nc models resolve --role scout
expect 1 "policy ~/work/a/\*\* denies the class free" nc models resolve --role researcher --path "$HOME/work/a"
grep -q "placeholder" "$T/err" && fail "placeholder named instead of the policy: $(cat "$T/err")"
expect 1 "policy ~/work/b/\*\* denies the class cheap" nc models resolve --role tester --path "$HOME/work/b"
[ ! -s "$T/out" ] || fail "resolve printed a line although it refused: $(cat "$T/out")"
expect 2 "unknown role" nc models resolve --role nobody
expect 2 "unknown class" nc models resolve --class nothing
expect 2 "exactly one" nc models resolve
expect 2 "exactly one" nc models resolve --class cheap --role tester
for d in "$HOME/work" "$HOME/work/a" "$HOME/work/b" "$HOME/sandbox"; do
  for pair in "frontier:claude-code" "standard:opencode openrouter/acme/big-1" "cheap:opencode openrouter/acme/small-1" "free:" "open:"; do
    got="$(line --class "${pair%%:*}" --path "$d")"
    [ -z "$got" ] || [ "$got" = "${pair#*:}" ] || fail "resolve --class ${pair%%:*} in $d answered with another class: $got"
  done
done
ok "resolve prints runtime and model of exactly the class asked for; placeholder and denied class are exit 1, unknown names exit 2"

# 12b. bunfig.toml (preload), .env and tsconfig.json/jsconfig.json (paths) in the folder or above change nothing
yaml "$A"
mkdir -p "$P/acme/evil" "$P/acme/evil2" "$P/acme/evil3"
printf 'preload = ["./pre.ts"]\n' > "$P/acme/evil/bunfig.toml"
printf 'process.exit(0);\n' > "$P/acme/evil/pre.ts"
printf 'NC_HARNESS_VERSION=1\nNC_PROJECT_PATH=personal/site\n' > "$P/acme/evil2/.env"
(cd "$P/acme/evil" && expect 1 "isolation: container" nc models check --host)
(cd "$P/acme/evil" && expect 1 "a free model" nc models check --model openrouter/x/y:free)
(cd "$P/acme/evil2" && expect 1 "a free model" nc models check --model openrouter/x/y:free)
(cd "$P/acme/evil2" && expect 1 "isolation: container" nc models check --host)
printf '{"compilerOptions":{"paths":{"*":["./x.ts"]}}}\n' > "$P/acme/evil3/tsconfig.json"
printf 'process.exit(0)\n' > "$P/acme/evil3/x.ts"
(cd "$P/acme/evil3" && expect 1 "isolation: container" nc models check --host)
(cd "$P/acme/evil3" && expect 1 "a free model" nc models check --model openrouter/x/y:free)
printf '{"compilerOptions":{"paths":{"*":["./x.ts"]}}}\n' > "$P/acme/jsconfig.json"   # in ~/projects/acme, read from below too
printf 'process.exit(0)\n' > "$P/acme/x.ts"
(cd "$P/acme" && expect 1 "isolation: container" nc models check --host)
(cd "$P/acme/website" && expect 1 "a free model" nc models check --model openrouter/x/y:free)
ok "bunfig.toml with a preload, .env, tsconfig.json and jsconfig.json with paths do not change the answer"

# 13. in a task container: the project path comes from NC_PROJECT_PATH, compared as text
yaml "$A"
box() { env NC_HARNESS_VERSION=0123456789abcdef HOME=/home/agent "$@"; }
for v in acme/website acme acme/; do
  got="$(NC_PROJECT_PATH="$v" box "$RC/bin/nc" models --json | bun -e 'const r = await Bun.stdin.json(); console.log(r.path, r.policy.match, r.classes.free.allowed, r.classes.free.reason.includes("policy"))')"
  is "$got" "/home/agent/projects/${v%/} ~/projects/acme/** false true" "container with NC_PROJECT_PATH=$v"
  NC_PROJECT_PATH="$v" expect 1 "denies the class free" box "$RC/bin/nc" models check --model openrouter/x/y:free
done
NC_PROJECT_PATH=personal/site expect 0 "" box "$RC/bin/nc" models check --model openrouter/x/y:free
for h in /home/agent/ / //home//agent/. /home/agent/./; do   # the asked path is normalised like the patterns
  NC_PROJECT_PATH=acme/website expect 1 "denies the class free" env NC_HARNESS_VERSION=0123456789abcdef HOME="$h" "$RC/bin/nc" models check --model openrouter/x/y:free
done
expect 2 "NC_PROJECT_PATH is not set" box "$RC/bin/nc" models
for v in "" /acme ./acme/website acme/../x acme//website "acme website" 'acme/*'; do
  NC_PROJECT_PATH="$v" expect 2 "NC_PROJECT_PATH" box "$RC/bin/nc" models
  NC_PROJECT_PATH="$v" expect 2 "NC_PROJECT_PATH" box "$RC/bin/nc" models check --model openrouter/x/y
done
NC_PROJECT_PATH=acme/website expect 2 "there is no --path or --host in a task container" box "$RC/bin/nc" models --path /workspace
NC_PROJECT_PATH=personal/site expect 2 "there is no --path or --host in a task container" box "$RC/bin/nc" models check --host
ok "container: NC_PROJECT_PATH acme/website and acme deny free, also with HOME=/home/agent/ or /; missing or malformed, --path and --host are exit 2"

# 14. nc opencode on the host: refused in an Acme folder before secrets.env is read
mkdir -p "$HOME/.config/opencode"
cp "$REPO/adapters/opencode/service.json" "$REPO/adapters/opencode/opencode.json" "$HOME/.config/opencode/"
cat > "$HOME/.local/bin/opencode" <<'EOF'
#!/usr/bin/env bash
touch "$HOME/.opencode-ran"
echo "args: $*"
echo "key: ${OPENROUTER_API_KEY:-<none>}"
echo "marker: ${NC_OPENCODE:-<none>}"
EOF
chmod 755 "$HOME/.local/bin/opencode"
S="$HOME/.config/nc-harness/secrets.env"
blocked() {  # blocked <exit code> <pattern> <folder> <nc opencode arguments…>: that exit, the pattern on stderr, OpenCode not started
  local want="$1" pat="$2" dir="$3" code=0; shift 3
  rm -f "$HOME/.opencode-ran"
  (cd "$dir" && nc opencode "$@") > "$T/out" 2> "$T/err" || code=$?
  [ "$code" = "$want" ] || fail "nc opencode $* in $dir: exit $code – $(cat "$T/out" "$T/err")"
  grep -q -- "$pat" "$T/err" || fail "nc opencode $* in $dir: expected '$pat', got: $(cat "$T/err")"
  [ ! -s "$T/out" ] && [ ! -e "$HOME/.opencode-ran" ] || fail "nc opencode $* in $dir started OpenCode"
}
refused() { blocked 1 "$@"; }
[ ! -e "$S" ] || fail "secrets.env exists too early"
refused "isolation: container" "$P/acme/website"
grep -q "secrets.env" "$T/err" && fail "secrets.env was looked at before the policy: $(cat "$T/err")"
grep -q "this machine has none" "$T/err" || fail "no nc-work: $(cat "$T/err")"
PATH="$T/ncwork:$PATH" refused "nc-work here --runtime opencode" "$P/acme/website" run hi
refused "isolation: container" "$P/agency/clients/globex" run --model openrouter/x/y hi
refused "isolation: container" "$P/personal/site" "$P/acme/website"
refused "isolation: container" "$P/personal/site" --prompt x "$P/acme/website"
refused "isolation: container" "$P/personal/site" --session=abc -c ../../acme/website --auto
refused "isolation: container" "$HOME/sandbox" link
refused "isolation: container" "$P"
refused "isolation: container" "$P/acme/evil"                  # its bunfig.toml would make check exit 0
refused "isolation: container" "$P/acme/evil3"                 # its tsconfig.json too
refused "isolation: container" "$P/acme/evil3" run -m openrouter/x/y:free hi
refused "isolation: container" "$P/acme"                       # its jsconfig.json too
refused "isolation: container" "$P/personal/site" --auto ../../acme/website   # not a switch value, so the folder
ok "nc opencode refuses in an Acme or client folder before secrets.env, also for a folder argument behind options"

# 14b. nc opencode stays shut when nc models fails (exit 2): broken models.yaml, deleted current folder
printf 'classes: [a, b\n' > "$RC/models.yaml"
blocked 2 "models.yaml: not valid YAML" "$P/personal/site"
blocked 2 "models.yaml: not valid YAML" "$P/personal/site" run --model openrouter/x/y hi
yaml "$A"
mkdir "$T/gone2"
code=0; (cd "$T/gone2" && rmdir "$T/gone2" && nc opencode) > "$T/out" 2> "$T/err" || code=$?
[ "$code" = 2 ] && [ ! -s "$T/out" ] && [ ! -e "$HOME/.opencode-ran" ] || fail "nc opencode in a deleted folder: exit $code, $(cat "$T/out" "$T/err")"
ok "nc opencode does not start when nc models ends with exit 2"

# 15. nc opencode: a free model where free is denied without a container; unclear arguments
mkdir -p "$(dirname "$S")" && printf 'OPENROUTER_API_KEY=%s\n' "$SYNTH" > "$S" && chmod 600 "$S"
yaml "$B"
refused "a free model" "$HOME/work/a" run --model openrouter/x/y:free hi
refused "a free model" "$HOME/work/a" run --model=openrouter/x/y:free hi
refused "a free model" "$HOME/work/a" run -m openrouter/x/y:free hi
refused "a free model" "$HOME/work/a" --auto mini -m openrouter/x/y:free
refused "not a model ID" "$HOME/work/a" run --model= hi
refused "several models given" "$HOME/work/a" run --model openrouter/x/y -m openrouter/x/y:free hi
refused "several models given" "$HOME/sandbox" run --model openrouter/x/y --model=openrouter/x/y hi
refused "not as -mopenrouter/x/y" "$HOME/sandbox" run -mopenrouter/x/y hi
refused "not as -m=openrouter/x/y" "$HOME/sandbox" run -m=openrouter/x/y hi
refused "\-\-model without a value" "$HOME/sandbox" run hi --model
refused "option --model is not known before a folder" "$HOME/sandbox" --model openrouter/x/y run hi
refused "option --dir is not known before a folder" "$HOME/sandbox" --dir "$P/personal/site"
refused "more than one folder" "$HOME/sandbox" "$P/personal/site" "$HOME/work/a"
refused "a folder and the subcommand" "$HOME/sandbox" "$P/personal/site" run hi
refused "starts with ~" "$HOME/sandbox" '~/work/a'
# a switch takes a following true/yes/on/1/y/false/no/off/0/n as its value: never the folder
refused "value of a switch" "$P" --auto true
refused "value of a switch" "$HOME/work/a" -c 1
refused "value of a switch" "$HOME/work/a" --standalone NO
# grouped short options and attached values
refused "not as -cm" "$HOME/work/a" run -cm openrouter/x/y:free hi
refused "not as -cm=openrouter/x/y:free" "$HOME/work/a" run -cm=openrouter/x/y:free hi
refused "not as -cm" "$HOME/work/a" mini -cm openrouter/x/y:free
refused "not as -cs" "$HOME/sandbox" run -cs abc hi
# --wizard builds and runs another command
refused "\-\-wizard builds" "$HOME/sandbox" --wizard
refused "\-\-wizard builds" "$HOME/sandbox" --session --wizard
refused "\-\-wizard builds" "$HOME/sandbox" -s --wizard=x
refused "\-\-wizard builds" "$HOME/sandbox" --prompt --wizard
refused "\-\-wizard builds" "$HOME/sandbox" --server --wizard
refused "\-\-wizard builds" "$HOME/sandbox" run --wizard
refused "\-\-wizard builds" "$HOME/sandbox" mini --wizard=x
refused "\-\-wizard builds" "$HOME/sandbox" models --wizard
# -- ends the options; directly after an option that takes a value it is not clear
refused "\-\- right after --title" "$HOME/work/a" run --title -- -m openrouter/x/y:free
refused "\-\- right after -s" "$HOME/work/a" mini -s -- -m openrouter/x/y:free
# acp, serve and api take folder and model from their client
refused "opencode serve takes folder and model from its client" "$HOME/sandbox" serve
refused "opencode serve takes" "$HOME/sandbox" serve --help
refused "opencode acp takes" "$HOME/sandbox" acp
refused "opencode api takes" "$HOME/sandbox" --auto api GET /session
# service start/restart start the shared background service with the key, whatever service.json says
mv "$S" "$T/secrets.away"                       # refused before secrets.env is read: the message is not about it
refused "opencode service start/restart starts the shared background service" "$HOME/sandbox" service start
refused "opencode service start/restart" "$HOME/sandbox" service restart
refused "opencode service start/restart" "$HOME/sandbox" --auto service status
mv "$T/secrets.away" "$S"
yaml "$A"
ok "nc opencode refuses a free model given as --model ID, --model=ID or -m ID, two models, -mID, -m=ID, -cm, a switch value as folder, --wizard (also as a skipped value), -- after a value option, acp/serve/api/service"

# 16. nc opencode in a free folder: free and paid models run, and the output is OpenCode's alone
runs() {  # runs <folder> <nc opencode arguments…>: stdout and stderr together are exactly what the fake prints
  local dir="$1"; shift
  is "$(cd "$dir" && nc opencode "$@" 2>&1)" "$(printf 'args: %s\nkey: %s\nmarker: 1' "$*" "$SYNTH")" "nc opencode $* in $dir"
}
runs "$P/personal/site" run --model openrouter/x/y:free hi
runs "$P/personal/site" run --model=openrouter/x/y hi
runs "$P/personal/site" --auto mini -m openrouter/x/y#high
runs "$P/personal/site" run hello
runs "$P/personal/site"
runs "$P/personal/site" models --help
runs "$P/personal/site" --auto ./1
runs "$P/personal/site" upgrade -m curl
runs "$P/acme/website" --prompt x "$P/personal/site"
runs "$HOME/sandbox" --session abc ../projects/personal/site --continue
yaml "$B"
runs "$HOME/work/a" run -- explain what -m does
runs "$HOME/work/a" run --title x -- -m openrouter/x/y:free
yaml "$A"
printf 'OPENROUTER_API_KEY_CLIENTS=sk-or-clients-synthetic\nOPENROUTER_API_KEY=%s\n' "$SYNTH" > "$S"   # the clients key never goes to the host
runs "$P/personal/site" run hello
printf 'OPENROUTER_API_KEY=%s\nOPENROUTER_API_KEY_CLIENTS=sk-or-clients-synthetic\n' "$SYNTH" > "$S"
runs "$P/personal/site" run hello
printf 'OPENROUTER_API_KEY=%s\n' "$SYNTH" > "$S"
ok "nc opencode passes free and paid models through in a free folder, with nothing added to the output; with OPENROUTER_API_KEY_CLIENTS before or after, OpenCode gets OPENROUTER_API_KEY"

# 17. nc doctor (direct): placeholders are a warning, a broken models.yaml is a failure
check() {
  bun -e 'const r = await Bun.file(process.argv[1]).json(); const c = r.checks.find((c) => c.name === process.argv[2]);
          console.log(c ? `${c.status} ${c.detail}` : "absent")' "$1" "$2"
}
nc doctor --json > "$T/doc.json" || true
is "$(check "$T/doc.json" models.yaml)" "ok 5 classes, 3 policies ($RC/models.yaml)" "doctor on a good models.yaml"
check "$T/doc.json" models | grep -q "^warn placeholder instead of a model in free, open " || fail "doctor placeholders: $(check "$T/doc.json" models)"
yaml '  - match: "~/projects/acme/**"
    isolation: containers
  - match: "**"'
nc doctor --json > "$T/doc.json" || true
check "$T/doc.json" models.yaml | grep -q '^fail policies\[0\].isolation is "containers"' || fail "doctor on a broken models.yaml: $(check "$T/doc.json" models.yaml)"
bun -e 'const r = await Bun.file(process.argv[1]).json(); process.exit(r.ok ? 1 : 0)' "$T/doc.json" || fail "doctor ok despite a broken models.yaml"
NC_HARNESS_VERSION=0123456789abcdef nc doctor --json > "$T/doc.json" || true
is "$(check "$T/doc.json" models.yaml)" "absent" "isolated doctor"
ok "nc doctor warns about placeholder classes by name and fails on a broken models.yaml (direct only)"

# 18. nc models orchestrator: one line from models.yaml, without policy, folder or NC_PROJECT_PATH
ORCH='claude_code:
  orchestrator: { model: opus, effort: high }'
yaml "$A" && printf '%s\n' "$ORCH" >> "$RC/models.yaml"
expect 0 "" nc models orchestrator
is "$(cat "$T/out")" "opus high" "nc models orchestrator"
[ ! -s "$T/err" ] || fail "orchestrator wrote to stderr: $(cat "$T/err")"
NC_HARNESS_VERSION=0123456789abcdef HOME=/home/agent expect 0 "" nc models orchestrator
is "$(cat "$T/out")" "opus high" "orchestrator in a container without NC_PROJECT_PATH"
mkdir "$T/gone3"
got="$(cd "$T/gone3" && rmdir "$T/gone3" && nc models orchestrator 2> "$T/err")" || fail "orchestrator in a deleted current folder: $(cat "$T/err")"
is "$got" "opus high" "orchestrator in a deleted current folder"
expect 2 "takes no arguments" nc models orchestrator --json
expect 2 "takes no arguments" nc models orchestrator --path "$P/acme"
yaml "$A"
expect 1 "claude_code.orchestrator is not set in models.yaml" nc models orchestrator
[ ! -s "$T/out" ] || fail "orchestrator printed a line without the block"
printf 'claude_code:\n  subagents: {}\n' >> "$RC/models.yaml"
expect 1 "not set" nc models orchestrator
yaml "$A" && printf 'claude_code:\n  orchestrator: { model: sonnet, effort: high }\n' >> "$RC/models.yaml"
expect 2 'claude_code.orchestrator.model is "sonnet", allowed: opus, fable' nc models orchestrator
yaml "$A" && printf 'claude_code:\n  orchestrator: { model: opus }\n' >> "$RC/models.yaml"
expect 2 "claude_code.orchestrator.effort is not set" nc models orchestrator
yaml "$A" && printf 'claude-code:\n  orchestrator: { model: opus, effort: high }\n' >> "$RC/models.yaml"
broken 'unknown key "claude-code" at the top level'
expect 2 'unknown key "claude-code"' nc models orchestrator
yaml "$A" && printf 'claude_code:\n  subagents:\n    nobody: { model: haiku, effort: low }\n' >> "$RC/models.yaml"
broken 'role "nobody" is not in roles'
yaml "$A"
ok "orchestrator: 'opus high' also in a container and a deleted folder; exit 1 without the block; wrong model, missing effort, extra argument, a misspelt top-level block: exit 2 for every nc models call"

# 19. nc doctor: agent files, placeholder, role files without an entry, variables that override models.yaml
yaml "$A"
printf '%s\n' 'claude_code:' '  subagents:' '    planner: { model: opus, effort: high }' '    tester:  { model: haiku, effort: low }' \
  'opencode:' '  subagents:' '    implementer: { variant: high }' '    researcher: {}' >> "$RC/models.yaml"
printf -- '---\nname: extra\ndescription: x\naccess: read\n---\nx\n' > "$RC/roles/extra.md"
nc doctor --json > "$T/doc.json" || true
check "$T/doc.json" agents | grep -q "^fail create ~/.claude/agents/planner.md, .* – nc generate$" || fail "doctor before nc generate: $(check "$T/doc.json" agents)"
expect 0 "" nc generate
[ ! -e "$HOME/.claude/agents/extra.md" ] && [ ! -e "$HOME/.config/opencode/agents/researcher.md" ] || fail "extra or a placeholder role got a file"
nc doctor --json > "$T/doc.json" || true
is "$(check "$T/doc.json" agents)" "ok up to date: ~/.claude/agents (2), ~/.config/opencode/agents (1)" "doctor after nc generate"
check "$T/doc.json" "agents (placeholder)" | grep -q "^warn no OpenCode agent for researcher" || fail "placeholder warning: $(check "$T/doc.json" "agents (placeholder)")"
check "$T/doc.json" "roles without an entry" | grep -q "^warn .*roles/extra.md" || fail "unlisted role file: $(check "$T/doc.json" "roles without an entry")"
is "$(check "$T/doc.json" CLAUDE_CODE_EFFORT_LEVEL)" "absent" "no variable, no warning"
echo "# by hand" >> "$HOME/.claude/agents/tester.md"
nc doctor --json > "$T/doc.json" || true
is "$(check "$T/doc.json" agents)" "fail replace ~/.claude/agents/tester.md – nc generate" "doctor after a change by hand"
expect 0 "" nc generate
CLAUDE_CODE_EFFORT_LEVEL=high nc doctor --json > "$T/doc.json" || true
check "$T/doc.json" CLAUDE_CODE_EFFORT_LEVEL | grep -q "^warn set" || fail "CLAUDE_CODE_EFFORT_LEVEL: $(check "$T/doc.json" CLAUDE_CODE_EFFORT_LEVEL)"
CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 CLAUDE_CODE_SUBAGENT_MODEL=haiku nc doctor --json > "$T/doc.json" || true
check "$T/doc.json" CLAUDE_CODE_SUBAGENT_MODEL_FORCE | grep -q "^warn set" || fail "CLAUDE_CODE_SUBAGENT_MODEL_FORCE"
is "$(check "$T/doc.json" CLAUDE_CODE_SUBAGENT_MODEL)" "absent" "CLAUDE_CODE_SUBAGENT_MODEL alone"
CLAUDE_CODE_SUBAGENT_MODEL_FORCE=False nc doctor --json > "$T/doc.json" || true
is "$(check "$T/doc.json" CLAUDE_CODE_SUBAGENT_MODEL_FORCE)" "absent" "CLAUDE_CODE_SUBAGENT_MODEL_FORCE=False"
rm "$RC/roles/extra.md"
yaml "$A"
ok "nc doctor: agent files missing or changed by hand fail, placeholder and unlisted role files warn, both override variables warn (FORCE=False does not)"

# 20. require and budgets checked strictly, isolation in the output, early refusal
yaml '  - match: "~/projects/acme/**"
    require: foo
  - match: "**"';                                        broken 'policies\[0\].require "foo" is unknown (known: no-training)'
yaml '  - match: "~/projects/acme/**"
    require: [no-training, 1]
  - match: "**"';                                        broken 'policies\[0\].require is neither a text nor a list'
{ sed 's/^isolation: .*/isolation: { clases: [cheap, free] }/' <<<"$CLASSES"; printf 'policies:\n%s\n' "$A"; } > "$RC/models.yaml"
broken 'isolation has an unknown key "clases"'
yaml '  - match: "~/projects/acme/**"
    require: [no-training]
  - match: "**"'
is "$(field r.policy.require --path "$P/acme/website")" '["no-training"]' "require as a list"
for b in '{ per_day_usd: 5 }' '{ per_task_usd: 1, per_day_usd: 5 }'; do
  { sed "s/^budgets: .*/budgets: $b/" <<<"$CLASSES"; printf 'policies:\n%s\n' "$A"; } > "$RC/models.yaml"
  broken 'budgets has an unknown key "per_day_usd"'
done
for b in '{ per_task_usd: -1 }' '{ per_task_usd: 0 }' '{ per_task_usd: "1" }' '{ per_task_usd: .nan }' '{ per_task_usd: .inf }'; do
  { sed "s/^budgets: .*/budgets: $b/" <<<"$CLASSES"; printf 'policies:\n%s\n' "$A"; } > "$RC/models.yaml"
  broken "budgets.per_task_usd is .*, expected a number greater than 0"
done
{ sed "s/^budgets: .*/budgets: { per_tsk_usd: 1 }/" <<<"$CLASSES"; printf 'policies:\n%s\n' "$A"; } > "$RC/models.yaml"
broken 'budgets has an unknown key "per_tsk_usd"'
{ sed "s/^budgets: .*/budgets: [1]/" <<<"$CLASSES"; printf 'policies:\n%s\n' "$A"; } > "$RC/models.yaml"
broken "budgets missing or not a mapping"
{ sed "/^budgets: .*/d" <<<"$CLASSES"; printf 'policies:\n%s\n' "$A"; } > "$RC/models.yaml"
is "$(field r.budgets --path "$P/personal/site")" '{}' "no budgets"
yaml "$A"
expect 0 "" nc models resolve --role tester --path "$P/acme/website" --json
grep -q '"isolation":"container"' "$T/out" && grep -q '"require":\["no-training"\]' "$T/out" || fail "resolve --json in Acme: $(cat "$T/out")"
is "$(nc models resolve --class cheap --json --path "$P/personal/site")" '{"class":"cheap","role":null,"runtime":"opencode","model":"openrouter/acme/small-1","isolation":"container","require":[]}' "cheap in ** (isolation.classes)"
is "$(nc models resolve --class standard --json --path "$P/personal/site")" '{"class":"standard","role":null,"runtime":"opencode","model":"openrouter/acme/big-1","isolation":null,"require":[]}' "standard in **"
expect 1 "denies the class free" nc models resolve --class free --path "$P/acme/website"
expect 1 "not approved" nc models check --model openrouter/anthropic/claude-whatever --path "$P/acme/website"
expect 0 "" nc models check --model "openrouter/acme/big-1#high" --path "$P/acme/website"
for id in openrouter/anthropic/claude-whatever openrouter/x/y:nitro "openrouter/x/y#high" openrouter/acme/big-1:nitro; do
  expect 0 "" nc models check --model "$id" --path "$P/personal/site"
done
# a policy with require only (no deny_classes): every model but the exact class models is refused
yaml '  - match: "~/projects/acme/**"
    require: no-training
  - match: "**"'
for id in openrouter/x/y openrouter/cohere/x:free openrouter/openrouter/auto openrouter/ACME/big-1 openrouter/acme/big-1:nitro; do
  expect 1 "not approved" nc models check --model "$id" --path "$P/acme/website"
done
expect 0 "" nc models check --model "openrouter/acme/small-1#low" --path "$P/acme/website"
is "$(field r.classes.cheap.allowed --path "$P/acme/website")" true "class model under a require-only policy"
yaml "$A"
# nc generate with the public models.yaml: the class models (with variants) of the agents in a client task are the
# ones of a free folder
cp "$REPO/models.yaml" "$RC/models.yaml"
mkdir -p "$P/clients/globex"
expect 0 "" nc generate --out "$T/gen-acme" --path "$P/clients/globex"
expect 0 "" nc generate --out "$T/gen-site" --path "$P/personal/site"
for f in implementer tester; do
  cmp -s "$T/gen-acme/opencode/$f.md" "$T/gen-site/opencode/$f.md" || fail "nc generate: $f.md differs between a client and a free folder"
done
grep -q "^model: openrouter/openai/gpt-6.1-terra#high$" "$T/gen-acme/opencode/implementer.md" || fail "implementer model: $(grep model "$T/gen-acme/opencode/implementer.md")"
grep -q "^model: openrouter/z-ai/glm-5.3-flash#low$" "$T/gen-acme/opencode/tester.md" || fail "tester model: $(grep model "$T/gen-acme/opencode/tester.md")"
[ ! -e "$T/gen-acme/opencode/researcher.md" ] && [ -e "$T/gen-site/opencode/researcher.md" ] || fail "researcher: free denied in the client folder only"
rm -r "$P/clients"; yaml "$A"
ok "require (text or list, only no-training), budgets (only per_task_usd > 0), isolation in --json and resolve, exact class models where free is denied or require is set, nc generate unchanged"

# 21. opencode.subagents.<role>.steps (whole number 1-500, optional) and the removed opencode.orchestrator: exit 2 for nc models
sa() { yaml "$A" && printf 'opencode:\n  subagents:\n    tester: %s\n' "$1" >> "$RC/models.yaml"; }
sa '{ steps: 1 }';                    expect 0 "" nc models
sa '{ variant: low, steps: 500 }';    expect 0 "" nc models
sa '{}';                              expect 0 "" nc models          # steps is optional
sa '{ steps: 0 }';                    broken "opencode.subagents.tester.steps is 0, expected a whole number from 1 to 500"
sa '{ steps: 501 }';                  broken "opencode.subagents.tester.steps is 501"
sa '{ steps: -3 }';                   broken "opencode.subagents.tester.steps is -3"
sa '{ steps: 2.5 }';                  broken "opencode.subagents.tester.steps is 2.5"
sa '{ steps: "60" }';                 broken 'opencode.subagents.tester.steps is "60"'
sa '{ steps: null }';                 broken "opencode.subagents.tester.steps is null"
sa '{ step: 5 }';                     broken 'opencode.subagents.tester has an unknown key "step"'
yaml "$A" && printf 'opencode:\n  orchestrator: { class: standard, overlay: openai }\n' >> "$RC/models.yaml"
broken 'opencode has an unknown key "orchestrator"'
yaml "$A" && printf 'opencode:\n  subagents: {}\n  orchestrator: {}\n' >> "$RC/models.yaml"
broken 'opencode has an unknown key "orchestrator"'
yaml "$A"
cp "$REPO/models.yaml" "$RC/models.yaml"
expect 0 "" nc generate --out "$T/gen-steps" --path "$P/personal/site"
is "$(grep '^steps:' "$T/gen-steps/opencode/implementer.md")" "steps: 150" "real models.yaml: implementer steps"
is "$(grep '^steps:' "$T/gen-steps/opencode/tester.md")" "steps: 100" "real models.yaml: tester steps"
yaml "$A"
ok "opencode steps: whole number 1-500 valid, optional; 0, 501, negative, fraction, text, null, unknown key: exit 2; opencode.orchestrator is an unknown key (exit 2); the real models.yaml sets implementer 150 and tester 100"

# 22. ~/.nc/overlay: on the host its models.yaml wins; a broken overlay fails closed (exit 2, doctor fail);
#     no variable redirects it, and a task container never reads it
OV="$HOME/.nc/overlay"
yaml "$A"
is "$(field r.file --path "$P/personal/site")" "\"$RC/models.yaml\"" "file without an overlay"
nc doctor --json > "$T/doc.json" || true
is "$(check "$T/doc.json" overlay)" "ok none – public defaults" "doctor without an overlay"
mkdir -p "$OV"
echo "own rules" > "$OV/AGENTS.md"
expect 2 "overlay/models.yaml missing or not readable (ENOENT) – an overlay needs its own models.yaml" nc models --path "$P/personal/site"
expect 2 "an overlay needs its own models.yaml" nc models check --model openrouter/acme/big-1 --path "$P/personal/site"
nc doctor --json > "$T/doc.json" || true
check "$T/doc.json" overlay | grep -q "^fail broken – .*an overlay needs its own models.yaml" || fail "doctor, overlay without models.yaml: $(check "$T/doc.json" overlay)"
printf '%s\npolicies:\n  - match: "**"\n    deny_classes: [cheap]\n' "$CLASSES" > "$OV/models.yaml"
is "$(field r.file --path "$P/personal/site")" "\"$OV/models.yaml\"" "file with an overlay"
is "$(field r.policy.deny_classes --path "$P/personal/site")" '["cheap"]' "policy from the overlay"
nc models --path "$P/personal/site" | grep -qx "policy file: $OV/models.yaml" || fail "nc models does not name the overlay file"
nc doctor --json > "$T/doc.json" || true
is "$(check "$T/doc.json" overlay)" "ok ~/.nc/overlay: AGENTS.md, models.yaml" "doctor with an overlay"
is "$(check "$T/doc.json" models.yaml)" "ok 5 classes, 1 policies ($OV/models.yaml)" "doctor names the overlay file"
mkdir -p "$T/nch/overlay" "$T/elsewhere"
printf '%s\npolicies:\n  - match: "**"\n' "$CLASSES" | tee "$T/nch/overlay/models.yaml" > "$T/elsewhere/models.yaml"
is "$(NC_HOME="$T/nch" NC_OVERLAY="$T/elsewhere" field r.file --path "$P/personal/site")" "\"$OV/models.yaml\"" "NC_HOME/NC_OVERLAY do not redirect"
is "$(NC_HARNESS_VERSION=0123456789abcdef NC_PROJECT_PATH=personal/site field r.file)" "\"$RC/models.yaml\"" "isolated mode ignores the overlay"
mv "$OV/models.yaml" "$T/ov-models.yaml" && mkdir "$OV/models.yaml"
expect 2 "overlay/models.yaml is not a regular file" nc models --path "$P/personal/site"
rm -rf "$OV" && touch "$OV"
expect 2 "overlay/models.yaml missing or not readable (ENOTDIR)" nc models --path "$P/personal/site"
rm "$OV" && ln -s "$T/gone" "$OV"
expect 2 "overlay/models.yaml missing or not readable (ENOENT)" nc models --path "$P/personal/site"
expect 2 "an overlay needs its own models.yaml" nc generate --check
nc doctor --json > "$T/doc.json" || true
check "$T/doc.json" overlay | grep -q "^fail broken – " || fail "doctor, dangling overlay link: $(check "$T/doc.json" overlay)"
bun -e 'const r = await Bun.file(process.argv[1]).json(); process.exit(r.ok ? 1 : 0)' "$T/doc.json" || fail "doctor ok despite a dangling overlay"
rm "$OV"
ok "overlay: none reads the repo file; with models.yaml the overlay file (nc models, doctor); without models.yaml, as a folder named models.yaml, as a file or a dangling link: exit 2 and doctor fail; NC_HOME/NC_OVERLAY and isolated mode ignore it"

echo "$pass tests passed"
