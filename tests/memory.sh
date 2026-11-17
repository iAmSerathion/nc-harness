#!/usr/bin/env bash
# Tests for nc memory and its nc doctor checks, apply --broker, the lock and the client through the broker. No network, no keys: the "GitHub" remote is a local bare repo,
# the nc-work container is simulated by a read-only view, an outbox and the environment nc-work sets.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUN_DIR="$(dirname "$(mise which bun 2>/dev/null || command -v bun)")"
export PATH="$BUN_DIR:$PATH"
# Server tests: the lock, the deadline and the runner's own session need util-linux and coreutils.
for b in flock timeout setsid; do
  command -v "$b" > /dev/null || { echo "skipped: needs flock, timeout, setsid (server test)"; exit 0; }
done
unset NC_HOME NC_MACHINE NC_HARNESS_VERSION NC_MEMORY_DIR NC_MEMORY_OUTBOX NC_PROJECT XDG_CONFIG_HOME GH_TOKEN GITHUB_TOKEN \
  NC_REQUESTS NC_INBOX NC_MEMORY_LOCKED NC_MEMORY_LOCK_S NC_DELEGATE_STALE_S NC_DELEGATE_ANSWER_S NC_MEMORY_START NC_MEMORY_BUDGET_S NC_MEMORY_TEST_DIE || true
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@invalid
export GIT_CONFIG_NOSYSTEM=1

T="$(mktemp -d)"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig"   # git config --global never reaches the real one
mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global pull.rebase true

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok   $*"; pass=$((pass + 1)); }
nc()   { "$REPO/bin/nc" "$@"; }
M="$HOME/.nc/memory"
A="$M/projects/alpha.md"
B="$M/projects/beta.md"
D="$(date +%F)"
commits() { git -C "$T/remote.git" rev-list --count main; }
refused() {  # refused <pattern> <nc args…>: must fail with a message matching pattern, and write nothing
  local pat="$1"; shift
  local before; before="$(cat "$A")"
  if nc "$@" > "$T/out" 2>&1; then fail "accepted: nc $*"; fi
  grep -q -- "$pat" "$T/out" || fail "nc $*: expected '$pat', got: $(cat "$T/out")"
  [ "$(cat "$A")" = "$before" ] || fail "nc $* changed alpha.md"
}

# Fixture: a memory repo with two projects, pushed to a bare "remote", cloned to ~/.nc/memory.
mkdir -p "$T/seed/global" "$T/seed/projects" "$T/seed/journal"
printf '# Index\n' > "$T/seed/MEMORY.md"
printf '# Tools\n\n- 2026-01-01: global hint\n' > "$T/seed/global/tools.md"
printf '# alpha\n\nHead\n\n' > "$T/seed/projects/alpha.md"
printf '# beta\n\nHead\n\n- 2026-01-01: beta secret sauce recipe\n' > "$T/seed/projects/beta.md"
printf '# 2026-01-01\n' > "$T/seed/journal/2026-01-01.md"
git init -q --bare "$T/remote.git"
git -C "$T/seed" init -q && git -C "$T/seed" add -A && git -C "$T/seed" commit -qm seed
git -C "$T/seed" push -q "$T/remote.git" main
mkdir -p "$HOME/.nc" && git clone -q "$T/remote.git" "$M"

# 1. limits: too long, empty, no project, secrets, control characters, unknown project – all refused whole
c0="$(commits)"
refused "501 characters, at most 500" memory add --project alpha "$(printf 'x%.0s' {1..501})"
refused "empty note" memory add --project alpha "   "
refused "empty note" memory add --project alpha
refused "\-\-project missing" memory add "a note without project"
refused "looks like a secret (sk-" memory add --project alpha "key is sk-or-v1-abcdef0123456789"
refused "looks like a secret (ghp_" memory add --project alpha "token ghp_abcdefghijklmnop1234"
refused "looks like a secret (-----BEGIN" memory add --project alpha -- "-----BEGIN OPENSSH PRIVATE KEY----- abc"
refused "looks like a secret (API_KEY=" memory add --project alpha "set OPENROUTER_API_KEY=abc in the file"
refused "control characters" memory add --project alpha "$(printf 'bell \a here')"
# invisible characters as UTF-8 bytes from printf, so the test does not depend on locale or bash version
refused "invisible characters (U+200B)" memory add --project alpha "$(printf 'zero\xe2\x80\x8bwidth')"
refused "invisible characters (U+202E)" memory add --project alpha "$(printf 'bidi \xe2\x80\xaeoverride')"
refused "invisible characters (U+FEFF)" memory add --project alpha "$(printf '\xef\xbb\xbfbom first')"
refused "invisible characters (U+E0041)" memory add --project alpha "$(printf 'tag \xf3\xa0\x81\x81 char')"
refused "invisible characters (U+00AD)" memory add --project alpha "$(printf 'soft\xc2\xadhyphen')"
refused "invisible characters (U+3164)" memory add --project alpha "$(printf 'hangul \xe3\x85\xa4 filler')"
refused "invisible characters (U+FE0E)" memory add --project alpha "$(printf 'variation \xef\xb8\x8e selector')"
refused "invisible characters (U+E0100)" memory add --project alpha "$(printf 'variation \xf3\xa0\x84\x80 supplement')"
refused "invisible characters" memory add --project alpha --replaces "$(printf 'x\xe2\x81\xa6y')" "valid note"
refused "no memory for project gamma" memory add --project gamma "valid note"
refused "invalid project name" memory add --project ../beta "valid note"
refused "unknown option --projct" memory add --projct alpha "typo in the flag"
[ "$(commits)" = "$c0" ] || fail "a refused note was committed"
grep -q "task-runner" <<<"$(nc memory add --project alpha 'use the task-runner skill' && cat "$A")" || fail "sk- inside a word was taken for a secret"
nc memory add --project alpha "$(printf 'emoji \xe2\x9d\xa4\xef\xb8\x8f stays')" > /dev/null || fail "U+FE0F (emoji presentation) refused"
ok "too long, empty, no project, secrets, control or invisible characters, unknown project: refused, nothing written"

# 2. add: one line with date in the right file, committed and pushed; beta untouched
nc memory add --project alpha "Build with bun run build," "then bun test" > "$T/out"
grep -qx -- "- $D: Build with bun run build, then bun test" "$A" || fail "note not in alpha.md: $(cat "$A")"
git -C "$T/remote.git" show main:projects/alpha.md | grep -q "Build with bun run build" || fail "note not pushed"
[ "$(cat "$B")" = "$(git -C "$T/seed" show HEAD:projects/beta.md)" ] || fail "beta.md changed"
nc memory add --project alpha "$(printf 'y%.0s' {1..500})" > /dev/null || fail "500 characters refused"
ok "add writes one dated line into projects/alpha.md and pushes it; 500 characters pass"

# 3. same note again: no duplicate; an older copy gets today's date; --replaces rewrites, must exist
c1="$(commits)"
nc memory add --project alpha "build with BUN run build, then bun test" | grep -q "unchanged" || fail "same note not recognised"
[ "$(grep -c "Build with bun run build" "$A")" = 1 ] && [ "$(commits)" = "$c1" ] || fail "duplicate or empty commit"
sed -i "s/^- $D: Build with/- 2025-01-01: Build with/" "$A" && git -C "$M" commit -qam old && git -C "$M" push -q
nc memory add --project alpha "Build with bun run build, then bun test" | grep -q "refreshed" || fail "not refreshed"
grep -qx -- "- $D: Build with bun run build, then bun test" "$A" && ! grep -q 2025-01-01 "$A" || fail "date not refreshed: $(cat "$A")"
nc memory add --project alpha --replaces "Build with bun run build, then bun test" "Build with bun run build; tests with bun test" | grep -q replaced
grep -q "tests with bun test" "$A" && ! grep -q "then bun test" "$A" || fail "--replaces did not rewrite"
refused "not found" memory add --project alpha --replaces "no such note" "new text"
ok "same note refreshes the date instead of duplicating; --replaces rewrites and needs an existing note"

