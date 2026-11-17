#!/usr/bin/env bash
# Tests for nc delegate (host side, broker path and container client). No network, no keys, no Docker, no herdr: nc-work and hc
# are fakes on PATH that log their argv; the fake `nc-work export` builds repo.git, export.json and RESULT.raw
# from a fixture worker repo. Runs against a copy of the repo with its own models.yaml, throwaway $HOME.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUN_DIR="$(dirname "$(mise which bun 2>/dev/null || command -v bun)")"
# Server tests: the lock, the deadline and the runner's own session need util-linux and coreutils.
for b in flock timeout setsid; do
  command -v "$b" > /dev/null || { echo "skipped: needs flock, timeout, setsid (server test)"; exit 0; }
done
unset NC_HOME NC_MACHINE NC_HARNESS_VERSION NC_PROJECT_PATH NC_OPENCODE OPENROUTER_API_KEY XDG_CONFIG_HOME OPENCODE_CONFIG_DIR \
  NC_MEMORY_DIR NC_MEMORY_OUTBOX NC_DELEGATE_LOCKED GH_TOKEN GITHUB_TOKEN || true
export BUN_RUNTIME_TRANSPILER_CACHE_PATH=0
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@invalid
export GIT_CONFIG_NOSYSTEM=1

T="$(mktemp -d)"
T="$(cd "$T" && pwd -P)"
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir "$T/cwd" && cd "$T/cwd"
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig"
mkdir -p "$HOME" "$T/bin"
git config --global init.defaultBranch main
# PATH without the real nc-work and hc; the fakes come first.
ALL_PATH="$BUN_DIR:$PATH"
BASE_PATH="$(IFS=:; for d in $ALL_PATH; do [ -x "$d/nc-work" ] || [ -x "$d/hc" ] || printf '%s:' "$d"; done)"
export PATH="$T/bin:${BASE_PATH%:}"
command -v python3 > /dev/null || { echo "FAIL: python3 missing" >&2; exit 1; }
# Never the real ones: a real hc would open a terminal in herdr.
(PATH="${BASE_PATH%:}"; ! command -v hc && ! command -v nc-work) > /dev/null || { echo "FAIL: real hc or nc-work on the test PATH" >&2; exit 1; }

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok   $*"; pass=$((pass + 1)); }
RC="$T/repo"
cp -a "$REPO" "$RC" && rm -rf "$RC/.git"
nc()   { "$RC/bin/nc" "$@"; }
expect() {  # expect <exit code> <pattern on stderr, or ''> <command…>; stdout in $T/out, stderr in $T/err
  local want="$1" pat="$2" code=0; shift 2
  "$@" > "$T/out" 2> "$T/err" || code=$?
  [ "$code" = "$want" ] || fail "exit $code, expected $want: $* – $(cat "$T/err")"
  [ -z "$pat" ] || grep -q -- "$pat" "$T/err" || fail "$*: expected '$pat' on stderr, got: $(cat "$T/err")"
}
js() {  # js <expression on r> <json>: one value from a JSON text
  bun -e 'const r = JSON.parse(process.argv[1]); const v = eval(process.argv[2]); console.log(typeof v === "string" ? v : JSON.stringify(v))' "$2" "$1"
}
is() { [ "$1" = "$2" ] || fail "$3: got '$1', expected '$2'"; }
calls() { grep -c -- "$1" "$T/calls.log" || true; }

cat > "$RC/models.yaml" <<'EOF'
classes:
  frontier: { runtime: claude-code }
  standard: { runtime: opencode, model: "openrouter/acme/big-1" }
  cheap:    { runtime: opencode, model: "openrouter/acme/small-1" }
  free:     { runtime: opencode, model: "openrouter/acme/tiny:free" }
roles: { planner: frontier, implementer: standard, tester: cheap, researcher: free, scout: frontier }
isolation: { classes: [cheap, free] }
budgets: { per_task_usd: 0.03 }
policies:
  - match: "~/projects/agency/clients/**"
    deny_classes: [free]
    isolation: container
  - match: "~/projects/acme/**"
    deny_classes: [free]
    isolation: container
  - match: "**"
    deny_classes: []
EOF

# Fixture checkouts: three profiles, a folder without profile, an embedded repo inside a profile.
P="$HOME/projects"
SITE="$P/personal/site"
for d in "$SITE" "$P/acme/website" "$P/agency/clients/globex" "$HOME/sandbox/loose"; do
  mkdir -p "$d" && git -C "$d" init -q && echo hi > "$d/README.md" && git -C "$d" add -A && git -C "$d" commit -qm init
done
mkdir -p "$SITE/sub" && git -C "$SITE/sub" init -q && echo sub/ >> "$SITE/.git/info/exclude"
printf '[{"id":"acme","path":"agency/clients/globex","github":"x/acme"},{"id":"site","path":"personal/site","github":"x/site"},{"id":"acme-website","path":"acme/website","github":"example/acme-website"}]\n' > "$T/profiles.json"
git clone -q "$SITE" "$T/worker"   # what the worker commits; the fake export takes its HEAD as the task branch
BASE="$(git -C "$SITE" rev-parse HEAD)"
TOK=0123456789abcdef0123456789abcdef
export FAKE_T="$T" FAKE_BASE="$BASE" FAKE_TOKEN="$TOK"

cat > "$T/bin/nc-work" <<'EOF'
#!/usr/bin/env bash
# Fake nc-work: logs argv, behaviour from files in $FAKE_T.
set -euo pipefail
printf '%s\n' "nc-work $*" >> "$FAKE_T/calls.log"
rcfile() { [ -f "$FAKE_T/$1" ] && cat "$FAKE_T/$1" || echo "${2:-0}"; }
case "$1" in
  profiles) cat "$FAKE_T/profiles.json" ;;
  create)
    rc="$(rcfile create_rc)"
    [ "$rc" != 3 ] || echo "nc-work: 3 tasks are already running; stop one first (nc-work stop <task>)" >&2
    [ "$rc" != 4 ] || echo "nc-work: the requesting task has uncommitted changes – commit first" >&2
    [ "$rc" = 0 ] || exit "$rc"
    if [ "${5:-}" = --from-task ]; then  # the record on stdout, as nc-work prints it
      printf 'Cloning into /workspace...\n{\n  "id": "%s",\n  "worker": true,\n  "from_task": "%s",\n  "from_token": "%s",\n  "base": "%s"\n}\n' \
        "$3" "$(rcfile from_task "$6")" "$(rcfile from_token "$FAKE_TOKEN")" "$(rcfile create_base "$FAKE_BASE")"
    fi ;;
  status) [ ! -f "$FAKE_T/status_record" ] || printf '{\n  "id": "%s",\n  "status": "failed"\n}\n' "$2"; exit "$(rcfile status_rc 1)" ;;
  stop)  # what a broker run's delivery/ and run folder held when the worker was stopped
    d="$HOME/.nc/delegate/$2"
    if [ -d "$d/delivery" ]; then (cd "$d/delivery" && LC_ALL=C ls | tr '\n' ' ') > "$FAKE_T/stop_saw_$2"; fi
    [ ! -e "$d/result.json" ] || echo result.json >> "$FAKE_T/stop_saw_$2"
    exit 0 ;;
  remove) rc="$(rcfile remove_rc)"; [ "$rc" = 0 ] || echo "nc-work: $2: not deleted – uncommitted changes. Use --force to delete anyway (discards everything)" >&2; exit "$rc" ;;
  opencode)  # prints $FAKE_T/events as OpenCode's JSON events would come
    printf '%s\0' "$@" > "$FAKE_T/opencode.argv"; [ ! -f "$FAKE_T/events" ] || cat "$FAKE_T/events"
    # exec: TERM from timeout reaches the sleeping process itself, as the real nc-work ends its docker exec
    [ ! -f "$FAKE_T/orphan" ] || { sleep 300 & }   # a process that keeps the pipe open after nc-work ends
    [ ! -f "$FAKE_T/orphan_sleep" ] || { sleep "$(cat "$FAKE_T/orphan_sleep")" & }   # the same, for a few seconds
    [ ! -f "$FAKE_T/opencode_sleep" ] || exec sleep "$(cat "$FAKE_T/opencode_sleep")"; exit "$(rcfile opencode_rc)" ;;
  export)
    id="$2" out="$4"
    [ -f "$FAKE_T/export_sleep" ] && sleep "$(cat "$FAKE_T/export_sleep")"
    rc="$(rcfile export_rc)"; [ "$rc" = 0 ] || { echo "nc-work: task $2 is not running – export does not start it" >&2; exit "$rc"; }
    mkdir -m 700 "$out"
    git init -q --bare "$out/repo.git"
    git -C "$out/repo.git" fetch -q "$FAKE_T/worker" "HEAD:refs/heads/nc-work/$id"
    head="$(git -C "$out/repo.git" rev-parse "refs/heads/nc-work/$id")"
    [ ! -f "$FAKE_T/export_head" ] || head="$(cat "$FAKE_T/export_head")"
    rf=missing
    if [ -f "$FAKE_T/result.raw" ]; then cp "$FAKE_T/result.raw" "$out/RESULT.raw"; rf="$(rcfile result_file present)"; fi
    printf '{"task":"%s","branch":"nc-work/%s","base":"%s","head":"%s","commits":1,"dirty":false,"base_is_ancestor":true,"result_file":"%s"}\n' \
      "$id" "$id" "$FAKE_BASE" "$head" "$rf" | tee "$out/export.json" ;;
  *) echo "fake nc-work: unknown $1" >&2; exit 2 ;;
esac
EOF
cat > "$T/bin/hc" <<'EOF'
#!/usr/bin/env bash
# Fake hc: logs argv; with $FAKE_T/hc_run it runs the worker command right away (bash -c, not -lc: a login
# shell would reset PATH and lose the fakes).
printf '%s\n' "hc $*" >> "$FAKE_T/calls.log"
[ -f "$FAKE_T/hc_rc" ] && { echo '{"error":{"kind":"name_taken"}}'; exit "$(cat "$FAKE_T/hc_rc")"; }
[ -f "$FAKE_T/hc_run" ] && bash -c "${@: -1}" > "$FAKE_T/worker.log" 2>&1
echo '{"address":"t2k","state":"live"}'
EOF
chmod +x "$T/bin/nc-work" "$T/bin/hc"
: > "$T/calls.log"
D="$HOME/.nc/delegate"
nothing_created() {
  [ ! -d "$D" ] || [ -z "$(ls -A "$D")" ] || fail "$1: a run folder was created"
  [ "$(calls 'nc-work create')" = 0 ] || fail "$1: nc-work create was called"
  [ "$(calls '^hc ')" = 0 ] || fail "$1: hc was called"
}

