#!/usr/bin/env bash
# Smoke tests for install.sh, nc doctor, nc opencode and nc version. No network, no keys.
# Runs against throwaway $HOMEs (and copies of the repo where a test could damage it), never the real
# home. OpenCode is a fake binary served from a local tarball.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Resolve real tool paths before swapping $HOME (mise shims read config from $HOME).
BUN_DIR="$(dirname "$(mise which bun 2>/dev/null || command -v bun)")"
export PATH="$BUN_DIR:$PATH"
unset OPENROUTER_API_KEY NC_HARNESS_VERSION NC_OPENCODE OPENCODE_DISABLE_CLAUDE_CODE OPENCODE_DISABLE_CLAUDE_CODE_SKILLS \
  NC_MEMORY_DIR NC_MEMORY_OUTBOX NC_PROJECT NC_PROJECT_PATH GH_TOKEN GITHUB_TOKEN XDG_CONFIG_HOME OPENCODE_CONFIG_DIR \
  CLAUDE_CODE_EFFORT_LEVEL CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE NC_HOME || true
export BUN_RUNTIME_TRANSPILER_CACHE_PATH=0   # no Bun cache anywhere
export NC_MACHINE=server   # the expectations are the server's, also on a Mac; only the Mac cases below set mac
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@invalid

T="$(cd "$(mktemp -d)" && pwd -P)"   # resolved: on the Mac /var is a link to /private/var, and doctor names resolved paths
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
# A neutral current folder: nc opencode asks nc models about it, and started from / or /tmp the throwaway
# HOME with its restricted ~/projects folders would lie below it.
mkdir "$T/cwd" && cd "$T/cwd"
REAL_PATH="$PATH"
SYNTH="sk-or-v1-synthetic-test-value-0000"   # never a real key

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok   $*"; pass=$((pass + 1)); }
sha()  { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
fresh_home() {  # fresh_home <dir>: a new $HOME with a CLAUDE.md, Claude's synced skills and shell rc files
  export HOME="$1" PATH="$1/.local/bin:$REAL_PATH"
  mkdir -p "$HOME/.claude/skills/synced/some-skill" "$HOME/projects"
  echo "old rules" > "$HOME/.claude/CLAUDE.md"
  echo "synced" > "$HOME/.claude/skills/synced/some-skill/SKILL.md"
  echo "# bashrc" > "$HOME/.bashrc"
  echo "# profile" > "$HOME/.profile"
}
check() {  # check <doctor.json> <name> -> "status detail" of that check
  bun -e 'const r = await Bun.file(process.argv[1]).json(); const c = r.checks.find((c) => c.name === process.argv[2]);
          console.log(c ? `${c.status} ${c.detail}` : "absent")' "$1" "$2"
}

# Platform as install.sh sees it, and the version pins.txt wants there.
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Linux-amd64) PLATFORM=linux-x64 ;; Linux-aarch64|Linux-arm64) PLATFORM=linux-arm64 ;;
  Darwin-arm64) PLATFORM=darwin-arm64 ;; Darwin-x86_64) PLATFORM=darwin-x64 ;; *) PLATFORM=unknown ;;
esac
PIN="$(awk -v p="$PLATFORM" '$1 == "opencode" && $3 == p { print $2 }' "$REPO/pins.txt")"
[ -n "$PIN" ] || { echo "skip: pins.txt has no OpenCode for $PLATFORM; add a pin to run these tests"; exit 0; }

# Fake OpenCode in the pinned version, packed like the release (single `opencode` at the root).
# It leaves a marker whenever it runs, so tests can tell whether install.sh executed it.
mkdir -p "$T/fake"
cat > "$T/fake/opencode" <<EOF
#!/usr/bin/env bash
touch "\$HOME/.opencode-ran"
if [ "\${1:-}" = --version ]; then echo "opencode v$PIN"; exit 0; fi
echo "args: \$*"
echo "key: \${OPENROUTER_API_KEY:-<none>}"
echo "marker: \${NC_OPENCODE:-<none>}"
EOF
chmod 755 "$T/fake/opencode"
case "$PLATFORM" in
  darwin-*) (cd "$T/fake" && zip -q "$T/opencode.zip" opencode); ARCHIVE="$T/opencode.zip" ;;
  *) tar -czf "$T/opencode.tar.gz" -C "$T/fake" opencode; ARCHIVE="$T/opencode.tar.gz" ;;
esac
export NC_OPENCODE_URL="file://$ARCHIVE" NC_OPENCODE_SHA256="$(sha "$ARCHIVE")"

fresh_home "$T/home"

# The memory repo: a local bare repo instead of GitHub (install.sh clones NC_MEMORY_REMOTE). Built after
# fresh_home, so git reads the throwaway home's config, never the real one.
mkdir -p "$T/memory-seed/projects"
printf '# Index\n' > "$T/memory-seed/MEMORY.md"
printf '# alpha\n\n' > "$T/memory-seed/projects/alpha.md"
git -C "$T/memory-seed" init -q -b main && git -C "$T/memory-seed" add -A && git -C "$T/memory-seed" commit -qm seed
git clone -q --bare "$T/memory-seed" "$T/memory.git"
export NC_MEMORY_REMOTE="$T/memory.git"

# 1. dry run changes nothing: the same tree in $HOME, also without the cache variables of this script (Bun's cache)
home_tree() { find "$HOME" -exec ls -ld {} + | awk '{print $1, $5, $NF}' | sort; }
before="$(home_tree)"
env -u BUN_RUNTIME_TRANSPILER_CACHE_PATH -u XDG_CACHE_HOME "$REPO/install.sh" --dry-run > "$T/dry.log"
after="$(home_tree)"
[ "$before" = "$after" ] || { diff <(echo "$before") <(echo "$after") >&2 || true; fail "dry run changed the home folder"; }
[ -f "$HOME/.claude/CLAUDE.md" ] && [ ! -L "$HOME/.claude/CLAUDE.md" ] || fail "dry run touched CLAUDE.md"
[ ! -e "$HOME/.nc" ] || fail "dry run created ~/.nc"
[ ! -e "$HOME/sandbox" ] || fail "dry run created ~/sandbox"
[ ! -e "$HOME/.config/nc-harness" ] || fail "dry run created secrets.env"
[ ! -e "$HOME/.claude/skills/nc-harness-check" ] || fail "dry run linked a skill"
grep -q "back up" "$T/dry.log" || fail "dry run does not announce the backup"
grep -q "download .*opencode $PIN" "$T/dry.log" || fail "dry run does not announce the OpenCode download"
grep -q "clone .*memory.git" "$T/dry.log" || fail "dry run does not announce the memory clone"
grep -q "^Agents$" "$T/dry.log" && grep -q "create     ~/.claude/agents/planner.md" "$T/dry.log" \
  && grep -q "create     ~/.config/opencode/agents/tester.md" "$T/dry.log" \
  || fail "dry run does not announce the agent files"
