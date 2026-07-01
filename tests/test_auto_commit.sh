#!/usr/bin/env bash
# test_auto_commit.sh — unit tests for scripts/auto-commit.sh.
#
# Hermetic: a throwaway git repo under mktemp, no network. Covers the shared
# auto-commit contract used by the PostToolUse and Stop hooks:
#   - commits when wiki/ is dirty
#   - no-op (no new commit) when the tree is clean
#   - no-op when .vault-meta/auto-commit.disabled exists
#   - defers (no commit) while an advisory lock is held
#   - no-op / clean exit when the target has no .git
#
# Lock-dependent assertions require flock (used by wiki-lock.sh's meta-lock).
# On a host without flock (e.g. Git Bash on Windows), wiki-lock's `list` errors
# and auto-commit *defers by design* — so those assertions are gated on flock
# presence, and a dedicated assertion verifies the defer-on-lock-error path
# (including the hook.log breadcrumb) instead.
#
# Usage: bash tests/test_auto_commit.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AC="$ROOT/scripts/auto-commit.sh"
LOCK_SH="$ROOT/scripts/wiki-lock.sh"

if command -v flock >/dev/null 2>&1; then HAVE_FLOCK=1; else HAVE_FLOCK=0; fi

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

skip() { echo "SKIP $1 (flock unavailable)"; }

