#!/usr/bin/env bash
# install.sh – set up nc-harness for the current user. Idempotent.
#
#   ./install.sh            apply manifest.txt, install OpenCode (pins.txt), generate the subagent files (nc generate),
#                           clone the memory, create secrets.env, run `nc doctor`
#   ./install.sh --dry-run  only show what would be linked, backed up and installed
#
# Existing files are moved to ~/.nc/backup/<date>/ before being replaced.
# No sudo, nothing outside $HOME.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MANIFEST="$REPO/manifest.txt"
NC_HOME="${NC_HOME:-$HOME/.nc}"
BACKUP_DIR="$NC_HOME/backup/$(date +%F)"
OVERLAY="$HOME/.nc/overlay"   # fixed, like cli/models.ts: no variable may redirect the policy
DRY_RUN=0

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '  %-10s %s\n' "$1" "$2"; }
tilde() { local p="$1"; case "$p" in "$HOME"/*) p="~/${p#"$HOME"/}" ;; esac; printf '%s' "$p"; }

# --- 1. prerequisites ---------------------------------------------------------
find_bun() {
  command -v bun 2>/dev/null && return
  for c in "$HOME/.local/share/mise/shims/bun" "$HOME/.bun/bin/bun"; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  return 1
}

echo "Prerequisites"
missing=0
if command -v git >/dev/null; then say ok git; else say MISSING "git"; missing=1; fi
if find_bun >/dev/null; then say ok bun; else say MISSING "bun (mise use -g bun@latest)"; missing=1; fi
if command -v claude >/dev/null; then say ok "claude"; else say missing "claude (Claude Code)"; fi
if command -v opencode >/dev/null; then say ok opencode; else say missing "opencode (installed below)"; fi
if command -v hc >/dev/null; then say ok "hc"; else say missing "hc (optional, herdr-core)"; fi
[ "$missing" = 0 ] || { echo "Stopped: required tools are missing." >&2; exit 1; }

# --- helpers -------------------------------------------------------------------
die() { echo "install.sh: $*" >&2; exit 1; }

# Move $1 into the backup dir, keeping its path below $HOME. Sets BACKED_UP. Not run in $(...),
# so a failing mv stops the script instead of being reported as backed up.
move_aside() {
  local target="$1" dest
  dest="$BACKUP_DIR/${target#"$HOME"/}"
  if [ -e "$dest" ] || [ -L "$dest" ]; then dest="$dest.$(date +%H%M%S)"; fi
  mkdir -p "$(dirname "$dest")" && mv "$target" "$dest" || die "could not back up $(tilde "$target")"
  BACKED_UP="$dest"
  say "backed up" "$(tilde "$target") -> $(tilde "$dest")"
}

# True if the physical location of the nearest existing ancestor of $1 lies inside the repo, e.g.
# because ~/.claude/skills is a link to <repo>/skills. Linking or backing up there would move repo files.
inside_repo() {
  local dir="$1" phys
  while [ ! -d "$dir" ]; do dir="$(dirname "$dir")"; done
  phys="$(cd "$dir" && pwd -P)"
  case "$phys/" in "$REPO/"*) return 0 ;; esac
  return 1
}

# --- 2. OpenCode: pinned standalone binary from the GitHub release, checksum from pins.txt ------
# Lands in ~/.nc/opencode/<version>/ and is linked to ~/.local/bin/opencode. No sudo, no shell rc
# changes. Runs before the links, so a failed download changes nothing.
# NC_OPENCODE_URL / NC_OPENCODE_SHA256 replace the download for tests.
oc_platform() {
  local os arch
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) return 1 ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=x64 ;; arm64|aarch64) arch=arm64 ;; *) return 1 ;; esac
  printf '%s-%s' "$os" "$arch"
}
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
oc_version() { "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }

install_opencode() {
  local platform version sum ext url dir bin link current tmp
  platform="$(oc_platform)" || { say missing "opencode (no version for $(uname -sm) in pins.txt)"; return; }
  version="" sum=""
  read -r version sum < <(awk -v p="$platform" '$1 == "opencode" && $3 == p { print $2, $4 }' "$REPO/pins.txt") || true
  [ -n "${version:-}" ] || { say missing "opencode (no version for $platform in pins.txt)"; return; }
  case "$platform" in darwin-*) ext=zip ;; *) ext=tar.gz ;; esac   # release assets: .zip for macOS
  url="${NC_OPENCODE_URL:-https://github.com/anomalyco/opencode/releases/download/v$version/opencode-$platform.$ext}"
  sum="${NC_OPENCODE_SHA256:-$sum}"
  dir="$NC_HOME/opencode/$version"
  bin="$dir/opencode"
  link="$HOME/.local/bin/opencode"

  # A dry run must not start the binary: `opencode --version` already writes into ~/.local/share.
  if [ -x "$bin" ] && { [ "$DRY_RUN" = 1 ] || [ "$(oc_version "$bin")" = "$version" ]; }; then
    :
  elif [ "$DRY_RUN" = 1 ]; then
    say download "opencode $version ($platform) to $(tilde "$dir")/"
  else
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/nc-opencode.XXXXXX")"
    fail() { rm -rf "$tmp"; die "$1"; }
    curl -fsSL --retry 2 -o "$tmp/opencode.$ext" "$url" || fail "download failed: $url"
    [ "$(sha256 "$tmp/opencode.$ext")" = "$sum" ] || fail "checksum of $url does not match, nothing installed"
    if [ "$ext" = zip ]; then unzip -q "$tmp/opencode.$ext" opencode -d "$tmp" || fail "unpacking failed"
    else tar -xzf "$tmp/opencode.$ext" -C "$tmp" opencode || fail "unpacking failed"; fi
    [ "$(oc_version "$tmp/opencode")" = "$version" ] || fail "the downloaded opencode is not version $version"
    mkdir -p "$dir"
    mv "$tmp/opencode" "$bin"
    chmod 755 "$bin"
    rm -rf "$tmp"
    say downloaded "opencode $version to $(tilde "$dir")/ (checksum ok)"
  fi

  if [ -L "$link" ] && [ "$(readlink "$link")" = "$bin" ]; then
    say ok "$(tilde "$link") -> $(tilde "$bin")"; return
  fi
  current="$(readlink "$link" 2>/dev/null || true)"
  if [ "$DRY_RUN" = 1 ]; then
    case "$current" in "$NC_HOME/opencode/"*) ;; *) if [ -e "$link" ] || [ -L "$link" ]; then say "back up" "$(tilde "$link")"; fi ;; esac
    say link "$(tilde "$link") -> $(tilde "$bin")"; return
  fi
  case "$current" in
    "$NC_HOME/opencode/"*) rm "$link" ;;   # an older pinned version of ours
    *) if [ -e "$link" ] || [ -L "$link" ]; then move_aside "$link"; fi ;;
  esac
  mkdir -p "$(dirname "$link")"
  ln -s "$bin" "$link"
  say linked "$(tilde "$link") -> $(tilde "$bin")"
}

echo
[ "$DRY_RUN" = 1 ] && echo "Dry run: nothing is changed"
echo "OpenCode"
install_opencode

# --- 3. directories and links --------------------------------------------------
ensure_dir() {
  local target="$HOME/$1"
  if [ -d "$target" ]; then say ok "$(tilde "$target")/"; return; fi
  if [ "$DRY_RUN" = 1 ]; then say create "$(tilde "$target")/"; return; fi
  if [ -e "$target" ] || [ -L "$target" ]; then move_aside "$target"; fi
  mkdir -p "$target"
  say created "$(tilde "$target")/"
}

# ensure_link <target> <source> [overlay]: with "overlay", ~/.nc/overlay/<source> wins when it exists.
ensure_link() {
  local target="$HOME/$1" source="$REPO/$2"
  [ "${3:-}" = overlay ] && [ -e "$OVERLAY/$2" ] && source="$OVERLAY/$2"
  [ -e "$source" ] || die "source missing: $source"
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
    say ok "$(tilde "$target") -> $(tilde "$source")"; return
  fi
  inside_repo "$(dirname "$target")" && die "$(tilde "$(dirname "$target")") leads into the repo through a link – remove that link by hand, then start again"
  if [ "$DRY_RUN" = 1 ]; then
    if [ -e "$target" ] || [ -L "$target" ]; then
      say "back up" "$(tilde "$target") -> $(tilde "$BACKUP_DIR/${target#"$HOME"/}")"
    fi
    say link "$(tilde "$target") -> $(tilde "$source")"
    return
  fi
  if [ -e "$target" ] || [ -L "$target" ]; then move_aside "$target"; fi
  mkdir -p "$(dirname "$target")"
  ln -s "$source" "$target"
  say linked "$(tilde "$target") -> $(tilde "$source")"
}

# skills <target> <source>: link every skill folder of <source> on its own, never the folder itself
# (Claude Code writes into ~/.claude/skills/synced). Skill folders that are links in the repo are
# skipped. Links into <source> whose skill is gone (dangling) are removed.
ensure_skills() {
  local tdir="$1" sdir="$2" d name l to
  [ -d "$REPO/$sdir" ] || die "source missing: $REPO/$sdir"
  [ -L "$HOME/$tdir" ] && die "$(tilde "$HOME/$tdir") is a link itself – Claude Code writes into it; remove the link by hand, then start again"
  for d in "$REPO/$sdir"/*/; do
    [ -f "$d/SKILL.md" ] && [ ! -L "${d%/}" ] || continue
    name="$(basename "$d")"
    [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { say skipped "$sdir/$name (invalid skill name)"; continue; }
    ensure_link "$tdir/$name" "$sdir/$name"
  done
  for l in "$HOME/$tdir"/*; do
    [ -L "$l" ] || continue
    to="$(readlink "$l")"
    case "$to" in "$REPO/$sdir/"*) ;; *) continue ;; esac
    [ -f "$to/SKILL.md" ] && continue
    if [ "$DRY_RUN" = 1 ]; then say remove "$(tilde "$l") (skill no longer in the repo)"; continue; fi
    rm "$l"
    say removed "$(tilde "$l") (skill no longer in the repo)"
  done
}

echo
echo "Folders and links"
# Fail closed: a dangling overlay would silently link the public AGENTS.md (nc models refuses it too).
[ -L "$OVERLAY" ] && [ ! -e "$OVERLAY" ] && die "$(tilde "$OVERLAY") is a dangling link"
while read -r kind a b c _; do
  case "$kind" in
    ''|\#*) continue ;;
    dir)    ensure_dir "$a" ;;
    link)   case "$c" in ''|overlay) ensure_link "$a" "$b" "$c" ;; *) die "bad manifest line: $kind $a $b $c" ;; esac ;;
    skills) ensure_skills "$a" "$b" ;;
    *) die "bad manifest line: $kind $a $b" ;;
  esac
done < "$MANIFEST"

# --- 3b. subagent files: nc generate (roles/ + models.yaml -> ~/.claude/agents, <OpenCode config>/agents) -----
# Not in an nc-work container: the generation for containers comes from the host. Dry run: only
# `nc generate --check` (exit 1 = something to do, not an error), without Bun's cache in the home folder.
echo
echo "Agents"
if [ -n "${NC_HARNESS_VERSION:-}" ]; then
  say skipped "in a container – the host generates the agent files"
elif [ "$DRY_RUN" = 1 ]; then
  rc=0; BUN_RUNTIME_TRANSPILER_CACHE_PATH=0 "$REPO/bin/nc" generate --check || rc=$?
  [ "$rc" -le 1 ] || die "nc generate --check: exit $rc"
else
  "$REPO/bin/nc" generate || die "nc generate failed – check models.yaml, roles/, orchestrator/ or mcp/servers.yaml (nc doctor)"
fi

# --- 4. shared memory: clone NC_MEMORY_REMOTE to ~/.nc/memory, or fast-forward it ------------------------------
# Never in an nc-work container (no network, no gh): nc-work mounts a read-only view there.
# There is no default remote: without NC_MEMORY_REMOTE a missing checkout is skipped and an existing one is updated
# from its own remote. A checkout with local changes, or another remote than NC_MEMORY_REMOTE, is left alone.
MEMORY_DIR="$NC_HOME/memory"
MEMORY_REMOTE="${NC_MEMORY_REMOTE:-}"
echo
echo "Memory"
if [ -n "${NC_HARNESS_VERSION:-}" ]; then
  say skipped "in a container – nc-work mounts a read-only copy"
elif [ -d "$MEMORY_DIR/.git" ] && [ ! -L "$MEMORY_DIR" ]; then
  origin="$(git -C "$MEMORY_DIR" remote get-url origin 2>/dev/null || true)"
  if [ -n "$MEMORY_REMOTE" ] && [ "$origin" != "$MEMORY_REMOTE" ]; then
    say differs "$(tilde "$MEMORY_DIR") has remote '${origin:-none}', expected $MEMORY_REMOTE – left alone"
  elif [ "$DRY_RUN" = 1 ]; then
    say check "$(tilde "$MEMORY_DIR") (git pull --ff-only)"
  elif [ -n "$(git -C "$MEMORY_DIR" status --porcelain)" ]; then
    say dirty "$(tilde "$MEMORY_DIR") has uncommitted changes – not updated"
  else
    before="$(git -C "$MEMORY_DIR" rev-parse -q --verify HEAD || true)"
    if git -C "$MEMORY_DIR" pull --ff-only -q >/dev/null 2>&1; then
      if [ "$(git -C "$MEMORY_DIR" rev-parse -q --verify HEAD || true)" = "$before" ]; then say ok "$(tilde "$MEMORY_DIR") up to date"
      else say updated "$(tilde "$MEMORY_DIR")"; fi
    else
      say "not updated" "$(tilde "$MEMORY_DIR"): git pull --ff-only failed (no network?) – nc memory sync later"
    fi
  fi
elif [ -z "$MEMORY_REMOTE" ]; then
  say skipped "no memory repo – set NC_MEMORY_REMOTE to your copy of github.com/iAmSerathion/nc-memory-template, then run ./install.sh again"
elif [ "$DRY_RUN" = 1 ]; then
  if [ -e "$MEMORY_DIR" ] || [ -L "$MEMORY_DIR" ]; then say "back up" "$(tilde "$MEMORY_DIR")"; fi
  say clone "$MEMORY_REMOTE to $(tilde "$MEMORY_DIR")"
else
  if [ -e "$MEMORY_DIR" ] || [ -L "$MEMORY_DIR" ]; then move_aside "$MEMORY_DIR"; fi
  mkdir -p "$NC_HOME"
  if git clone -q "$MEMORY_REMOTE" "$MEMORY_DIR" >/dev/null 2>&1; then say cloned "$MEMORY_REMOTE to $(tilde "$MEMORY_DIR")"
  else say MISSING "$(tilde "$MEMORY_DIR"): git clone $MEMORY_REMOTE failed (network, GitHub access?)"; fi
fi

# --- 5. secrets.env: create an empty template if missing, never touch an existing one --------
SECRETS="$HOME/.config/nc-harness/secrets.env"
echo
echo "Keys"
if [ -e "$SECRETS" ] || [ -L "$SECRETS" ]; then
  say ok "$(tilde "$SECRETS") present, stays unchanged"
elif [ "$DRY_RUN" = 1 ]; then
  say create "$(tilde "$SECRETS") (empty template, permissions 600)"
else
  ( umask 077
    mkdir -p "$(dirname "$SECRETS")"
    cat > "$SECRETS" <<'EOF'
# nc-harness – keys. Permissions 600. Never commit, never export into the shell.
# Read only by `nc opencode` (host) and `nc-work opencode` (container), each for that one process only.
OPENROUTER_API_KEY=
# Key of the OpenRouter workspace `clients` (guardrail with the allowed models); nc-work gives it to tasks of
# projects whose policy in models.yaml denies `free`, instead of OPENROUTER_API_KEY.
OPENROUTER_API_KEY_CLIENTS=
EOF
  )
  say created "$(tilde "$SECRETS") (empty template, permissions 600) – add the keys yourself"
fi

[ "$DRY_RUN" = 1 ] && exit 0

# --- 6. PATH and doctor ----------------------------------------------------------
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo; echo "Note: ~/.local/bin is not on PATH. nc can be called only after a new login shell." ;;
esac

echo
"$REPO/bin/nc" doctor