[ ! -e "$HOME/.claude/agents" ] && [ ! -e "$HOME/.config/opencode" ] || fail "dry run created an agents folder"
ok "dry run changes nothing and announces backup, skills, OpenCode, the agent files and the memory clone"

# 2. first run links, backs up, creates dirs, installs OpenCode, creates secrets.env
rc_before="$(sha "$HOME/.bashrc") $(sha "$HOME/.profile")"
"$REPO/install.sh" > "$T/run1.log" || { cat "$T/run1.log"; fail "first run failed"; }
[ "$(readlink "$HOME/.claude/CLAUDE.md")" = "$REPO/AGENTS.md" ] || fail "CLAUDE.md not linked"
[ "$(readlink "$HOME/.config/opencode/AGENTS.md")" = "$REPO/AGENTS.md" ] || fail "opencode AGENTS.md not linked"
[ "$(readlink "$HOME/.config/opencode/opencode.json")" = "$REPO/adapters/opencode/opencode.json" ] || fail "opencode.json not linked"
[ "$(readlink "$HOME/.config/opencode/service.json")" = "$REPO/adapters/opencode/service.json" ] || fail "service.json not linked"
[ "$(readlink "$HOME/.local/bin/nc")" = "$REPO/bin/nc" ] || fail "nc not linked"
[ -d "$HOME/sandbox" ] && [ -d "$HOME/notes" ] || fail "sandbox/notes missing"
backup="$(find "$HOME/.nc/backup" -name CLAUDE.md -type f)"
[ "$(cat "$backup")" = "old rules" ] || fail "old CLAUDE.md not backed up"
[ "$(cat "$HOME/.claude/skills/synced/some-skill/SKILL.md")" = "synced" ] || fail "synced skills touched"
[ "$(git -C "$HOME/.nc/memory" remote get-url origin)" = "$T/memory.git" ] && [ -f "$HOME/.nc/memory/MEMORY.md" ] || fail "memory not cloned"
for f in .claude/agents/planner.md .claude/agents/tester.md .config/opencode/agents/tester.md; do
  [ "$(sed -n 2p "$HOME/$f")" = "# GENERATED by nc-harness – do not edit by hand" ] || fail "$f not generated"
done
[ ! -e "$REPO/agents" ] || fail "the repo has a top-level agents folder: the container start script would link it to ~/.claude/agents, where nc-work mounts the generated roles read-only, and every new container would fail to start"
ok "first run links, backs up the old CLAUDE.md, leaves synced/ alone, generates the agent files, clones the memory"

# 3. shell rc files untouched, the key is not exported into login shells
[ "$(sha "$HOME/.bashrc") $(sha "$HOME/.profile")" = "$rc_before" ] || fail "install changed ~/.bashrc or ~/.profile"
[ ! -e "$HOME/.zshrc" ] && [ ! -e "$HOME/.bash_profile" ] || fail "install created a shell rc file"
[ -z "$(env -u OPENROUTER_API_KEY bash -lc 'printenv OPENROUTER_API_KEY' 2>/dev/null)" ] || fail "key exported into login shells"
ok "shell rc files untouched, no key in a login shell"

