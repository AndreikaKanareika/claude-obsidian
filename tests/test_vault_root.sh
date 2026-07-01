#!/usr/bin/env bash
# test_vault_root.sh — unit tests for scripts/vault-root.sh.
#
# Hermetic: throwaway dirs under mktemp, no network, no external deps beyond
# bash + POSIX utils. Covers the resolution contract used by the command hooks:
#   - $CLAUDE_OBSIDIAN_VAULT unset            -> echoes $PWD (pre-global-access behavior)
#   - set to a valid vault (has wiki/)        -> echoes that vault (absolute)
#   - set to a valid vault (has .obsidian/)   -> echoes that vault (absolute)
#   - set to a non-vault dir                  -> falls back to $PWD
#   - set to a nonexistent path               -> falls back to $PWD
#   - set to a relative path to a vault       -> absolutized
#
# Usage: bash tests/test_vault_root.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VR="$ROOT/scripts/vault-root.sh"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "OK   $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label: expected '$expected', got '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

SANDBOX=$(mktemp -d /tmp/vault-root-test-XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

# A directory that looks like a vault (has wiki/)
VAULT_WIKI="$SANDBOX/vault-wiki"
mkdir -p "$VAULT_WIKI/wiki"
VAULT_WIKI_ABS="$(cd "$VAULT_WIKI" && pwd)"

# A directory that looks like a vault (has .obsidian/)
VAULT_OBS="$SANDBOX/vault-obs"
mkdir -p "$VAULT_OBS/.obsidian"
VAULT_OBS_ABS="$(cd "$VAULT_OBS" && pwd)"

# A directory that is NOT a vault
NON_VAULT="$SANDBOX/plain-project"
mkdir -p "$NON_VAULT"

# A neutral cwd to run from (its logical pwd is the fallback)
CWD_DIR="$SANDBOX/somewhere"
mkdir -p "$CWD_DIR"
CWD_ABS="$(cd "$CWD_DIR" && pwd)"

echo "=== test_vault_root.sh ==="
echo "sandbox: $SANDBOX"
echo ""

# ── unset -> $PWD ─────────────────────────────────────────────────────────────
OUT=$( cd "$CWD_DIR" && unset CLAUDE_OBSIDIAN_VAULT 2>/dev/null; bash "$VR" )
assert_eq "unset -> cwd" "$CWD_ABS" "$OUT"

# ── valid vault via wiki/ -> that vault ──────────────────────────────────────
OUT=$( cd "$CWD_DIR" && CLAUDE_OBSIDIAN_VAULT="$VAULT_WIKI" bash "$VR" )
assert_eq "wiki/ vault -> vault" "$VAULT_WIKI_ABS" "$OUT"

# ── valid vault via .obsidian/ -> that vault ─────────────────────────────────
OUT=$( cd "$CWD_DIR" && CLAUDE_OBSIDIAN_VAULT="$VAULT_OBS" bash "$VR" )
assert_eq ".obsidian/ vault -> vault" "$VAULT_OBS_ABS" "$OUT"

# ── non-vault dir -> fall back to cwd ────────────────────────────────────────
OUT=$( cd "$CWD_DIR" && CLAUDE_OBSIDIAN_VAULT="$NON_VAULT" bash "$VR" )
assert_eq "non-vault -> cwd" "$CWD_ABS" "$OUT"

# ── nonexistent path -> fall back to cwd ─────────────────────────────────────
OUT=$( cd "$CWD_DIR" && CLAUDE_OBSIDIAN_VAULT="$SANDBOX/does-not-exist" bash "$VR" )
assert_eq "nonexistent -> cwd" "$CWD_ABS" "$OUT"

# ── relative path to a vault -> absolutized ──────────────────────────────────
# From SANDBOX, "vault-wiki" is a relative vault dir; resolver must absolutize.
OUT=$( cd "$SANDBOX" && CLAUDE_OBSIDIAN_VAULT="vault-wiki" bash "$VR" )
assert_eq "relative vault -> absolute" "$VAULT_WIKI_ABS" "$OUT"

echo ""
echo "Pass: $PASS  Fail: $FAIL"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
echo "All vault-root tests passed."
