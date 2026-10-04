#!/usr/bin/env bash
# env-repro / scripts/verify.sh — check the reproduced environment against the pinned manifest.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/c0a2302825/env-repro/main/scripts/verify.sh)
#
# Exit code 0 = every check passed, 1 = at least one FAIL.

REPO_RAW="https://raw.githubusercontent.com/c0a2302825/env-repro/main"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; warn=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
wn()   { printf '  \033[33mWARN\033[0m  %s\n' "$*"; warn=$((warn+1)); }

hash_of() { shasum -a 256 "$1" 2>/dev/null | cut -c1-16; }

printf '\n\033[1menv-repro verification\033[0m\n\n'

# ---------------------------------------------------------------- tools
echo "[1/5] toolchain"
check_ver() {
  local cmd="$1" want="$2" label="$3"
  if ! command -v "$cmd" >/dev/null 2>&1; then no "$label: not on PATH"; return; fi
  local got; got="$("$cmd" --version 2>&1 | head -1)"
  case "$got" in
    *"$want"*) ok "$label $want" ;;
    *) wn "$label: expected $want, got '${got:0:40}'" ;;
  esac
}
check_ver opencode 1.18.29 "opencode"
check_ver claude   2.1.233 "claude"
check_ver node     v26.7.0 "node"
check_ver npm      11.19.0 "npm"
check_ver rg       15.2.0 "ripgrep"
check_ver jq       1.7.1 "jq"
check_ver gh       2.100.0 "gh"

# python must be miniconda and first on PATH
PYBIN="$(command -v python3 2>/dev/null)"
if [ -z "$PYBIN" ]; then
  no "python3: not on PATH"
elif [ "$PYBIN" != "/opt/miniconda3/bin/python3" ]; then
  wn "python3 resolves to $PYBIN, expected /opt/miniconda3/bin/python3 — check PATH order"
else
  ok "python3 -> miniconda3 ($("$PYBIN" -V 2>&1))"
fi

# ---------------------------------------------------------------- config
echo
echo "[2/5] config files"
for f in .config/opencode/opencode.jsonc .config/opencode/.opencode.json \
         .config/opencode/package.json .claude/settings.json .agents/.skill-lock.json; do
  if [ -f "$HOME/$f" ]; then ok "$f"; else no "$f missing"; fi
done
if [ -d "$HOME/.config/opencode/node_modules/@opencode-ai/plugin" ]; then
  ok "~/.config/opencode/node_modules (@opencode-ai/plugin)"
else
  wn "@opencode-ai/plugin not installed — run: cd ~/.config/opencode && npm install"
fi

# ---------------------------------------------------------------- skills
echo
echo "[3/5] skills"
# Prefer a local manifest (running from a clone) so verification works offline.
LOCAL_M=""
for cand in "${REPO_ROOT:-}/manifests/env-manifest.json" "$HOME/env-repro/manifests/env-manifest.json" "./manifests/env-manifest.json"; do
  [ -n "$cand" ] && [ -f "$cand" ] && { LOCAL_M="$cand"; break; }
done
if [ -n "$LOCAL_M" ]; then
  M="$LOCAL_M"
  ok "manifest: local ($LOCAL_M)"
elif curl -fsSL "$REPO_RAW/manifests/env-manifest.json" -o "$WORK/m.json" 2>/dev/null; then
  M="$WORK/m.json"
  ok "manifest: fetched from repo"
else
  no "cannot obtain manifest (no local copy, and fetch failed)"
  exit 1
fi

# path helper: works on both mac and (via git-bash) windows layouts
HOMEDIR_WIN="$(cygpath -u "$HOME" 2>/dev/null || echo "$HOME")"

n=$(jq '.skills | length' "$M")
skills_ok=0
for i in $(seq 0 $((n - 1))); do
  name=$(jq -r ".skills[$i].name" "$M")
  dest=$(jq -r ".skills[$i].dest" "$M")
  want=$(jq -r ".skills[$i].skillMdSha256 // empty" "$M")
  f="$HOMEDIR_WIN/$dest/SKILL.md"
  if [ ! -f "$f" ]; then no "skill $name: SKILL.md missing at $dest"; continue; fi
  got=$(hash_of "$f")
  exp="${want:0:16}"
  case "$got" in
    "$exp") ok "skill $name ($got)"; skills_ok=$((skills_ok+1)) ;;
    *) no "skill $name: sha256 $got != $exp" ;;
  esac
done
printf '  ---- %d/%d skills verified\n' "$skills_ok" "$n"

# ---------------------------------------------------------------- symlinks
echo
echo "[4/5] symlinks (~/.claude/skills -> ~/.agents/skills)"
m=$(jq '.symlinks | length' "$M")
for i in $(seq 0 $((m - 1))); do
  from="$HOMEDIR_WIN/$(jq -r ".symlinks[$i].from" "$M")"
  base=$(basename "$from")
  if [ -L "$from" ]; then
    if [ -e "$from" ]; then ok "$base -> $(readlink "$from" | sed 's|.*/||')"; else no "$base: broken symlink"; fi
  elif [ -d "$from" ]; then
    wn "$base is a real directory, expected a symlink"
  else
    no "$base: not linked"
  fi
done

# ---------------------------------------------------------------- runtime
echo
echo "[5/5] runtime state"
if command -v ollama >/dev/null 2>&1; then
  ok "ollama installed ($(ollama --version 2>&1 | head -1))"
  if ollama list >/dev/null 2>&1; then
    ok "ollama server running"
  else
    wn "ollama server not running — matches the captured host; start with: brew services start ollama"
  fi
else
  wn "ollama not installed (optional)"
fi

if command -v soffice >/dev/null 2>&1; then
  ok "LibreOffice present (document QA)"
else
  wn "LibreOffice absent (only needed for pptx/docx -> PDF)"
fi

if [ -f "$HOME/.local/share/opencode/opencode.db" ]; then
  wn "opencode.db exists — this is session state, not part of the reproduction"
else
  ok "no session DB (correct: not reproduced)"
fi

printf '\n\033[1msummary\033[0m  pass=%d  warn=%d  fail=%d\n' "$pass" "$warn" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf '\033[32mEnvironment matches the manifest.\033[0m\n\n'