# 4. skills are linked one by one, never the folder
[ ! -L "$HOME/.claude/skills" ] || fail "~/.claude/skills itself became a link"
for d in "$REPO"/skills/*/; do
  name="$(basename "$d")"
  [ "$(readlink "$HOME/.claude/skills/$name")" = "$REPO/skills/$name" ] || fail "skill $name not linked"
done
[ -f "$HOME/.claude/skills/nc-harness-check/SKILL.md" ] || fail "test skill not reachable"
ok "every skill is linked on its own, ~/.claude/skills stays a real folder"

# 5. every skill has valid frontmatter: name = folder, description present
for f in "$REPO"/skills/*/SKILL.md; do
  dir="$(basename "$(dirname "$f")")"
  [ "$(sed -n 1p "$f")" = "---" ] || fail "$f: no frontmatter"
  name="$(awk 'NR > 1 && /^---$/ { exit } NR > 1 && /^name:/ { sub(/^name:[ ]*/, ""); print }' "$f")"
  desc="$(awk 'NR > 1 && /^---$/ { exit } NR > 1 && /^description:/ { sub(/^description:[ ]*/, ""); print }' "$f")"
  [ "$name" = "$dir" ] || fail "$f: name '$name' does not match folder '$dir'"
  [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail "$f: invalid name"
  [ -n "$desc" ] && [ "${#desc}" -le 1024 ] || fail "$f: description missing or too long"
done
grep -q "nc version" "$REPO/skills/nc-harness-check/SKILL.md" || fail "test skill does not use nc version"
# the skill crew says it is for Claude Code only (OpenCode reads ~/.claude/skills too) and fetches the text
grep -q '^description: Claude Code only\.' "$REPO/skills/crew/SKILL.md" && grep -q 'nc orchestrator claude' "$REPO/skills/crew/SKILL.md" \
  || fail "skill crew: description without 'Claude Code only.' or no nc orchestrator claude"
ok "skill frontmatter is valid (name = folder, description present), crew is for Claude Code only"

# 6. OpenCode: pinned binary under ~/.nc, linked into ~/.local/bin
[ "$(readlink "$HOME/.local/bin/opencode")" = "$HOME/.nc/opencode/$PIN/opencode" ] || fail "opencode not linked"
[ "$(opencode --version)" = "opencode v$PIN" ] || fail "opencode on PATH is not the installed one"
ok "OpenCode $PIN installed under ~/.nc/opencode and linked"

# 7. secrets.env: template with 600, never overwritten
S="$HOME/.config/nc-harness/secrets.env"
[ "$(mode_of "$S")" = 600 ] || fail "secrets.env not 600"
grep -qx "OPENROUTER_API_KEY=" "$S" || fail "secrets.env template has no empty key line"
grep -qx "OPENROUTER_API_KEY_CLIENTS=" "$S" || fail "secrets.env template has no empty line for the clients key"
grep -B1 -x "OPENROUTER_API_KEY_CLIENTS=" "$S" | head -1 | grep -q "^# .*free" || fail "no comment line before the clients key"
ok "secrets.env created as empty template with 600 (both keys, a comment before the clients key)"

# 8. second run changes nothing, does not download, keeps secrets.env; a dry run does not start OpenCode
printf 'OPENROUTER_API_KEY=%s\n' "$SYNTH" > "$S"
before_secret="$(sha "$S")"
tree() { find "$HOME" -path "$HOME/.nc/memory/.git" -prune -o -print | sort; }   # git pull may add FETCH_HEAD
before="$(tree)"
NC_OPENCODE_URL="file://$T/does-not-exist" "$REPO/install.sh" > "$T/run2.log" || { cat "$T/run2.log"; fail "second run failed"; }
after="$(tree)"
changed="backed up|linked|created|downloaded|removed|cloned|updated|replaced"
grep -qE "$changed" "$T/run1.log" || fail "the pattern for changes matches nothing in the first run"   # positive control
grep -qE "$changed" "$T/run2.log" && fail "second run changed something"
grep -q "ok         agents up to date" "$T/run2.log" || fail "second run did not check the agent files"
grep -q "memory up to date" "$T/run2.log" || fail "second run did not check the memory"
[ "$before" = "$after" ] || { diff <(echo "$before") <(echo "$after") >&2 || true; fail "second run changed the file tree"; }
[ "$(sha "$S")" = "$before_secret" ] || fail "second run touched secrets.env"
rm -f "$HOME/.opencode-ran"
"$REPO/install.sh" --dry-run > /dev/null
[ ! -e "$HOME/.opencode-ran" ] || fail "dry run executed the installed OpenCode"
ok "second run is a no-op (no download, secrets.env untouched); dry run does not start OpenCode"

# 8b. there is no default memory remote: without NC_MEMORY_REMOTE an existing checkout is still updated from its own
#     remote, and a missing one is skipped with a hint to the template
env -u NC_MEMORY_REMOTE NC_OPENCODE_URL="file://$T/does-not-exist" "$REPO/install.sh" > "$T/run2b.log" || { cat "$T/run2b.log"; fail "run without NC_MEMORY_REMOTE failed"; }
grep -q "memory up to date" "$T/run2b.log" || fail "without NC_MEMORY_REMOTE the existing memory was not checked"
mv "$HOME/.nc/memory" "$T/memory-aside"
env -u NC_MEMORY_REMOTE "$REPO/install.sh" --dry-run > "$T/dry2b.log"
grep -q "skipped .*NC_MEMORY_REMOTE.*nc-memory-template" "$T/dry2b.log" || fail "no template hint: $(grep -A1 '^Memory' "$T/dry2b.log")"
grep -q "clone " "$T/dry2b.log" && fail "a clone was announced without NC_MEMORY_REMOTE"
# memory is optional: a real run without it ends green (doctor is its last step), the memory line only warns
env -u NC_MEMORY_REMOTE NC_OPENCODE_URL="file://$T/does-not-exist" "$REPO/install.sh" > "$T/run2c.log" || { cat "$T/run2c.log"; fail "install without NC_MEMORY_REMOTE and without a memory checkout failed"; }
nc doctor --json > "$T/doc-nomem.json" || true
[ "$(check "$T/doc-nomem.json" "~/.nc/memory")" = "warn none – set NC_MEMORY_REMOTE to your copy of nc-memory-template, then ./install.sh" ] || fail "missing memory: $(check "$T/doc-nomem.json" "~/.nc/memory")"
[ ! -e "$HOME/.nc/memory" ] || fail "install created ~/.nc/memory without NC_MEMORY_REMOTE"
mv "$T/memory-aside" "$HOME/.nc/memory"
ok "without NC_MEMORY_REMOTE: an existing memory checkout is updated, a missing one is skipped with a hint and only warns"

# 9. dangling links into skills/ are reported and removed; alias and foreign links stay
ln -s "$REPO/skills/gone-skill" "$HOME/.claude/skills/gone-skill"
ln -s "$REPO/skills/nc-harness-check" "$HOME/.claude/skills/check-alias"
ln -s "$T/elsewhere" "$HOME/.claude/skills/foreign"
nc doctor > "$T/doc-stale.log" || true
grep -q "gone-skill .*no longer in the repo" "$T/doc-stale.log" || fail "doctor does not report the stale skill link"
grep -q "check-alias" "$T/doc-stale.log" && fail "doctor reports a valid alias link as stale"
"$REPO/install.sh" > "$T/run3.log"
[ ! -L "$HOME/.claude/skills/gone-skill" ] || fail "stale skill link not removed"
[ -L "$HOME/.claude/skills/check-alias" ] || fail "alias link to an existing skill removed"
[ -L "$HOME/.claude/skills/foreign" ] || fail "foreign link removed"
grep -q "removed" "$T/run3.log" || fail "removal not reported"
rm "$HOME/.claude/skills/foreign" "$HOME/.claude/skills/check-alias"
ok "dangling skill links are reported and removed, alias and foreign links stay"

# 10. doctor is green, its OpenCode check is ok, JSON is valid, the key value never shows up
nc doctor > "$T/doc.log" || { cat "$T/doc.log"; fail "nc doctor not green"; }
grep -q "^all green (" "$T/doc.log" || fail "doctor text output without the all-green line: $(tail -2 "$T/doc.log")"
nc doctor --json > "$T/doc.json" || fail "nc doctor --json not green"
bun -e 'const r = await Bun.file(process.argv[1]).json(); if (!r.ok || r.failed || r.mode !== "direct") process.exit(1)' "$T/doc.json" \
  || fail "nc doctor --json not ok"
[ "$(check "$T/doc.json" opencode)" = "ok $PIN" ] || fail "doctor's OpenCode check: $(check "$T/doc.json" opencode)"
[ "$(check "$T/doc.json" "$HOME/.config/opencode/service.json" | cut -d' ' -f1)" = "absent" ] || true
[ "$(check "$T/doc.json" OPENROUTER_API_KEY | cut -d' ' -f1)" = ok ] || fail "doctor does not report the key as present"
! grep -q "$SYNTH" "$T/doc.log" "$T/doc.json" || fail "doctor printed the key"
is_mcp="$(check "$T/doc.json" MCP)"
[ "$is_mcp" = "ok no servers" ] || fail "doctor's MCP line with servers: {}: $is_mcp"
ok "nc doctor is green (text and --json), OpenCode $PIN ok, key present without its value, MCP: no servers"

# 10a. nc orchestrator: base.md plus the overlay, an unknown overlay is exit 2
nc orchestrator claude > "$T/orch.out" || fail "nc orchestrator claude failed"
grep -qx "## Plan: musts, phase → lane → task" "$T/orch.out" && grep -qx "## Claude Code" "$T/orch.out" || fail "nc orchestrator claude lacks base or claude"
grep -qx "## OpenCode (OpenAI models)" "$T/orch.out" && fail "nc orchestrator claude has the openai overlay"
code=0; nc orchestrator openai > /dev/null 2>&1 || code=$?; [ "$code" = 2 ] || fail "nc orchestrator openai: exit $code, expected 2 (overlay removed)"
for bad in xyz ../roles/tester "" ; do
  code=0; nc orchestrator "$bad" > /dev/null 2> "$T/orch.err" || code=$?
  [ "$code" = 2 ] || fail "nc orchestrator '$bad': exit $code, expected 2"
done
code=0; nc orchestrator > /dev/null 2>&1 || code=$?; [ "$code" = 2 ] || fail "nc orchestrator without an overlay: exit $code"
code=0; nc orchestrator claude openai > /dev/null 2>&1 || code=$?; [ "$code" = 2 ] || fail "nc orchestrator with two overlays: exit $code"
code=0; NC_HARNESS_VERSION=0123456789abcdef nc orchestrator claude > /dev/null || code=$?; [ "$code" = 0 ] || fail "nc orchestrator in a container: exit $code"
ok "nc orchestrator claude: base plus the claude overlay only (also in a container); unknown, path-like, empty, missing or two overlays: exit 2"

# 10b. doctor: the clients key present, missing or invalid; with both lines both are present (values never shown).
CK=OPENROUTER_API_KEY_CLIENTS
[ "$(check "$T/doc.json" $CK)" = "warn missing – OpenCode does not start in client tasks" ] \
  || fail "doctor without the clients key: $(check "$T/doc.json" $CK)"
for content in "OPENROUTER_API_KEY=$SYNTH\n$CK=$SYNTH-clients" "$CK=$SYNTH-clients\nOPENROUTER_API_KEY=$SYNTH"; do
  printf '%b\n' "$content" > "$S"
  nc doctor --json > "$T/doc-k.json" || fail "doctor not green with both keys"
  [ "$(check "$T/doc-k.json" OPENROUTER_API_KEY)" = "ok present in secrets.env" ] || fail "first key with both lines: $(check "$T/doc-k.json" OPENROUTER_API_KEY)"
  [ "$(check "$T/doc-k.json" $CK)" = "ok present in secrets.env" ] || fail "clients key with both lines: $(check "$T/doc-k.json" $CK)"
  ! grep -q "$SYNTH" "$T/doc-k.json" || fail "doctor printed a key"
done
printf 'OPENROUTER_API_KEY=%s\n%s=sk-or-x # comment\n' "$SYNTH" $CK > "$S"
if nc doctor --json > "$T/doc-k.json"; then fail "doctor accepted an invalid clients key"; fi
check "$T/doc-k.json" $CK | grep -q "^fail invalid in " || fail "invalid clients key: $(check "$T/doc-k.json" $CK)"
[ "$(check "$T/doc-k.json" OPENROUTER_API_KEY | cut -d' ' -f1)" = ok ] || fail "an invalid clients key spoiled the first key"
printf '%s=%s\n' $CK "$SYNTH" > "$S"
nc doctor --json > "$T/doc-k.json" || true
[ "$(check "$T/doc-k.json" OPENROUTER_API_KEY | cut -d' ' -f1)" = warn ] || fail "the clients line counted as OPENROUTER_API_KEY"
# an empty value is missing, a malformed one invalid; only the whole name before "=" counts; never shown as a value
while IFS='|' read -r content want; do
  printf '%b\n' "OPENROUTER_API_KEY=$SYNTH\n$content" > "$S"
  code=0; nc doctor --json > "$T/doc-k.json" || code=$?
  got="$(check "$T/doc-k.json" $CK)"
  case "$want" in
    ok) [ "$got" = "ok present in secrets.env" ] && [ "$code" = 0 ] || fail "[$content]: $got (exit $code)" ;;
    invalid) [ "$got" = "fail invalid in ~/.config/nc-harness/secrets.env (space or comment in the value)" ] || fail "[$content]: $got" ;;
    missing) [ "$got" = "warn missing – OpenCode does not start in client tasks" ] || fail "[$content]: $got" ;;
  esac
  ! grep -q "sk-or-new" "$T/doc-k.json" || fail "doctor printed the key"
