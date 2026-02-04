# CLAUDE.md — Ship While You Sleep

This file provides guidance to Claude Code when working in the ship_asleep repository.

## Purpose

Ship While You Sleep is an autonomous overnight development system using Claude Code CLI. It executes a priority backlog while the user sleeps, producing PRs by morning.

**This is infrastructure, not a product.** Changes here affect all projects that use this system.

## ZERO-CONTEXT QUICKSTART (MANDATORY)

**If you are a fresh Claude instance launching a build, this is all you need.**

### Preconditions (must be true or the pipeline will abort)

1. Project has `reports/PRIORITIES.md` — this is the only file the pipeline reads
2. `reports/PRIORITIES.md` is **committed and pushed** to origin/main
3. Project working tree is clean (no uncommitted changes)

### Launch (the only correct command)

```powershell
C:\ship_asleep\scripts\launch-auto-compound.ps1 -ProjectPath "C:\your-project" -Verbose
```

That's it. The launcher spawns a visible window, sets the required env var, and runs the pipeline. Do NOT run auto-compound.ps1 directly.

### If there is nothing to build

The pipeline exits 0 with: "All priorities are complete in PRIORITIES.md. Nothing to build." This is expected and correct.

### Dry run (verify without building)

```powershell
C:\ship_asleep\scripts\launch-auto-compound.ps1 -ProjectPath "C:\your-project" -Verbose -DryRun
```

---

## Architecture

```
C:\ship_asleep\
├── CLAUDE.md                 # This file
├── README.md                 # User documentation
├── scripts/
│   ├── launch-auto-compound.ps1  # LAUNCHER — the only correct entry point
│   ├── auto-compound.ps1     # Full pipeline: preflight → reset → report → PRD → tasks → execute → PR
│   ├── loop.ps1              # Core execution loop (CRITICAL)
│   ├── analyze-report.ps1    # Pick #1 priority from report
│   ├── compound-review.ps1   # Extract learnings from sessions
│   ├── overnight.ps1         # Retry wrapper with backoff
│   └── install-scheduler.ps1 # Windows Task Scheduler setup
├── templates/                # Starter files for projects
└── docs/
    ├── architecture.md       # Three-tier model, tier contracts, pipeline stages
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

5. **MANDATORY: Launch via launch-auto-compound.ps1** — The build process MUST always run in a separate visible PowerShell window via the launcher script. auto-compound.ps1 will refuse to run without the launcher's env var. Never run inline, hidden, or as a background job.

6. **Native command stderr is not an error** — `git`, `gh`, and other native commands write progress info to stderr even on success. Always use `Invoke-Native` or `$ErrorActionPreference = "Continue"` + `$LASTEXITCODE`.

7. **One active report: PRIORITIES.md** — The pipeline reads exactly `reports/PRIORITIES.md`. No file selection logic. Old reports go to `reports/archive/`. Do not create multiple active reports.

### Self-Healing Build Cleanup

The pipeline automatically cleans up after itself between builds. `.gitignore` is the manifest of what's safe to auto-clean.

**How it works:** Stage 0 runs `git clean -fdX` (uppercase X = remove only gitignored files) before checking tree cleanliness. This removes build leftovers from the prior run (tasks/, logs/, NUL, __pycache__/) without touching tracked files or non-ignored untracked files. Stage 1 runs it again after reset for a full clean slate.

**Why this matters:** Every prior build leaves artifacts (PRDs, task JSONs, loop logs) that are gitignored. Without self-healing, these trigger Stage 0's dirty-tree check and block the next launch. The old approach was manual `Remove-Item` on specific directories, which required updating the script every time a new artifact type appeared.

**The rule:** If a build artifact shouldn't block the next launch, add it to `.gitignore`. The self-healing cleanup handles the rest. Never manually delete directories in the pipeline script.

**Sequencing constraint:** After `git clean -fdX`, `logs/` no longer exists. The `logs/` directory must be recreated immediately after the clean, before any `Write-Log` call. Both Stage 0 and Stage 1 follow this pattern: clean, recreate logs/, then log.

### Pipeline Stages

| Stage | What | Destructive? |
|-------|------|-------------|
| 0 | **Preflight** — self-healing cleanup, check for real uncommitted work, report on remote, open priorities | No (safe cleanup only) |
| 1 | Git reset to origin/main + full clean (untracked + ignored) | YES — destroys uncommitted work |
| 2 | Load PRIORITIES.md, analyze for #1 priority | No |
| 3 | Create feature branch | No |
| 4 | Generate PRD from priority | No |
| 5 | Convert PRD to task JSON | No |
| 6 | Execute tasks via loop.ps1 | Writes code |
| 7 | Push branch, create PR | No |
| 8 | Mark priority complete in report, push to main | Modifies report |

### Recent Fixes

| Date | Fix | Why It Mattered |
|------|-----|-----------------|
| 2026-02-01 | Removed age-based node cleanup | Was killing active long-running tasks mid-execution |
| 2026-02-01 | Removed `--print` flag | Enables true streaming instead of buffered output |
| 2026-02-01 | Added visible window mode | Users can watch Claude work in real-time |
| 2026-02-01 | True streaming output | `Tee-Object` directly in pipeline, not via variable |
| 2026-02-01 | Removed "press any key" prompt | Allows unattended overnight runs |
| 2026-02-03 | Fixed Stage 7 native command stderr bug | `git push` stderr was causing false termination |
| 2026-02-03 | Added Stage 0 preflight | Prevents uncommitted reports from being destroyed by Stage 1 |
| 2026-02-03 | Deterministic report path | Always reads PRIORITIES.md, no timestamp-based file selection |
| 2026-02-03 | Launcher script | Enforces visible window + env var, prevents inline launches |
| 2026-02-04 | Self-healing Stage 0 (`git clean -fdX`) | Auto-cleans gitignored build leftovers before checking tree; .gitignore is the manifest |
| 2026-02-04 | Stage 8 heading match by priority ID | Matches `P08` in `[P08-WIDER-MC]` instead of full title text; fixes Claude summary mismatch |

## Development Conventions

### Testing Changes

Before committing loop.ps1 or auto-compound.ps1 changes:

1. Create a test task file with 2-3 small tasks
2. Run `loop.ps1` directly on the test tasks
3. Verify output capture, timeout handling, and task verification all work
4. Then test full pipeline with `launch-auto-compound.ps1 -DryRun`

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

**Native command safety (use Invoke-Native helper):**
```powershell
$result = Invoke-Native git push -u origin $branch
if ($result.ExitCode -eq 0) { Write-Log "Pushed" }
else { Write-Log "Failed: $($result.Output)" "WARN" }
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

