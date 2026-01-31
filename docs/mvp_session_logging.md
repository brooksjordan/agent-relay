# MVP Session Logging

Phase 1 of the "Ship While You Sleep" system: capture Claude Code sessions for nightly compound review.

---

## What It Does

Every time you run Claude Code through the wrapper:

1. Creates a session folder: `.claude-sessions/<timestamp>_<repo>_<branch>/`
2. Captures terminal transcript via PowerShell `Start-Transcript`
3. Snapshots git state before and after the session
4. Redacts common secret patterns from the transcript
5. Saves metadata (timestamps, args, commit range)

---

## Scripts

| Script | Purpose |
|--------|---------|
| `claude-session.ps1` | Wrapper - run this instead of `claude` |
| `list-sessions.ps1` | View recent sessions |
| `gather-sessions.ps1` | Consolidate sessions for LLM review |

---

## Setup

### 1. Add to PATH (optional but recommended)

Add `C:\ship_asleep\scripts` to your PATH, or create an alias:

```powershell
# Add to your PowerShell profile ($PROFILE)
function claude-session { & "C:\ship_asleep\scripts\claude-session.ps1" @args }
function list-sessions { & "C:\ship_asleep\scripts\list-sessions.ps1" @args }
```

### 2. Create sessions directory

The wrapper auto-creates `.claude-sessions/` in the current directory. For a global sessions store, set a fixed path in the script.

---

## Usage

### Run a session (instead of `claude`)

```powershell
# Interactive session
.\claude-session.ps1

# With arguments
.\claude-session.ps1 -p "Fix the login bug"

# If aliased
claude-session -p "Refactor the payment module"
```

### List recent sessions

```powershell
# Last 24 hours (default)
.\list-sessions.ps1

# Last 8 hours
.\list-sessions.ps1 -Hours 8

# Custom path
.\list-sessions.ps1 -Path "C:\projects\myapp\.claude-sessions"
```

### Gather sessions for review

```powershell
# Output to console
.\gather-sessions.ps1

# Save to file
.\gather-sessions.ps1 -OutputFile "sessions_summary.md"

# Last 12 hours only
.\gather-sessions.ps1 -Hours 12 -OutputFile "sessions_summary.md"
```

---

## Session Folder Structure

```
.claude-sessions/
  2026-01-30_143022_myapp_main/
    meta.json                    # Session metadata
    transcript.txt               # Terminal capture (redacted)
    git_status_before.txt        # Git status at session start
    git_status_after.txt         # Git status at session end
    git_diff_before.patch        # Uncommitted changes at start
    git_diff_after.patch         # Uncommitted changes at end
    git_diff_staged_before.patch # Staged changes at start
    git_diff_staged_after.patch  # Staged changes at end
    commits_during_session.txt   # Commits made during session
```

### meta.json Example

```json
{
  "timestamp_start": "2026-01-30T14:30:22.1234567-05:00",
  "timestamp_end": "2026-01-30T15:12:45.9876543-05:00",
  "repo": "myapp",
  "branch": "main",
  "head_start": "a1b2c3d",
  "head_end": "e4f5g6h",
  "remote_url": "https://github.com/user/myapp.git",
  "working_directory": "C:\\projects\\myapp",
  "claude_args": "-p \"Fix the login bug\"",
  "exit_code": 0
}
```

---

## Secret Redaction

The wrapper automatically redacts common secret patterns:

- AWS access keys (`AKIA...`)
- GitHub tokens (`ghp_...`, `github_pat_...`)
- Generic API keys and passwords (heuristic patterns)
- Bearer tokens

To add custom patterns, edit the `Remove-Secrets` function in `claude-session.ps1`.

---

## Limitations (MVP)

1. **Role separation is fuzzy** — PowerShell `Start-Transcript` captures output well but may miss some interactive input. The transcript shows what happened, but user vs. assistant turns aren't cleanly labeled.

2. **Per-directory sessions** — Sessions are stored relative to where you run the command. For a unified log, update `$SessionsRoot` to an absolute path.

3. **No automatic cleanup** — Old sessions accumulate. Add a cleanup script or scheduled task for hygiene.

---

## Next Steps (Phase 2)

- PTY recorder with `node-pty` for structured JSONL output
- Clean role separation (user/assistant/tool)
- Centralized session store with indexing
- Nightly compound review script that calls Claude to extract learnings