done <<EOF
$CK=sk-or-new|ok
$CK=|missing
$CK=""|missing
$CK=sk-or-bad # x|invalid
${CK}X=sk-or-new|missing
EOF
printf 'OPENROUTER_API_KEY=%s\n' "$SYNTH" > "$S"
ok "doctor reports the clients key as present, missing (warning) or invalid (failure); an empty value is missing; each name reads only its own line"

# 11. doctor warns on a wrong OpenCode version
mkdir -p "$T/otherver"
printf '#!/usr/bin/env bash\necho "opencode v0.0.1"\n' > "$T/otherver/opencode"; chmod 755 "$T/otherver/opencode"
PATH="$T/otherver:$PATH" nc doctor --json > "$T/doc-ver.json" || true
check "$T/doc-ver.json" opencode | grep -q "^warn 0.0.1, pinned is $PIN" || fail "doctor did not warn on 0.0.1: $(check "$T/doc-ver.json" opencode)"
ok "nc doctor warns when OpenCode is not the pinned version"

# Mac prerequisites. A folder with links to every program on $PATH except the names given, for a PATH without them.
linkbin() {  # linkbin <dir> <name…>
  local dir="$1" d f n; shift
  local skip=" $* "
  mkdir -p "$dir"
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      n="${f##*/}"
      [ -x "$f" ] && [ ! -d "$f" ] || continue
      case "$skip" in *" $n "*) continue ;; esac
      [ -e "$dir/$n" ] || [ -L "$dir/$n" ] || ln -s "$f" "$dir/$n"
    done
  done
}
ISO="ok isolation only on the server"

# 11b. opencode: the pinned file, not only the version. The same version before ~/.local/bin fails on the Mac and
#      warns on the server; the pinned file (also through a link) is ok, a wrong version keeps its message (regressions)
mkdir -p "$T/samever" && cp "$T/fake/opencode" "$T/samever/opencode"
want="another opencode before ~/.local/bin on PATH: $T/samever/opencode (pinned: ~/.nc/opencode/$PIN/opencode)"
if PATH="$T/samever:$PATH" NC_MACHINE=mac nc doctor --json > "$T/doc-same.json"; then fail "Mac doctor green with an unpinned opencode first"; fi
[ "$(check "$T/doc-same.json" opencode)" = "fail $want" ] || fail "Mac, unpinned opencode: $(check "$T/doc-same.json" opencode)"
PATH="$T/samever:$PATH" nc doctor --json > "$T/doc-same.json" || fail "server doctor not green with an unpinned opencode (a warning only)"
[ "$(check "$T/doc-same.json" opencode)" = "warn $want" ] || fail "server, unpinned opencode: $(check "$T/doc-same.json" opencode)"
NC_MACHINE=mac nc doctor --json > "$T/doc-same.json" || true
[ "$(check "$T/doc-same.json" opencode)" = "ok $PIN" ] || fail "regression, Mac with the pinned opencode: $(check "$T/doc-same.json" opencode)"
mkdir -p "$T/oclink" && ln -s "$HOME/.local/bin/opencode" "$T/oclink/opencode"
PATH="$T/oclink:$PATH" NC_MACHINE=mac nc doctor --json > "$T/doc-same.json" || true
[ "$(check "$T/doc-same.json" opencode)" = "ok $PIN" ] || fail "regression, Mac with a link to the pinned opencode: $(check "$T/doc-same.json" opencode)"
PATH="$T/otherver:$PATH" NC_MACHINE=mac nc doctor --json > "$T/doc-same.json" || true
check "$T/doc-same.json" opencode | grep -q "^warn 0.0.1, pinned is $PIN" || fail "regression, Mac with a wrong version: $(check "$T/doc-same.json" opencode)"
ok "doctor checks the pinned path: an unpinned opencode of the same version fails on the Mac and warns on the server; pinned (also linked) ok, wrong version unchanged"