# 3b. a "- YYYY-MM-DD: " prefix copied along from nc memory show is cut off, once or twice; --replaces takes a whole line
nc memory add --project alpha "- 2026-01-02: - 2026-01-02: copied with its date" > /dev/null
grep -qx -- "- $D: copied with its date" "$A" || fail "date prefix not cut off: $(grep 'copied with' "$A")"
nc memory add --project alpha "2026-01-02:bare date prefix" > /dev/null
grep -qx -- "- $D: bare date prefix" "$A" || fail "bare date prefix not cut off: $(grep 'bare date' "$A")"
nc memory add --project alpha --replaces "- $D: copied with its date" "copied, then replaced" | grep -q replaced || fail "--replaces with a whole line did not match"
grep -qx -- "- $D: copied, then replaced" "$A" && ! grep -q "copied with its date" "$A" || fail "--replaces with a whole line did not rewrite"
refused "empty note" memory add --project alpha "- 2026-01-02: "
nc memory add --project alpha "since 2026-01-02: dates inside stay" > /dev/null
grep -qx -- "- $D: since 2026-01-02: dates inside stay" "$A" || fail "a date inside the note was cut"
# a line already stored with a doubled date (from before the fix) is found and repaired by --replaces
echo "- 2026-01-03: - 2026-01-03: legacy doubled date" >> "$A" && git -C "$M" commit -qam legacy && git -C "$M" push -q
nc memory add --project alpha --replaces "- 2026-01-03: - 2026-01-03: legacy doubled date" "legacy repaired" | grep -q replaced || fail "doubled legacy line not found"
grep -qx -- "- $D: legacy repaired" "$A" && ! grep -q "legacy doubled" "$A" || fail "doubled legacy line not repaired: $(cat "$A")"
ok "a copied date prefix is cut off (also twice and without the dash); --replaces matches a whole line and repairs doubled ones; inner dates stay"

# 4. line limit: a project file never grows past 100 lines
cp "$A" "$T/alpha.bak"
for i in $(seq "$(wc -l < "$A")" 99); do echo "- 2026-01-01: filler $i" >> "$A"; done
git -C "$M" commit -qam fill && git -C "$M" push -q
[ "$(wc -l < "$A")" = 100 ] || fail "fixture: $(wc -l < "$A") lines"
refused "101 lines, at most 100" memory add --project alpha "one too many"
nc memory add --project alpha "filler 50" > /dev/null || fail "refreshing within the limit refused"
cp "$T/alpha.bak" "$A" && git -C "$M" commit -qam unfill && git -C "$M" push -q
ok "a note that would make the project file 101 lines is refused; refreshing still works"

# 5. dirty checkout and rebase conflict: refused, nothing overwritten, rebase aborted
echo "local edit" >> "$A"
refused "uncommitted changes" memory add --project alpha "while dirty"
git -C "$M" checkout -q -- projects/alpha.md
git clone -q "$T/remote.git" "$T/other"
sed -i 's/^Head$/Head from elsewhere/' "$T/other/projects/alpha.md" && git -C "$T/other" commit -qam other && git -C "$T/other" push -q
sed -i 's/^Head$/Head from here/' "$A" && git -C "$M" commit -qam here
refused "pull --rebase failed" memory add --project alpha "during a conflict"
[ -z "$(git -C "$M" status --porcelain)" ] && [ ! -d "$M/.git/rebase-merge" ] && [ ! -d "$M/.git/rebase-apply" ] || fail "rebase left behind"
grep -q "Head from here" "$A" || fail "local commit lost"
git -C "$M" reset -q --hard origin/main && git -C "$M" pull -q
ok "dirty checkout and rebase conflict: refused, nothing written, no rebase left behind"

# 6. sync pulls remote changes and pushes local commits
git -C "$T/other" pull -q && echo "- 2026-01-02: from elsewhere" >> "$T/other/global/tools.md" && git -C "$T/other" commit -qam b && git -C "$T/other" push -q
echo "- 2026-01-03: local only" >> "$B" && git -C "$M" commit -qam local
nc memory sync > /dev/null || fail "sync failed"
grep -q "from elsewhere" "$M/global/tools.md" && git -C "$T/remote.git" show main:projects/beta.md | grep -q "local only" || fail "sync did not pull and push"
ok "sync pulls and pushes"

# 7. search and show, direct: everything, or one project plus the shared files
nc memory search "SECRET SAUCE" | grep -q "^projects/beta.md:" || fail "direct search misses beta"
if nc memory search "secret sauce" --project alpha > /dev/null 2>&1; then fail "search --project alpha found beta's note"; fi
nc memory search "global hint" --project alpha | grep -q "^global/tools.md:" || fail "search --project drops global/"
nc memory show --project alpha | grep -q "=== projects/alpha.md ===" || fail "show --project"
nc memory show | grep -q "secret sauce" && fail "show without project prints project files"
ok "direct search covers everything, --project narrows to the project plus MEMORY.md and global/"

# 8. isolated: read-only view of MEMORY.md, global/ and the own project (as nc-work builds it), writable outbox
V="$T/view"; O="$T/outbox"
mkdir -p "$V/projects" "$O" && cp -r "$M/MEMORY.md" "$M/global" "$V/" && cp "$A" "$V/projects/"
chmod -R a-w "$V"
iso() { NC_HARNESS_VERSION=0123456789abcdef NC_PROJECT=alpha NC_MEMORY_DIR="$V" NC_MEMORY_OUTBOX="$O" nc "$@"; }
iso memory show | grep -q "=== projects/alpha.md ===" || fail "isolated show lacks the own project"
iso memory search "tests with bun test" | grep -q "^projects/alpha.md:" || fail "isolated search misses the own note"
if iso memory search "secret sauce" > /dev/null 2>&1; then fail "isolated search found another project's note"; fi
iso memory add "Isolated note from the container" | grep -q "request .* in the outbox" || fail "isolated add"
iso memory add --project alpha "Second note" > /dev/null || fail "isolated add with own project"
[ "$(ls "$O" | wc -l)" = 2 ] || fail "expected two requests: $(ls -a "$O")"
bun -e 'for (const f of process.argv.slice(1)) { const r = await Bun.file(f).json();
  if (Object.keys(r).sort().join() !== "text,ts,v" || r.v !== 1 || isNaN(Date.parse(r.ts))) process.exit(1) }' "$O"/*.json \
  || fail "request format: $(cat "$O"/*.json)"
grep -q "Isolated note" "$A" && fail "isolated add wrote into the memory checkout"
ok "isolated: show and search see only the own project; add writes {v,ts,text} requests, no project field"

# 9. isolated refusals: other project, limits, secrets, sync/apply, missing mounts
n="$(ls "$O" | wc -l)"
for args in "memory add --project beta note for beta" "memory add $(printf 'z%.0s' {1..501})" "memory add has ghp_abcdefghijklmnop1234" "memory add" "memory sync" "memory apply --outbox $O --project alpha"; do
  # shellcheck disable=SC2086
  if iso $args > /dev/null 2>&1; then fail "isolated accepted: $args"; fi
