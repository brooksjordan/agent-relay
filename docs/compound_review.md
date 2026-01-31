# Compound Review (Job 1)

The nightly learning extraction job. Runs at 10:30 PM, before Auto-Compound.

---

## What It Does

1. Pulls latest from main/master
2. Gathers all Claude Code sessions from last 24 hours
3. Feeds transcripts + diffs to Claude Code
4. Claude extracts learnings and updates CLAUDE.md
5. Commits and pushes changes

---

## Usage

### Manual Run

```powershell
# Standard run
.\scripts\compound-review.ps1

# Custom hours window
.\scripts\compound-review.ps1 -Hours 12

# Dry run (see what would happen without changes)
.\scripts\compound-review.ps1 -DryRun

# Verbose output
.\scripts\compound-review.ps1 -Verbose

# Specify project path (if running from elsewhere)
.\scripts\compound-review.ps1 -ProjectPath "C:\projects\myapp"
```

### Scheduled Run (Windows Task Scheduler)

See [Scheduler Setup](scheduler_setup.md) for Task Scheduler configuration.

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Hours` | 24 | How far back to look for sessions |
| `-SessionsPath` | `.claude-sessions` | Relative path to sessions directory |
| `-ProjectPath` | `.` | Path to the project root |
| `-DryRun` | false | Preview without making changes |
| `-Verbose` | false | Show detailed output |

---

## What Claude Extracts

### Patterns
Reusable approaches that worked well:
- "When modifying the auth module, always regenerate tokens"
- "Use `--force` flag when resetting test database"

### Gotchas
Edge cases and bugs discovered:
- "API returns 500 if user.email is null"
- "Don't use `any` type in the validation layer — breaks runtime checks"

### Context
Project-specific knowledge:
- "Auth handled in /lib/auth, not /api/auth"
- "Legacy endpoints in /v1 are deprecated but still used by mobile"

---

## CLAUDE.md Structure

The compound review updates your project's CLAUDE.md. Use the template at `templates/CLAUDE.md.template` as a starting point:

```markdown
# CLAUDE.md

## Project Overview
...

## Learned Patterns
<!-- Auto-populated by compound review -->

## Gotchas
<!-- Auto-populated by compound review -->

## Context
<!-- Auto-populated by compound review -->
```

---

## Logs

Logs are written to `logs/compound-review.log` in the project directory.

```powershell
# View recent logs
Get-Content .\logs\compound-review.log -Tail 50

# Follow logs in real-time
Get-Content .\logs\compound-review.log -Wait
```

---

## How It Works (Detail)

```
┌─────────────────────────────────────────────────────────────────┐
│                     COMPOUND REVIEW FLOW                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. git checkout main && git pull                               │
│                    │                                            │
│                    ▼                                            │
│  2. gather-sessions.ps1 -Hours 24                               │
│     └─► Produces: sessions_summary.md                           │
│                    │                                            │
│                    ▼                                            │
│  3. Build prompt with:                                          │
│     - Current CLAUDE.md                                         │
│     - Sessions summary                                          │
│     - Extraction guidelines                                     │
│                    │                                            │
│                    ▼                                            │
│  4. claude -p "<prompt>" --dangerously-skip-permissions         │
│     └─► Claude reads, analyzes, updates CLAUDE.md               │
│                    │                                            │
│                    ▼                                            │
│  5. git commit -m "compound: extract learnings..."              │
│     git push                                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

### "No sessions found"
- Check that `.claude-sessions/` exists and has recent folders
- Verify you're running the wrapper (`claude-session.ps1`) not raw `claude`

### "Claude Code exited with code 1"
- Check `logs/compound-review.log` for details
- May be a permissions issue — ensure `--dangerously-skip-permissions` is accepted
- May be a context length issue — reduce `-Hours` to limit input size

### CLAUDE.md not updating
- Ensure the file exists (use template if not)
- Check that Claude has write permissions to the project directory
- Review logs for Claude's reasoning

---

## Security Notes

1. **`--dangerously-skip-permissions`**: Required for unattended operation. The script runs trusted prompts only — no external input.

2. **Session transcripts**: May contain sensitive info despite redaction. Keep `.claude-sessions/` in `.gitignore`.

3. **Commit access**: The script pushes to main. Ensure branch protection rules allow this, or modify to create PRs instead.