# 11c. Mac, PATH without nc-work and mise: the isolation lines are ok (no isolation on the Mac), the clients key is not needed,
#      mise is ok with Bun from Homebrew, node found is ok; a fake nc-work on PATH is a warning
linkbin "$T/macbin" nc-work mise
NC_MACHINE=mac PATH="$T/macbin" nc doctor --json > "$T/doc-mac.json" || true
for n in "docker without sudo" nc-work "nc delegate"; do
  [ "$(check "$T/doc-mac.json" "$n")" = "$ISO" ] || fail "Mac line $n: $(check "$T/doc-mac.json" "$n")"
done
[ "$(check "$T/doc-mac.json" $CK)" = "ok only for nc-work, not needed on the Mac" ] || fail "Mac clients key: $(check "$T/doc-mac.json" $CK)"
[ "$(check "$T/doc-mac.json" mise)" = "ok not needed – Bun from Homebrew" ] || fail "Mac mise: $(check "$T/doc-mac.json" mise)"
[ "$(check "$T/doc-mac.json" node | cut -d' ' -f1)" = ok ] || fail "Mac node found: $(check "$T/doc-mac.json" node)"
[ "$(check "$T/doc-mac.json" opencode)" = "ok $PIN" ] || fail "Mac opencode through the link folder: $(check "$T/doc-mac.json" opencode)"
mkdir -p "$T/fakework" && printf '#!/bin/sh\nexit 0\n' > "$T/fakework/nc-work" && chmod 755 "$T/fakework/nc-work"
NC_MACHINE=mac PATH="$T/fakework:$T/macbin" nc doctor --json > "$T/doc-mac2.json" || true
[ "$(check "$T/doc-mac2.json" nc-work)" = "warn nc-work on the Mac – the harness plans no isolation here ($T/fakework/nc-work)" ] \
  || fail "Mac with nc-work: $(check "$T/doc-mac2.json" nc-work)"
ok "Mac without nc-work and mise: docker, nc-work, nc delegate ok, clients key not needed, mise ok (Bun from Homebrew); nc-work on the Mac warns"

# 11d. node missing: a warning on the Mac, still a failure on the server; server lines without nc-work and mise unchanged (regressions)
linkbin "$T/macbin-nonode" nc-work mise node
NC_MACHINE=mac PATH="$T/macbin-nonode" nc doctor --json > "$T/doc-nn.json" || true
[ "$(check "$T/doc-nn.json" node)" = "warn not found – nothing in the harness needs Node (Mac: fnm)" ] || fail "Mac without node: $(check "$T/doc-nn.json" node)"
PATH="$T/macbin-nonode" nc doctor --json > "$T/doc-nn.json" || true
[ "$(check "$T/doc-nn.json" node)" = "fail not found – set up the machine (mise)" ] || fail "regression, server without node: $(check "$T/doc-nn.json" node)"
[ "$(check "$T/doc-nn.json" mise)" = "warn not found – set up the machine" ] || fail "regression, server without mise: $(check "$T/doc-nn.json" mise)"
[ "$(check "$T/doc-nn.json" nc-work)" = "warn not found – needed only on servers (nc-infra)" ] || fail "regression, server without nc-work: $(check "$T/doc-nn.json" nc-work)"
check "$T/doc-nn.json" "nc delegate" | grep -q "^warn nc-work not found – nc delegate refuses" || fail "regression, server nc delegate: $(check "$T/doc-nn.json" "nc delegate")"
grep -q "isolation only" <<<"$ISO" || fail "the pattern for the Mac's docker line matches nothing"   # positive control
check "$T/doc-nn.json" "docker without sudo" | grep -q "isolation only" && fail "regression, the server's docker line says isolation only on the server"
[ "$(check "$T/doc-nn.json" $CK)" = "warn missing – OpenCode does not start in client tasks" ] || fail "regression, server clients key: $(check "$T/doc-nn.json" $CK)"
check "$T/doc-nn.json" machine | grep -q absent || fail "a machine line with a valid machine"
ok "node missing: warning on the Mac, failure on the server; server lines for mise, nc-work, nc delegate, docker and the clients key unchanged"

# 11e. flock, a new line on both machines: missing is a warning, present ok. Only $T/noflock on the PATH: linkbin links
#      bun and every other program there, and $BUN_DIR (on the Mac /opt/homebrew/bin) may hold flock itself
linkbin "$T/noflock" flock
mkdir -p "$T/fakeflock" && printf '#!/bin/sh\necho "flock (fake) 0.1"\n' > "$T/fakeflock/flock" && chmod 755 "$T/fakeflock/flock"
for m in server mac; do
  NC_MACHINE=$m PATH="$T/noflock" nc doctor --json > "$T/doc-fl.json" || true
  [ "$(check "$T/doc-fl.json" flock)" = "warn not found – nc memory writes without a lock (Mac: brew install flock)" ] || fail "$m without flock: $(check "$T/doc-fl.json" flock)"
  NC_MACHINE=$m PATH="$T/fakeflock:$T/noflock" nc doctor --json > "$T/doc-fl.json" || true
  [ "$(check "$T/doc-fl.json" flock)" = "ok flock (fake) 0.1" ] || fail "$m with flock: $(check "$T/doc-fl.json" flock)"
done
ok "flock: missing warns (nc memory without a lock), present is ok, on the server and the Mac"

# 11f. NC_MACHINE other than server or mac: nc generate exit 2 with the reason, nc doctor a fail line (no stack trace)
code=0; NC_MACHINE=xyz nc generate > /dev/null 2> "$T/gen-xyz.err" || code=$?
[ "$code" = 2 ] && grep -q 'NC_MACHINE is "xyz", allowed: server, mac' "$T/gen-xyz.err" || fail "nc generate with NC_MACHINE=xyz: exit $code, $(cat "$T/gen-xyz.err")"
if NC_MACHINE=xyz nc doctor --json > "$T/doc-xyz.json" 2> "$T/doc-xyz.err"; then fail "doctor green with NC_MACHINE=xyz"; fi
[ "$(check "$T/doc-xyz.json" machine)" = 'fail NC_MACHINE is "xyz", allowed: server, mac' ] || fail "doctor with NC_MACHINE=xyz: $(check "$T/doc-xyz.json" machine)"
[ ! -s "$T/doc-xyz.err" ] || fail "doctor with NC_MACHINE=xyz wrote to stderr: $(cat "$T/doc-xyz.err")"
ok "NC_MACHINE=xyz: nc generate exit 2 with the allowed values, nc doctor a fail line machine"

# 12. exported key: warning, but not inside an nc opencode session; loose permissions fail
OPENROUTER_API_KEY=x nc doctor > "$T/doc-env.log" || true
grep -q "in the shell .*exported" "$T/doc-env.log" || fail "doctor does not warn about an exported key"
OPENROUTER_API_KEY=x NC_OPENCODE=1 nc doctor > "$T/doc-env2.log" || true
grep -q "in the shell .*from nc opencode" "$T/doc-env2.log" || fail "doctor warns inside an nc opencode session"
chmod 644 "$S"
if nc doctor > "$T/doc-perm.log"; then fail "doctor accepted secrets.env with 644"; fi
chmod 600 "$S"
ok "nc doctor warns about an exported key (not inside nc opencode) and fails on 644"

