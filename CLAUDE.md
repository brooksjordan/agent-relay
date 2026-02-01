# CLAUDE.md — Ship While You Sleep

This file provides guidance to Claude Code when working in the ship_asleep repository.

## Purpose

Ship While You Sleep is an autonomous overnight development system using Claude Code CLI. It executes a priority backlog while the user sleeps, producing PRs by morning.

**This is infrastructure, not a product.** Changes here affect all projects that use this system.

## Architecture

```
C:\ship_asleep\
├── CLAUDE.md                 # This file
├── README.md                 # User documentation
├── scripts/
│   ├── loop.ps1              # Core execution loop (CRITICAL)
│   ├── auto-compound.ps1     # Full pipeline: report → PRD → tasks → execute
│   ├── compound-review.ps1   # Extract learnings from sessions
│   ├── analyze-report.ps1    # Pick #1 priority from report
│   ├── overnight.ps1         # Retry wrapper with backoff
│   └── install-scheduler.ps1 # Windows Task Scheduler setup
├── templates/                # Starter files for projects
└── docs/
    ├── LESSONS_LEARNED.md    # Critical debugging knowledge (READ THIS)
    └── ...
```

## Critical Knowledge

**Before modifying any script, read `docs/LESSONS_LEARNED.md`.** It contains hard-won debugging lessons that prevent regression of fixed bugs.

### The Cardinal Rules

1. **Never kill processes by age or name** — Only kill specific PIDs via `taskkill /T /PID <pid>`. Age-based cleanup was THE BUG that killed active tasks.

2. **Stdin for prompts** — Claude CLI takes prompts via stdin, not as arguments:
   ```powershell
   # CORRECT
   Get-Content prompt.txt | claude --dangerously-skip-permissions

   # WRONG
   claude -p "prompt text"  # -p is a boolean flag, not an argument
   ```

3. **Set working directory** — Always `Set-Location` to project root before running Claude. Files are created relative to CWD.

4. **Verify outcomes** — Don't trust "TASK_COMPLETE" claims. Check files exist, are non-empty, and were modified recently.

5. **Visible windows for observability** — When launching auto-compound, always use a separate visible PowerShell window so users can monitor progress.

### Recent Fixes (2026-02-01)

| Fix | Why It Mattered |
|-----|-----------------|
| Removed age-based node cleanup | Was killing active long-running tasks mid-execution |
| Removed `--print` flag | Enables true streaming instead of buffered output |
| Added visible window mode | Users can watch Claude work in real-time |
| True streaming output | `Tee-Object` directly in pipeline, not via variable |
| Removed "press any key" prompt | Allows unattended overnight runs |

## Development Conventions

### Testing Changes

Before committing loop.ps1 or auto-compound.ps1 changes:

1. Create a test task file with 2-3 small tasks
2. Run `loop.ps1` directly on the test tasks
3. Verify output capture, timeout handling, and task verification all work
4. Then test full pipeline with `auto-compound.ps1 -DryRun`

### Adding Features

When adding new functionality:

1. Consider failure modes — overnight runs must be robust
2. Add logging at decision points
3. Test with both short tasks (<1 min) and long tasks (>5 min)
4. Document in LESSONS_LEARNED.md if you discover non-obvious behavior

### PowerShell Patterns

**Process spawning with output capture:**
```powershell
# Visible window with output capture via temp file
$wrapperContent = @"
Get-Content "$promptFile" -Raw | & "$claudePath" --dangerously-skip-permissions 2>&1 |
    Tee-Object -FilePath "$outputFile"
"@
Start-Process powershell -ArgumentList "-File", $wrapperScript -PassThru
```

**Quote handling for Start-Process:**
```powershell
# Use -File instead of -Command for reliable argument passing
Start-Process powershell -ArgumentList @(
    '-NoExit'
    '-File', 'C:\ship_asleep\scripts\overnight.ps1'
    '-ProjectPath', 'C:\project'
    '-ProjectName', '"Name With Spaces"'
)
```

**Claude path resolution (spawned windows may not inherit PATH):**
```powershell
$whereResult = & where.exe claude 2>$null
if ($whereResult) {
    $claudePath = $whereResult | Where-Object { $_ -like "*.cmd" } | Select-Object -First 1
}
```

## Integration with Computronium

This project follows the Computronium methodology from `C:\computronium\CLAUDE.md`:

- **Forced Intake** — Any significant change needs answers to: artifacts, deliverable, audience, constraints, done criteria
- **The Tribunal** — Before shipping script changes that affect overnight reliability, get review
- **Impedance Matching** — Outputs (logs, transcripts) must be readable by humans waking up to review them

## Common Tasks

### Running for a project
```powershell
# From any location
C:\ship_asleep\scripts\auto-compound.ps1 -ProjectPath "C:\your-project"
```

### Launching in visible window (recommended)
```powershell
Start-Process powershell -ArgumentList @(
    '-ExecutionPolicy', 'Bypass'
    '-NoExit'
    '-Command', 'cd C:\ship_asleep\scripts; .\auto-compound.ps1 -ProjectPath "C:\your-project" -Verbose'
)
```

### Debugging a failed run
1. Check `tasks/*.output` for Claude's raw output
2. Check `logs/transcripts/` for full prompt/response/stderr
3. Check Windows Event Viewer for crash details
4. Read LESSONS_LEARNED.md for known issues

## What NOT to Do

- Don't add proactive process cleanup — it killed active tasks
- Don't use `-p` flag with arguments — it's boolean only
- Don't use PowerShell async event handlers — they don't fire reliably
- Don't run destructive git commands on main branch
- Don't assume PATH is inherited by spawned processes
- **Don't start a new priority without merging the previous one** — work gets orphaned

## The Compounding Principle

> **Build incrementally. Merge before moving on.**

Each overnight run should:
1. Complete a feature on its branch
2. Create PR and **merge to main**
3. Only then start the next priority

Without this, `git reset --hard` at the start of each run orphans previous work. Features that took hours to build end up stranded in git history, never reaching main.

**Before running auto-compound:** Check for open PRs (`gh pr list`) and merge completed work first.

## Files That Matter Most

| File | Risk Level | Notes |
|------|------------|-------|
| `scripts/loop.ps1` | HIGH | Core engine. Changes can break all overnight runs. |
| `scripts/auto-compound.ps1` | HIGH | Full pipeline. Git operations, branch creation. |
| `scripts/overnight.ps1` | MEDIUM | Retry logic wrapper. |
| `docs/LESSONS_LEARNED.md` | REFERENCE | Read before any debugging session. |

---

**Last updated:** 2026-02-01
**Status:** Working. 8/8 tasks completed on test_orchids run.
