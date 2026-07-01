#!/usr/bin/env bash
# vault-root.sh — resolve the absolute vault root for command hooks.
#
# The claude-obsidian command hooks (hooks/hooks.json) historically used
# cwd-relative paths (wiki/hot.md, .git, .vault-meta/, ...). That only works
# when Claude Code runs *inside* the vault directory. Driving a single global
# vault from another project's directory made every command hook silently
# no-op. This resolver lets the hooks find the vault from any cwd.
#
# Resolution (deterministic, never fails):
#   - If $CLAUDE_OBSIDIAN_VAULT is set AND points at a directory that looks
#     like a vault (contains wiki/ OR .obsidian/) → echo its absolute path.
#   - Otherwise → echo the current working directory ($PWD).
#
# The "looks like a vault" guard means a misconfigured env var (typo, stale
# path, non-vault dir) falls back to cwd = the pre-global-access behavior, instead of
# silently operating on the wrong directory.
#
# Backward compatibility: with $CLAUDE_OBSIDIAN_VAULT unset, this always echoes
# $PWD, so hooks behave exactly as they did before the global-access release.
#
# Usage:
#   V="$(bash scripts/vault-root.sh)"
#
# Exit codes:
#   0 — always (a path is always printed)

set -uo pipefail

# Absolutize a directory path without requiring GNU realpath. Echoes the
# resolved absolute path on success, nothing on failure (caller falls back).
_abspath() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  ( cd "$dir" 2>/dev/null && pwd ) || return 1
}

fallback="$PWD"

candidate="${CLAUDE_OBSIDIAN_VAULT:-}"
if [ -n "$candidate" ]; then
  abs="$(_abspath "$candidate" || true)"
  if [ -n "$abs" ] && { [ -d "$abs/wiki" ] || [ -d "$abs/.obsidian" ]; }; then
    printf '%s\n' "$abs"
    exit 0
  fi
fi

printf '%s\n' "$fallback"
exit 0