done
[ "$(ls "$O" | wc -l)" = "$n" ] || fail "a refused isolated note reached the outbox"
{ iso memory add --project beta x || true; } 2>&1 | grep -q "belongs to project alpha" || fail "no message for a foreign project"
{ NC_HARNESS_VERSION=x nc memory show || true; } 2>&1 | grep -q "NC_MEMORY_DIR is not set" || fail "no message without NC_MEMORY_DIR"
{ NC_HARNESS_VERSION=x NC_MEMORY_DIR="$V" nc memory add "note" || true; } 2>&1 | grep -q "NC_MEMORY_OUTBOX is not set" || fail "no message without NC_MEMORY_OUTBOX"
ok "isolated: other project, limits, secrets, sync, apply and missing mounts are refused with a clear message"

# 10. doctor in the container: view read-only and without other projects, outbox writable
check() { bun -e 'const r = await Bun.file(process.argv[1]).json(); const c = r.checks.find((c) => c.name === process.argv[2]);
                  console.log(c ? `${c.status} ${c.detail}` : "absent")' "$1" "$2"; }
iso doctor --json > "$T/iso.json" || true
for name in NC_MEMORY_DIR NC_MEMORY_OUTBOX "other projects" MEMORY.md; do
  check "$T/iso.json" "$name" | grep -q "^ok" || fail "isolated doctor $name: $(check "$T/iso.json" "$name")"
done
[ "$(ls -A "$O" | wc -l)" = 2 ] || fail "doctor left a probe in the outbox"
chmod u+w "$V/projects" && cp "$B" "$V/projects/" && chmod a-w "$V/projects"
iso doctor --json > "$T/iso2.json" || true
check "$T/iso2.json" "other projects" | grep -q "^fail visible: beta.md" || fail "doctor missed beta.md: $(check "$T/iso2.json" "other projects")"
chmod u+w "$V/projects" && rm "$V/projects/beta.md" && chmod u+w "$V"
iso doctor --json > "$T/iso3.json" || true
check "$T/iso3.json" NC_MEMORY_DIR | grep -q "^fail .*is writable" || fail "doctor missed a writable view"
chmod -R a-w "$V"
NC_HARNESS_VERSION=x nc doctor --json > "$T/iso4.json" || true
check "$T/iso4.json" NC_MEMORY_DIR | grep -q "^fail not set" || fail "doctor without NC_MEMORY_DIR"
ok "isolated doctor: read-only view, own project only, writable outbox; fails on foreign files, writable view, missing env"

# 11. apply: the host writes the requests into the project it names, deletes them, pushes; twice is a no-op
mkdir "$T/replay" && cp "$O"/*.json "$T/replay/"   # keep copies for the replay below
c2="$(commits)"
nc memory apply --outbox "$O" --project alpha | grep -q "2 new" || fail "apply"
grep -qx -- "- $D: Isolated note from the container" "$A" && grep -qx -- "- $D: Second note" "$A" || fail "requests not in alpha.md"
git -C "$T/remote.git" show main:projects/alpha.md | grep -q "Isolated note" || fail "apply did not push"
[ "$(commits)" = $((c2 + 1)) ] || fail "apply should make one commit"
[ -z "$(ls -A "$O")" ] || fail "applied requests not deleted: $(ls -A "$O")"
grep -q "Isolated note" "$B" && fail "apply wrote into beta"
nc memory apply --outbox "$O" --project alpha | grep -q "no requests" || fail "second apply"
cp "$T"/replay/*.json "$O/"
nc memory apply --outbox "$O" --project alpha > /dev/null || fail "replayed apply failed"
[ "$(grep -c "Isolated note" "$A")" = 1 ] && [ "$(commits)" = $((c2 + 1)) ] && [ -z "$(ls -A "$O")" ] || fail "replay duplicated or committed"
ok "apply writes into the project nc-work names, deletes the requests, pushes once; repeating it does not duplicate"

# 12. hostile requests: project field, unknown field, bad version/JSON, too long, secret, link, FIFO, planted .reason
req() { printf '%s' "$2" > "$O/$1.json"; }
req a-project '{"v":1,"ts":"2026-11-13T10:00:00Z","text":"redirect me","project":"beta"}'
req b-extra '{"v":1,"ts":"2026-11-13T10:00:00Z","text":"extra","path":"../beta.md"}'
req c-version '{"v":2,"ts":"2026-11-13T10:00:00Z","text":"v2"}'
req d-json '{"v":1,'
req e-long "{\"v\":1,\"ts\":\"2026-11-13T10:00:00Z\",\"text\":\"$(printf 'l%.0s' {1..501})\"}"
req f-secret '{"v":1,"ts":"2026-11-13T10:00:00Z","text":"-----BEGIN RSA PRIVATE KEY-----"}'
req g-array '[1]'
echo "host file" > "$T/hostfile"
ln -s "$T/hostfile" "$O/h-link.json"
mkfifo "$O/i-fifo.json"
req j-good '{"v":1,"ts":"2026-11-13T10:00:00Z","text":"valid among the rejected"}'
ln -s "$T/hostfile" "$O/a-project.json.reason"     # the container plants a link where the host writes the reason
rc=0; timeout 20 "$REPO/bin/nc" memory apply --outbox "$O" --project alpha > "$T/apply.out" 2> "$T/apply.err" || rc=$?
[ "$rc" != 124 ] || fail "apply hung (FIFO?)"
[ "$rc" = 1 ] || fail "apply exit $rc despite rejections: $(cat "$T/apply.err")"
grep -q "valid among the rejected" "$A" || fail "the valid request was not applied"
[ ! -e "$O/j-good.json" ] || fail "applied request not deleted"
grep -q "redirect me" "$A" "$B" && fail "request with project field was applied"
[ "$(cat "$T/hostfile")" = "host file" ] || fail "host file behind a link was changed"
grep -q "project field" "$O/a-project.json.reason" && [ ! -L "$O/a-project.json.reason" ] || fail "reason for the project field"
for pair in "b-extra:unknown field" "c-version:version 2" "d-json:not valid JSON" "e-long:501 characters" "f-secret:secret" "g-array:not a JSON object" "h-link:is a link" "i-fifo:not a regular file"; do
  f="${pair%%:*}"; why="${pair#*:}"
  [ -e "$O/$f.json" ] || [ -L "$O/$f.json" ] || fail "rejected $f.json was deleted"
  grep -q "$why" "$O/$f.json.reason" || fail "$f: expected reason '$why', got: $(cat "$O/$f.json.reason" 2>/dev/null)"
done
ok "hostile requests rejected with a reason and left in place; links are never followed, a FIFO does not hang apply"

# 13. apply with a project the memory does not know, or without --project: nothing written, requests stay
rm -f "$O"/*; req k '{"v":1,"ts":"2026-11-13T10:00:00Z","text":"for nobody"}'
if nc memory apply --outbox "$O" --project gamma > /dev/null 2>&1; then fail "apply into an unknown project"; fi
if nc memory apply --outbox "$O" > /dev/null 2>&1; then fail "apply without --project"; fi
[ -e "$O/k.json" ] || fail "request lost"
ok "apply without a known project writes nothing and keeps the request"

# 14. apply shows each request with outcome and text (replaces as old → new), the commit body lists the same lines;
#     a repeated replaces request whose result is already there counts as done
rm -f "$O"/*
req r1 '{"v":1,"ts":"2026-11-13T10:00:00Z","text":"Deploy check with bun run check"}'
nc memory apply --outbox "$O" --project alpha > "$T/out" || fail "apply r1: $(cat "$T/out")"
grep -qx '  new: "Deploy check with bun run check"' "$T/out" || fail "no line for the new note: $(cat "$T/out")"
req r2 '{"v":1,"ts":"2026-11-13T10:01:00Z","text":"Deploy check with bun run verify","replaces":"Deploy check with bun run check"}'
cp "$O/r2.json" "$T/r2.json"
c3="$(commits)"
nc memory apply --outbox "$O" --project alpha > "$T/out" || fail "apply r2: $(cat "$T/out")"
line='replaced: "Deploy check with bun run check" → "Deploy check with bun run verify"'
grep -qxF "  $line" "$T/out" || fail "no old → new line: $(cat "$T/out")"
grep -qx -- "- $D: Deploy check with bun run verify" "$A" && ! grep -q "bun run check" "$A" || fail "replaces via apply: $(cat "$A")"
git -C "$T/remote.git" log -1 --format=%B main | grep -qxF "$line" || fail "commit body: $(git -C "$T/remote.git" log -1 --format=%B main)"
cp "$T/r2.json" "$O/"
nc memory apply --outbox "$O" --project alpha > "$T/out" || fail "repeated replaces rejected: $(cat "$O"/*.reason 2>/dev/null)"
grep -q "1 unchanged" "$T/out" && [ "$(commits)" = $((c3 + 1)) ] && [ -z "$(ls -A "$O")" ] || fail "repeated replaces: $(cat "$T/out")"
ok "apply prints and commits one line per request (replaces as old → new); a repeated replaces is done, not rejected"

# 15. a replaces that changes nothing (same text, same date) is "unchanged": no empty commit, request deleted
req r3 '{"v":1,"ts":"2026-11-13T10:02:00Z","text":"Deploy check with bun run verify","replaces":"Deploy check with bun run verify"}'
c4="$(commits)"
rc=0; nc memory apply --outbox "$O" --project alpha > "$T/out" 2>&1 || rc=$?
[ "$rc" = 0 ] && grep -q "1 unchanged" "$T/out" || fail "no-op replaces: rc $rc, $(cat "$T/out")"
[ "$(commits)" = "$c4" ] && [ -z "$(ls -A "$O")" ] || fail "no-op replaces committed or left the request: $(ls -A "$O")"
ok "a replaces that changes nothing is unchanged: no commit, request deleted"

# 16. a request never deletes a note: replaces A with the text of an existing note B is rejected; direct it is allowed
req r4 '{"v":1,"ts":"2026-11-13T10:03:00Z","text":"Second note","replaces":"Isolated note from the container"}'
before="$(cat "$A")"
rc=0; nc memory apply --outbox "$O" --project alpha > "$T/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && [ "$(cat "$A")" = "$before" ] || fail "deleting replaces applied: rc $rc, $(cat "$T/out")"
grep -q "deletes no note" "$O/r4.json.reason" || fail "reason: $(cat "$O/r4.json.reason" 2>/dev/null)"
rm -f "$O"/*
nc memory add --project alpha --replaces "Isolated note from the container" "Second note" | grep -q replaced || fail "direct replaces onto an existing note"
! grep -q "Isolated note" "$A" && [ "$(grep -c "Second note" "$A")" = 1 ] || fail "direct replaces: $(cat "$A")"
ok "a request whose replaces would delete a note is rejected with a reason; direct on the host it is allowed"

# 17. every *.json is a request: names apply cannot take are rejected with a reason and exit 1, never skipped
for n in _x -x é; do req "$n" '{"v":1,"ts":"2026-11-13T10:00:00Z","text":"odd name"}'; done
rc=0; nc memory apply --outbox "$O" --project alpha > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" = 1 ] || fail "odd names: exit $rc, $(cat "$T/out")"
grep -q 'refused "é.json"' "$T/err" || fail "name not shown quoted: $(cat "$T/err")"
for n in _x -x é; do grep -q "not a valid request name" "$O/$n.json.reason" || fail "$n.json: no reason"; done
grep -q "odd name" "$A" && fail "odd-named request applied"
rm -f "$O"/*
ok "requests with names apply cannot take are rejected with a reason (exit 1), not skipped"

# 18. git commit fails: the project file is reset, the requests stay, the next run works (here: a failing hook)
printf '#!/bin/sh\nexit 1\n' > "$M/.git/hooks/pre-commit" && chmod +x "$M/.git/hooks/pre-commit"
req r5 '{"v":1,"ts":"2026-11-13T10:04:00Z","text":"after a failed commit"}'
rc=0; nc memory apply --outbox "$O" --project alpha > "$T/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -q "git commit failed" "$T/out" || fail "failed commit: rc $rc, $(cat "$T/out")"
[ -z "$(git -C "$M" status --porcelain)" ] || fail "failed commit left changes: $(git -C "$M" status --porcelain)"
[ -e "$O/r5.json" ] && [ ! -e "$O/r5.json.reason" ] || fail "request lost or marked rejected after a failed commit"
refused "git commit failed" memory add --project alpha "direct, hook fails"
[ -z "$(git -C "$M" status --porcelain)" ] || fail "failed direct commit left changes"
rm "$M/.git/hooks/pre-commit"
nc memory apply --outbox "$O" --project alpha | grep -q "1 new" || fail "apply after the failed commit"
ok "a failed git commit resets the project file; requests stay and the next run applies them"

# 19. at most 50 requests per run, the rest waits and is reported; a commit message far over the 128 KiB argument
#     limit (50 lines of ~4000 bytes) goes through stdin; the checkout is clean afterwards
rm -f "$O"/*
W="$(printf '\xf0\x9d\x94\xb8')"; big=""; for i in $(seq 500); do big+="$W"; done
req n00 "{\"v\":1,\"ts\":\"2026-11-13T10:00:00Z\",\"text\":\"$big\"}"
for i in $(seq 1 59); do
  old="$i"; for j in $(seq 497); do old+="$W"; done
  req "n$(printf %02d "$i")" "{\"v\":1,\"ts\":\"2026-11-13T10:00:00Z\",\"text\":\"$big\",\"replaces\":\"$old\"}"
done
c5="$(commits)"
rc=0; nc memory apply --outbox "$O" --project alpha > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" = 0 ] || fail "60 requests: exit $rc, $(head -c 300 "$T/err")"
grep -q "1 new, 49 unchanged" "$T/out" && grep -q "10 more request(s) stay in the outbox" "$T/out" || fail "60 requests: $(head -c 300 "$T/out")"
[ "$(ls "$O" | wc -l)" = 10 ] && [ -z "$(git -C "$M" status --porcelain)" ] && [ "$(commits)" = $((c5 + 1)) ] || fail "60 requests: $(ls "$O" | wc -l) left, $(git -C "$M" status --porcelain)"
[ "$(git -C "$T/remote.git" log -1 --format=%B main | wc -c)" -gt 131072 ] || fail "commit message shorter than the case it tests"
nc memory apply --outbox "$O" --project alpha | grep -q "10 unchanged" && [ -z "$(ls -A "$O")" ] || fail "second run did not take the rest"
ok "at most 50 requests per run, the rest waits and is reported; a commit message over 128 KiB goes through stdin"

# 20. values from the container in rejection lines and .reason files: control and invisible characters as \u{…}, v cut to 40
rm -f "$O"/*
req c1 '{"v":"\u009b2J\u009b31mVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV","ts":"2026-11-13T10:00:00Z","text":"x"}'
req c2 '{"v":1,"ts":"2026-11-13T10:00:00Z","text":"x","\u202efield":1}'
req "$(printf 'c3\xc2\x9bname')" '{"v":1,"ts":"2026-11-13T10:00:00Z","text":"x"}'
rc=0; nc memory apply --outbox "$O" --project alpha > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" = 1 ] || fail "C1 requests: exit $rc"
C1="$(printf '\xc2\x9b')"; RLO="$(printf '\xe2\x80\xae')"
for f in "$T/err" "$T/out" "$O"/*.reason; do
  ! LC_ALL=C grep -q -e "$C1" -e "$RLO" "$f" || fail "raw C1 or bidi character in $f"
done
grep -qF 'version "\u{9b}2J\u{9b}31mVVV' "$O/c1.json.reason" && grep -qF '\u{9b}2J' "$T/err" || fail "v not written out: $(cat "$O/c1.json.reason")"
! grep -q "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" "$O/c1.json.reason" || fail "v not cut to 40 characters"
grep -qF '"\u{202e}field"' "$O/c2.json.reason" || fail "field name: $(cat "$O/c2.json.reason")"
grep -qF 'refused "c3\u{9b}name.json"' "$T/err" || fail "file name: $(cat "$T/err")"
rm -f "$O"/* "$O"/.[!.]* 2>/dev/null || true
ok "rejection lines and .reason files write control and invisible characters as \\u{…} and cut v to 40 characters"

# 21. requests that cancel out (A → B, then B → A): the file is the same, so no commit, and both are done
req ca '{"v":1,"ts":"2026-11-13T10:00:00Z","text":"Second note B","replaces":"Second note"}'
req cb '{"v":1,"ts":"2026-11-13T10:01:00Z","text":"Second note","replaces":"Second note B"}'
before="$(cat "$A")"; c6="$(commits)"
rc=0; nc memory apply --outbox "$O" --project alpha > "$T/out" 2>&1 || rc=$?
[ "$rc" = 0 ] && grep -q "2 replaced – the file is the same in the end, no commit" "$T/out" || fail "cancelling requests: rc $rc, $(cat "$T/out")"
[ "$(cat "$A")" = "$before" ] && [ "$(commits)" = "$c6" ] && [ -z "$(ls -A "$O")" ] || fail "cancelling requests left something: $(ls -A "$O")"
ok "requests that cancel out leave the file as it was: no commit, both done"

# 22. direct on the host, --replaces with a typo stays an error even if the new text is already there
refused "not found" memory add --project alpha --replaces "Secnod note" "Second note"
ok "direct --replaces with a typo is 'not found', not 'unchanged'"

# 23. doctor on the host: memory checkout present, remote set, clean, MEMORY.md within the limit
check_direct() { nc doctor --json > "$T/d.json" || true; check "$T/d.json" "$1"; }
check_direct "~/.nc/memory" | grep -q "^ok" || fail "direct doctor memory: $(check "$T/d.json" "~/.nc/memory")"
check "$T/d.json" "memory clean" | grep -q "^ok" || fail "direct doctor clean"
check "$T/d.json" MEMORY.md | grep -q "^ok 1 lines" || fail "direct doctor MEMORY.md: $(check "$T/d.json" MEMORY.md)"
echo x >> "$A"; check_direct "memory clean" | grep -q "^warn" || fail "doctor missed a dirty checkout"
git -C "$M" checkout -q -- projects/alpha.md
for i in $(seq 1 151); do echo "line $i"; done >> "$M/MEMORY.md"
check_direct MEMORY.md | grep -q "^fail 152 lines" || fail "doctor missed MEMORY.md over the limit"
git -C "$M" checkout -q -- MEMORY.md
git -C "$M" remote remove origin; check_direct "~/.nc/memory" | grep -q "^fail no remote" || fail "doctor missed the missing remote"
mv "$M" "$T/mem-away"; check_direct "~/.nc/memory" | grep -q "^warn none – set NC_MEMORY_REMOTE" || fail "a missing memory does not warn"
mkdir "$M"; check_direct "~/.nc/memory" | grep -q "^fail not a git checkout" || fail "doctor missed a memory folder without git"
rmdir "$M"
ok "direct doctor: present, remote, clean, MEMORY.md limit; missing only warns, a folder without git fails"

# --- apply --broker, the lock on ~/.nc/memory, nc memory add through the broker -------------------------
mv "$T/mem-away" "$M"
git -C "$M" remote add origin "$T/remote.git" && git -C "$M" fetch -q && git -C "$M" branch -q --set-upstream-to=origin/main
git -C "$M" pull -q
[ -z "$(git -C "$M" status --porcelain)" ] || fail "fixture: checkout not clean"
S="$T/staged"; mkdir -p "$S"
mreq() { printf '%s' "$2" > "$S/$1.json"; printf '%s' "$S/$1.json"; }
jsget() { bun -e 'const r = JSON.parse(await Bun.file(process.argv[1]).text()); const v = r[process.argv[2]];
                  console.log(typeof v === "string" ? v : JSON.stringify(v))' "$T/out" "$1"; }
braw() {  # braw <nc memory apply args…>: stdout in $T/out (exactly one line), state in BSTATE, exit in BCODE
  BCODE=0; "$REPO/bin/nc" memory apply "$@" > "$T/out" 2> "$T/err" || BCODE=$?
  [ "$(grep -c '' "$T/out")" = 1 ] || fail "apply --broker: not exactly one line: $(cat "$T/out") / $(cat "$T/err")"
  BSTATE="$(jsget state)"; BREASON="$(jsget reason)"
}
bapply() { braw --broker --project "${2:-alpha}" --request "$1" --requester "${3:-t1}"; }
bwant() {  # bwant <state> <exit> <pattern in reason or ''> <what>
  [ "$BSTATE" = "$1" ] && [ "$BCODE" = "$2" ] || fail "$4: state $BSTATE, exit $BCODE, want $1/$2: $(cat "$T/out") / $(cat "$T/err")"
  [ -z "$3" ] || grep -q -- "$3" <<<"$BREASON" || fail "$4: reason '$BREASON' without '$3'"
}

# 24. apply --broker stores: one JSON line, exit 0, the commit names the task, only projects/<P>.md changes
c="$(commits)"
bapply "$(mreq s1 '{"v":1,"type":"memory","text":"Broker note one"}')"; bwant stored 0 "" "stored"
[ "$(jsget outcome) $(jsget pushed) $(jsget note)" = "new true Broker note one" ] || fail "stored line: $(cat "$T/out")"
[ "$(commits)" = $((c + 1)) ] || fail "stored: no commit"
git -C "$T/remote.git" log -1 --format=%s main | grep -qxF "nc memory apply: alpha (task t1, new)" || fail "subject: $(git -C "$T/remote.git" log -1 --format=%s main)"
git -C "$T/remote.git" log -1 --format=%b main | grep -qxF 'new: "Broker note one"' || fail "body: $(git -C "$T/remote.git" log -1 --format=%b main)"
[ "$(git -C "$T/remote.git" show --name-only --format= main)" = "projects/alpha.md" ] || fail "other files changed"
grep -qx -- "- $D: Broker note one" "$A" || fail "note not in alpha.md"
[ -z "$(git -C "$M" status --porcelain)" ] || fail "checkout dirty after stored"
ok "apply --broker: one stored line (new, pushed), commit 'task t1, new', only projects/alpha.md"

# 25. refused (exit 1, one line, no commit): the request's content, applyNote's rules, an unknown project
c="$(commits)"
echo "host file" > "$T/hostfile2"; ln -sf "$T/hostfile2" "$S/link.json"
rm -f "$S/fifo.json"; mkfifo "$S/fifo.json"
mreq big "{\"v\":1,\"type\":\"memory\",\"text\":\"$(head -c 8200 /dev/zero | tr '\0' a)\"}" > /dev/null
for c_ in 'project|{"v":1,"type":"memory","text":"x","project":"beta"}|contains a project field – the host sets the project, not the request' \
          'ts|{"v":1,"type":"memory","text":"x","ts":"2026-11-13T10:00:00Z"}|unknown field' \
          'field|{"v":1,"type":"memory","text":"x","path":"../beta.md"}|unknown field' \
          'v2|{"v":2,"type":"memory","text":"x"}|version 2' \
          'type|{"v":1,"type":"delegate","text":"x"}|type "delegate"' \
          'notype|{"v":1,"text":"x"}|type' \
          'secret|{"v":1,"type":"memory","text":"token ghp_abcdefghijklmnop1234"}|secret' \
          'invisible|{"v":1,"type":"memory","text":"zero\u200bwidth"}|invisible characters (U+200B)' \
          "long|{\"v\":1,\"type\":\"memory\",\"text\":\"$(printf 'l%.0s' {1..501})\"}|501 characters" \
          'deletes|{"v":1,"type":"memory","text":"Second note","replaces":"Broker note one"}|deletes no note' \
          'nothing|{"v":1,"type":"memory","text":"fresh","replaces":"does not exist"}|not found'; do
  IFS='|' read -r name body pat <<<"$c_"
  bapply "$(mreq "$name" "$body")"; bwant refused 1 "$pat" "refused $name"
done
bapply "$S/link.json"; bwant refused 1 "is a link" "refused link"
timeout 20 "$REPO/bin/nc" memory apply --broker --project alpha --request "$S/fifo.json" --requester t1 > "$T/out" 2> "$T/err" || BCODE=$?
[ "$BCODE" != 124 ] || fail "apply --broker hung on a FIFO"
BSTATE="$(jsget state)"; BREASON="$(jsget reason)"; bwant refused 1 "not a regular file" "refused fifo"
bapply "$S/big.json"; bwant refused 1 "larger than 8192" "refused over 8 KiB"
bapply "$(mreq gamma '{"v":1,"type":"memory","text":"for gamma"}')" gamma; bwant refused 1 "no memory for project gamma" "refused unknown project"
[ "$(commits)" = "$c" ] && [ "$(cat "$T/hostfile2")" = "host file" ] || fail "a refused request was committed or followed a link"
[ -z "$(git -C "$M" status --porcelain)" ] || fail "checkout dirty after refusals"
ok "apply --broker refused (exit 1): project, ts, unknown field, v, type, secret, invisible, 501, link, FIFO, 8 KiB, deleting replaces, missing original, unknown project"

# 26. error (exit 2, one line): dirty checkout, pull conflict, failing commit hook, isolated, bad arguments, lock held
R="$(mreq e1 '{"v":1,"type":"memory","text":"never written"}')"
echo "local edit" >> "$A"
bapply "$R"; bwant error 2 "uncommitted changes" "dirty checkout"
git -C "$M" checkout -q -- projects/alpha.md
git -C "$T/other" pull -q
sed -i '1s/.*/# alpha from elsewhere/' "$T/other/projects/alpha.md" && git -C "$T/other" commit -qam other2 && git -C "$T/other" push -q
sed -i '1s/.*/# alpha from here/' "$A" && git -C "$M" commit -qam here2
bapply "$R"; bwant error 2 "pull --rebase failed" "pull conflict"
[ ! -d "$M/.git/rebase-merge" ] && [ ! -d "$M/.git/rebase-apply" ] || fail "rebase left behind"
git -C "$M" reset -q --hard origin/main && git -C "$M" pull -q
printf '#!/bin/sh\nexit 1\n' > "$M/.git/hooks/pre-commit" && chmod +x "$M/.git/hooks/pre-commit"
bapply "$R"; bwant error 2 "git commit failed" "failing commit hook"
[ -z "$(git -C "$M" status --porcelain)" ] || fail "failing hook left changes: $(git -C "$M" status --porcelain)"
rm "$M/.git/hooks/pre-commit"
BCODE=0; NC_HARNESS_VERSION=x "$REPO/bin/nc" memory apply --broker --project alpha --request "$R" --requester t1 > "$T/out" 2>&1 || BCODE=$?
BSTATE="$(jsget state)"; BREASON="$(jsget reason)"; bwant error 2 "only on the host" "isolated"
for args in "--broker --project alpha --request $R" "--broker --project alpha --project alpha --request $R --requester t1" \
            "--broker --broker --project alpha --request $R --requester t1" "--broker --project alpha --request $R --requester t1 --outbox $O" \
            "--broker --project ../alpha --request $R --requester t1" "--broker --project alpha --request $R --requester T1" \
            "--broker --project alpha --request $R --requester" "--broker --project=alpha --request $R --requester t1"; do
  # shellcheck disable=SC2086
  braw $args; bwant error 2 "" "arguments: $args"
done
rm -f "$T/held"; flock -x "$M" sh -c "touch '$T/held'; sleep 6" & holder=$!
for _ in $(seq 50); do [ -e "$T/held" ] && break; sleep 0.1; done
s0=$SECONDS; BCODE=0
NC_MEMORY_LOCK_S=1 "$REPO/bin/nc" memory apply --broker --project alpha --request "$R" --requester t1 > "$T/out" 2> "$T/err" || BCODE=$?
BSTATE="$(jsget state)"; BREASON="$(jsget reason)"; bwant error 2 "has been locked for" "lock held"
[ $((SECONDS - s0)) -lt 5 ] || fail "lock wait not shortened"
wait "$holder"
! grep -q "never written" "$A" && ! git -C "$T/remote.git" log --format=%B main | grep -q "never written" || fail "an error case wrote the note"
ok "apply --broker error (exit 2): dirty, pull conflict, failing hook (file reset), isolated, bad or doubled options, lock held"

# 27. the same note again: stored/unchanged without a commit; note in the line is at most 120 characters
long="$(for i in $(seq 300); do printf 'é'; done)"
bapply "$(mreq u1 "{\"v\":1,\"type\":\"memory\",\"text\":\"$long\"}")"; bwant stored 0 "" "long note"
[ "$(bun -e 'console.log([...JSON.parse(await Bun.file(process.argv[1]).text()).note].length)' "$T/out")" = 120 ] || fail "note not cut to 120: $(cat "$T/out")"
c="$(commits)"
bapply "$S/s1.json"; bwant stored 0 "" "same note"
[ "$(jsget outcome) $(jsget pushed)" = "unchanged true" ] && [ "$(commits)" = "$c" ] || fail "unchanged: $(cat "$T/out")"
ok "apply --broker: the same note is stored/unchanged without a commit; note is cut to 120 characters"

# 28. push refused by the remote: stored, pushed false, local commit; with a short budget no second push attempt
printf '#!/bin/sh\nexit 1\n' > "$T/remote.git/hooks/pre-receive" && chmod +x "$T/remote.git/hooks/pre-receive"
mkdir -p "$T/gitwrap"; REALGIT="$(command -v git)"
printf '#!/bin/sh\nfor a in "$@"; do if [ "$a" = push ]; then echo push >> "%s"; [ -n "${GIT_PUSH_SLEEP:-}" ] && sleep "$GIT_PUSH_SLEEP"; break; fi; done\nexec "%s" "$@"\n' \
  "$T/pushes" "$REALGIT" > "$T/gitwrap/git" && chmod +x "$T/gitwrap/git"
: > "$T/pushes"
PATH="$T/gitwrap:$PATH" bapply "$(mreq p1 '{"v":1,"type":"memory","text":"push refused"}')"; bwant stored 0 "" "push refused"
[ "$(jsget pushed)" = false ] && [ "$(git -C "$M" rev-list --count origin/main..HEAD)" = 1 ] || fail "pushed:false: $(cat "$T/out")"
[ "$(wc -l < "$T/pushes")" = 2 ] || fail "without a budget: expected push and one retry, got $(wc -l < "$T/pushes")"
: > "$T/pushes"
GIT_PUSH_SLEEP=4 NC_MEMORY_BUDGET_S=3 PATH="$T/gitwrap:$PATH" bapply "$(mreq p2 '{"v":1,"type":"memory","text":"push refused, short budget"}')"
bwant stored 0 "" "short budget"
[ "$(jsget pushed)" = false ] && [ "$(wc -l < "$T/pushes")" = 1 ] || fail "short budget: $(cat "$T/out"), $(wc -l < "$T/pushes") pushes"
rm "$T/remote.git/hooks/pre-receive"
nc memory sync > /dev/null && [ "$(git -C "$M" rev-list --count origin/main..HEAD)" = 0 ] || fail "sync after the refused pushes"
ok "apply --broker: a refused push is stored with pushed:false and a local commit; past the budget no further push starts"

# 28b. the budget is checked before every git call. A slow git add (not a pre-commit hook: that runs inside git commit,
# after the last check) pushes the commit past the budget: error, file reset, no commit. Unchanged past the budget
# (slow pull): pushed:false without rev-list.
mkdir -p "$T/gitslow"
cat > "$T/gitslow/git" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    add) echo add >> "$T/gitcalls"; [ -n "\${GIT_SLEEP_ADD:-}" ] && sleep "\$GIT_SLEEP_ADD"; break ;;
    pull) echo pull >> "$T/gitcalls"; [ -n "\${GIT_SLEEP_PULL:-}" ] && sleep "\$GIT_SLEEP_PULL"; break ;;
    commit|push|rev-list) echo "\$a" >> "$T/gitcalls"; break ;;
  esac