# 1. refusals before anything is created
cd "$SITE"
expect 2 "no mailbox (workers do not delegate further" env NC_HARNESS_VERSION=abc "$RC/bin/nc" delegate --role tester --task x
expect 1 "researcher blocked as a worker (for good): it cannot write RESULT.md – for research use the native subagent researcher or OpenCode in your own session" nc delegate --role researcher --task x
expect 1 "only implementer, tester;" nc delegate --role planner --task x
expect 1 "only implementer" nc delegate --role scout --task x
expect 1 "only implementer" nc delegate --role nobody --task x
expect 1 "researcher blocked as a worker" nc delegate --role researcher --task x --repo "$P/acme/website"
expect 1 "nc models check" nc delegate --role implementer --task x --repo "$P/agency/clients/globex" --model openrouter/acme/tiny:free
expect 1 "$HOME/sandbox/loose lies in no nc-work profile – workers only for repos in an nc-work profile" nc delegate --role tester --task x --repo "$HOME/sandbox/loose"
cp "$RC/models.yaml" "$T/models.yaml.ok" && echo 'classes: [' > "$RC/models.yaml"
expect 2 "nc models resolve" nc delegate --role tester --task x
cp "$T/models.yaml.ok" "$RC/models.yaml"
expect 1 "an embedded repo" nc delegate --role tester --task x --repo "$SITE/sub"
echo dirty > "$SITE/new.txt"
expect 1 "has local changes" nc delegate --role tester --task x
rm "$SITE/new.txt"
expect 2 "whole minutes" nc delegate --role tester --task x --timeout 0
expect 2 "whole minutes" nc delegate --role tester --task x --timeout 21
expect 2 "whole minutes" nc delegate --role tester --task x --timeout 1.5
expect 2 "at most 20480" nc delegate --role tester --task "$(head -c 20481 /dev/zero | tr '\0' a)"
expect 2 "missing or empty" nc delegate --role tester --task "  "
expect 2 "exclude each other" nc delegate --role tester --task x --wait --bg
for bad in ../x 'd1115-1432-ab12;rm' D1115-1432-AB12 d1115-1432-ab1 ''; do
  expect 2 "invalid ID" nc delegate --result "$bad"
  expect 2 "invalid ID" nc delegate --cleanup "$bad"
done
expect 2 "no run" nc delegate --result d1115-1432-ab12
expect 2 "only --wait" nc delegate --result d1115-1432-ab12 --bg
expect 1 "nc-work not found – no container, no worker; workers exist only on the server" env PATH="${BASE_PATH%:}" "$RC/bin/nc" delegate --role implementer --task x
expect 1 "class cheap in $SITE only in a container (isolation) – without nc-work no worker" env PATH="${BASE_PATH%:}" "$RC/bin/nc" delegate --role tester --task x
mv "$T/bin/hc" "$T/hc.off"
expect 2 "hc not found" nc delegate --role tester --task x
mv "$T/hc.off" "$T/bin/hc"
nothing_created "refusals"
echo 3 > "$T/create_rc"
expect 1 "3 tasks running – nc delegate stops none (nc-work: 3 tasks are already running; stop one first (nc-work stop <task>))" nc delegate --role tester --task x
[ -z "$(ls -A "$D")" ] || fail "run folder left after the 3-tasks refusal"
[ "$(calls 'nc-work stop')" = 0 ] || fail "something was stopped"
echo 1 > "$T/create_rc"; echo 0 > "$T/status_rc"
expect 2 "nc-work remove d[0-9-]*[0-9a-f]* --force" nc delegate --role tester --task x
rm "$T/status_rc"; touch "$T/status_record"   # failed record whose proxy never started: status prints it, exits 1
expect 2 "nc-work remove d[0-9-]*[0-9a-f]* --force" nc delegate --role tester --task x
rm "$T/status_record"
expect 2 "nc-work create" nc delegate --role tester --task x
grep -q "nc-work remove" "$T/err" && fail "remove hint without a record left"
rm "$T/create_rc"
[ -z "$(ls -A "$D")" ] || fail "run folder left after a failed create"
[ "$(calls '^hc ')" = 0 ] || fail "hc called after a failed create"
ok "refusals (roles incl. researcher, policy, --model, profile, embedded repo, dirty, 3 tasks, container, timeout, task size, IDs, tools) create nothing"

# 2. --bg: create, hc in the fixed form, request.json, prompt.md; no task text on hc's command line
: > "$T/calls.log"
start() {  # start [nc delegate options…]: --bg run in SITE, sets ID and JSON
  JSON="$(nc delegate --role tester --task "SECRET-TASK-TEXT do it" --bg "$@")" || fail "--bg failed: $*"
  ID="$(js r.task_id "$JSON")"
  [[ "$ID" =~ ^d[0-9]{4}-[0-9]{4}-[0-9a-f]{4}$ ]] || fail "bad id $ID"
}
start
is "$(js r.status "$JSON")" running "--bg status"
is "$(js r.model "$JSON")" openrouter/acme/small-1 "--bg model"
is "$(js r.ref "$JSON")" "refs/nc-delegate/$ID" "--bg ref"
is "$(js r.base "$JSON")" "$BASE" "--bg base"
grep -qx "nc-work create site $ID --worker" "$T/calls.log" || fail "create call: $(cat "$T/calls.log")"
grep -qxF "hc run --bg --no-notify --outlive-parent --name $ID -- bash -lc '$RC/cli/delegate-run.sh' $ID" "$T/calls.log" || fail "hc call: $(cat "$T/calls.log")"
! grep -q SECRET-TASK-TEXT "$T/calls.log" || fail "task text on a command line"
is "$(stat -c %a "$D/$ID")" 700 "run folder mode"
head -c 2 "$D/$ID/prompt.md" | grep -q '^# ' || fail "prompt.md does not start with the contract"
grep -q "STATUS: waiting_on" "$D/$ID/prompt.md" && grep -q "SECRET-TASK-TEXT" "$D/$ID/prompt.md" || fail "prompt.md content"
is "$(js r.timeout_min "$(cat "$D/$ID/request.json")")" 20 "default timeout"
is "$(js r.checkout "$(cat "$D/$ID/request.json")")" "$SITE" "checkout"
ok "--bg creates the worker task, starts hc in the fixed form without task text, writes request.json and prompt.md"

# 3. --result while running: no export; --cleanup without ref refused
expect 0 "" nc delegate --result "$ID"
is "$(js r.status "$(cat "$T/out")")" running "--result running"
[ "$(calls 'nc-work export')" = 0 ] || fail "export while running"
expect 1 "nc delegate --result $ID first" nc delegate --cleanup "$ID"
[ "$(calls 'nc-work remove')" = 0 ] || fail "remove without ref"
ok "--result without status.json says running without export; --cleanup without ref refuses"

# 4. a finished worker: fetch into refs/nc-delegate only, cleaned RESULT.md, same JSON twice, export once
echo work > "$T/worker/work.txt" && git -C "$T/worker" add -A && git -C "$T/worker" commit -qm "worker commit"
WHEAD="$(git -C "$T/worker" rev-parse HEAD)"
printf 'STATUS: done\nesc \033[31mred\033[0m bell\a bidi \xe2\x80\xaeevil\xe2\x80\xac zw\xe2\x80\x8bsp bad \xff byte csi \xc2\x9b31m\r\nend\tok\n' > "$T/result.raw"
printf '{"exit": 0, "ended": "%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$D/$ID/status.json"
branches="$(git -C "$SITE" for-each-ref refs/heads refs/tags)"
expect 0 "" nc delegate --result "$ID"
R1="$(cat "$T/out")"
expect 0 "" nc delegate --result "$ID" --wait
[ "$(cat "$T/out")" = "$R1" ] || fail "second --result differs"
[ "$(calls "nc-work export $ID --out $D/$ID/export")" = 1 ] || fail "export not exactly once: $(cat "$T/calls.log")"
[ "$(wc -l <<<"$R1")" = 1 ] || fail "JSON not one line"
is "$(js r.status "$R1")" done "status ($R1)"
is "$(js r.head "$R1")" "$WHEAD" "head"
is "$(js r.result "$R1")" "$D/$ID/RESULT.md" "result path"
is "$(js 'Object.keys(r).join(",")' "$R1")" "task_id,role,runtime,model,status,waiting_on,branch,ref,base,head,result,diff_stat,duration_s,cost_usd,over_budget,reason" "JSON keys"
is "$(js r.runtime "$R1")" opencode "runtime"
is "$(js '[r.cost_usd, r.over_budget]' "$R1")" "[null,null]" "cost_usd and over_budget without events.jsonl"
is "$(js r.branch "$R1")" "nc-work/$ID" "branch"
js r.diff_stat "$R1" | grep -q "work.txt | 1 +" || fail "diff_stat: $(js r.diff_stat "$R1")"
is "$(git -C "$SITE" rev-parse "refs/nc-delegate/$ID")" "$WHEAD" "ref in checkout"
is "$(git -C "$SITE" for-each-ref refs/heads refs/tags)" "$branches" "branches or tags changed"
is "$(git -C "$SITE" rev-parse HEAD)" "$BASE" "HEAD moved"
[ -z "$(git -C "$SITE" status --porcelain)" ] && [ ! -e "$SITE/work.txt" ] || fail "working tree changed"
grep -nE "nc-work export|nc-work stop" "$T/calls.log" | tail -1 | grep -q "nc-work stop $ID" || fail "stop not after export"
ok "--result fetches only refs/nc-delegate/<id>, leaves branches and working tree alone, stops after export, same JSON twice, export once"

# 5. cleaning of RESULT.md
M="$D/$ID/RESULT.md"
LC_ALL=C grep -q $'[\x01-\x08\x0b-\x1f\x7f]' "$M" && fail "control characters left in RESULT.md"
grep -qE $'\xe2\x80\xae|\xe2\x80\xac|\xe2\x80\x8b' "$M" && fail "bidi or zero-width left in RESULT.md"
python3 -I -c 'import sys; open(sys.argv[1], "rb").read().decode("utf-8")' "$M" || fail "RESULT.md is not UTF-8"
python3 -I -c 'import sys; t = open(sys.argv[1], encoding="utf-8").read(); sys.exit(any(0x80 <= ord(c) <= 0x9f for c in t))' "$M" || fail "C1 control characters left in RESULT.md"
grep -q $'bad \xef\xbf\xbd byte' "$M" || fail "invalid byte not replaced by U+FFFD: $(cat -v "$M")"
grep -q $'^end\tok$' "$M" && grep -q "esc \[31mred\[0m bell bidi evil zwsp" "$M" || fail "cleaned text: $(cat -v "$M")"
is "$(stat -c %a "$M")" 600 "RESULT.md mode"
start
head -c $((70 * 1024)) /dev/zero | tr '\0' x | sed '1s/^/STATUS: done\n/' > "$T/result.raw"
printf '{"exit": 0, "ended": "x"}\n' > "$D/$ID/status.json"
expect 0 "" nc delegate --result "$ID"
is "$(js r.status "$(cat "$T/out")")" done "70 KiB status"
[ "$(stat -c %s "$D/$ID/RESULT.md")" -le 65536 ] || fail "RESULT.md larger than 64 KiB"
tail -n 1 "$D/$ID/RESULT.md" | grep -q "cut – RESULT.md was longer than 64 KiB" || fail "no truncation note"
start
printf 'STATUS: done\n\xc3' > "$T/result.raw"; echo truncated > "$T/result_file"
printf '{"exit": 0, "ended": "x"}\n' > "$D/$ID/status.json"
expect 0 "" nc delegate --result "$ID"
grep -q $'\xef\xbf\xbd' "$D/$ID/RESULT.md" && fail "cut character shown as U+FFFD"
grep -q "cut – RESULT.md was longer than 64 KiB" "$D/$ID/RESULT.md" || fail "no note for an export that was cut"
rm "$T/result_file"
ok "RESULT.md: control (C0, C1), bidi and invisible characters removed, invalid bytes as U+FFFD, 70 KiB cut to 64 KiB with a note"

