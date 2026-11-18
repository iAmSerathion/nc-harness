#!/usr/bin/env bash
# Tests for nc orchestrator status (the writer of the nc-orchestrator card's status file). No network, no keys,
# throwaway $HOME with a fake ~/.claude/sessions/<pid>.json; the real ~/.claude is never touched.
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
export HOME="$T/home"
mkdir -p "$HOME/.claude/sessions"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok   $*"; pass=$((pass + 1)); }
nc()   { "$REPO/bin/nc" "$@"; }
expect() {  # expect <exit code> <pattern on stderr, or ''> <command…>; stdout in $T/out, stderr in $T/err
  local want="$1" pat="$2" code=0; shift 2
  "$@" > "$T/out" 2> "$T/err" < "${STDIN:-/dev/null}" || code=$?
  [ "$code" = "$want" ] || fail "exit $code, expected $want: $* – $(cat "$T/err")"
  [ -z "$pat" ] || grep -q -- "$pat" "$T/err" || fail "$*: expected '$pat' on stderr, got: $(cat "$T/err")"
}
SID="sess-0001-abcd"
DIR="$HOME/.claude/nc-orchestrator"
F="$DIR/$SID.json"
export CLAUDE_CODE_SESSION_ID="$SID"
st() { expect 0 '' nc orchestrator status "$@"; valid; }
# valid: the file is JSON v3 with exactly the contract's keys and types, and no tmp file is left.
valid() {
  bun -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const keys = (o, k) => JSON.stringify(Object.keys(o).sort()) === JSON.stringify(k.sort()) || die("keys " + Object.keys(o));
    const die = (m) => { console.error(m); process.exit(1); };
    const str = (v, n) => (typeof v === "string" && [...v].length <= n) || die("string " + JSON.stringify(v));
    const strn = (v, n) => v === null || str(v, n);
    keys(s, ["v", "updated", "crew", "reason", "state", "musts", "phases"]);
    s.v === 3 && Number.isInteger(s.updated) || die("v/updated");
    ["one", "pair", "team"].includes(s.crew) || die("crew");
    ["planning", "awaiting_approval", "running", "closing", "done", "error"].includes(s.state) || die("state");
    str(s.reason, 80);
    s.musts.length <= 12 || die("musts");
    s.musts.forEach((c) => { keys(c, ["id", "text"]); str(c.text, 80); });
    s.phases.length <= 8 || die("phases");
    let n = 0;
    for (const p of s.phases) {
      keys(p, ["name", "lanes"]); str(p.name, 40); p.lanes.length <= 6 || die("lanes");
      for (const l of p.lanes) for (const t of (keys(l, ["id", "tasks"]), l.tasks)) {
        n++;
        keys(t, ["id", "title", "role", "status", "files", "proof", "after", "musts", "redos", "branch", "delegate", "review", "answers", "evidence"]);
        str(t.title, 60); str(t.role, 20); strn(t.proof, 80); strn(t.branch, 60); strn(t.delegate, 40); strn(t.review, 20); strn(t.evidence, 100);
        ["pending", "running", "review", "redo", "pass", "fail", "blocked", "conflict"].includes(t.status) || die("status");
        t.files.length <= 8 || die("files"); t.files.forEach((f) => str(f, 80));
        Number.isInteger(t.redos) || die("redos");
        Object.values(t.answers).every((v) => v === "kept" || v === "broken") || die("answers");
      }
    }
    n <= 40 || die("tasks");
  ' "$F" || fail "status file not valid: $(cat "$F")"
  ! ls "$DIR" | grep -q '\.tmp$' || fail "tmp file left in $DIR"
}
get() { bun -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(JSON.stringify(eval(process.argv[2])))' "$F" "$1"; }
is() { [ "$1" = "$2" ] || fail "$3: got $1, expected $2"; }
task() { get "(t => t.$2)(s.phases.flatMap(p => p.lanes.flatMap(l => l.tasks)).find(t => t.id === '$1'))"; }

# 1. crew: a new file; team starts in planning, one in running; a new crew drops the old plan
st crew team split into two parts
is "$(get 's.crew + "|" + s.state + "|" + s.reason')" '"team|planning|split into two parts"' "crew team"
is "$(stat -c %a "$DIR" 2>/dev/null || stat -f %Lp "$DIR")" 700 "folder mode"
cat > "$T/plan" <<'EOF'
Crew: team – two parts
```
Musts:
  M1 no new dependency – proof: git diff --stat -- package.json is empty
  M2 English only
Phase 1: Interface
  Lane A:
    A1 write interface – role: implementer – files: cli/a.ts, cli/b.ts – proof: bun test - all green – musts: M1
Phase 2: Build
  Lane A:
    A2 write tests - role: tester - files: tests/x.sh tests/y.sh - after: A1 - proof: bash tests/x.sh
  Lane B:
    B1 build it – musts: M1, M2 – after: A1, A2 – role: implementer
    B2 no fields
  Lane C:
    just prose without an id-title pair
```
EOF
STDIN="$T/plan" st plan
is "$(get 's.state + "|" + s.crew')" '"awaiting_approval|team"' "plan state"
is "$(get 's.musts')" '[{"id":"M1","text":"no new dependency – proof: git diff --stat -- package.json is empty"},{"id":"M2","text":"English only"}]' "musts"
is "$(get 's.phases.map(p => p.name + ":" + p.lanes.map(l => l.id + l.tasks.map(t => t.id).join("")).join(","))')" '["Interface:AA1","Build:AA2,BB1B2,C"]' "phases and lanes"
is "$(task A1 files)" '["cli/a.ts","cli/b.ts"]' "A1 files (commas)"
is "$(task A1 proof)" '"bun test - all green"' "A1 proof keeps an ascii dash inside"
is "$(task A2 files)" '["tests/x.sh","tests/y.sh"]' "A2 files (ascii dash, whitespace)"
is "$(task A2 after)" '["A1"]' "A2 after"
is "$(task B1 'after.join() + "|" + t.musts.join() + "|" + t.role')" '"A1,A2|M1,M2|implementer"' "B1 fields in any order"
is "$(task B2 'title + "|" + t.role + "|" + t.proof + "|" + t.status + "|" + t.redos')" '"no fields||null|pending|0"' "B2 defaults"
ok "crew starts a file (folder 0700); plan: musts, 2 phases / 3 lanes, en dash and ascii dash, files/after/musts/proof, defaults"

st crew one small fix
is "$(get 's.crew + "|" + s.state + "|" + s.phases.length + "|" + s.musts.length')" '"one|running|0|0"' "crew resets"
ok "a new crew drops the old plan"

# 2. task status changes
STDIN="$T/plan" st plan
st state running
is "$(get 's.state')" '"running"' "state running"
st task A1 running branch=worktree-agent-a1
st task A1 review review=findings:2
st task A1 redo missing test for the empty case
st task A1 redo
st task A1 pass M1=kept M2=broken bash tests/x.sh: 12 ok
is "$(task A1 'status + "|" + t.redos + "|" + t.branch + "|" + t.review + "|" + t.evidence')" '"pass|2|worktree-agent-a1|findings:2|bash tests/x.sh: 12 ok"' "A1 after the loop"
is "$(task A1 answers)" '{"M1":"kept","M2":"broken"}' "A1 must answers"
st task B1 running delegate=d-0042
is "$(task B1 'delegate + "|" + t.status')" '"d-0042|running"' "B1 delegate"
for s in conflict blocked fail pending; do st task B2 "$s"; is "$(task B2 status)" "\"$s\"" "B2 $s"; done
st state closing
st state done
is "$(get 's.state')" '"done"' "state done"
ok "task: running/review/redo (counted twice)/pass, branch, delegate, review, must answers, evidence; states"

# 3. wrong usage: exit 2, file unchanged
before="$(cat "$F")"
expect 2 'unknown task id "Z9"' nc orchestrator status task Z9 pass
expect 2 'task status "done"' nc orchestrator status task A1 done
expect 2 'a must answer is kept or broken' nc orchestrator status task A1 pass M1=pass
expect 2 'state "finished"' nc orchestrator status state finished
expect 2 'crew "solo"' nc orchestrator status crew solo
expect 2 'crew "big"' nc orchestrator status crew big
expect 2 'unknown command "lane"' nc orchestrator status lane team
expect 2 'unknown command "bogus"' nc orchestrator status bogus
expect 2 'give a command' nc orchestrator status
printf 'Phase 1: x\n  Lane A:\n\nsome prose\n' > "$T/empty"
STDIN="$T/empty" expect 2 'no task line' nc orchestrator status plan
printf 'Phase 1: x\n  Lane A:\n    A1 one\n    A1 two\n' > "$T/dup"
STDIN="$T/dup" expect 2 'appears twice' nc orchestrator status plan
[ "$(cat "$F")" = "$before" ] || fail "file changed by wrong usage"
expect 2 'does not have the form' nc orchestrator status/x
ok "unknown task id, bad task status / must answer / state / crew / command, plan without tasks or with a duplicate id: exit 2, file unchanged"

# 4. caps
long="$(printf 'x%.0s' $(seq 200))"
{
  echo "Musts:"; for i in $(seq 1 14); do echo "  M$i $long"; done
  for p in $(seq 1 9); do
    echo "Phase $p: $long"
    for l in A B C D E F G; do
      echo "  Lane $l:"
      echo "    $l${p}1 $long – role: $long – proof: $long – files: $(for i in $(seq 10); do printf '%s%s, ' "$long" "$i"; done)"
    done
  done
} > "$T/big"
STDIN="$T/big" st plan
is "$(get 's.musts.length + "|" + s.phases.length + "|" + s.phases[0].lanes.length + "|" + s.phases.flatMap(p => p.lanes.flatMap(l => l.tasks)).length')" '"12|8|6|40"' "caps on counts"
is "$(get 's.phases[6].lanes.map(l => l.tasks.length).join()')" '"1,1,1,1,0,0"' "tasks beyond 40 dropped"
{ echo "Phase 1: many"; echo "  Lane A:"; for i in $(seq 1 45); do echo "    A$i task $i"; done; } > "$T/many"
STDIN="$T/many" st plan
is "$(get 's.phases[0].lanes[0].tasks.length')" 40 "task cap"
expect 2 'unknown task id "A41"' nc orchestrator status task A41 pass
STDIN="$T/big" st plan
st task A11 pass "branch=$long" "delegate=$long" "review=$long" "$long"
is "$(task A11 'branch.length + "|" + t.delegate.length + "|" + t.review.length + "|" + t.evidence.length + "|" + t.files.length')" '"60|40|20|100|8"' "caps on fields"
st crew pair "$long"
is "$(get 's.reason.length')" 80 "reason cap"
ok "caps: 12 musts, 8 phases (9th dropped), 6 lanes, 40 tasks, 8 files, all string lengths"

# 5. session id: CLAUDE_PID fallback, invalid id, none at all
expect 0 "" nc orchestrator status clear
[ ! -e "$F" ] || fail "clear left the file"
expect 0 '' nc orchestrator status clear
unset CLAUDE_CODE_SESSION_ID
echo '{"pid":4242,"sessionId":"from-pid-file-1234"}' > "$HOME/.claude/sessions/4242.json"
CLAUDE_PID=4242 expect 0 '' nc orchestrator status crew one
[ -f "$DIR/from-pid-file-1234.json" ] || fail "CLAUDE_PID fallback wrote no file"
rm -rf "$DIR"
expect 0 'warning: no session id' nc orchestrator status crew one
[ ! -e "$DIR" ] || fail "file written without a session id"
CLAUDE_PID=9999 expect 0 'warning: no session id' nc orchestrator status state done
CLAUDE_CODE_SESSION_ID="../../etc" expect 0 'warning: no session id' nc orchestrator status crew one
CLAUDE_CODE_SESSION_ID="short" expect 0 'warning: no session id' nc orchestrator status crew one
[ ! -e "$DIR" ] || fail "file written with an invalid session id"
CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PID=4242 expect 0 '' nc orchestrator status crew one
[ -f "$F" ] && [ ! -e "$DIR/from-pid-file-1234.json" ] || fail "CLAUDE_CODE_SESSION_ID does not win over CLAUDE_PID"
ok "session id from CLAUDE_PID's session file; missing/invalid id: warning, exit 0, no file; clear deletes (also when absent)"

# 6. a failed write is a warning, exit 0
export CLAUDE_CODE_SESSION_ID="$SID"
chmod 500 "$DIR"
expect 0 'warning: .* not written' nc orchestrator status state done
chmod 700 "$DIR"
! ls "$DIR" | grep -q '\.tmp$' || fail "tmp file left after a failed write"
ok "failed write: warning, exit 0, no tmp file"

# 7. the overlay form still works; status is no overlay
expect 0 '' nc orchestrator claude
grep -q '^# Orchestrator' "$T/out" || fail "nc orchestrator claude printed no procedure"
grep -q 'nc orchestrator status' "$T/out" || fail "the procedure does not mention nc orchestrator status"
ok "nc orchestrator claude still prints the procedure, which publishes through nc orchestrator status"

# 8. parallel calls lose no update (lock file); a v3 file of the wrong shape is a warning, exit 0; a file with another version starts over
printf 'Phase 1: p\n  Lane A:\n    A1 one\n  Lane B:\n    B1 two\n  Lane C:\n    C1 three\n' > "$T/par"
st crew team parallel
STDIN="$T/par" st plan
nc orchestrator status task A1 running 2>"$T/e1" & p1=$!
nc orchestrator status task B1 running 2>"$T/e2" & p2=$!
nc orchestrator status task C1 running 2>"$T/e3" & p3=$!
wait $p1 $p2 $p3
valid
is "$(get 's.phases[0].lanes.map(l => l.tasks[0].status).join()')" '"running,running,running"' "three parallel task calls"
[ ! -e "$F.lock" ] || fail "lock file left"
echo '{"v":3,"phases":[{"name":"x"}]}' > "$F"
expect 0 'warning: status file not usable' nc orchestrator status task A1 running
touch -t 202001010000 "$F.lock"
expect 0 '' nc orchestrator status crew one
[ ! -e "$F.lock" ] || fail "stale lock not taken over"
other='{"v":2,"crew":"team","phases":[{"name":"p","lanes":[{"id":"A","tasks":[{"id":"A1"}]}]}]}'
echo "$other" > "$F"
expect 2 'unknown task id "A1"' nc orchestrator status task A1 running
[ "$(cat "$F")" = "$other" ] || fail "a refused task call changed the file with another version"
st state running
is "$(get 's.v + "|" + s.crew + "|" + s.phases.length')" '"3|one|0"' "a file with another version starts over as v3"
ok "parallel calls keep every update; broken v3 shape: warning, exit 0; a stale lock is taken over; a file with another version is replaced"

# 9. status context (the SessionStart hook, matcher compact): the open run as text; nothing when there is no open run
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
CTX="ctx-sess-0001"; OTHER="ctx-other-0002"; DECOY="ctx-decoy-0003"; BAD="ctx-bad-0004"; BIG="ctx-big-0006"
ctx() {  # ctx <stdin text>: nc orchestrator status context with that stdin; output in $T/ctx, exit 0, nothing on stderr
  printf '%s' "$1" > "$T/ctxin"
  STDIN="$T/ctxin" expect 0 '' nc orchestrator status context
  [ ! -s "$T/err" ] || fail "context wrote to stderr: $(cat "$T/err")"
  cp "$T/out" "$T/ctx"
}
CRUMB="Crew: one – fix the lint. State: running."

rm -f "$DIR/$CTX.json"
ctx "{\"session_id\":\"$CTX\",\"hook_event_name\":\"SessionStart\",\"source\":\"compact\"}"
[ ! -s "$T/ctx" ] || fail "no file: output $(cat "$T/ctx")"

CLAUDE_CODE_SESSION_ID="$CTX" expect 0 '' nc orchestrator status crew one fix the lint
ctx "{\"session_id\":\"$CTX\"}"
grep -qxF "$CRUMB" "$T/ctx" || fail "crew line: $(cat "$T/ctx")"
grep -qF "$CTX.json" "$T/ctx" || fail "the header names no file"
! grep -q '^Phase' "$T/ctx" || fail "a crew with no plan prints phases"
ok "crew with no plan: the header, the crew, the reason and the state; no phases"

ctx '{}'   # no session id in the hook input and no environment id: nothing, not even this session's file
[ ! -s "$T/ctx" ] || fail "no session id printed a run"
CLAUDE_CODE_SESSION_ID="$CTX" ctx '{"hook_event_name":"SessionStart"}'   # no session_id in the input: the environment's id
grep -qxF "$CRUMB" "$T/ctx" || fail "environment fallback: $(cat "$T/ctx")"
CLAUDE_CODE_SESSION_ID="$CTX" ctx '{"session_id":5}'   # not a string: the environment's id
grep -qxF "$CRUMB" "$T/ctx" || fail "a non-string session_id: $(cat "$T/ctx")"
ok "session id: from the hook input, else CLAUDE_CODE_SESSION_ID; none at all prints nothing"

# a traversal id in the input is ignored: the decoy sits where ../x.json would point
CLAUDE_CODE_SESSION_ID="$DECOY" expect 0 '' nc orchestrator status crew pair decoy run
cp "$DIR/$DECOY.json" "$HOME/.claude/x.json"
ctx '{"session_id":"../x"}'
[ ! -s "$T/ctx" ] || fail "an invalid id in the input read a file: $(cat "$T/ctx")"
CLAUDE_CODE_SESSION_ID="$CTX" ctx '{"session_id":"../x"}'
grep -qxF "$CRUMB" "$T/ctx" && ! grep -q decoy "$T/ctx" || fail "an invalid id in the input did not fall back to the environment: $(cat "$T/ctx")"
rm -f "$HOME/.claude/x.json"
ok "invalid id in the input (../x) is ignored: nothing read outside the folder, the environment's id is used"

# the id in the input wins over the environment
CLAUDE_CODE_SESSION_ID="$OTHER" expect 0 '' nc orchestrator status crew pair other run
ctx "{\"session_id\":\"$CTX\"}"
grep -qxF "$CRUMB" "$T/ctx" && ! grep -q 'other run' "$T/ctx" || fail "the environment's id won: $(cat "$T/ctx")"
ok "the session_id in the hook input wins over CLAUDE_CODE_SESSION_ID"

# CLAUDE_PID's session file when there is no environment id
unset CLAUDE_CODE_SESSION_ID
echo "{\"pid\":4343,\"sessionId\":\"$CTX\"}" > "$HOME/.claude/sessions/4343.json"
CLAUDE_PID=4343 ctx '{}'
grep -qxF "$CRUMB" "$T/ctx" || fail "CLAUDE_PID fallback: $(cat "$T/ctx")"
ok "session id from CLAUDE_PID's session file when the input and the environment have none"

# garbage on stdin: exit 0, the environment's id is still used; binary garbage too
CLAUDE_CODE_SESSION_ID="$CTX" ctx 'not json {{{'
grep -qxF "$CRUMB" "$T/ctx" || fail "garbage stdin: no fallback: $(cat "$T/ctx")"
head -c 512 /dev/urandom > "$T/ctxin"
CLAUDE_CODE_SESSION_ID="$CTX" STDIN="$T/ctxin" expect 0 '' nc orchestrator status context
[ ! -s "$T/err" ] || fail "binary stdin wrote to stderr: $(cat "$T/err")"
ok "garbage and binary stdin: exit 0, nothing on stderr, the environment's id is used"

# no open run: state done or error prints nothing (exit 0); closing still is an open run
CLAUDE_CODE_SESSION_ID="$CTX" expect 0 '' nc orchestrator status state done
ctx "{\"session_id\":\"$CTX\"}"
[ ! -s "$T/ctx" ] || fail "state done printed: $(cat "$T/ctx")"
CLAUDE_CODE_SESSION_ID="$CTX" expect 0 '' nc orchestrator status state error
ctx "{\"session_id\":\"$CTX\"}"
[ ! -s "$T/ctx" ] || fail "state error printed: $(cat "$T/ctx")"
CLAUDE_CODE_SESSION_ID="$CTX" expect 0 '' nc orchestrator status state closing
ctx "{\"session_id\":\"$CTX\"}"
grep -qF "State: closing." "$T/ctx" || fail "state closing not printed: $(cat "$T/ctx")"
ok "state done and error: nothing, exit 0; closing is still printed"

# a team plan with task results: the musts, phase, lanes and every recorded field of the tasks
cat > "$T/ctxplan" <<'EOF'
Musts:
  M1 no new dependency – proof: git diff --stat is empty
Phase 1: Interface
  Lane A:
    A1 write the interface – role: implementer – files: cli/a.ts – musts: M1 – proof: bun test
  Lane B:
    B1 write the tests – role: tester – after: A1
EOF
CLAUDE_CODE_SESSION_ID="$CTX" STDIN="$T/ctxplan" expect 0 '' nc orchestrator status plan
CLAUDE_CODE_SESSION_ID="$CTX" expect 0 '' nc orchestrator status state running
CLAUDE_CODE_SESSION_ID="$CTX" expect 0 '' nc orchestrator status task A1 pass branch=wt-a1 M1=kept bun test 12 ok
CLAUDE_CODE_SESSION_ID="$CTX" expect 0 '' nc orchestrator status task B1 running delegate=d-7
ctx "{\"session_id\":\"$CTX\"}"
for want in \
  "Crew: team" \
  "State: running." \
  "Musts:" \
  "  M1 no new dependency – proof: git diff --stat is empty" \
  "Phase: Interface" \
  "  Lane A:" \
  "    A1 write the interface – status: pass – role: implementer – files: cli/a.ts – musts: M1 – proof: bun test – branch: wt-a1 – answers: M1=kept – evidence: bun test 12 ok" \
  "  Lane B:" \
  "    B1 write the tests – status: running – role: tester – after: A1 – delegate: d-7"; do
  grep -qF -- "$want" "$T/ctx" || fail "line missing: '$want' in: $(cat "$T/ctx")"
done
ok "team plan with results: musts, phase, lanes, task status, role, files, proof, branch, answers, evidence, delegate, after"

# hand-edited file with wrong types: exit 0, no crash, what is readable is printed
printf '%s' '{"v":3,"updated":"x","crew":["team"],"reason":{"a":1},"state":"running","musts":"M1","phases":[null,{"name":5,"lanes":"x"},{"name":"P","lanes":[{"id":null,"tasks":[null,{"id":"A1","title":7,"status":"pending","files":"a.ts","after":{},"musts":[1,"M1"],"redos":"2","answers":[1,2],"evidence":["x"],"proof":{},"branch":[],"delegate":5,"review":null}]}]}]}' > "$DIR/$BAD.json"
ctx "{\"session_id\":\"$BAD\"}"
grep -q '^    A1 7 – status: pending' "$T/ctx" || fail "the readable task line is missing: $(cat "$T/ctx")"
grep -q '^Phase: P$' "$T/ctx" || fail "the readable phase is missing: $(cat "$T/ctx")"
ok "hand-edited file with wrong types: exit 0, nothing on stderr, the readable parts printed"

# huge file: at most 8000 characters, cut at a line end, with a note
bun -e '
  const task = (l, i) => ({ id: l + i, title: "t".repeat(60), role: "r".repeat(20), status: "running", files: Array(8).fill("f".repeat(80)),
    proof: "p".repeat(80), after: ["A1"], musts: ["M1"], redos: 1, branch: "b".repeat(60), delegate: "d".repeat(40), review: "v".repeat(20),
    answers: { M1: "kept" }, evidence: "e".repeat(100) });
  const lanes = () => "ABCDEF".split("").map((l) => ({ id: l, tasks: Array.from({ length: 40 }, (_, i) => task(l, i + 1)) }));
  const phases = Array.from({ length: 8 }, (_, p) => ({ name: "P" + p, lanes: lanes() }));
  require("fs").writeFileSync(process.argv[1], JSON.stringify({ v: 3, updated: 1, crew: "team", reason: "", state: "running", musts: [], phases }));
' "$DIR/$BIG.json"
ctx "{\"session_id\":\"$BIG\"}"
[ "$(bun -e 'console.log(require("fs").readFileSync(process.argv[1], "utf8").length)' "$T/ctx")" -le 8000 ] || fail "the output is over 8000 characters"
tail -n 1 "$T/ctx" | grep -q '^… (cut' || fail "no cut note at the end: $(tail -n 1 "$T/ctx")"
grep -q '^nc orchestrator: this session' "$T/ctx" || fail "the header is missing after the cut"
ok "huge file: at most 8000 characters, cut at a line end with a note, the header kept"

echo "all $pass tests passed"