# 13. nc opencode: key only for the OpenCode process, never in argv, no extra flags
out="$(nc opencode run hello)"
grep -qx "args: run hello" <<<"$out" || fail "nc opencode args: $out"
grep -qx "key: $SYNTH" <<<"$out" || fail "nc opencode did not pass the key"
grep -qx "marker: 1" <<<"$out" || fail "nc opencode did not set NC_OPENCODE"
grep -qx "args: models --help" <<<"$(nc opencode models --help)" || fail "nc opencode changed the arguments of models"
ok "nc opencode passes the key to OpenCode only, not in argv, arguments unchanged"

# 13b. OpenCode reading its config elsewhere (XDG_CONFIG_HOME/OPENCODE_CONFIG_DIR): refused, doctor fails,
#      because the shared background server would start and keep the key
for var in XDG_CONFIG_HOME OPENCODE_CONFIG_DIR; do
  if env "$var=$T/elsewhere-config" nc opencode run x > /dev/null 2> "$T/xdg.err"; then fail "nc opencode started with $var elsewhere"; fi
  grep -q "service.json does not switch off" "$T/xdg.err" || fail "no service.json message for $var"
  env "$var=$T/elsewhere-config" nc doctor --json > "$T/xdg.json" || true
  check "$T/xdg.json" "OpenCode configuration" | grep -q "^fail" || fail "doctor did not notice $var: $(check "$T/xdg.json" "OpenCode configuration")"
done
mv "$HOME/.config/opencode/service.json" "$T/service.json.away"
if nc opencode run x > /dev/null 2>&1; then fail "nc opencode started without service.json"; fi
mv "$T/service.json.away" "$HOME/.config/opencode/service.json"
[ "$(check "$T/doc.json" "OpenCode configuration" | cut -d' ' -f1)" = ok ] || fail "doctor's config check not ok in the normal case"
ok "nc opencode refuses and doctor fails when OpenCode would not read the harness' service.json"

# 14. one parsing rule for nc opencode and nc doctor (nc-work tests the same table, for the clients key)
#     each case: <file content, N for the name> | <expected key, or ! for refused>
B=$'\xef\xbb\xbf'
# in a file: bash 3.2 misparses quotes in a here-document inside a command substitution
cat > "$T/table" <<EOF
N=sk-a|sk-a
N=sk-a   |sk-a
N="sk-a" |sk-a
N='sk-a'|sk-a
N= sk-a|sk-a
  N=sk-a|sk-a
export N=sk-a|sk-a
export\tN=sk-a|sk-a
N=sk-a\r|sk-a
${B}N=sk-a|sk-a
N=old\nN=sk-new|sk-new
N=sk-a # comment|!
N=sk-a\0302\0240|!
N=sk-\0303\0244|!
N=" "|!
N=|!
OTHER=1|!
EOF
rows=0
for name in OPENROUTER_API_KEY $CK; do
  while IFS='|' read -r row expect; do
    content="${row//N=/$name=}"
    printf '%b\n' "$content" > "$S"
    nc doctor --json > "$T/case.json" || true
    if [ "$name" = OPENROUTER_API_KEY ]; then
      got="$(nc opencode run x 2>/dev/null | sed -n 's/^key: //p' || true)"
      state="$(check "$T/case.json" OPENROUTER_API_KEY | cut -d' ' -f1)"
      if [ "$expect" = "!" ]; then
        [ -z "$got" ] || fail "nc opencode accepted [$content]"
        [ "$state" != ok ] || fail "doctor ok for [$content], nc opencode refuses"
      else
        [ "$got" = "$expect" ] || fail "nc opencode read [$got] from [$content], expected [$expect]"
        [ "$state" = ok ] || fail "doctor $state for [$content], nc opencode accepts"
      fi
    else                                       # the clients line: present, or not
      found="$(check "$T/case.json" $CK)"
      accepted="ok present in secrets.env"
      if [ "$expect" = "!" ]; then [ "$found" != "$accepted" ] || fail "doctor accepted [$content]: $found"
      else [ "$found" = "$accepted" ] || fail "doctor did not accept [$content]: $found"; fi
    fi
    rows=$((rows + 1))
  done < "$T/table"
done
[ "$rows" = 34 ] || fail "the parse table ran $rows rows, expected 2 x 17"
chmod 700 "$S"; printf 'OPENROUTER_API_KEY=%s\n' "$SYNTH" > "$S"
grep -qx "key: $SYNTH" <<<"$(nc opencode run x)" || fail "nc opencode refused 700"
nc doctor > /dev/null || fail "doctor refused 700"
chmod 644 "$S"
if nc opencode run x 2> /dev/null; then fail "nc opencode accepted 644"; fi
chmod 600 "$S"
ok "nc opencode and nc doctor agree on 17 secrets.env cases and on permissions; doctor reads the clients key by the same rule"

# 15. nc version in direct mode
nc version | grep -Eq '^nc-harness [0-9a-f]{7}(\+dirty)? direct$' || fail "nc version direct: $(nc version)"
ok "nc version shows commit and mode (direct)"

# 16. a broken link fails doctor
rm "$HOME/.claude/CLAUDE.md"
echo "foreign" > "$HOME/.claude/CLAUDE.md"
if nc doctor > "$T/doc-broken.log"; then fail "doctor did not notice a replaced CLAUDE.md"; fi
BACKS_UP="./install.sh backs it up"   # test 18 checks that this hint stays out for a linked skills folder
grep -q -- "$BACKS_UP" "$T/doc-broken.log" || fail "no backup hint for a replaced link: $(cat "$T/doc-broken.log")"
ok "nc doctor fails when a link is replaced"

# 17. checksum mismatch: stops before anything is linked or created
fresh_home "$T/home-badsum"
if NC_OPENCODE_SHA256="0000" "$REPO/install.sh" > "$T/bad.log" 2>&1; then fail "install accepted a wrong checksum"; fi
grep -q "checksum" "$T/bad.log" || fail "no checksum message"
[ ! -e "$HOME/.local/bin/opencode" ] && [ ! -e "$HOME/.nc/opencode" ] || fail "OpenCode installed despite the wrong checksum"
[ ! -L "$HOME/.claude/CLAUDE.md" ] && [ ! -e "$HOME/.config/nc-harness" ] && [ ! -e "$HOME/sandbox" ] || fail "links or files created despite the wrong checksum"
ok "a wrong checksum stops the install before anything is linked or created"

