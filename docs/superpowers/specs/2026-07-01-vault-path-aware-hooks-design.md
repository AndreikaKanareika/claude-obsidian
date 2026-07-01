# Vault-path-aware hooks — design spec

**Date:** 2026-07-01
**Status:** Approved for implementation
**Target version:** 1.9.2-global-access

## Problem

All four command hooks in `hooks/hooks.json` use **current-working-directory-relative**
paths (`wiki/hot.md`, `scripts/wiki-lock.sh`, `.git`, `.vault-meta/`, `wiki/`, `.raw/`).

When the plugin drives a single **global** vault (e.g. `~/second-brain`) from *another*
project's directory, every command hook silently no-ops (`|| true` / `exit 0`):

- **SessionStart** — hot cache is never injected (`[ -f wiki/hot.md ]` is false).
- **PostToolUse (Write|Edit)** — `[ -d .git ] || exit 0` sees the *other* project's repo (or
  none); `git add wiki/ .raw/ .vault-meta/` finds nothing → no vault auto-commit.
- **Stop** — `[ -d wiki ]` is false → no hot-cache-refresh nudge.

Separately, auto-commit **never** fires for vault writes made through the `obsidian-vault`
**MCP** server, because the `PostToolUse` matcher is `Write|Edit` and MCP tool calls are
neither. This is the documented cross-project write path, so its changes never auto-commit.

Failures are silent by design, so the plugin just goes inert cross-project.

## Goals

1. Command hooks operate on the correct vault from **any** working directory.
2. Vault writes made via **MCP** get committed (at session Stop).
3. **Zero behavior change** when running from inside the vault (backward compatible).

Non-goals: changing MCP transport, changing lock semantics, per-hook config beyond one
env var.

## Two-root resolution model

The current hooks conflate two distinct locations. Separate them:

| Root | Holds | Source |
|------|-------|--------|
| **Plugin root** | `scripts/` | `$CLAUDE_PLUGIN_ROOT` (set by Claude Code for plugin hooks); fallback to relative `scripts/` (correct in-vault) |
| **Vault root** | `wiki/`, `.raw/`, `.vault-meta/`, `.git` | `$CLAUDE_OBSIDIAN_VAULT`; if unset/invalid → `$PWD` = today's exact behavior |

`$CLAUDE_OBSIDIAN_VAULT` unset ⇒ every hook resolves vault = `$PWD` ⇒ byte-for-byte the
current behavior. In-vault sessions are untouched.

## New helper scripts (testable, DRY)

### `scripts/vault-root.sh`
Echoes the resolved absolute vault root to stdout. Deterministic; never fails.

```
if $CLAUDE_OBSIDIAN_VAULT is set AND (has wiki/ OR .obsidian/):
    echo "$CLAUDE_OBSIDIAN_VAULT" (absolute)
else:
    echo "$PWD"
```

The "looks like a vault" guard prevents committing into an unrelated directory if the env
var is set to garbage — it falls back to `$PWD` (current behavior) instead.

### `scripts/auto-commit.sh <vault-root>`
The lock-aware `git add`/commit dance, adapted from the current PostToolUse inline command
(behavior-preserving apart from the pathspec-robustness hardening noted below), parameterized
by vault root:

- No-op unless `<vault-root>/.git` exists.
- No-op if `<vault-root>/.vault-meta/auto-commit.disabled` exists.
- If `wiki-lock.sh list` (run with `WIKI_LOCK_VAULT=<vault-root>`) errors → log to
  `<vault-root>/.vault-meta/hook.log`, defer commit (exit 0).
- If any locks are held → defer commit (exit 0).
- Else `git add` only the sub-dirs that **exist** (per-dir, so a missing `.raw/`/`.vault-meta/`
  can't abort the whole add) and commit only the sub-dirs with **staged changes** (so an
  empty sub-dir can't abort the commit). Both guard against the "pathspec did not match any
  file(s)" abort that would otherwise drop the wiki change on a fresh/minimal vault.

Locates `wiki-lock.sh` via its own directory (`BASH_SOURCE`), so it works regardless of
cwd or whether `$CLAUDE_PLUGIN_ROOT` is set. Shared by both PostToolUse and Stop.

## Hook rewrites

- **SessionStart** — resolve `V`; `cat "$V/wiki/hot.md"`; `clear-stale` via the plugin's
  `wiki-lock.sh` with `WIKI_LOCK_VAULT="$V"`.
- **PostToolUse (Write|Edit)** — resolve `V`; `auto-commit.sh "$V"`.
- **Stop** — resolve `V`; **capture `CHANGED`** (wiki files differing vs HEAD) *first*;
  run `auto-commit.sh "$V"` (persists MCP writes); then, if `CHANGED`, emit the existing
  `WIKI_CHANGED` hot-cache-refresh nudge. Capturing before committing keeps the nudge
  firing.
- **Prompt-type hooks** (PostCompact, SessionStart context restore) — reword to reference
  `$CLAUDE_OBSIDIAN_VAULT/wiki/hot.md` *or* cwd `wiki/hot.md`.

## wiki-lock integration

Every `wiki-lock.sh` invocation from a hook passes `WIKI_LOCK_VAULT="$V"` so locks live in
the **real** vault's `.vault-meta/locks`, not the plugin dir. `wiki-lock.sh` already
supports this override (line 90).

## Setup & docs

- `/wiki` setup offers to write `CLAUDE_OBSIDIAN_VAULT` into `~/.claude/settings.json`'s
  `env` block (this is what makes the var visible to hooks).
- Update cross-project sections in `CLAUDE.md`, `README.md`, `WIKI.md`,
  `docs/install-guide.md`: hooks now work cross-project once the env var is set; the MCP
  auto-commit caveat is resolved by the Stop-hook commit.
- New `docs/updating-and-configuring.md`: step-by-step for existing installs to update +
  configure the env var, and first-time-install configuration.
- CHANGELOG entry + version bump 1.9.2-hidden-skills → 1.9.2-global-access in `plugin.json`
  + `marketplace.json`.

## Tests

Add to the existing `make test` harness (hermetic, mktemp sandbox, style of
`tests/test_wiki_lock.sh`):

- `tests/test_vault_root.sh` — env unset → `$PWD`; env set to a valid vault → that path;
  env set to a non-vault dir → `$PWD`; relative env → absolutized.
- `tests/test_auto_commit.sh` — commits when `wiki/` dirty; no-op when clean; no-op when
  `.git` absent; defers when a lock is held; respects `auto-commit.disabled`.
  Lock-dependent assertions require `flock`; on hosts without it the suite verifies the
  defer-on-lock-error path (with `hook.log` breadcrumb) instead.

Wire both into `Makefile` (`test-vault-root`, `test-auto-commit`) and the `test` aggregate.

## Backward compatibility & risks

- **Env unset** → vault = `$PWD` → current behavior preserved exactly.
- **`$CLAUDE_PLUGIN_ROOT` unset** (older Claude Code) → relative `scripts/` fallback,
  correct when cwd == vault.
- **Env set, working in a non-vault project** → each Write/Edit does a tiny
  `git add`/`diff --quiet` against the vault; cheap, short-circuits when clean.
- **Stop ordering** → `CHANGED` captured before the commit so the nudge still fires.
- **`flock` absent (e.g. Git Bash on Windows)** → `wiki-lock` can't run, so auto-commit
  defers by design (pre-existing behavior); hot-cache injection is unaffected.