done
exec "$REALGIT" "\$@"
EOF
chmod +x "$T/gitslow/git"
c="$(commits)"; : > "$T/gitcalls"
GIT_SLEEP_ADD=3 NC_MEMORY_BUDGET_S=2 PATH="$T/gitslow:$PATH" bapply "$(mreq b1 '{"v":1,"type":"memory","text":"slow add, never committed"}')"
bwant error 2 "deadline passed .* before git commit, nothing written" "slow add"
grep -qx add "$T/gitcalls" && ! grep -qx commit "$T/gitcalls" || fail "slow add: git calls $(tr '\n' ' ' < "$T/gitcalls")"
[ -z "$(git -C "$M" status --porcelain)" ] && [ ! -e "$M/.git/index.lock" ] || fail "slow add left changes: $(git -C "$M" status --porcelain)"
[ "$(commits)" = "$c" ] && [ "$(git -C "$M" rev-list --count origin/main..HEAD)" = 0 ] && ! grep -q "never committed" "$A" || fail "slow add committed"
: > "$T/gitcalls"
GIT_SLEEP_PULL=3 NC_MEMORY_BUDGET_S=2 PATH="$T/gitslow:$PATH" bapply "$S/s1.json"; bwant stored 0 "" "unchanged past the budget"
[ "$(jsget outcome) $(jsget pushed)" = "unchanged false" ] || fail "unchanged past the budget: $(cat "$T/out")"
grep -qx pull "$T/gitcalls" && ! grep -qx rev-list "$T/gitcalls" || fail "unchanged past the budget: git calls $(tr '\n' ' ' < "$T/gitcalls")"
ok "apply --broker: past the budget after git add → error, file reset, no commit; unchanged past the budget → pushed:false, no rev-list"

