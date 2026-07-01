# Updating & Configuring — vault-path-aware hooks (v1.9.2-global-access)

This guide covers two audiences:

- **[A. Existing installs](#a-updating-an-existing-install)** — you already run
  claude-obsidian and want the global-access release + the new cross-project hook behavior.
- **[B. First-time installs](#b-first-time-install)** — you're setting up the plugin now.

Both end at the same place: **[Configuration](#configuration)**, where you point the
hooks at your vault.

---

## What changed in the global-access release (and why you'd configure it)

Before this release, the plugin's four command hooks used paths relative to whatever directory
Claude Code was launched in. That's fine if you always work **inside** the vault. But if
you keep **one global vault** (e.g. `~/second-brain`) and drive it from *other* project
directories, the hooks silently did nothing:

| Hook | Before (from another dir) | After (with `CLAUDE_OBSIDIAN_VAULT` set) |
|------|----------------------------------|------------------------------------------------|
| SessionStart | No hot-cache injection | Injects `<vault>/wiki/hot.md` |
| PostToolUse | No auto-commit | Commits vault changes after each Write/Edit |
| Stop | No refresh nudge | Nudges hot-cache refresh **and** commits MCP writes |
| PostCompact | No re-read | Re-reads the vault hot cache |

The fix is one environment variable: **`CLAUDE_OBSIDIAN_VAULT`** = the absolute path to
your vault. Leave it unset and everything behaves exactly as it did before (paths resolve
to the current directory) — so this change is safe and opt-in.

> **Platform note — auto-commit needs `flock`.** The auto-commit steps (PostToolUse and
> the Stop-time MCP commit) go through `wiki-lock.sh`, which uses `flock` for its mutex.
> `flock` ships on Linux and macOS but **not in Git Bash on Windows**. Where it's missing,
> auto-commit **defers by design** and logs to `.vault-meta/hook.log` — hot-cache
> injection and reading are unaffected. On Windows, run hooks under WSL (or put a `flock`
> binary on PATH) to enable auto-commit; otherwise commit the vault manually. See
> [Troubleshooting](#troubleshooting).

---

## A. Updating an existing install

### A.1 If you installed as a Claude Code plugin

The simplest path is the interactive menu — run `/plugin` in a Claude Code session, open
**Manage plugins → claude-obsidian**, and choose update/reinstall.

Or from the CLI, refresh the marketplace metadata and reinstall to pull the update.
Note: `add` takes the `owner/repo`, but `update`/`remove` take the registered
marketplace **name** (`agricidaniel-claude-obsidian`), not the repo path:

```bash
# Refresh cached marketplace metadata, then reinstall
claude plugin marketplace update agricidaniel-claude-obsidian
claude plugin install claude-obsidian@agricidaniel-claude-obsidian
```

Then verify the version:

```bash
claude plugin list          # claude-obsidian should show 1.9.2-global-access
```

If `claude plugin marketplace update` isn't available in your Claude Code version, remove
and re-add the marketplace instead:

```bash
claude plugin marketplace remove agricidaniel-claude-obsidian
claude plugin marketplace add AndreikaKanareika/claude-obsidian
claude plugin install claude-obsidian@agricidaniel-claude-obsidian
```

### A.2 If you cloned the repo / use it as a vault directory

```bash
cd /path/to/claude-obsidian
git pull
```

The new files you should see after updating:

- `scripts/vault-root.sh` — vault-root resolver
- `scripts/auto-commit.sh` — shared, lock-aware auto-commit
- rewritten `hooks/hooks.json`

### A.3 Confirm the hooks are registered

```bash
claude hooks list
```

You should see `SessionStart`, `PostCompact`, `PostToolUse`, and `Stop` entries. If you
had customized `hooks/hooks.json` locally, re-apply your changes on top of the new
version (see [Customizing the hooks](#customizing-the-hooks)).

Now continue to **[Configuration](#configuration)**.

---

## B. First-time install

Follow the main [install guide](install-guide.md) first (or the README's
[Install as Claude Code plugin](../README.md#option-2-install-as-claude-code-plugin)
section):

```bash
# Step 1: add the marketplace
claude plugin marketplace add AndreikaKanareika/claude-obsidian

# Step 2: install the plugin
claude plugin install claude-obsidian@agricidaniel-claude-obsidian
```

Then run `/wiki` in a Claude Code session to scaffold or point at your vault. Once you have
a vault, continue to **[Configuration](#configuration)** to enable cross-project hooks.

> **You can skip configuration entirely** if you always launch Claude Code from *inside*
> the vault directory. The env var only matters when you drive a global vault from other
> projects.

---

## Configuration

### Step 1 — Find your vault's absolute path

Your vault is the directory that contains the `wiki/` folder (and usually `.obsidian/`).

```bash
# from inside the vault:
pwd
# -> e.g. /Users/you/second-brain   (macOS/Linux)
# -> e.g. D:\ObsidianVaults\second-brain   (Windows)
```

### Step 2 — Set `CLAUDE_OBSIDIAN_VAULT` in Claude Code settings

Claude Code passes its `env` block to hook commands, so this is where the variable must
live (a shell `export` in your profile is **not** guaranteed to reach hooks). Edit
`~/.claude/settings.json`:

```jsonc
{
  "env": {
    "CLAUDE_OBSIDIAN_VAULT": "/absolute/path/to/your/vault"
  }
}
```

On Windows, use a forward-slash or escaped path, e.g.
`"CLAUDE_OBSIDIAN_VAULT": "D:/ObsidianVaults/second-brain"`.

> **Tip:** you can ask Claude to do this for you — "add `CLAUDE_OBSIDIAN_VAULT` pointing at
> `<path>` to my Claude settings" — and it will use the settings-editing skill.

**Relationship to the per-project `CLAUDE.md` pointer.** The env var and the cross-project
`## Wiki Knowledge Base` block in another project's `CLAUDE.md` do different jobs: the env
var tells the **hooks** (shell scripts) where the vault is; the `CLAUDE.md` block tells
**Claude** the read protocol (hot → index → drill) and when *not* to read the wiki. The
block's location line points at `$CLAUDE_OBSIDIAN_VAULT`, so once that env var is set Claude
resolves the vault from it. To point a specific project at a **different** vault than the
global default, put an absolute path in place of `$CLAUDE_OBSIDIAN_VAULT`.

### Step 3 — Restart the session

Environment changes in `settings.json` are read when a session starts. Open a new Claude
Code session (from any directory) for the hooks to pick up the value.

### Step 4 — Verify it works

From a directory that is **not** your vault:

1. Start a new Claude Code session. The hot cache should be injected at startup — ask
   Claude "what's in the hot cache?" and it should know your vault's recent context.
2. Make a wiki change (via a skill or MCP), end the session, and check the vault repo:

   ```bash
   git -C /absolute/path/to/your/vault log --oneline -3
   ```

   You should see a `wiki: auto-commit …` entry.

If nothing happens, see [Troubleshooting](#troubleshooting).

---

## How resolution works (reference)

The hooks separate two locations:

- **Plugin root** (where `scripts/` lives) — found via `$CLAUDE_PLUGIN_ROOT`, which Claude
  Code sets for plugin hooks. Falls back to a relative `scripts/` path (correct when the
  cwd is the vault).
- **Vault root** (where `wiki/`, `.raw/`, `.vault-meta/`, `.git` live) — produced by
  `scripts/vault-root.sh`:
  - if `$CLAUDE_OBSIDIAN_VAULT` is set **and** points at a directory containing `wiki/` or
    `.obsidian/` → that path (absolutized);
  - otherwise → the current working directory (`$PWD`) — the pre-global-access behavior.

The "looks like a vault" guard means a typo or stale path safely degrades to the old
behavior instead of committing into the wrong place.

---

## Customizing the hooks

If you disable auto-commit, drop a marker file in the vault:

```bash
touch /absolute/path/to/your/vault/.vault-meta/auto-commit.disabled
```

Both the PostToolUse and Stop hooks honor it and skip committing.

To edit hook behavior directly, see `hooks/hooks.json`. The command hooks call
`scripts/vault-root.sh`, `scripts/auto-commit.sh`, and `scripts/wiki-lock.sh` — keep those
calls intact so cross-project resolution keeps working.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Hot cache not injected cross-project | `CLAUDE_OBSIDIAN_VAULT` unset or not in the `env` block of `~/.claude/settings.json`. A shell `export` alone doesn't reach hooks. Restart the session after editing. |
| Set the var but still nothing | Confirm the path contains a `wiki/` (or `.obsidian/`) folder — the resolver ignores non-vault paths and falls back to the cwd. Check with `ls "$CLAUDE_OBSIDIAN_VAULT"`. |
| No auto-commit even in-vault | The vault has no `.git` (run `git init` there), or `.vault-meta/auto-commit.disabled` exists, or an advisory lock is held (auto-commit defers while `wiki-lock` reports held locks). |
| No auto-commit on Windows / Git Bash | `wiki-lock.sh` needs `flock`, which Git Bash lacks; auto-commit then **defers by design** and logs to `.vault-meta/hook.log`. Run hooks under WSL, or a bash with `flock` (util-linux), for lock-gated auto-commit. Reading/hot-cache injection is unaffected. |
| MCP writes not committed | Fixed in the global-access release — they commit at session **Stop**, not per-write. End the session (or run a Write/Edit) to trigger the commit. |
| Version still shows old number | Re-run `claude plugin marketplace update …` then `claude plugin install …`; check `claude plugin list`. |

---

## See also

- Changelog: [`../CHANGELOG.md`](../CHANGELOG.md) → `[1.9.2-global-access]`
- Cross-project reading setup: [`../README.md`](../README.md#cross-project-knowledge-base)