# 6. status rules
status_case() {  # status_case <exit> <RESULT.raw content or -> <expected status> [expected waiting_on]
  start
  if [ "$2" = - ]; then rm -f "$T/result.raw"; else printf '%b' "$2" > "$T/result.raw"; fi
  printf '{"exit": %s, "ended": "2026-11-15T10:00:00Z"}\n' "$1" > "$D/$ID/status.json"
  expect 0 "" nc delegate --result "$ID"
  is "$(js r.status "$(cat "$T/out")")" "$3" "status for exit $1, '$2'"
  [ -z "${4:-}" ] || is "$(js r.waiting_on "$(cat "$T/out")")" "$4" "waiting_on"
}
status_case 124 'STATUS: done\n' timeout
status_case 137 'STATUS: done\n' timeout
status_case 1 'STATUS: done\n' failed
is "$(js r.reason "$(cat "$T/out")")" "worker ended with exit 1" "failed reason"
status_case 0 'STATUS: done; rm -rf /\n' failed
is "$(js r.reason "$(cat "$T/out")")" "RESULT.md missing or without a valid status line" "invalid line reason"
status_case 0 - failed
is "$(js r.result "$(cat "$T/out")")" null "result without RESULT.md"
status_case 0 ' STATUS: done\n' failed
status_case 0 'status: done\n' failed
status_case 0 'STATUS: cannot_complete\r\nbecause\n' cannot_complete
status_case 0 'STATUS: requires_user_auth\n' requires_user_auth
status_case 0 'STATUS: waiting_on d1115-1432-ab12\n' waiting_on d1115-1432-ab12
status_case 0 'STATUS: waiting_on ../x\n' failed
status_case 0 'STATUS: waiting_on d1115-1432-ab12 \n' failed
status_case 0 '\xef\xbb\xbfSTATUS: done\n' failed
echo error > "$T/result_file"
status_case 0 'STATUS: done\n' failed
is "$(js r.reason "$(cat "$T/out")")" "RESULT.md not readable" "reason for result_file error"
rm "$T/result_file"
ok "status by rules: 124/137 timeout, exit != 0 failed, only an exact first line counts, waiting_on with a valid ID"

# 7. deadline without status.json: timeout, export, then stop; export failure writes nothing and can be retried
start --timeout 1
python3 -I -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r["started"]="2026-01-01T00:00:00.000Z"; json.dump(r, open(p,"w"))' "$D/$ID/request.json"
printf 'STATUS: done\n' > "$T/result.raw"
echo 1 > "$T/export_rc"
expect 2 "is not running – export does not start it" nc delegate --result "$ID" --wait
[ ! -e "$D/$ID/result.json" ] || fail "result.json written after a failed export"
rm "$T/export_rc"
expect 0 "" nc delegate --result "$ID" --wait
is "$(js r.status "$(cat "$T/out")")" timeout "deadline status"
js r.reason "$(cat "$T/out")" | grep -q "nc-work stop" || fail "deadline reason"
grep -nE "nc-work export $ID|nc-work stop $ID" "$T/calls.log" | tail -1 | grep -q "stop" || fail "no stop after the deadline"
ok "past the deadline without status.json: timeout, fetched, stopped; a failed export writes nothing and --result retries"

# 7b. export there, next step fails (head mismatch): exit 2, nothing written, export/ stays; the retry replaces it
start
printf 'STATUS: done\n' > "$T/result.raw"
printf '{"exit": 0, "ended": "x"}\n' > "$D/$ID/status.json"
printf '%040d\n' 0 > "$T/export_head"
expect 2 "does not point to" nc delegate --result "$ID"
[ ! -e "$D/$ID/result.json" ] || fail "result.json written after a failed fetch"
[ -d "$D/$ID/export" ] || fail "export/ not left by the failed attempt"
rm "$T/export_head"
expect 0 "" nc delegate --result "$ID"
is "$(js r.status "$(cat "$T/out")")" done "retry after a stale export/"
ok "a failed step after the export writes nothing; the retry removes the stale export/ and succeeds"

# 7c. diff_stat: file names from the worker cleaned, at most 50 lines
git config --global core.quotePath false
mkdir -p "$T/worker/many"
for i in $(seq 1 60); do echo "$i" > "$T/worker/many/f$i.txt"; done
echo x > "$T/worker/"$'bidi\xe2\x80\xaeevil.txt'
echo x > "$T/worker/"$'c1\xc2\x9bname.txt'
echo x > "$T/worker/"$'esc\033[31m.txt'
git -C "$T/worker" add -A && git -C "$T/worker" commit -qm "many files"
start
printf 'STATUS: done\n' > "$T/result.raw"
printf '{"exit": 0, "ended": "x"}\n' > "$D/$ID/status.json"
expect 0 "" nc delegate --result "$ID"
git config --global --unset core.quotePath
DS="$(js r.diff_stat "$(cat "$T/out")")"
[ "$(wc -l <<<"$DS")" -le 50 ] || fail "diff_stat has more than 50 lines"
grep -q "lines cut" <<<"$DS" || fail "diff_stat without the cut note"
python3 -I -c 'import sys, unicodedata; t = sys.argv[1]; sys.exit(any((ord(c) < 32 and c != "\n") or 0x7f <= ord(c) <= 0x9f or unicodedata.category(c) == "Cf" for c in t))' "$DS" || fail "control, C1 or bidi characters in diff_stat"
ok "diff_stat: worker file names without control, C1 or bidi characters, at most 50 lines with a note"

# 8. two --result at once: one export, same output (flock)
start
printf 'STATUS: done\n' > "$T/result.raw"; echo 1 > "$T/export_sleep"
printf '{"exit": 0, "ended": "x"}\n' > "$D/$ID/status.json"
nc delegate --result "$ID" > "$T/a" 2>&1 & pa=$!
nc delegate --result "$ID" > "$T/b" 2>&1 & pb=$!
wait "$pa" && wait "$pb" || fail "concurrent --result failed: $(cat "$T/a" "$T/b")"
rm "$T/export_sleep"
[ "$(calls "nc-work export $ID")" = 1 ] || fail "concurrent --result exported twice"
cmp -s "$T/a" "$T/b" || fail "concurrent outputs differ"
ok "two --result at the same time: one export under the lock, same JSON"

# 9. log line: result fields minus diff_stat plus profile
L="$(grep "\"task_id\":\"$ID\"" "$HOME/.nc/log/delegate.jsonl")"
is "$(wc -l <<<"$L")" 1 "one log line per result"
is "$(js r.profile "$L")" site "log profile"
is "$(js '"diff_stat" in r' "$L")" false "log without diff_stat"
is "$(js r.status "$L")" done "log status"
ok "one log line per result, with profile, without diff_stat"

# 10. --cleanup: refused by nc-work keeps everything; success removes task, ref and run folder, log stays
CH="$(git -C "$SITE" rev-parse "refs/nc-delegate/$ID")"
echo 1 > "$T/remove_rc"
expect 1 "not deleted – uncommitted changes" nc delegate --cleanup "$ID"
git -C "$SITE" rev-parse -q --verify "refs/nc-delegate/$ID" > /dev/null || fail "ref deleted although nc-work refused"
[ -d "$D/$ID" ] || fail "run folder deleted although nc-work refused"
rm "$T/remove_rc"
expect 0 "" nc delegate --cleanup "$ID"
grep -qx "nc-work remove $ID --delivered $CH" "$T/calls.log" || fail "remove call: $(grep remove "$T/calls.log")"
! git -C "$SITE" rev-parse -q --verify "refs/nc-delegate/$ID" > /dev/null || fail "ref left after cleanup"
[ ! -e "$D/$ID" ] || fail "run folder left after cleanup"
grep -q "\"task_id\":\"$ID\"" "$HOME/.nc/log/delegate.jsonl" || fail "log line removed"
ok "--cleanup calls remove --delivered <head>, deletes ref and run folder only on success, keeps the log"

# 11. --wait end to end: hc runs delegate-run.sh, which calls nc-work opencode and writes status.json
touch "$T/hc_run"
printf 'STATUS: done\nall good\n' > "$T/result.raw"
expect 0 "" nc delegate --role implementer --task "do the thing" --timeout 2 --model openrouter/acme/big-1#high
J="$(cat "$T/out")"; ID="$(js r.task_id "$J")"
is "$(js r.status "$J")" done "--wait status"
is "$(js r.model "$J")" "openrouter/acme/big-1#high" "--wait model"
is "$(js r.exit "$(cat "$D/$ID/status.json")")" 0 "status.json exit"
mapfile -d '' argv < "$T/opencode.argv"
is "${argv[*]:0:10}" "opencode $ID -- run --format json --agent implementer --model openrouter/acme/big-1#high" "opencode argv"
head -c 2 <<<"${argv[10]}" | grep -q '^# ' && grep -q "do the thing" <<<"${argv[10]}" || fail "prompt argument"
echo 7 > "$T/opencode_rc"
expect 0 "" nc delegate --role tester --task "fail please" --timeout 1
is "$(js r.status "$(cat "$T/out")")" failed "worker exit 7"
mapfile -d '' argv < "$T/opencode.argv"
is "${argv[*]:0:8}" "opencode $(js r.task_id "$(cat "$T/out")") -- run --format json --agent tester" "argv without --model"
grep -q -- "--model" <<<"${argv[*]:0:9}" && fail "--model passed without override"
rm "$T/hc_run" "$T/opencode_rc"
ok "--wait end to end: delegate-run.sh runs nc-work opencode with role, model override and prompt, status.json decides"

# 12. hc failure after create: the unused worker task and the run folder are removed again; if that fails, the command is named
echo 1 > "$T/hc_rc"
: > "$T/calls.log"
before="$(ls "$D" | sort)"
expect 2 "name_taken.*deleted again" nc delegate --role tester --task x --bg
ID="$(grep -o 'task d[0-9]\{4\}-[0-9]\{4\}-[0-9a-f]\{4\}' "$T/err" | cut -d' ' -f2)"
grep -qx "nc-work remove $ID --force" "$T/calls.log" || fail "no remove --force after the hc failure: $(cat "$T/calls.log")"
[ ! -e "$D/$ID" ] && [ "$(ls "$D" | sort)" = "$before" ] || fail "run folder left after the hc failure"
grep -q "nc-work stop" "$T/calls.log" && fail "something stopped after the hc failure"
echo 1 > "$T/remove_rc"
expect 2 "name_taken.*not deleted: nc-work remove d[0-9-]*[0-9a-f]* --force" nc delegate --role tester --task x --bg
rm "$T/hc_rc" "$T/remove_rc"
ID="$(grep -o 'nc-work remove d[0-9]\{4\}-[0-9]\{4\}-[0-9a-f]\{4\}' "$T/err" | cut -d' ' -f3)"
[ -d "$D/$ID" ] || fail "run folder removed although the task could not be removed"
rm -rf "${D:?}/$ID"
ok "hc failure after create: remove --force and the run folder go; a failed remove names the command and keeps the folder"