# 28c. the child under the lock dies without its line (SIGKILL: flock exits 137; or exit 1 before writing): exactly one error line, exit 2
for die in kill:137 exit1:1; do
  NC_MEMORY_TEST_DIE="${die%%:*}" bapply "$(mreq d1 '{"v":1,"type":"memory","text":"child dies"}')"
  bwant error 2 "stopped (exit ${die##*:}) – check ~/.nc/memory (git status)" "child $die"
done
! grep -q "child dies" "$A" && [ -z "$(git -C "$M" status --porcelain)" ] || fail "a dying child wrote the note"
ok "apply --broker: a child killed by SIGKILL or ending with exit 1 without its line → exactly one error line, exit 2"

# 29. the lock: two direct nc memory add at once (a pre-commit hook sleeps 2 s) both get through, two commits, clean
printf '#!/bin/sh\nsleep 2\n' > "$M/.git/hooks/pre-commit" && chmod +x "$M/.git/hooks/pre-commit"
c="$(commits)"
nc memory add --project alpha "parallel note A" > "$T/la" 2>&1 & pa=$!
sleep 0.3
nc memory add --project alpha "parallel note B" > "$T/lb" 2>&1 & pb=$!
wait "$pa" || fail "first parallel add: $(cat "$T/la")"
wait "$pb" || fail "second parallel add: $(cat "$T/lb")"
rm "$M/.git/hooks/pre-commit"
[ "$(commits)" = $((c + 2)) ] && [ -z "$(git -C "$M" status --porcelain)" ] || fail "parallel adds: $(commits) commits, $(git -C "$M" status --porcelain)"
grep -q "parallel note A" "$A" && grep -q "parallel note B" "$A" || fail "a parallel note is missing"
[ ! -e "$M/.lock" ] && [ -z "$(git -C "$M" status --porcelain --ignored)" ] || fail "the lock left a file in the checkout"
ok "lock: two direct adds at once both get through (two commits, clean checkout, no lock file)"