SANDBOX=$(mktemp -d /tmp/auto-commit-test-XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

VAULT="$SANDBOX/vault"
mkdir -p "$VAULT/wiki" "$VAULT/.raw" "$VAULT/.vault-meta"

# Init a hermetic git repo with a local identity (no global config leakage).
git -C "$VAULT" init -q
git -C "$VAULT" config user.email "test@example.com"
git -C "$VAULT" config user.name "Test"
git -C "$VAULT" config commit.gpgsign false
echo "seed" > "$VAULT/README.md"
git -C "$VAULT" add -A
git -C "$VAULT" commit -qm "seed"

count() { git -C "$VAULT" rev-list --count HEAD; }

echo "=== test_auto_commit.sh ==="
echo "sandbox: $SANDBOX"
echo "flock:   $([ "$HAVE_FLOCK" = 1 ] && echo present || echo absent)"
echo ""

# ── disabled kill-switch short-circuits before any lock check (flock-agnostic) ─
touch "$VAULT/.vault-meta/auto-commit.disabled"
echo "world" > "$VAULT/wiki/page-disabled.md"
BEFORE=$(count)
bash "$AC" "$VAULT" >/dev/null 2>&1
AFTER=$(count)
assert_eq "disabled -> no new commit" "0" "$((AFTER - BEFORE))"
rm -f "$VAULT/.vault-meta/auto-commit.disabled"

# ── no .git -> clean exit, no error, and no repo created (flock-agnostic) ────
NOGIT="$SANDBOX/nogit"
mkdir -p "$NOGIT/wiki"
echo "x" > "$NOGIT/wiki/p.md"
bash "$AC" "$NOGIT" >/dev/null 2>&1
assert_eq "no .git -> exit 0" "0" "$?"
[ -d "$NOGIT/.git" ] && MADE=yes || MADE=no
assert_eq "no .git -> repo not created" "no" "$MADE"

# ── flock-agnostic happy path: the add+commit path runs on EVERY host ────────
# auto-commit.sh consults wiki-lock.sh only if it finds it as a sibling; a copy
# with no sibling skips the lock check, so the commit path is exercised even
# where flock is unavailable (Git Bash on Windows). Closes the hole where a
# commit-path regression could pass green on a flock-less host.
NOSIB="$SANDBOX/nolock"
mkdir -p "$NOSIB"
cp "$AC" "$NOSIB/auto-commit.sh"

# Assertions measure commit-COUNT delta, so any untracked leftover from an earlier
# case (e.g. the disabled kill-switch test's page) simply coalesces into this one
# commit — the delta stays exactly 1 regardless of how many files are swept in.
echo "hi" > "$VAULT/wiki/nolock-page.md"
BEFORE=$(count)
bash "$NOSIB/auto-commit.sh" "$VAULT" >/dev/null 2>&1
AFTER=$(count)
assert_eq "no-lock: dirty wiki -> one new commit" "1" "$((AFTER - BEFORE))"

BEFORE=$(count)
bash "$NOSIB/auto-commit.sh" "$VAULT" >/dev/null 2>&1
AFTER=$(count)
assert_eq "no-lock: clean tree -> no new commit" "0" "$((AFTER - BEFORE))"

# ── regression: fresh/minimal vault with NO .raw/ or .vault-meta/ must still ──
# commit the wiki/ change. Before the add-side fix, `git add -- .raw/ .vault-meta/`
# aborted on the missing dirs and staged nothing, silently dropping the change.
FRESH="$SANDBOX/fresh"
mkdir -p "$FRESH/wiki"            # deliberately no .raw/ or .vault-meta/
git -C "$FRESH" init -q
git -C "$FRESH" config user.email "test@example.com"
git -C "$FRESH" config user.name "Test"
git -C "$FRESH" config commit.gpgsign false
echo "seed" > "$FRESH/README.md"
git -C "$FRESH" add -A
git -C "$FRESH" commit -qm "seed"
echo "new" > "$FRESH/wiki/page.md"
FBEFORE=$(git -C "$FRESH" rev-list --count HEAD)
bash "$NOSIB/auto-commit.sh" "$FRESH" >/dev/null 2>&1
FAFTER=$(git -C "$FRESH" rev-list --count HEAD)
assert_eq "fresh vault (no .raw/.vault-meta) -> wiki change commits" "1" "$((FAFTER - FBEFORE))"

if [ "$HAVE_FLOCK" = 1 ]; then
  # ── commits when wiki/ is dirty ────────────────────────────────────────────
  echo "hello" > "$VAULT/wiki/page.md"
  BEFORE=$(count)
  bash "$AC" "$VAULT" >/dev/null 2>&1
  AFTER=$(count)
  assert_eq "dirty wiki -> one new commit" "1" "$((AFTER - BEFORE))"

  # ── no-op when clean ───────────────────────────────────────────────────────
  BEFORE=$(count)
  bash "$AC" "$VAULT" >/dev/null 2>&1
  AFTER=$(count)
  assert_eq "clean tree -> no new commit" "0" "$((AFTER - BEFORE))"

  # ── defers while a lock is held ────────────────────────────────────────────
  echo "world" > "$VAULT/wiki/page2.md"
  WIKI_LOCK_VAULT="$VAULT" bash "$LOCK_SH" acquire wiki/page2.md >/dev/null 2>&1
  BEFORE=$(count)
  bash "$AC" "$VAULT" >/dev/null 2>&1
  AFTER=$(count)
  assert_eq "lock held -> deferred (no commit)" "0" "$((AFTER - BEFORE))"
  WIKI_LOCK_VAULT="$VAULT" bash "$LOCK_SH" release wiki/page2.md >/dev/null 2>&1

  # ── after release, the deferred change commits ─────────────────────────────
  BEFORE=$(count)
  bash "$AC" "$VAULT" >/dev/null 2>&1
  AFTER=$(count)
  assert_eq "after release -> commits deferred change" "1" "$((AFTER - BEFORE))"
else
  skip "dirty wiki -> commit"
  skip "clean tree -> no commit"
  skip "lock held -> deferred"
  skip "after release -> commits"

  # ── defer-on-lock-error safety path (this host's reality) ──────────────────
  # wiki-lock list can't run without flock, so auto-commit must defer AND leave
  # a hook.log breadcrumb rather than committing blindly.
  echo "hello" > "$VAULT/wiki/page.md"
  rm -f "$VAULT/.vault-meta/hook.log"
  BEFORE=$(count)
  bash "$AC" "$VAULT" >/dev/null 2>&1
  AFTER=$(count)
  assert_eq "lock-list error -> deferred (no commit)" "0" "$((AFTER - BEFORE))"
  if grep -q "wiki-lock list failed" "$VAULT/.vault-meta/hook.log" 2>/dev/null; then
    assert_eq "defer logged to hook.log" "yes" "yes"
  else
    assert_eq "defer logged to hook.log" "yes" "no"
  fi
fi

echo ""
echo "Pass: $PASS  Fail: $FAIL"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
echo "All auto-commit tests passed."