# 12b. delegate-run.sh writes status.json when it is ended by TERM
start
echo 30 > "$T/opencode_sleep"; rm -f "$T/opencode.argv"
setsid bash "$RC/cli/delegate-run.sh" "$ID" > "$T/runner.log" 2>&1 & runner=$!
for _ in $(seq 100); do [ -f "$T/opencode.argv" ] && break; sleep 0.1; done
[ -f "$T/opencode.argv" ] || fail "delegate-run.sh did not start nc-work opencode: $(cat "$T/runner.log")"
kill -TERM -- "-$runner"
wait "$runner" || true
rm "$T/opencode_sleep"
[ -f "$D/$ID/status.json" ] || fail "no status.json after TERM"
is "$(js r.exit "$(cat "$D/$ID/status.json")")" 143 "status.json exit after TERM"
sleep 0.5; ! pgrep -f "$RC/cli/delegate-events.py" > /dev/null || fail "delegate-events still running after TERM: $(pgrep -fa delegate-events)"
ok "delegate-run.sh: TERM still writes status.json with exit 143, and no filter is left"

# 12c. SIGHUP to delegate-run.sh alone (hc kill: hang up, then SIGKILL): status.json comes at once, the signal goes on
start
echo 30 > "$T/opencode_sleep"; rm -f "$T/opencode.argv"
setsid bash "$RC/cli/delegate-run.sh" "$ID" > "$T/runner.log" 2>&1 & runner=$!
for _ in $(seq 100); do [ -f "$T/opencode.argv" ] && break; sleep 0.1; done
[ -f "$T/opencode.argv" ] || fail "delegate-run.sh did not start nc-work opencode: $(cat "$T/runner.log")"
kill -HUP "$runner"
for _ in $(seq 20); do [ -f "$D/$ID/status.json" ] && break; sleep 0.1; done
[ -f "$D/$ID/status.json" ] || fail "no status.json within 2 s of SIGHUP"
is "$(js r.exit "$(cat "$D/$ID/status.json")")" 129 "status.json exit after HUP"
wait "$runner" || true
sleep 0.5
rm "$T/opencode_sleep"
! pgrep -f "^sleep 30$" > /dev/null || fail "the worker (fake nc-work) still runs after HUP"
! pgrep -f "$RC/cli/delegate-events.py" > /dev/null || fail "delegate-events still running after HUP"
ok "delegate-run.sh: SIGHUP alone writes status.json 129 at once, ends the run and leaves no filter"

# 13. nc doctor names nc-work and hc for nc delegate
cd "$T/cwd"
"$RC/bin/nc" doctor --json > "$T/doc.json" || true
is "$(js 'r.checks.find(c => c.name === "nc delegate").status' "$(cat "$T/doc.json")")" ok "doctor with nc-work and hc"
env PATH="${BASE_PATH%:}" "$RC/bin/nc" doctor --json > "$T/doc.json" || true
is "$(js 'r.checks.find(c => c.name === "nc delegate").status' "$(cat "$T/doc.json")")" warn "doctor without nc-work and hc"
ok "nc doctor: one line for nc delegate, a warning without nc-work and hc"

# --- broker and container client --------------------------------------------------------------------------------------
cd "$SITE"
rm -f "$T/result.raw" "$T/opencode_rc" "$T/opencode_sleep"

# 14. an older researcher run is still fetched and cleaned up
start
python3 -I -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r["role"]="researcher"; json.dump(r, open(p,"w"))' "$D/$ID/request.json"
printf '{"exit": 0, "ended": "x"}\n' > "$D/$ID/status.json"
expect 0 "" nc delegate --result "$ID"
is "$(js r.role "$(cat "$T/out")")" researcher "old researcher run role"
is "$(js r.status "$(cat "$T/out")")" failed "old researcher run without RESULT.md"
expect 0 "" nc delegate --cleanup "$ID"
[ ! -e "$D/$ID" ] || fail "old researcher run not cleaned up"
ok "an older researcher run: --result and --cleanup still work"

# 15. --result without --wait past the deadline: timeout, export once, stop
: > "$T/calls.log"
start --timeout 1
python3 -I -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r["started"]="2026-01-01T00:00:00.000Z"; json.dump(r, open(p,"w"))' "$D/$ID/request.json"
expect 0 "" nc delegate --result "$ID"
is "$(js r.status "$(cat "$T/out")")" timeout "--result without --wait past the deadline"
[ "$(calls "nc-work export $ID")" = 1 ] && [ "$(calls "nc-work stop $ID")" = 1 ] || fail "export/stop past the deadline: $(cat "$T/calls.log")"
expect 0 "" nc delegate --result "$ID"
[ "$(calls "nc-work export $ID")" = 1 ] || fail "second --result exported again"
ok "--result without --wait past the deadline: timeout, exported once, stopped"

# 16. --broker: requester, token, profile and project path from nc-work; the request is data and checked whole
B="$T/broker"; mkdir -p "$B"
breq() {  # breq <request file> [project path] [profile]: --broker as nc-work broker calls it; stdout in $T/out
  local code=0
  "$RC/bin/nc" delegate --broker --requester b-req --token "$TOK" --profile "${3:-site}" --project-path "${2:-personal/site}" \
    --request "$1" --request-name r1.json > "$T/out" 2> "$T/err" || code=$?
  [ "$(wc -l < "$T/out")" = 1 ] || fail "--broker: not exactly one line on stdout: $(cat "$T/out")"
  BSTATE="$(js r.state "$(cat "$T/out")")"; BREASON="$(js r.reason "$(cat "$T/out")")"; BCODE=$code
}
bwant() {  # bwant <state> <exit> <pattern in reason or ''> <what>
  is "$BSTATE" "$1" "$4: state ($(cat "$T/out"))"; is "$BCODE" "$2" "$4: exit"
  [ -z "$3" ] || grep -q -- "$3" <<<"$BREASON" || fail "$4: reason '$BREASON' without '$3'"
}
rm -rf "$D"; mkdir -p "$D"; : > "$T/calls.log"
printf '{"v":1,"type":"delegate","role":"tester","task":"x","project":"example-site"}' > "$B/project.json"
printf '{"v":1,"type":"delegate","role":"tester","task":"x","path":"acme/website"}' > "$B/path.json"
printf '{"v":2,"type":"delegate","role":"tester","task":"x"}' > "$B/v2.json"
printf '{"v":1,"type":"publish","role":"tester","task":"x"}' > "$B/type.json"
printf '{"v":1,"type":"delegate","role":"tester","task":"%s"}' "$(head -c 20481 /dev/zero | tr '\0' a)" > "$B/big.json"
printf '{"v":1,"type":"delegate","role":"tester","task":"\xff"}' > "$B/utf8.json"
printf '[{"v":1}]' > "$B/array.json"
ln -s "$B/v2.json" "$B/link.json"
printf '{"v":1,"type":"cleanup","task_id":"d1115-1432-ab12"}' > "$B/cleanup.json"
printf '{"v":1,"type":"delegate","role":"researcher","task":"x"}' > "$B/researcher.json"
printf '{"v":1,"type":"delegate","role":"tester","task":"x","timeout":21}' > "$B/timeout.json"
printf '{"v":1,"type":"memory","text":"x"}' > "$B/memory.json"
for c in "memory:type \"memory\" unknown" "project:unknown field" "path:unknown field" "v2:version 2" "type:type" "big:at most 20480" "utf8:not valid JSON" \
         "array:not a JSON object" "link:is a link" "cleanup:does not go through --broker" "researcher:researcher blocked as a worker" "timeout:whole minutes"; do
  breq "$B/${c%%:*}.json"; bwant refused 1 "${c#*:}" "request ${c%%:*}"
done
printf '{"v":1,"type":"delegate","role":"implementer","task":"x","model":"openrouter/acme/tiny:free"}' > "$B/free.json"
breq "$B/free.json" acme/website acme-website; bwant refused 1 "nc models check" "free model in acme/website"
printf '{"v":1,"type":"delegate","role":"tester","task":"x"}' > "$B/ok.json"
breq "$B/ok.json" acme/../personal/site; bwant error 2 "not a project path" "project path with .."
"$RC/bin/nc" delegate --broker --requester b-req --token short --profile site --project-path personal/site --request "$B/ok.json" --request-name r1.json > "$T/out" 2>&1 || true
is "$(js r.state "$(cat "$T/out")")" error "bad token"
env NC_HARNESS_VERSION=abc "$RC/bin/nc" delegate --broker --requester b-req --token "$TOK" --profile site --project-path personal/site --request "$B/ok.json" --request-name r1.json > "$T/out" 2>&1 || true
is "$(js r.state "$(cat "$T/out")")" error "--broker in a container"
nothing_created "--broker refusals"
for c in "3:refused:1:3 tasks are already running; stop one first" "4:refused:1:the requesting task has uncommitted changes – commit first" "1:error:2:nc-work create"; do
  IFS=: read -r rc st ex pat <<<"$c"; echo "$rc" > "$T/create_rc"
  breq "$B/ok.json"; bwant "$st" "$ex" "$pat" "create exit $rc"
  [ -z "$(ls -A "$D")" ] || fail "run folder left after create exit $rc"
done
rm "$T/create_rc"
mv "$D" "$D.off" && touch "$D"
breq "$B/ok.json"; bwant error 2 "unexpected error" "unexpected error"
rm "$D" && mv "$D.off" "$D"
ok "--broker refuses unknown fields, versions, types, sizes, links, bad UTF-8, researcher and a free model in acme/website; create exit 3/4 refused, others error; always one JSON line"

: > "$T/calls.log"
printf '%040d\n' 7 | tr 0 c > "$T/create_base"   # nc-work's verified base of the requester, not the checkout's HEAD
printf '{"v":1,"type":"delegate","role":"tester","task":"SECRET-BROKER-TASK","model":null,"timeout":3}' > "$B/ok.json"
breq "$B/ok.json"; bwant started 0 "" "valid broker request"
ID="$(js r.task_id "$(cat "$T/out")")"
is "$(js r.timeout_min "$(cat "$T/out")")" 3 "started timeout_min"
js r.started "$(cat "$T/out")" | grep -q 'Z$' || fail "started is not an ISO time in UTC"
grep -qx "nc-work create site $ID --worker --from-task b-req" "$T/calls.log" || fail "create call: $(cat "$T/calls.log")"
grep -q "^hc run --bg --no-notify --outlive-parent --name $ID " "$T/calls.log" || fail "hc not started"
! grep -q SECRET-BROKER-TASK "$T/calls.log" || fail "task text on a command line"
RJ="$(cat "$D/$ID/request.json")"
is "$(js r.base "$RJ")" "$(cat "$T/create_base")" "base from nc-work create's record"
is "$(js '[r.origin, r.requester, r.requester_token, r.request_name].join(" ")' "$RJ")" "broker b-req $TOK r1.json" "broker fields in request.json"
is "$(js r.checkout "$RJ")" "$SITE" "checkout for the policy"
rm -rf "${D:?}/$ID"
for f in from_task:b-other from_token:ffffffffffffffffffffffffffffffff; do
  : > "$T/calls.log"; echo "${f#*:}" > "$T/${f%%:*}"
  breq "$B/ok.json"; bwant error 2 "does not match the request" "${f%%:*} mismatch"
  grep -q "^nc-work remove d[0-9-]*[0-9a-f]* --force$" "$T/calls.log" || fail "${f%%:*} mismatch: unused worker not removed"
  [ "$(calls '^hc ')" = 0 ] || fail "${f%%:*} mismatch: hc started"
  rm "$T/${f%%:*}"
done
[ -z "$(ls -A "$D")" ] || fail "run folder left after a record mismatch"
ok "--broker: nc-work create --worker --from-task <requester>, base from create's record, from_task/from_token checked, request.json with origin, requester, token and name"

