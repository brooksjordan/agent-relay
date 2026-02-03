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

5. **MANDATORY: Visible window for every build** — The build process MUST always run in a separate visible PowerShell window. This is not optional. The Architect needs to monitor progress in real-time. Never run auto-compound or overnight.ps1 inline, hidden, or as a background job. Always launch via `Start-Process powershell` with a visible window.

6. **Native command stderr is not an error** — `git`, `gh`, and other native commands write progress info to stderr even on success. Never rely on `$ErrorActionPreference = "Stop"` around native commands. Always use `$ErrorActionPreference = "Continue"` and check `$LASTEXITCODE` explicitly.

### Recent Fixes

| Date | Fix | Why It Mattered |
|------|-----|-----------------|
| 2026-02-01 | Removed age-based node cleanup | Was killing active long-running tasks mid-execution |
| 2026-02-01 | Removed `--print` flag | Enables true streaming instead of buffered output |
| 2026-02-01 | Added visible window mode | Users can watch Claude work in real-time |
| 2026-02-01 | True streaming output | `Tee-Object` directly in pipeline, not via variable |
| 2026-02-01 | Removed "press any key" prompt | Allows unattended overnight runs |
| 2026-02-03 | Fixed Stage 7 native command stderr bug | `git push` stderr was causing false termination, aborting PR creation after successful push |

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
# MANDATORY: Always launch in a separate visible window. See below.
# Do NOT run auto-compound inline or hidden. The Architect must be able to monitor.
```

### Launching in visible window (MANDATORY)
```powershell
# This is the ONLY correct way to run the build pipeline.
# A separate visible window is required so the Architect can monitor progress.
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
- Don't run the build pipeline hidden or inline — ALWAYS use a separate visible window
- Don't use `$ErrorActionPreference = "Stop"` around native commands (git, gh, claude) — they write to stderr on success and will cause false termination

## Files That Matter Most

| File | Risk Level | Notes |
|------|------------|-------|
| `scripts/loop.ps1` | HIGH | Core engine. Changes can break all overnight runs. |
| `scripts/auto-compound.ps1` | HIGH | Full pipeline. Git operations, branch creation. |
| `scripts/overnight.ps1` | MEDIUM | Retry logic wrapper. |
| `docs/LESSONS_LEARNED.md` | REFERENCE | Read before any debugging session. |

---

**Last updated:** 2026-02-03
**Status:** Working. v2-stable tag. 7/7 tasks on agent_roi P04, 8/8 on test_orchids.
