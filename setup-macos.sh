#!/usr/bin/env bash
# env-repro / setup-macos.sh
# One-paste reproduction of the environment captured 2026-10-05.
#
#   curl -fsSL https://raw.githubusercontent.com/c0a2302825/env-repro/main/setup-macos.sh | bash
#
# Every version is pinned. Re-running is safe: existing files are left alone.

set -uo pipefail

MANIFEST_URL="https://raw.githubusercontent.com/c0a2302825/env-repro/main/manifests/env-manifest.json"
REPO_RAW="https://raw.githubusercontent.com/c0a2302825/env-repro/main"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- prerequisites
say "OS / arch check"
ARCH="$(uname -m)"
[ "$ARCH" = "arm64" ] || warn "captured host is arm64 (Apple M3); you are $ARCH. Scripts may still work but perf/paths differ."

if ! command -v brew >/dev/null 2>&1; then
  say "Installing Homebrew (this may prompt for sudo)"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
command -v brew >/dev/null 2>&1 || die "Homebrew still unavailable"
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || brew shellenv)"

command -v git >/dev/null 2>&1 || brew install git
command -v curl >/dev/null 2>&1 || die "curl is required"

# ---------------------------------------------------------------- manifest
say "Fetching manifest"
command -v jq >/dev/null 2>&1 || brew install jq
curl -fsSL "$MANIFEST_URL" -o "$WORK/manifest.json" || die "manifest download failed"
MANIFEST="$WORK/manifest.json"

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- tools
say "Installing pinned tools"
run_brew() {
  local pkg="$1"
  if brew list --versions "$pkg" >/dev/null 2>&1; then
    printf '    %-22s already installed (%s)\n' "$pkg" "$(brew list --versions "$pkg" | awk '{print $2}')"
  else
    printf '    %-22s installing...\n' "$pkg"
    brew install "$pkg" >/dev/null 2>&1 || warn "brew install $pkg failed — continuing"
  fi
}

have brew || die
run_brew opencode
run_brew ripgrep
run_brew jq
run_brew gh
run_brew git-lfs
run_brew ollama
if brew list --cask libreoffice >/dev/null 2>&1; then
  printf '    %-22s already installed\n' "libreoffice (cask)"
else
  say "Installing LibreOffice (large download, ~700MB)"
  brew install --cask libreoffice >/dev/null 2>&1 || warn "LibreOffice cask failed — only needed for document QA"
fi

# miniconda: only if python3 is not already miniconda
if [ -x /opt/miniconda3/bin/python3 ]; then
  printf '    %-22s already installed (miniconda)\n' "miniconda3"
else
  say "Installing Miniconda (PATH order matters — see below)"
  brew install --cask miniconda >/dev/null 2>&1 || warn "miniconda cask failed; install it manually"
fi

# node
if have node; then
  printf '    %-22s already installed (%s)\n' "node" "$(node -v)"
else
  run_brew node
fi

# claude code via npm
if have claude; then
  printf '    %-22s already installed (%s)\n' "claude" "$(claude --version 2>/dev/null | head -1)"
else
  say "Installing @anthropic-ai/claude-code@2.1.233"
  npm i -g @anthropic-ai/claude-code@2.1.233 >/dev/null 2>&1 || warn "claude-code install failed"
fi

# ---------------------------------------------------------------- PATH: miniconda first
say "Ensuring miniconda3 precedes other pythons on PATH"
SHELL_RC="$HOME/.zshrc"
touch "$SHELL_RC"
if ! grep -q 'miniconda3/bin' "$SHELL_RC"; then
  cat >> "$SHELL_RC" <<'EOF'

# --- env-repro: miniconda3 must precede system/Homebrew python ---
export PATH="/opt/miniconda3/bin:$PATH"
EOF
  say "added PATH export to $SHELL_RC (restart your shell or: source $SHELL_RC)"
else
  printf '    already present in %s\n' "$SHELL_RC"
fi
export PATH="/opt/miniconda3/bin:$PATH"

# ---------------------------------------------------------------- skills
say "Fetching skills at pinned commits"
mkdir -p "$HOME/.agents/skills" "$HOME/.config/opencode/skills" "$HOME/.claude/skills"

skill_count=$(jq '.skills | length' "$MANIFEST")

fetch_github_skill() {
  local repo="$1" ref="$2" subdir="$3" dest="$4" name="$5" want="$6"
  if [ -f "$dest/SKILL.md" ]; then
    printf '    %-24s already present\n' "$name"
    return 0
  fi
  # Sparse fetch of just the skill folder at the pinned ref.
  local tmp="$WORK/$name"
  mkdir -p "$tmp"
  if ! git clone --quiet --filter=blob:none --no-checkout --depth 1 \
        "https://github.com/$repo.git" "$tmp/repo" >/dev/null 2>&1; then
    warn "$name: clone of $repo failed"
    return 1
  fi
  ( cd "$tmp/repo" \
    && git fetch --quiet --depth 1 origin "$ref" 2>/dev/null \
    && git checkout --quiet "$ref" -- "$subdir" 2>/dev/null ) || {
    warn "$name: ref $ref not fetchable (shallow clone limit)"
    rm -rf "$tmp"
    return 1
  }
  mkdir -p "$(dirname "$dest")"
  cp -R "$tmp/repo/$subdir" "$dest" 2>/dev/null || { warn "$name: copy failed"; return 1; }
  rm -rf "$tmp/repo"

  if [ -n "$want" ]; then
    local got
    got=$(shasum -a 256 "$dest/SKILL.md" 2>/dev/null | cut -c1-16)
    if [ "$got" != "$want" ]; then
      warn "$name: SKILL.md sha256 prefix $got != expected $want"
      return 1
    fi
  fi
  printf '    %-24s ok (%s@%s)\n' "$name" "$repo" "${ref:0:8}"
}