# 17. fetching a broker run: no fetch into a checkout, delivery/ with bundle, cleaned RESULT.md and result.json
rm "$T/create_base"; : > "$T/calls.log"
breq "$B/ok.json"; bwant started 0 "" "broker run for fetching"
ID="$(js r.task_id "$(cat "$T/out")")"
WHEAD="$(git -C "$T/worker" rev-parse HEAD)"
refs_before="$(git -C "$SITE" for-each-ref)"; head_before="$(git -C "$SITE" rev-parse HEAD)"
printf 'STATUS: done\nesc \033[31mred\033[0m bidi \xe2\x80\xaeevil\n' > "$T/result.raw"
printf '{"exit": 0, "ended": "x"}\n' > "$D/$ID/status.json"
expect 0 "" nc delegate --result "$ID"
R="$(cat "$T/out")"
is "$(js r.status "$R")" done "broker run status"
is "$(js r.result "$R")" "/opt/nc-inbox/r1/RESULT.md" "result points into the inbox"
is "$(js r.ref "$R")" "refs/nc-delegate/$ID" "ref name"
is "$(git -C "$SITE" for-each-ref)" "$refs_before" "refs in the checkout changed"
is "$(git -C "$SITE" rev-parse HEAD)" "$head_before" "checkout HEAD changed"
grep -q -e "git.*fetch" -e "nc-work.*$SITE" "$T/calls.log" && fail "something touched the checkout"
DL="$D/$ID/delivery"
is "$(LC_ALL=C ls "$DL" | tr '\n' ' ')" "RESULT.md result.bundle result.json " "delivery files"
is "$(git bundle list-heads "$DL/result.bundle" | awk '{print $2}' | tr '\n' ' ')" "refs/heads/nc-work/$ID " "bundle refs"
is "$(git bundle list-heads "$DL/result.bundle" | awk '{print $1}')" "$WHEAD" "bundle head"
cmp -s "$DL/result.json" "$D/$ID/result.json" && [ "$(cat "$DL/result.json")" = "$R" ] || fail "delivery/result.json differs"
grep -qE $'\033|\xe2\x80\xae' "$DL/RESULT.md" && fail "delivery/RESULT.md not cleaned"
cmp -s "$DL/RESULT.md" "$D/$ID/RESULT.md" || fail "delivery/RESULT.md is not the cleaned file"
is "$(js r.requester "$(grep "\"task_id\":\"$ID\"" "$HOME/.nc/log/delegate.jsonl")")" b-req "log line requester"
is "$(cat "$T/stop_saw_$ID")" "RESULT.md result.bundle " "delivery/ at nc-work stop (bundle and RESULT.md before, result.json after)"
: > "$T/calls.log"
expect 0 "" nc delegate --cleanup "$ID"
grep -qx "nc-work remove $ID --delivered $WHEAD" "$T/calls.log" || fail "cleanup remove call: $(cat "$T/calls.log")"
[ ! -e "$D/$ID" ] || fail "run folder left after a broker cleanup"
is "$(git -C "$SITE" for-each-ref)" "$refs_before" "cleanup touched the checkout"
breq "$B/ok.json"; ID="$(js r.task_id "$(cat "$T/out")")"
expect 1 "not collected yet" nc delegate --cleanup "$ID"
rm -rf "${D:?}/$ID"
ok "broker run: fetched into delivery/ only (one-ref bundle, cleaned RESULT.md before nc-work stop, result.json last), result in the inbox, --cleanup from export/repo.git"

# 18. container client against a small test broker
MB="$T/mb"; REQ="$MB/requests"; INBOX="$MB/inbox"; mkdir -p "$REQ" "$INBOX" "$MB/log"
git clone -q "$SITE" "$T/ws"
cat > "$T/tbroker.py" <<'EOF'
# Test broker: heartbeat, picks up requests, answers by $MB/mode. Flags in $MB: no_heartbeat, no_pickup, slow, stop.
# Modes dropped, dropped-broken, dropped-link, dropped-big: delete the request and write .dropped (valid, broken, as a link,
# over 32 KiB) instead of an answer; both: an error answer and a .dropped entry for the same request.
import json, os, pathlib, shutil, sys, time
mb = pathlib.Path(sys.argv[1]); req, inbox, log = mb / "requests", mb / "inbox", mb / "log"
def now(): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
def put(path, data):
    tmp = path.with_name("." + path.name + ".tmp"); tmp.write_text(json.dumps(data)); os.replace(tmp, path)
while not (mb / "stop").exists():
    if not (mb / "no_heartbeat").exists(): put(inbox / ".broker", {"v": 1, "ts": now()})
    if (mb / "race").exists():  # read it, but answer only after the client has taken it back (a late answer)
        for f in sorted(req.iterdir()):
            if f.name.startswith("."): continue
            while f.exists(): time.sleep(0.05)
            (inbox / f.name[:-5]).mkdir()
            put(inbox / f.name[:-5] / "response.json", {"v": 1, "request": f.name[:-5], "state": "refused", "reason": "late", "task_id": None,
                                                         "timeout_min": None, "started": None, "result": None})
        time.sleep(0.2); continue
    for f in sorted(req.iterdir()):
        if f.name.startswith(".") or (mb / "no_pickup").exists(): continue
        raw = f.read_bytes(); (log / f.name).write_bytes(raw); f.unlink()
        if (mb / "slow").exists(): time.sleep(4)
        body, mode, stem = json.loads(raw), (mb / "mode").read_text().strip(), f.name[:-5]
        if mode.startswith("dropped") or mode == "both":
            doc = {"v": 1, "entries": [{"request": "r00000000000000-ffff", "reason": "foreign", "ts": now()},
                                       {"request": stem, "reason": "inbox full \x1b[31m(200 answers) – run nc delegate --cleanup <id> for collected runs first", "ts": now()}]}
            d = inbox / ".dropped"
            if d.is_symlink(): d.unlink()
            if mode == "dropped-broken": d.write_text(json.dumps(doc)[:-3])
            elif mode == "dropped-link": (mb / "dropped-target").write_text(json.dumps(doc)); d.unlink(missing_ok=True); d.symlink_to(mb / "dropped-target")
            elif mode == "dropped-big": doc["pad"] = "x" * 40000; put(d, doc)
            else: put(d, doc)
            if mode != "both": continue
            mode = "error"
        r = {"v": 1, "request": stem, "state": mode, "reason": None, "task_id": None, "timeout_min": None, "started": None, "result": None}
        if body["type"] == "cleanup":
            r["task_id"] = body["task_id"]
            if mode == "cleaned":
                if (mb / "gone").exists(): r["gone"] = True
                for d in list(inbox.iterdir()):
                    p = d / "response.json"
                    if d.name.startswith("r") and p.exists() and json.loads(p.read_text()).get("task_id") == body["task_id"]: shutil.rmtree(d)
            else: r["state"], r["reason"] = "refused", "does not belong to this requesting task"
        elif mode in ("refused", "error"): r["reason"] = "no \x1b[31mred\u202e"
        elif mode == "started": r.update(task_id="d1115-1432-ab12", timeout_min=1, started=now())
        (inbox / stem).mkdir(); put(inbox / stem / "response.json", r)
    time.sleep(0.2)
EOF
python3 -I "$T/tbroker.py" "$MB" & tb=$!
trap 'kill "$tb" 2>/dev/null || true; chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
cnc() { env NC_HARNESS_VERSION=abc NC_REQUESTS="$REQ" NC_INBOX="$INBOX" NC_TEST_WORKSPACE="$T/ws" NC_DELEGATE_STALE_S=2 "$RC/bin/nc" delegate "$@"; }
echo refused > "$MB/mode"
expect 1 'no \\u{1b}\[31mred\\u{202e}' cnc --role tester --task "hello world" --model openrouter/acme/x --timeout 3 --bg
N="$(ls "$MB/log" | tail -1)"
[[ "$N" =~ ^r[0-9]{14}-[0-9a-f]{4}\.json$ ]] || fail "request name $N"
is "$(cat "$MB/log/$N")" '{"v":1,"type":"delegate","role":"tester","task":"hello world","model":"openrouter/acme/x","timeout":3}' "request format"
[ -z "$(ls -A "$REQ")" ] || fail "left in the mailbox: $(ls -A "$REQ")"
echo error > "$MB/mode"
expect 2 "no .*red" cnc --role implementer --task x --bg
echo started > "$MB/mode"
expect 0 "" cnc --role tester --task x --bg
is "$(js '[r.status, r.task_id, r.role].join(" ")' "$(cat "$T/out")")" "running d1115-1432-ab12 tester" "--bg after started"
expect 0 "" cnc --result d1115-1432-ab12
is "$(js r.status "$(cat "$T/out")")" running "--result while started"
ok "client: request in the broker's format, written with rename; refused → 1, error → 2, started with --bg → running"

# done: the test acts as host and writes the answer the broker would write
TID=d1115-1432-ab12
RD="$(grep -l "\"$TID\"" "$INBOX"/r*/response.json | head -1)"; RD="$(dirname "$RD")"; RS="$(basename "$RD")"
git init -q --bare "$T/res.git" && git -C "$T/res.git" fetch -q "$T/worker" "HEAD:refs/heads/nc-work/$TID"
git -C "$T/res.git" bundle create -q "$RD/result.bundle" "refs/heads/nc-work/$TID"
python3 -I -c '
import json, sys
d, tid, head, stem = sys.argv[1:5]
res = {"task_id": tid, "role": "tester", "runtime": "opencode", "model": "m", "status": "done", "waiting_on": None, "branch": "nc-work/" + tid,
       "ref": "refs/nc-delegate/" + tid, "base": head, "head": head, "result": "/opt/nc-inbox/%s/RESULT.md" % stem, "diff_stat": "a | 1 +\u202e",
       "duration_s": 5, "cost_usd": None, "over_budget": None, "reason": None}
json.dump({"v": 1, "request": stem, "state": "done", "reason": None, "task_id": tid, "timeout_min": 1, "started": "2026-11-15T10:00:00Z", "result": res}, open(d + "/response.json", "w"))
' "$RD" "$TID" "$WHEAD" "$RS"
ws_status="$(git -C "$T/ws" status --porcelain; git -C "$T/ws" rev-parse HEAD)"
expect 0 "" cnc --result "$TID"
is "$(git -C "$T/ws" rev-parse "refs/nc-delegate/$TID")" "$WHEAD" "ref in the workspace"
is "$(js r.head "$(cat "$T/out")")" "$WHEAD" "done JSON head"
js r.diff_stat "$(cat "$T/out")" | grep -q $'\xe2\x80\xae' && fail "bidi character in the printed JSON"
is "$(git -C "$T/ws" status --porcelain; git -C "$T/ws" rev-parse HEAD)" "$ws_status" "workspace changed"
mv "$RD/result.bundle" "$T/result.bundle.off"
expect 0 "" cnc --result "$TID" --wait
is "$(js r.head "$(cat "$T/out")")" "$WHEAD" "second --result without fetching"
mv "$T/result.bundle.off" "$RD/result.bundle"
ok "client: done fetches the branch from the bundle as refs/nc-delegate/<id> once; a second --result does not fetch again"