# 18. ~/.claude/skills as a link into the repo: refused, the repo stays intact (on a copy of the repo)
cp -a "$REPO" "$T/repo-copy"
RC="$T/repo-copy"
mkdir -p "$T/linked-skill-src" && printf -- '---\nname: linked-skill\ndescription: x\n---\n' > "$T/linked-skill-src/SKILL.md"
ln -s "$T/linked-skill-src" "$RC/skills/linked-skill"     # a skill folder that is a link in the repo
fresh_home "$T/home-dirlink"
rm -rf "$HOME/.claude/skills" && ln -s "$RC/skills" "$HOME/.claude/skills"
if "$RC/install.sh" > "$T/dirlink.log" 2>&1; then fail "install accepted ~/.claude/skills as a link into the repo"; fi
grep -q "is a link itself" "$T/dirlink.log" || fail "no message for a linked skills folder: $(tail -3 "$T/dirlink.log")"
[ -f "$RC/skills/nc-harness-check/SKILL.md" ] || fail "install moved a skill out of the repo"
[ -z "$(find "$HOME/.nc/backup" -path '*skills*' 2>/dev/null)" ] || fail "install backed up repo skills"
nc doctor > "$T/dirlink-doc.log" || true
grep -q "skills .*is a link itself – remove it by hand" "$T/dirlink-doc.log" || fail "doctor hint for a linked skills folder"
grep -q -- "$BACKS_UP" "$T/dirlink-doc.log" && fail "doctor suggests install.sh for skills inside a linked folder"
rm "$HOME/.claude/skills" && mkdir "$HOME/.claude/skills"
"$RC/install.sh" > "$T/dirlink2.log" || { cat "$T/dirlink2.log"; fail "install failed after fixing the folder"; }
[ ! -e "$HOME/.claude/skills/linked-skill" ] || fail "a skill folder that is a link in the repo was linked"
nc doctor > "$T/dirlink2-doc.log" || { cat "$T/dirlink2-doc.log"; fail "doctor not green"; }
grep -q "linked-skill" "$T/dirlink2-doc.log" && fail "doctor mentions the skipped linked skill"
ok "a linked ~/.claude/skills is refused without touching the repo; linked skill folders are skipped consistently"

# 18b. ~/.nc/overlay: both AGENTS.md links point into it while its AGENTS.md exists, else into the repo; opencode.json
#      never; doctor shows an overlay line; a dangling overlay stops install.sh; an unknown third word is a bad line
fresh_home "$T/home-ov"
OV="$HOME/.nc/overlay"
mkdir -p "$T/private" "$HOME/.nc" && echo "own rules" > "$T/private/AGENTS.md" && cp "$REPO/models.yaml" "$T/private/"
ln -s "$T/private" "$OV"
"$REPO/install.sh" > "$T/ov1.log" || { cat "$T/ov1.log"; fail "install with an overlay failed"; }
for l in .claude/CLAUDE.md .config/opencode/AGENTS.md; do
  [ "$(readlink "$HOME/$l")" = "$OV/AGENTS.md" ] || fail "$l not linked into the overlay: $(readlink "$HOME/$l")"
done
[ "$(readlink "$HOME/.config/opencode/opencode.json")" = "$REPO/adapters/opencode/opencode.json" ] || fail "opencode.json overlaid"
nc doctor --json > "$T/ov.json" || true
is_check() { [ "$(check "$T/ov.json" "$1")" = "$2" ] || fail "doctor $1: $(check "$T/ov.json" "$1"), expected $2"; }
is_check "~/.claude/CLAUDE.md" "ok -> ~/.nc/overlay/AGENTS.md"
is_check "~/.config/opencode/AGENTS.md" "ok -> ~/.nc/overlay/AGENTS.md"
is_check overlay "ok ~/.nc/overlay: AGENTS.md, models.yaml"
rm "$T/private/AGENTS.md"
nc doctor --json > "$T/ov.json" || true
is_check "~/.claude/CLAUDE.md" "fail points to $OV/AGENTS.md"
"$REPO/install.sh" > "$T/ov2.log" || { cat "$T/ov2.log"; fail "install after removing the overlay AGENTS.md failed"; }
[ "$(readlink "$HOME/.claude/CLAUDE.md")" = "$REPO/AGENTS.md" ] || fail "CLAUDE.md not linked back to the repo"
nc doctor --json > "$T/ov.json" || true
is_check "~/.claude/CLAUDE.md" "ok -> $REPO/AGENTS.md"
is_check overlay "ok ~/.nc/overlay: models.yaml"
rm "$OV" && ln -s "$T/gone" "$OV"
if "$REPO/install.sh" > "$T/ov3.log" 2>&1; then fail "install accepted a dangling overlay"; fi
grep -q "overlay is a dangling link" "$T/ov3.log" || fail "no message for a dangling overlay: $(tail -2 "$T/ov3.log")"
rm "$OV"
cp "$RC/manifest.txt" "$T/manifest.orig"
sed -i.bak 's|^link .claude/CLAUDE.md .*|link .claude/CLAUDE.md AGENTS.md private|' "$RC/manifest.txt"
if "$RC/install.sh" > "$T/ov4.log" 2>&1; then fail "install accepted an unknown third word"; fi
grep -q "bad manifest line: link .claude/CLAUDE.md AGENTS.md private" "$T/ov4.log" || fail "no bad-line message: $(tail -2 "$T/ov4.log")"
if "$RC/bin/nc" doctor > "$T/ov4-doc.log" 2>&1; then fail "doctor accepted an unknown third word"; fi
grep -q "bad manifest line" "$T/ov4-doc.log" || fail "doctor: no bad-line message"
cp "$T/manifest.orig" "$RC/manifest.txt" && rm "$RC/manifest.txt.bak"
ok "overlay: AGENTS.md links follow ~/.nc/overlay/AGENTS.md while it exists and go back to the repo after it is removed; opencode.json stays; doctor overlay line; dangling overlay and unknown third word refused"

# 19. isolated mode on a read-only snapshot, links like nc-infra's entry script makes them
RO="$T/snapshot"
cp -a "$REPO" "$RO" && rm -rf "$RO/.git" "$RO/skills/linked-skill" && chmod -R a-w "$RO"
C="$T/container"
export HOME="$C" PATH="$C/.local/bin:$REAL_PATH" NC_HARNESS_VERSION="0123456789abcdef0123456789abcdef01234567"
mkdir -p "$C/.claude" "$C/.config/opencode" "$C/.local/bin"
ln -s "$RO/AGENTS.md" "$C/.claude/CLAUDE.md"
ln -s "$RO/AGENTS.md" "$C/.config/opencode/AGENTS.md"
ln -s "$RO/adapters/opencode/opencode.json" "$C/.config/opencode/opencode.json"
ln -s "$RO/adapters/opencode/service.json" "$C/.config/opencode/service.json"
ln -s "$RO/skills" "$C/.claude/skills"            # whole folder, as nc-work does
ln -s "$RO/bin/nc" "$C/.local/bin/nc"
cp "$T/fake/opencode" "$C/.local/bin/opencode"
mkdir -p "$T/mem-view/projects" "$T/mem-outbox"              # what nc-work mounts: read-only view, writable outbox
cp "$T/memory-seed/MEMORY.md" "$T/mem-view/" && cp "$T/memory-seed/projects/alpha.md" "$T/mem-view/projects/"
chmod -R a-w "$T/mem-view"
export NC_MEMORY_DIR="$T/mem-view" NC_MEMORY_OUTBOX="$T/mem-outbox" NC_PROJECT=alpha
mkdir -p "$C/.nc/overlay" && echo "agent's own" > "$C/.nc/overlay/AGENTS.md"   # the agent owns HOME: never an overlay
nc doctor --json > "$T/iso.json" || { cat "$T/iso.json"; fail "isolated doctor not green"; }
bun -e '
  const r = await Bun.file(process.argv[1]).json();
  const names = r.checks.map((c) => c.name);
  if (!r.ok || r.mode !== "isolated" || r.harness !== "0123456") process.exit(1);
  for (const n of ["gh", "hc", "docker without sudo", "~/projects/", "~/sandbox/", "mise"]) if (names.includes(n)) process.exit(2);
  if (!names.includes("~/.claude/skills/nc-harness-check")) process.exit(3);