fetch_vendored_skill() {
  local dest="$1" name="$2" file="$3" want="$4"
  if [ -f "$dest/SKILL.md" ]; then
    printf '    %-24s already present\n' "$name"
    return 0
  fi
  mkdir -p "$dest"
  curl -fsSL "$REPO_RAW/$file" -o "$dest/SKILL.md" || { warn "$name: vendored copy download failed"; return 1; }
  local got; got=$(shasum -a 256 "$dest/SKILL.md" | cut -c1-16)
  if [ -n "$want" ] && [ "$got" != "${want:0:16}" ]; then
    warn "$name: sha256 $got != expected ${want:0:16}"
    return 1
  fi
  printf '    %-24s ok (vendored)\n' "$name"
}

for i in $(seq 0 $((skill_count - 1))); do
  name=$(jq -r ".skills[$i].name" "$MANIFEST")
  dest="$HOME/$(jq -r ".skills[$i].dest" "$MANIFEST")"
  src=$(jq -r ".skills[$i].source" "$MANIFEST")
  want=$(jq -r ".skills[$i].skillMdSha256 // empty" "$MANIFEST")
  if [ "$src" = "github" ]; then
    fetch_github_skill "$(jq -r ".skills[$i].repo" "$MANIFEST")" \
                       "$(jq -r ".skills[$i].ref" "$MANIFEST")" \
                       "$(jq -r ".skills[$i].subdir" "$MANIFEST")" \
                       "$dest" "$name" "$want"
  else
    fetch_vendored_skill "$dest" "$name" "$(jq -r ".skills[$i].file" "$MANIFEST")" "$want"
  fi
done

# ---------------------------------------------------------------- symlinks
say "Linking ~/.claude/skills -> ~/.agents/skills"
sl_count=$(jq '.symlinks | length' "$MANIFEST")
for i in $(seq 0 $((sl_count - 1))); do
  from="$HOME/$(jq -r ".symlinks[$i].from" "$MANIFEST")"
  to=$(jq -r ".symlinks[$i].to" "$MANIFEST")
  target="$(cd "$(dirname "$from")" && cd "$(dirname "$to")" && pwd)/$(basename "$to")"
  if [ -L "$from" ]; then
    printf '    %-24s already linked\n' "$(basename "$from")"
  elif [ -e "$from" ]; then
    warn "$(basename "$from") exists and is not a symlink — left untouched"
  elif [ -d "$target" ]; then
    ln -s "$target" "$from"
    printf '    %-24s -> %s\n' "$(basename "$from")" "$(basename "$target")"
  else
    warn "$(basename "$from"): target missing, skipped"
  fi
done

# ---------------------------------------------------------------- config files
say "Writing config files"
cfg_count=$(jq '.configFiles | length' "$MANIFEST")
for i in $(seq 0 $((cfg_count - 1))); do
  dest="$HOME/$(jq -r ".configFiles[$i].dest" "$MANIFEST")"
  tpl=$(jq -r ".configFiles[$i].template" "$MANIFEST")
  if [ -f "$dest" ]; then
    printf '    %-38s already exists (not overwritten)\n' "${dest#$HOME/}"
    continue
  fi
  mkdir -p "$(dirname "$dest")"
  if curl -fsSL "$REPO_RAW/$tpl" -o "$dest"; then
    printf '    %-38s written\n' "${dest#$HOME/}"
  else
    warn "${dest#$HOME/}: download failed"
  fi
done

# opencode plugin dep
say "Installing opencode plugin dependency"
if [ -f "$HOME/.config/opencode/package.json" ]; then
  ( cd "$HOME/.config/opencode" && npm install --silent >/dev/null 2>&1 ) \
    && printf '    %-38s installed\n' "~/.config/opencode/node_modules" \
    || warn "npm install in ~/.config/opencode failed"
fi

# ---------------------------------------------------------------- dirs only
mkdir -p "$HOME/.local/share/opencode"/{log,repos,snapshot,tool-output}
say "Created ~/.local/share/opencode/ (empty — session DB is intentionally not reproduced)"

# ---------------------------------------------------------------- verify
say "Verifying"
curl -fsSL "$REPO_RAW/scripts/verify.sh" -o "$WORK/verify.sh" && chmod +x "$WORK/verify.sh"
REPO_ROOT="" bash "$WORK/verify.sh"

cat <<'EOF'

------------------------------------------------------------------
Done. Open a NEW shell (or `source ~/.zshrc`) so the miniconda3 PATH
export takes effect, then run:  bash <(curl -fsSL https://raw.githubusercontent.com/c0a2302825/env-repro/main/scripts/verify.sh)
------------------------------------------------------------------
EOF