# started past the deadline, --wait: no endless wait
python3 -I -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r.update(state="started", result=None, started="2026-01-01T00:00:00Z"); json.dump(r, open(p,"w"))' "$RD/response.json"
expect 2 "no result yet – nc delegate --result $TID later" cnc --result "$TID" --wait
expect 2 "no run d1115-1432-ffff" cnc --result d1115-1432-ffff
expect 2 "invalid ID" cnc --result ../x
ok "client: --result --wait gives up after started + timeout + 5 minutes; unknown and invalid IDs are errors"

# broker not running; request already picked up (ENOENT)
touch "$MB/no_heartbeat" "$MB/no_pickup"; rm -f "$INBOX/.broker"; sleep 0.5
expect 2 "broker is not running – start \`nc-work broker\` in a herdr pane" cnc --role tester --task x --bg
[ -z "$(ls -A "$REQ")" ] || fail "request left in the mailbox without a broker: $(ls -A "$REQ")"
rm "$MB/no_pickup"; touch "$MB/slow"; echo refused > "$MB/mode"
expect 1 "no .*red" cnc --role tester --task x --bg
rm "$MB/slow" "$MB/no_heartbeat"
ok "client: without a heartbeat it takes its request back and exits 2; a request the broker already took (ENOENT) is waited for"

expect 2 "there is no --repo in a task container" cnc --role tester --task x --repo "$SITE"
expect 2 "this task has no mailbox (workers do not delegate further; a task made by an older nc-work has none)" \
  env NC_HARNESS_VERSION=abc NC_INBOX="$INBOX" "$RC/bin/nc" delegate --role tester --task x
expect 2 "no mailbox" env NC_HARNESS_VERSION=abc NC_REQUESTS="$T/nope" NC_INBOX="$INBOX" "$RC/bin/nc" delegate --result "$TID"
n="$(ls "$MB/log" | wc -l)"
expect 1 "researcher blocked as a worker" cnc --role researcher --task x
is "$(ls "$MB/log" | wc -l)" "$n" "researcher request written"
[ -z "$(ls -A "$REQ")" ] || fail "researcher left a request"
ok "client: --repo is an error, no mailbox gives the worker text, researcher is refused without a request"

# --cleanup: head read first (the broker deletes the run's folder), the ref goes only on cleaned
python3 -I -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r.update(state="done"); r["result"]={"task_id":sys.argv[2],"head":sys.argv[3]}; json.dump(r, open(p,"w"))' "$RD/response.json" "$TID" "$WHEAD"
echo refused > "$MB/mode"
expect 1 "does not belong to this requesting task" cnc --cleanup "$TID"
git -C "$T/ws" rev-parse -q --verify "refs/nc-delegate/$TID" > /dev/null || fail "ref deleted on refused"
C="$(ls "$MB/log" | grep "^c" | tail -1)"
[[ "$C" =~ ^c[0-9]{14}-[0-9a-f]{4}\.json$ ]] || fail "cleanup request name $C"
is "$(cat "$MB/log/$C")" "{\"v\":1,\"type\":\"cleanup\",\"task_id\":\"$TID\"}" "cleanup request format"
echo cleaned > "$MB/mode"
expect 0 "" cnc --cleanup "$TID"
! git -C "$T/ws" rev-parse -q --verify "refs/nc-delegate/$TID" > /dev/null || fail "ref left after cleaned"
[ ! -e "$RD" ] || fail "test broker did not delete the run folder"
ok "client: --cleanup reads head before asking, deletes the ref only on cleaned"

# the client's own waiting time (NC_DELEGATE_ANSWER_S, tests only), taking the request back, a late answer, gone
canswer() { local s="$1"; shift; env NC_DELEGATE_ANSWER_S="$s" NC_HARNESS_VERSION=abc NC_REQUESTS="$REQ" NC_INBOX="$INBOX" NC_TEST_WORKSPACE="$T/ws" NC_DELEGATE_STALE_S=2 "$RC/bin/nc" delegate "$@"; }
touch "$MB/no_pickup"; sleep 0.5                                   # the broker runs (heartbeat) but is busy
s0=$SECONDS
expect 2 "no answer after 2 seconds – request taken back; if the broker accepted it just before, the answer shows up in the inbox later (request r[0-9a-f-]*)" canswer 2 --role tester --task x --bg
[ -z "$(ls -A "$REQ")" ] || fail "request left in the mailbox after the own waiting time: $(ls -A "$REQ")"
expect 2 "after 1 seconds – request taken back" canswer 0.01 --role tester --task x --bg   # at least 1 s
expect 2 "no answer" canswer 2 --cleanup "$TID"                                          # cleanup too
[ -z "$(ls -A "$REQ")" ] || fail "cleanup request left in the mailbox: $(ls -A "$REQ")"
[ $((SECONDS - s0)) -lt 30 ] || fail "the shortened waiting time took $((SECONDS - s0)) s"
rm "$MB/no_pickup"; touch "$MB/slow"; echo refused > "$MB/mode"   # picked up, but no answer in time (ENOENT)
expect 2 "in progress – look in the inbox later (request r[0-9]*-[0-9a-f]*)" canswer 1 --role tester --task x --bg
sleep 5; rm "$MB/slow"
n="$(ls -d "$INBOX"/r* | wc -l)"
touch "$MB/no_heartbeat" "$MB/race"; rm -f "$INBOX/.broker"; sleep 0.5    # stale heartbeat, but the answer comes after all
expect 1 "late" cnc --role tester --task x --bg
rm "$MB/race" "$MB/no_heartbeat"; sleep 0.5
touch "$MB/race"; sleep 0.5                    # heartbeat fresh; the broker accepts it just as the own waiting time takes it back
expect 1 "late" canswer 1 --role tester --task x --bg
rm "$MB/race"
ok "client: after its own waiting time it takes the request back (exit 2), says 'in progress' if the broker has it; a late answer after a stale heartbeat or a take-back counts"

git -C "$T/ws" update-ref refs/nc-delegate/d1115-1432-0001 "$WHEAD"   # its answer folder is gone already: no head from the inbox
echo cleaned > "$MB/mode"
expect 0 "" cnc --cleanup d1115-1432-0001
git -C "$T/ws" rev-parse -q --verify refs/nc-delegate/d1115-1432-0001 > /dev/null || fail "ref deleted on cleaned without gone and without head"
touch "$MB/gone"
expect 0 "" cnc --cleanup d1115-1432-0001
grep -q "was already deleted on the host" "$T/out" || fail "gone not reported: $(cat "$T/out")"
! git -C "$T/ws" rev-parse -q --verify refs/nc-delegate/d1115-1432-0001 > /dev/null || fail "ref left after cleaned with gone"
rm "$MB/gone"
ok "client: cleaned with gone deletes the local ref at its current value"

# an entry for the request in the host's .dropped ends the wait at once with exit 1 and the reason
s0=$SECONDS
echo dropped > "$MB/mode"
expect 1 'request r[0-9]*-[0-9a-f]* dropped without an answer: inbox full \\u{1b}\[31m(200 answers) – run nc delegate --cleanup <id> for collected runs first' cnc --role tester --task x --bg
expect 1 "request c[0-9]*-[0-9a-f]* dropped without an answer: inbox full" cnc --cleanup d1115-1432-0002
[ $((SECONDS - s0)) -lt 10 ] || fail ".dropped: took $((SECONDS - s0)) s"
echo error > "$MB/mode"                        # .dropped holds only other requests' entries now: ignored
expect 2 "no .*red" cnc --role tester --task x --bg
echo both > "$MB/mode"                         # an answer folder and an entry for the same request: the answer wins
expect 2 "no .*red" cnc --role tester --task x --bg
grep -q "dropped without an answer" "$T/err" && fail "the .dropped entry won over the answer"
for m in dropped-broken dropped-link dropped-big; do  # no entry is seen: the old way, until the own waiting time
  echo "$m" > "$MB/mode"; s0=$SECONDS
  expect 2 "in progress – look in the inbox later" canswer 2 --role tester --task x --bg
  [ $((SECONDS - s0)) -lt 15 ] || fail "$m: took $((SECONDS - s0)) s"
done
rm -f "$INBOX/.dropped"
ok "client: a .dropped entry for its request ends delegate and cleanup at once with exit 1; foreign entries, broken, linked or too large .dropped are ignored; an answer wins"

touch "$MB/stop"; wait "$tb" 2>/dev/null || true

# 18b. awaitAnswer: a request taken back ends with TakenBack (a DelegateError, exit 2), stale heartbeat or own waiting time
TB="$T/takenback"; mkdir -p "$TB/requests" "$TB/inbox"
cat > "$T/takenback.ts" <<'EOF'
import { awaitAnswer, DelegateError, post, TakenBack } from "./cli/delegate.ts";
const m = { requests: process.argv[2], inbox: process.argv[3] };
const out: string[] = [];
for (const fresh of [false, true]) {
  if (fresh) await Bun.write(`${m.inbox}/.broker`, JSON.stringify({ v: 1, ts: new Date(Date.now() + 60_000).toISOString() }));
  const name = post(m, "m", { v: 1, type: "memory", text: "x" });
  try { awaitAnswer(m, name, ["stored"], 1500); out.push("no throw"); }
  catch (e: any) { out.push(`${e instanceof TakenBack} ${e instanceof DelegateError} ${e.message.split(" – ")[0].split(" after ")[0]}`); }
}
console.log(out.join("|"));
EOF
cp "$T/takenback.ts" "$RC/takenback.ts"
got="$(cd "$RC" && NC_DELEGATE_STALE_S=1 bun --no-env-file takenback.ts "$TB/requests" "$TB/inbox")"
rm "$RC/takenback.ts"
is "$got" "true true broker is not running|true true no answer" "TakenBack"
[ -z "$(ls -A "$TB/requests")" ] || fail "TakenBack left a request"
ok "awaitAnswer: a take-back after a stale heartbeat or the own waiting time throws TakenBack (a DelegateError, texts unchanged)"

# 19. nc doctor in a task: one line on mailbox, inbox and heartbeat (warning only)
cd "$T/cwd"
dj() { env NC_HARNESS_VERSION=abc "$@" "$RC/bin/nc" doctor --json 2>/dev/null | bun -e 'const r = JSON.parse(await Bun.stdin.text()); const c = r.checks.find(c => c.name === "nc delegate"); console.log(c.status + " " + c.detail)' || true; }
printf '{"v":1,"ts":"2026-01-01T00:00:00Z"}' > "$INBOX/.broker"
dj NC_REQUESTS="$REQ" NC_INBOX="$INBOX" | grep -q "^warn .*broker is not running – start \`nc-work broker\` in a herdr pane" || fail "doctor without heartbeat: $(dj NC_REQUESTS="$REQ" NC_INBOX="$INBOX")"
printf '{"v":1,"ts":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INBOX/.broker"
dj NC_REQUESTS="$REQ" NC_INBOX="$INBOX" | grep -q "^ok .*broker running" || fail "doctor with heartbeat: $(dj NC_REQUESTS="$REQ" NC_INBOX="$INBOX")"
dj | grep -q "^warn .*no mailbox" || fail "doctor without mailbox: $(dj)"
ok "nc doctor in a task: mailbox, inbox and heartbeat in one line, warnings only"

