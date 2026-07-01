#!/usr/bin/env bash
# auto-commit.sh — lock-aware auto-commit of vault changes for a given vault root.
#
# Extracted (behavior-preserving) from the PostToolUse inline hook command so it
# can be shared by both the PostToolUse hook (commit after each Write/Edit) and
# the Stop hook (commit pending changes at session end, including writes made via
# the obsidian-vault MCP server, which the Write|Edit matcher never sees).
#
# Behavior (unchanged from the pre-global-access inline command, just parameterized):
#   - No-op unless <vault-root>/.git exists.
#   - No-op if <vault-root>/.vault-meta/auto-commit.disabled exists.
#   - Consult wiki-lock.sh: if `list` errors, log to hook.log and defer (exit 0);
#     if any locks are held, defer (exit 0) — the PostToolUse hook must not commit
#     a half-written page while a multi-writer ingest holds locks.
#   - Otherwise `git add` the vault dirs and commit iff the staged diff is non-empty.
#
# The sibling wiki-lock.sh is located via this script's own directory, so it works
# regardless of cwd or whether $CLAUDE_PLUGIN_ROOT is set.
#
# Usage:
#   bash scripts/auto-commit.sh /abs/path/to/vault
#
# Exit codes:
#   0 — always (advisory hook helper; never blocks the session)

set -uo pipefail

VAULT="${1:-$PWD}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_SH="$SCRIPT_DIR/wiki-lock.sh"

# Resolve to an absolute directory; bail quietly if it isn't one.
VAULT="$(cd "$VAULT" 2>/dev/null && pwd)" || exit 0

# Only touch a git repo.
[ -d "$VAULT/.git" ] || exit 0

# Operator kill-switch.
[ -f "$VAULT/.vault-meta/auto-commit.disabled" ] && exit 0

cd "$VAULT" || exit 0

# Defer the commit while advisory locks are held (multi-writer ingest in flight).
if [ -f "$LOCK_SH" ]; then
  LOCK_LIST="$(WIKI_LOCK_VAULT="$VAULT" bash "$LOCK_SH" list 2>/dev/null)"
  LOCK_RC=$?
  if [ "$LOCK_RC" != "0" ]; then
    mkdir -p "$VAULT/.vault-meta" 2>/dev/null
    printf '%s wiki-lock list failed rc=%s; deferred auto-commit\n' \
      "$(date '+%Y-%m-%dT%H:%M:%SZ')" "$LOCK_RC" \
      >> "$VAULT/.vault-meta/hook.log" 2>/dev/null
    exit 0
  fi
  if [ -n "$LOCK_LIST" ]; then
    exit 0
  fi
fi

# Stage only the sub-dirs that exist. `git add -- <missing-dir>` fails with
# "fatal: pathspec did not match any files" and aborts the WHOLE add (staging
# nothing), which would silently drop a wiki/ change in a fresh/minimal vault
# that has no .raw/ or .vault-meta/ yet (vault-root.sh accepts a wiki-only vault).
for d in wiki .raw .vault-meta; do
  [ -d "$d" ] && git add -- "$d" 2>/dev/null || true
done

# Commit only the vault paths that actually have staged changes. Passing a
# pathspec that matches no tracked/staged files makes `git commit` error out
# ("pathspec did not match any file(s) known to git") and abort the WHOLE
# commit — which is exactly what happens in a fresh or minimal vault where,
# e.g., .raw/ or .vault-meta/ is still empty. Building the pathspec from only
# the dirs with staged changes keeps the commit scoped (never sweeps in the
# user's unrelated staged files) while staying robust to empty/missing dirs.
COMMIT_PATHS=()
for d in wiki .raw .vault-meta; do
  git diff --cached --quiet -- "$d" 2>/dev/null || COMMIT_PATHS+=("$d")
done
if [ "${#COMMIT_PATHS[@]}" -gt 0 ]; then
  git commit -m "wiki: auto-commit $(date '+%Y-%m-%d %H:%M')" -- "${COMMIT_PATHS[@]}" 2>/dev/null || true
fi

exit 0