# 30. the client: nc memory add in a task with a mailbox, against a small test broker
MB="$T/mb"; REQ="$MB/requests"; INBOX="$MB/inbox"; mkdir -p "$REQ" "$INBOX" "$MB/log"
cat > "$T/tmem.py" <<'EOF'
# Test broker for memory requests: heartbeat, picks up, answers by $MB/mode (stored, stored-odd, stored-local, refused, error, dropped).
# Flags in $MB: no_heartbeat, no_pickup, hold (pick up, never answer), stop.
import json, os, pathlib, sys, time
mb = pathlib.Path(sys.argv[1]); req, inbox, log = mb / "requests", mb / "inbox", mb / "log"
def now(): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
def put(path, data):
    tmp = path.with_name("." + path.name + ".tmp"); tmp.write_text(json.dumps(data)); os.replace(tmp, path)
while not (mb / "stop").exists():
    if not (mb / "no_heartbeat").exists(): put(inbox / ".broker", {"v": 1, "ts": now()})
    for f in sorted(req.iterdir()):
        if f.name.startswith(".") or (mb / "no_pickup").exists(): continue
        raw = f.read_bytes(); (log / f.name).write_bytes(raw); f.unlink()
        mode, stem = (mb / "mode").read_text().strip(), f.name[:-5]
        if (mb / "hold").exists(): continue
        if mode == "dropped":
            put(inbox / ".dropped", {"v": 1, "entries": [{"request": stem, "reason": "inbox full (200 answers) – run nc delegate --cleanup <id> for collected runs first", "ts": now()}]}); continue
        r = {"v": 1, "request": stem, "state": mode, "reason": None, "task_id": None, "timeout_min": None, "started": None, "result": None}
        odd = {"stored-odd": "xyzzy"}  # an outcome the client does not know
        if mode.startswith("stored"): r.update(state="stored", result={"outcome": odd.get(mode, "new"), "pushed": mode != "stored-local"})
        else: r["reason"] = "no \x1b[31mred"
        (inbox / stem).mkdir(); put(inbox / stem / "response.json", r)
    time.sleep(0.2)