# --- policy, cost and the events filter -------------------------------------------------------------------------------
cd "$SITE"
: > "$T/calls.log"
rm -f "$T/opencode_rc" "$T/opencode_sleep" "$T/export_head" "$T/result_file"
EV="$RC/cli/delegate-events.py"
mkev() {  # mkev <file> <cost>…: text, tool_use, one step_finish per cost, a line without JSON, a text with ESC, U+009B, U+202E
  python3 -I -c '
import json, sys
out = open(sys.argv[1], "wb")
w = lambda o: out.write(json.dumps(o).encode() + b"\n")
w({"type": "step_start", "part": {"type": "step-start"}})
w({"type": "text", "part": {"type": "text", "text": "Hello from the worker"}})
w({"type": "tool_use", "part": {"type": "tool", "tool": "shell", "state": {"status": "completed", "title": "git commit -m x", "input": {"command": "git commit -m x"}}}})
for c in sys.argv[2:]: w({"type": "step_finish", "part": {"type": "step-finish", "cost": float(c)}})
out.write(b"not json at all\n")
w({"type": "text", "part": {"type": "text", "text": "esc \x1b[31mred c1 \x9b31m bidi ‮evil end"}})
' "$@"
}

# 20. a worker run end to end: events.jsonl raw (600), readable pane, cost_usd and over_budget
touch "$T/hc_run"
printf 'STATUS: done\n' > "$T/result.raw"
mkev "$T/events" 0.01 0.02 0.005
expect 0 "" nc delegate --role tester --task "cost please" --timeout 2
J="$(cat "$T/out")"; ID="$(js r.task_id "$J")"
[ "$(wc -l < "$T/out")" = 1 ] || fail "stdout of --wait with over_budget is not one line: $(cat "$T/out")"
is "$(js '[r.status, r.cost_usd, r.over_budget]' "$J")" '["done",0.035,true]' "cost_usd and over_budget"
grep -qxF 'nc delegate: cost (reported by the worker) 0.035 $ over per_task_usd 0.03 $' "$T/err" || fail "no over_budget line on stderr: $(cat "$T/err")"
cmp -s "$T/events" "$D/$ID/events.jsonl" || fail "events.jsonl is not byte-equal to OpenCode's output"
is "$(stat -c %a "$D/$ID/events.jsonl")" 600 "events.jsonl mode"
grep -q "^Hello from the worker$" "$T/worker.log" && grep -q "^→ shell: git commit -m x$" "$T/worker.log" \
  && grep -q "^(line without JSON, 15 bytes)$" "$T/worker.log" && grep -q "^esc \[31mred c1 31m bidi evil end$" "$T/worker.log" || fail "pane: $(cat -v "$T/worker.log")"
grep -qE '"type"|not json' "$T/worker.log" && fail "raw JSON or a raw line in the pane: $(cat -v "$T/worker.log")"
python3 -I -c 'import sys; t = open(sys.argv[1], encoding="utf-8").read(); sys.exit(any((ord(c) < 32 and c not in "\n\t") or 0x7f <= ord(c) <= 0x9f or ord(c) == 0x202e for c in t))' "$T/worker.log" || fail "control characters in the pane"
L="$(grep "\"task_id\":\"$ID\"" "$HOME/.nc/log/delegate.jsonl")"
is "$(js '[r.cost_usd, r.over_budget]' "$L")" "[0.035,true]" "log line cost and over_budget"
is "$(js 'Object.keys(r).slice(12, 15).join(",")' "$L")" "cost_usd,over_budget,reason" "log key order"
mkev "$T/events" 0.01
expect 0 "" nc delegate --role tester --task "cheap" --timeout 2
is "$(js '[r.cost_usd, r.over_budget]' "$(cat "$T/out")")" "[0.01,false]" "within budget"
grep -qF "cost (reported by the worker)" "$T/err" && fail "over_budget line although within budget"
ok "worker run: events.jsonl byte-equal (600), pane only text, one line per tool, no raw JSON or control characters; cost_usd 0.035 over 0.03, 0.01 within"

# 21. faked and broken lines: the filter reads to EOF, exits 0, the sum holds only valid step_finish lines
python3 -I -c '
import json, sys
out = open(sys.argv[1], "wb")
w = lambda s: out.write(s.encode() + b"\n")
w(json.dumps({"type": "step_finish", "part": {"cost": 0.01}}))
w("{\"type\": \"step_finish\", \"part\": {\"cost\": NaN}}")
w(json.dumps({"type": "step_finish", "part": {"cost": -5}}))
w(json.dumps({"type": "step_finish", "part": {"cost": "0.5"}}))
w(json.dumps({"type": "step_finish", "part": {"cost": 1e999}}))
w(json.dumps({"type": "step_finish", "part": {"cost": 7, "pad": "x" * (1024 * 1024 + 10)}}))
w("[" * 100000)
out.write(b"\xff\xfe broken utf-8\n")
w(json.dumps({"type": "step_finish", "part": {"cost": 0.002}}))
out.write(b"y" * (2 * 1024 * 1024))   # 2 MiB without a newline at the end
' "$T/events"
expect 0 "" nc delegate --role tester --task "fakes" --timeout 2
J="$(cat "$T/out")"; ID="$(js r.task_id "$J")"
is "$(js '[r.status, r.cost_usd, r.over_budget]' "$J")" '["done",0.012,false]' "sum of valid lines only"
is "$(js r.exit "$(cat "$D/$ID/status.json")")" 0 "exit with faked lines"
cmp -s "$T/events" "$D/$ID/events.jsonl" || fail "events.jsonl with long lines differs"
grep -q "line of .* bytes, not read" "$T/worker.log" || fail "long line not named: $(head -c 2000 "$T/worker.log" | cat -v)"
[ "$(stat -c %s "$T/worker.log")" -lt 10000 ] || fail "pane shows long lines raw ($(stat -c %s "$T/worker.log") bytes)"
# over 16 MiB: at most 16 MiB stored, only whole lines, still exit 0 and everything read
python3 -I -c '
import json, sys
line = json.dumps({"type": "step_finish", "part": {"cost": 0.001, "pad": "z" * 500000}}).encode() + b"\n"
with open(sys.argv[1], "wb") as f:
    for _ in range(40): f.write(line)
' "$T/big.jsonl"
code=0; python3 -I -B "$EV" "$T/big-out.jsonl" < "$T/big.jsonl" > "$T/big-view" 2>&1 || code=$?
is "$code" 0 "filter exit over 16 MiB"
[ "$(stat -c %s "$T/big-out.jsonl")" -le $((16 * 1024 * 1024)) ] || fail "events.jsonl larger than 16 MiB"
[ "$(tail -c 1 "$T/big-out.jsonl" | od -An -c | tr -d ' ')" = '\n' ] || fail "events.jsonl does not end with a whole line"
python3 -I -c 'import sys; b = open(sys.argv[1], "rb").read(); l = open(sys.argv[2], "rb").read().split(b"\n")[0] + b"\n"; sys.exit(0 if b == l * (len(b) // len(l)) else 1)' "$T/big-out.jsonl" "$T/big.jsonl" || fail "stored part is not whole raw lines"
# one line longer than what is left: cut back to the line's start
python3 -I -c '
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"{\"type\":\"text\",\"part\":{\"text\":\"a\"}}\n" * 3); f.write(b"q" * (17 * 1024 * 1024) + b"\n"); f.write(b"{}\n")
' "$T/huge.jsonl"
code=0; python3 -I -B "$EV" "$T/huge-out.jsonl" < "$T/huge.jsonl" > /dev/null 2>&1 || code=$?
is "$code" 0 "filter exit with a 17 MiB line"
is "$(stat -c %s "$T/huge-out.jsonl")" "$((3 * 36))" "17 MiB line cut back, nothing stored after it"
# without a target: shows, stores nothing; an existing target or a link is not written, the run goes on
code=0; python3 -I -B "$EV" < "$T/events" > "$T/view" 2>&1 || code=$?
is "$code" 0 "filter without a target"
echo keep > "$T/existing"; ln -sf "$T/existing" "$T/evlink"
code=0; python3 -I -B "$EV" "$T/existing" < "$T/events" > /dev/null 2> "$T/everr" || code=$?
is "$code:$(cat "$T/existing")" "0:keep" "existing target untouched"
code=0; python3 -I -B "$EV" "$T/evlink" < "$T/events" > /dev/null 2> "$T/everr" || code=$?
is "$code:$(cat "$T/existing")" "0:keep" "linked target untouched"
# a closed pane (EIO) and a closed pipe on stdout: still read to EOF, exit 0, events stored
code=0; python3 -I -B "$EV" "$T/eio.jsonl" < "$T/big.jsonl" > /dev/full 2>/dev/null || code=$?
is "$code" 0 "filter exit with stdout /dev/full"
cmp -s <(head -c "$(stat -c %s "$T/eio.jsonl")" "$T/big.jsonl") "$T/eio.jsonl" && [ "$(stat -c %s "$T/eio.jsonl")" -gt $((15 * 1024 * 1024)) ] || fail "events not stored with a broken stdout"
code=0; { python3 -I -B "$EV" "$T/pipe.jsonl" < "$T/events" 2>/dev/null || code=$?; } | true
is "$code" 0 "filter exit with a closed pipe"
ok "filter: NaN, negative, text, infinite, >1 MiB, deep nesting, bad UTF-8, 2 MiB without newline skipped; >16 MiB stored up to whole lines; no target, existing file, link, /dev/full, closed pipe: exit 0"

# 22. cost_usd null: no events.jsonl, a link, a file over 16 MiB; a broken models.yaml: over_budget null, result and status right
rm -f "$T/events" "$T/hc_run"   # start (--bg) without running the worker
start; printf '{"exit": 0, "ended": "x"}\n' > "$D/$ID/status.json"
expect 0 "" nc delegate --result "$ID"
is "$(js '[r.status, r.cost_usd, r.over_budget]' "$(cat "$T/out")")" '["done",null,null]' "no events.jsonl"
mkev "$T/ev-real" 0.5
start; printf '{"exit": 0, "ended": "x"}\n' > "$D/$ID/status.json"; ln -s "$T/ev-real" "$D/$ID/events.jsonl"
expect 0 "" nc delegate --result "$ID"
is "$(js '[r.cost_usd, r.over_budget]' "$(cat "$T/out")")" "[null,null]" "events.jsonl as a link"
start; printf '{"exit": 0, "ended": "x"}\n' > "$D/$ID/status.json"; cp "$T/big.jsonl" "$D/$ID/events.jsonl"
expect 0 "" nc delegate --result "$ID"
is "$(js r.cost_usd "$(cat "$T/out")")" null "events.jsonl over 16 MiB"
start; printf '{"exit": 7, "ended": "x"}\n' > "$D/$ID/status.json"; cp "$T/ev-real" "$D/$ID/events.jsonl"
cp "$RC/models.yaml" "$T/models.yaml.ok" && echo 'budgets: [' >> "$RC/models.yaml"
expect 0 "budget not read" nc delegate --result "$ID"
cp "$T/models.yaml.ok" "$RC/models.yaml"
is "$(js '[r.status, r.cost_usd, r.over_budget]' "$(cat "$T/out")")" '["failed",0.5,null]' "broken models.yaml at fetching"
[ -f "$D/$ID/result.json" ] || fail "no result.json with a broken models.yaml"
grep -n "nc-work stop $ID" "$T/calls.log" > /dev/null || fail "worker not stopped"
ok "cost_usd null without file, for a link and over 16 MiB; a broken models.yaml makes only over_budget null"