## What NOT to Do

- Don't add proactive process cleanup — it killed active tasks
- Don't use `-p` flag with arguments — it's boolean only
- Don't use PowerShell async event handlers — they don't fire reliably
- Don't run destructive git commands on main branch
- Don't assume PATH is inherited by spawned processes
- Don't run auto-compound.ps1 directly — use launch-auto-compound.ps1
- Don't use `$ErrorActionPreference = "Stop"` around native commands (git, gh, claude)
- Don't create multiple active reports in `reports/` — only `PRIORITIES.md` is active. Archives go in `reports/archive/`

## Files That Matter Most

| File | Risk Level | Notes |
|------|------------|-------|
| `scripts/launch-auto-compound.ps1` | HIGH | Entry point. Changes affect how all builds launch. |
| `scripts/auto-compound.ps1` | HIGH | Full pipeline. Stage 0 preflight + git operations. |
| `scripts/loop.ps1` | HIGH | Core engine. Changes can break all overnight runs. |
| `scripts/analyze-report.ps1` | MEDIUM | Priority extraction. Must handle "all complete" gracefully. |
| `docs/architecture.md` | REFERENCE | Three-tier model, tier contracts, versioning policy. |
| `docs/LESSONS_LEARNED.md` | REFERENCE | Read before any debugging session. |

---

**Last updated:** 2026-02-03
**Status:** Working. v2.0.1-stable tag. Stage 0 preflight + launcher added.