EOF
python3 -I "$T/tmem.py" "$MB" & tb=$!
trap 'kill "$tb" 2>/dev/null || true; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
rm -f "$O"/* 2>/dev/null || true
cm() { env NC_HARNESS_VERSION=0123456789abcdef NC_PROJECT=alpha NC_MEMORY_DIR="$V" NC_MEMORY_OUTBOX="$O" NC_REQUESTS="$REQ" NC_INBOX="$INBOX" \
         NC_DELEGATE_STALE_S=2 "$REPO/bin/nc" memory "$@"; }
cexpect() {  # cexpect <exit> <pattern in output or ''> <cm args…>
  local want="$1" pat="$2" code=0; shift 2
  cm "$@" > "$T/out" 2>&1 || code=$?
  [ "$code" = "$want" ] || fail "nc memory $*: exit $code, want $want: $(cat "$T/out")"
  [ -z "$pat" ] || grep -q -- "$pat" "$T/out" || fail "nc memory $*: no '$pat' in: $(cat "$T/out")"
}
echo stored > "$MB/mode"; sleep 0.5
cexpect 0 "^projects/alpha.md: new$" add "hello broker"
N="$(ls "$MB/log" | tail -1)"
[[ "$N" =~ ^m[0-9]{14}-[0-9a-f]{4}\.json$ ]] || fail "request name $N"
[ "$(cat "$MB/log/$N")" = '{"v":1,"type":"memory","text":"hello broker"}' ] || fail "request format: $(cat "$MB/log/$N")"
cexpect 0 "" add --replaces "hello broker" "hello again"
[ "$(cat "$MB/log/$(ls "$MB/log" | tail -1)")" = '{"v":1,"type":"memory","text":"hello again","replaces":"hello broker"}' ] || fail "replaces format"
echo stored-odd > "$MB/mode"
cexpect 0 "^projects/alpha.md: stored$" add "hello odd outcome"
echo stored-local > "$MB/mode"
cexpect 0 "push later (nc memory sync on the host)" add "stored locally"
echo refused > "$MB/mode"
cexpect 1 'no \\u{1b}\[31mred' add "refused note"
echo error > "$MB/mode"
cexpect 2 "no .*red" add "error note"
[ -z "$(ls -A "$O")" ] && [ -z "$(ls -A "$REQ")" ] || fail "outbox or mailbox not empty: $(ls -A "$O" "$REQ")"
ok "client: an m… request with exactly {v,type,text[,replaces]}; stored → 0 (an unknown outcome reads as stored, pushed:false with a hint), refused → 1, error → 2, outbox empty"

touch "$MB/no_heartbeat"; rm -f "$INBOX/.broker"; sleep 0.5
cexpect 0 "broker not reachable – note in the outbox, later nc-work memory-apply" add "no heartbeat"
[ "$(ls "$O" | wc -l)" = 1 ] && [ -z "$(ls -A "$REQ")" ] || fail "stale heartbeat: outbox $(ls -A "$O"), mailbox $(ls -A "$REQ")"
printf '{"v":1,"ts":"2026-01-01T00:00:00Z"}' > "$INBOX/.broker"
cexpect 0 "broker not reachable" add "old heartbeat"
[ "$(ls "$O" | wc -l)" = 2 ] && [ -z "$(ls -A "$REQ")" ] || fail "old heartbeat: outbox $(ls -A "$O")"
rm "$MB/no_heartbeat"; sleep 0.5
code=0; env NC_HARNESS_VERSION=0123456789abcdef NC_PROJECT=alpha NC_MEMORY_DIR="$V" NC_MEMORY_OUTBOX="$O" "$REPO/bin/nc" memory add "no mailbox" > "$T/out" 2>&1 || code=$?
[ "$code" = 0 ] && grep -q "request .* in the outbox" "$T/out" && ! grep -q "broker" "$T/out" || fail "without NC_REQUESTS: $(cat "$T/out")"
[ "$(ls "$O" | wc -l)" = 3 ] || fail "without NC_REQUESTS: no request in the outbox"
rm -f "$O"/*
ok "client: a missing or old heartbeat, or no mailbox at all: the note goes into the outbox, the mailbox stays empty"

touch "$MB/no_pickup"; s0=$SECONDS
NC_DELEGATE_ANSWER_S=2 cexpect 0 "broker not reachable" add "not picked up"
[ "$(ls "$O" | wc -l)" = 1 ] && [ -z "$(ls -A "$REQ")" ] || fail "taken back: outbox $(ls -A "$O"), mailbox $(ls -A "$REQ")"
rm -f "$O"/* "$MB/no_pickup"; touch "$MB/hold"
NC_DELEGATE_ANSWER_S=2 cexpect 2 "note is still being processed – do not submit it again, the result shows in the broker's pane" add "picked up, no answer"
[ -z "$(ls -A "$O")" ] || fail "picked up: a note went into the outbox"
rm "$MB/hold"; echo dropped > "$MB/mode"
cexpect 1 "dropped without an answer: inbox full (200 answers) – run nc delegate --cleanup <id> for collected runs first" add "dropped note"
[ -z "$(ls -A "$O")" ] || fail "dropped: a note went into the outbox"
[ $((SECONDS - s0)) -lt 30 ] || fail "the client cases took $((SECONDS - s0)) s"
touch "$MB/stop"; wait "$tb" 2>/dev/null || true
ok "client: not picked up in time → taken back, outbox; picked up without an answer → exit 2, no outbox; .dropped → exit 1"

# 31. NC_HOME: nc memory uses $NC_HOME/memory like install.sh, not ~/.nc/memory (add, show, doctor)
H2="$T/nchome"; mkdir -p "$H2" && git clone -q "$T/remote.git" "$H2/memory"
before="$(git -C "$M" rev-parse HEAD)"
NC_HOME="$H2" nc memory add --project alpha "note through NC_HOME" > /dev/null || fail "add with NC_HOME failed"
grep -q "note through NC_HOME" "$H2/memory/projects/alpha.md" || fail "NC_HOME: the note did not go into \$NC_HOME/memory"
[ "$(git -C "$M" rev-parse HEAD)" = "$before" ] && ! grep -q "note through NC_HOME" "$A" || fail "NC_HOME: ~/.nc/memory was written"
NC_HOME="$H2" nc memory show --project alpha | grep -q "note through NC_HOME" || fail "NC_HOME: show did not read \$NC_HOME/memory"
mv "$M" "$T/mem-away2"
NC_HOME="$H2" nc memory add --project alpha "second NC_HOME note" > /dev/null || fail "NC_HOME: add needed ~/.nc/memory"
mv "$T/mem-away2" "$M"
ok "NC_HOME: add and show use \$NC_HOME/memory and leave ~/.nc/memory alone"

echo "$pass tests passed"