# 23. the pipe keeps exit codes: 124 from timeout, --timeout 1 with commits after the limit
touch "$T/hc_run"
mkev "$T/events" 0.01
echo 124 > "$T/opencode_rc"
expect 0 "" nc delegate --role tester --task x --timeout 2
J="$(cat "$T/out")"; ID="$(js r.task_id "$J")"
is "$(js r.exit "$(cat "$D/$ID/status.json")")" 124 "status.json 124 through the pipe"
is "$(js '[r.status, r.cost_usd]' "$J")" '["timeout",0.01]' "timeout with cost"
rm "$T/opencode_rc"
echo late > "$T/worker/late.txt" && git -C "$T/worker" add -A && git -C "$T/worker" commit -qm "committed before the limit"
LHEAD="$(git -C "$T/worker" rev-parse HEAD)"
rm "$T/hc_run"; start --timeout 1     # the fake hc would wait for the worker only 30 s: run it here
echo 120 > "$T/opencode_sleep"
bash "$RC/cli/delegate-run.sh" "$ID" > "$T/runner.log" 2>&1 || true
rm "$T/opencode_sleep"
expect 0 "" nc delegate --result "$ID"
J="$(cat "$T/out")"
is "$(js '[r.status, r.head, r.cost_usd]' "$J")" "[\"timeout\",\"$LHEAD\",0.01]" "--timeout 1 with the pipe"
is "$(js r.exit "$(cat "$D/$ID/status.json")")" 124 "status.json after --timeout 1"
sleep 0.5; ! pgrep -f "$EV" > /dev/null || fail "delegate-events still running after the timeout"
ok "the pipe keeps the exit code of timeout: 124 is timeout, --timeout 1 fetches what was committed; no filter left"

# 23b. a process that outlives nc-work and keeps the filter's pipe open: the filter is ended 10 s after the run
start; touch "$T/orphan"; mkev "$T/events" 0.02
s0=$SECONDS
bash "$RC/cli/delegate-run.sh" "$ID" > "$T/runner.log" 2>&1 || true
rm "$T/orphan"
[ $((SECONDS - s0)) -lt 30 ] || fail "delegate-run.sh waited $((SECONDS - s0)) s for an orphaned writer"
is "$(js r.exit "$(cat "$D/$ID/status.json")")" 0 "status.json with an orphaned writer"
! pgrep -f "$EV" > /dev/null || fail "delegate-events still running with an orphaned writer"
pkill -f "^sleep 300$" || true
expect 0 "" nc delegate --result "$ID"
is "$(js r.cost_usd "$(cat "$T/out")")" 0.02 "cost with an orphaned writer"
ok "an orphaned writer on the pipe: the filter is ended after at most 10 s, status.json and cost_usd are there"

# 23c. a signal after wait has returned (stop_filter waits for a pipe still held open) keeps the real exit code;
# a second signal after status.json does not cut stop_filter short
start; echo 6 > "$T/orphan_sleep"; mkev "$T/events" 0.02; rm -f "$T/opencode.argv"
setsid bash "$RC/cli/delegate-run.sh" "$ID" > "$T/runner.log" 2>&1 & runner=$!
for _ in $(seq 100); do [ -f "$T/opencode.argv" ] && break; sleep 0.1; done
[ -f "$T/opencode.argv" ] || fail "delegate-run.sh did not start nc-work opencode: $(cat "$T/runner.log")"
sleep 1   # the fake nc-work has ended with 0; the orphan keeps the filter alive for a few more seconds
pgrep -f "^sleep 6$" > /dev/null || fail "no orphan holds the pipe"
[ ! -f "$D/$ID/status.json" ] || fail "status.json before the filter ended"
kill -HUP "$runner"
for _ in $(seq 20); do [ -f "$D/$ID/status.json" ] && break; sleep 0.1; done
[ -f "$D/$ID/status.json" ] || fail "no status.json within 2 s of a late SIGHUP"
kill -HUP "$runner" 2>/dev/null || true
wait "$runner" || true
rm "$T/orphan_sleep"
is "$(js r.exit "$(cat "$D/$ID/status.json")")" 0 "status.json exit after a late HUP"
! pgrep -f "$EV" > /dev/null || fail "delegate-events still running after a late HUP: $(pgrep -fa delegate-events)"
pkill -f "^sleep 6$" || true
ok "a late SIGHUP during stop_filter keeps exit 0 in status.json; a second one leaves no filter"

# 24. policy: isolation without nc-work, a harness without isolation/require, requireContainer
cd "$SITE"; rm -rf "$D"; mkdir -p "$D"; : > "$T/calls.log"
expect 1 "class cheap in $SITE only in a container (isolation) – without nc-work no worker" env PATH="${BASE_PATH%:}" "$RC/bin/nc" delegate --role tester --task x
grep -q "workers exist only on the server" "$T/err" && fail "the no-nc-work text named for an isolation class"
expect 1 "class standard in $P/acme/website only in a container" env PATH="${BASE_PATH%:}" "$RC/bin/nc" delegate --role implementer --task x --repo "$P/acme/website"
expect 1 "nc-work not found – no container, no worker; workers exist only on the server" env PATH="${BASE_PATH%:}" "$RC/bin/nc" delegate --role implementer --task x
RO="$T/repo-old"; cp -a "$RC" "$RO"; mv "$RO/bin/nc" "$RO/bin/nc.real"
printf '%s\n' '#!/usr/bin/env bash' 'if [ "${1:-} ${2:-}" = "models resolve" ]; then' \
  '  out="$("$(dirname "$0")/nc.real" "$@")"; rc=$?; printf "%s\n" "$out" | sed "s/,\"isolation\":[^,]*,\"require\":\[[^]]*\]//"; exit $rc' \
  'fi' 'exec "$(dirname "$0")/nc.real" "$@"' > "$RO/bin/nc"; chmod 755 "$RO/bin/nc"
"$RO/bin/nc" models resolve --role tester --json | grep -q isolation && fail "fixture: old harness still says isolation"
expect 2 "harness too old" "$RO/bin/nc" delegate --role tester --task x
nothing_created "policy refusals"
is "$(cd "$RC" && bun -e 'import { requireContainer as r } from "./cli/delegate.ts"; console.log([r("container", false), r(null, false), r("container", true), r(null, true)].join(" "))')" \
  "isolation no-container ok ok" "requireContainer"
ok "without nc-work an isolation class gets the isolation refusal, another one the server-only one; an old bin/nc is exit 2; requireContainer"

# 25. broker requests on a client path: what the request names or claims is never the policy
: > "$T/calls.log"; rm -rf "$D"; mkdir -p "$D"
for c in 'free|"model":"openrouter/acme/tiny:free"|a free model' 'auto|"model":"openrouter/openrouter/auto"|a router or alias' \
         'paid|"model":"openrouter/other/paid-1"|not approved' 'project|"project":"personal/x"|unknown field' \
         'class|"class":"standard"|unknown field'; do
  IFS='|' read -r name kv pat <<<"$c"
  printf '{"v":1,"type":"delegate","role":"implementer","task":"x",%s}' "$kv" > "$B/c-$name.json"
  breq "$B/c-$name.json" agency/clients/globex acme; bwant refused 1 "$pat" "client request $name"
done
printf '{"v":1,"type":"delegate","role":"researcher","task":"x"}' > "$B/c-researcher.json"
breq "$B/c-researcher.json" agency/clients/globex acme; bwant refused 1 "researcher blocked as a worker (for good)" "client request researcher"
nothing_created "client requests"
ok "broker on a client path: free model, router, foreign paid model, project, class and researcher are refused; no worker"

# 26. --list: read-only JSONL of the run folders, oldest first; a broken folder is listed as unreadable
rm -rf "$D"; mkdir -p "$D"
lreq() {  # lreq <id> <role> <started>: a minimal valid request.json
  mkdir -p "$D/$1"
  printf '{"task_id":"%s","role":"%s","class":"cheap","model":"m","model_override":null,"profile":"site","checkout":"%s","base":"%s","timeout_min":20,"started":"%s"}' \
    "$1" "$2" "$SITE" "$BASE" "$3" > "$D/$1/request.json"
}
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
lreq d1117-1000-aaaa tester "$NOW"                  # running: no result.json, no status.json, deadline ahead
lreq d1117-0930-dddd tester "$NOW"                  # ended through status.json alone: its deadline is still ahead
#   (same start as aaaa: equal times keep name order, so dddd comes right before aaaa)
printf '{"exit":0,"ended":"2026-11-16T09:40:00Z"}' > "$D/d1117-0930-dddd/status.json"
lreq d1117-0700-eeee implementer 2026-11-16T07:00:00Z  # ended: no status.json, but its deadline (20 min + grace) has passed
lreq d1117-0900-bbbb implementer 2026-11-16T09:00:00Z
printf '{"task_id":"d1117-0900-bbbb","status":"done","cost_usd":0.0123,"over_budget":false}\n' > "$D/d1117-0900-bbbb/result.json"
mkdir "$D/d1117-0800-cccc"; echo '{broken' > "$D/d1117-0800-cccc/request.json"
echo stray > "$D/stray-file"
before="$(cd "$D" && { find . | LC_ALL=C sort; find . -type f | LC_ALL=C sort | xargs cat; } | cksum)"
expect 0 "" nc delegate --list
is "$(wc -l < "$T/out" | tr -d ' ')" 5 "--list lines"
is "$(sed -n 1p "$T/out")" '{"task_id":"d1117-0700-eeee","role":"implementer","status":"ended","started_at":"2026-11-16T07:00:00Z","collected":false}' "--list past the deadline: ended"
is "$(js r.task_id "$(sed -n 2p "$T/out")")" d1117-0900-bbbb "--list second (oldest first)"
is "$(sed -n 2p "$T/out")" '{"task_id":"d1117-0900-bbbb","role":"implementer","status":"done","started_at":"2026-11-16T09:00:00Z","collected":true,"cost_usd":0.0123,"over_budget":false}' "--list collected line"
is "$(sed -n 3p "$T/out")" "{\"task_id\":\"d1117-0930-dddd\",\"role\":\"tester\",\"status\":\"ended\",\"started_at\":\"$NOW\",\"collected\":false}" "--list ended through status.json"
is "$(sed -n 4p "$T/out")" "{\"task_id\":\"d1117-1000-aaaa\",\"role\":\"tester\",\"status\":\"running\",\"started_at\":\"$NOW\",\"collected\":false}" "--list running line"
is "$(js r.task_id "$(sed -n 5p "$T/out")")" d1117-0800-cccc "--list unreadable task_id"
is "$(js r.status "$(sed -n 5p "$T/out")")" unreadable "--list unreadable status"
[ -n "$(js r.reason "$(sed -n 5p "$T/out")")" ] || fail "--list unreadable without reason"
is "$(cd "$D" && { find . | LC_ALL=C sort; find . -type f | LC_ALL=C sort | xargs cat; } | cksum)" "$before" "--list changed a run folder"
expect 2 "takes no other options" nc delegate --list --wait
expect 2 "unknown option or argument" nc delegate --list x
expect 1 "host-only" env NC_HARNESS_VERSION=1 "$RC/bin/nc" delegate --list
rm -rf "$D"; mkdir -p "$D"
expect 0 "" nc delegate --list
[ ! -s "$T/out" ] || fail "--list without runs printed: $(cat "$T/out")"
ok "--list: JSONL oldest first with cost, an ended and a running run, an unreadable folder, read-only; other options exit 2, container exit 1, no runs no output"

echo "$pass passed"