' "$T/iso.json" || fail "isolated doctor checks the wrong things"
check "$T/iso.json" "harness $RO" | grep -q "^ok read-only, commit 0123456" || fail "read-only check: $(check "$T/iso.json" "harness $RO")"
[ "$(check "$T/iso.json" opencode)" = "ok $PIN" ] || fail "isolated OpenCode check: $(check "$T/iso.json" opencode)"
[ "$(nc version)" = "nc-harness 0123456 isolated" ] || fail "nc version isolated: $(nc version)"
ok "isolated doctor is green on a read-only snapshot with nc-work's links, skips host-only checks"

# 19b. isolated: the agent folders nc-work mounts (NC_AGENTS=<claude>:<opencode>), read-only, generated files only
[ "$(check "$T/iso.json" agents)" = "warn task without agent folders (made by an older nc-work) – create a new task for the roles" ] \
  || fail "no warning without NC_AGENTS: $(check "$T/iso.json" agents)"
GENLINE='# GENERATED by nc-harness – do not edit by hand'
AC="$T/ag-claude" AO="$T/ag-opencode"
mkdir -p "$AC" "$AO"
for f in "$AC/tester.md" "$AC/planner.md" "$AO/tester.md"; do printf -- '---\n%s\ndescription: x\n---\nx\n' "$GENLINE" > "$f"; done
chmod 555 "$AC" "$AO"
export NC_AGENTS="$AC:$AO"
nc doctor --json > "$T/iso.json" || { cat "$T/iso.json"; fail "isolated doctor not green with agent folders"; }
[ "$(check "$T/iso.json" MCP)" = "ok no MCP servers in the container" ] || fail "isolated MCP line: $(check "$T/iso.json" MCP)"
[ "$(check "$T/iso.json" "agents $AC")" = "ok read-only, 2 generated file(s)" ] || fail "claude folder: $(check "$T/iso.json" "agents $AC")"
[ "$(check "$T/iso.json" "agents $AO")" = "ok read-only, 1 generated file(s)" ] || fail "opencode folder: $(check "$T/iso.json" "agents $AO")"
agents_fail() {  # agents_fail <folder> <pattern>: nc doctor fails, the check of that folder says why
  if nc doctor --json > "$T/iso.json"; then fail "isolated doctor green although: $2"; fi
  check "$T/iso.json" "agents $1" | grep -q "^fail .*$2" || fail "agent check for $1: $(check "$T/iso.json" "agents $1")"
}
if [ "$(id -u)" != 0 ]; then                           # root writes anyway: no read-only cases
  chmod 755 "$AC"; agents_fail "$AC" "writable"
  printf 'mine\n' > "$AC/mine.md"; chmod 555 "$AC"; agents_fail "$AC" "without the GENERATED line: mine.md"
  chmod 755 "$AC" && rm "$AC/mine.md" && chmod 555 "$AC"
  chmod 755 "$AO" && rm "$AO/tester.md" && chmod 555 "$AO"
  nc doctor --json > "$T/iso.json" || fail "an empty OpenCode folder is not a failure"
  check "$T/iso.json" "agents $AO" | grep -q "^warn empty" || fail "empty OpenCode folder: $(check "$T/iso.json" "agents $AO")"
fi
NC_AGENTS="$AC:$T/missing" agents_fail "$T/missing" "missing"
ln -s "$AO" "$T/ag-link"
NC_AGENTS="$T/ag-link:$AO" agents_fail "$T/ag-link" "is a link"
rm "$T/ag-link"; chmod 755 "$AC" "$AO"; unset NC_AGENTS
ok "isolated doctor: agent folders green when read-only with generated files; writable, a foreign .md, missing or a link fail; no NC_AGENTS and an empty OpenCode folder warn"

# 20. isolated: secrets.env must not exist, nc opencode needs the key from nc-work
mkdir -p "$C/.config/nc-harness" && touch "$C/.config/nc-harness/secrets.env"
if nc doctor > /dev/null; then fail "isolated doctor accepted a secrets.env in the container"; fi
rm -r "$C/.config/nc-harness"
# nc-work opencode gives OpenCode only the key proxy's placeholder; a real value is the old way
OPENROUTER_API_KEY=nc-keyproxy nc doctor --json > "$T/iso-key.json" || { cat "$T/iso-key.json"; fail "isolated doctor not green with the placeholder"; }
[ "$(check "$T/iso-key.json" OPENROUTER_API_KEY)" = "ok placeholder, key in the proxy" ] || fail "placeholder: $(check "$T/iso-key.json" OPENROUTER_API_KEY)"
OPENROUTER_API_KEY="$SYNTH" nc doctor --json > "$T/iso-key.json" || true
check "$T/iso-key.json" OPENROUTER_API_KEY | grep -q "^warn real value in the container (old way?)" || fail "real value: $(check "$T/iso-key.json" OPENROUTER_API_KEY)"
grep -q -- "$SYNTH" "$T/iso-key.json" && fail "doctor printed the key"
nc doctor --json > "$T/iso-key.json" || true
check "$T/iso-key.json" OPENROUTER_API_KEY | grep -q "^warn not set" || fail "unset: $(check "$T/iso-key.json" OPENROUTER_API_KEY)"
if nc opencode run x 2> "$T/iso-oc.err"; then fail "isolated nc opencode started without a key"; fi
grep -q "nc-work opencode" "$T/iso-oc.err" || fail "no hint to nc-work opencode"
grep -qx "key: $SYNTH" <<<"$(OPENROUTER_API_KEY="$SYNTH" nc opencode run x)" || fail "isolated nc opencode lost the key"
rm "$C/.config/opencode/service.json"
if nc doctor > /dev/null; then fail "isolated doctor missed a missing service.json"; fi
ok "isolated: no secrets.env allowed, doctor tells the placeholder from a real key, nc opencode only with a key from nc-work, missing links fail"

echo "$pass tests passed"
