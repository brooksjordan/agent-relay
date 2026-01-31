# Ship While You Sleep

Autonomous overnight development using Claude Code. Based on [Ryan Carson's methodology](https://x.com/ryancarson/status/1881021946307342828).

**Tested and working as of 2026-01-31.** (v2: timeouts, retries, transcripts)

---

## What It Does

You maintain a priority backlog. The system executes it while you sleep.

```
10:30 PM  Compound Review    Extract learnings from today's sessions
11:00 PM  Auto-Compound      Pick #1 priority, build it, open PR
Morning   You review         Merge or refine, update priorities
```

Each night makes future nights smarter. Learnings compound into CLAUDE.md.

---

## Quick Start

```powershell
# 1. Create a priority report in your project
mkdir C:\your-project\reports
"1. Build the user dashboard`n2. Add authentication`n3. Fix cart bug" | Out-File C:\your-project\reports\priority.md

# 2. Install the scheduler
C:\ship_asleep\scripts\install-scheduler.ps1 -ProjectPath "C:\your-project"

# 3. Go to sleep. Wake up to PRs.
```

---

## Manual Execution

Run the loop directly for testing:

```powershell
# Generate tasks from a priority report
C:\ship_asleep\scripts\auto-compound.ps1 -ProjectPath "C:\your-project"

# Or run the loop on an existing task file
C:\ship_asleep\scripts\loop.ps1 -TasksFile "C:\your-project\tasks\tasks-feature-xyz.json"

# With quality checks
C:\ship_asleep\scripts\loop.ps1 -TasksFile "path\to\tasks.json" -QualityChecks @("npm run typecheck", "npm test")
```

---

## Critical Implementation Details

These are the lessons learned from debugging. **Do not skip this section.**

### 1. Claude Code CLI Invocation

**WRONG:**
```powershell
claude -p $prompt --dangerously-skip-permissions
```

**RIGHT:**
```powershell
$prompt | claude --print --dangerously-skip-permissions
```

The `-p` / `--print` flag is a **boolean flag**, not an argument that takes a value. The prompt goes via **stdin** (pipe or redirect), not as a flag argument.

This is how Ryan's [Ralph](https://github.com/snarktank/ralph) does it:
```bash
claude --dangerously-skip-permissions --print < CLAUDE.md
```

### 2. Working Directory

The loop MUST set the working directory before running Claude:

```powershell
Set-Location $WorkspaceRoot
$output = $prompt | claude --print --dangerously-skip-permissions
```

Without this, Claude creates files in the wrong location (wherever the loop script was invoked from).

### 3. Fresh Instance Pattern

Each iteration spawns a **fresh Claude process**. This is intentional:
- No context pollution between tasks
- Each task gets a clean slate
- Progress tracked externally in tasks.json

### 4. Task Verification

After each task, verify the work actually happened:
- Check file existence
- Check file is non-empty
- Check modification time is recent

Don't trust Claude's claim of "TASK_COMPLETE" alone.

### 5. Completion Signal

When all tasks are done, emit:
```
<promise>COMPLETE</promise>
```

This allows parent scripts to exit early rather than burning through remaining iterations.

---

## Architecture

```
C:\ship_asleep\
├── README.md                 # This file
├── scripts/
│   ├── loop.ps1              # Core execution loop
│   ├── auto-compound.ps1     # Full pipeline: report → PRD → tasks → execute
│   ├── compound-review.ps1   # Extract learnings from sessions
│   ├── analyze-report.ps1    # Pick #1 priority from report
│   ├── install-scheduler.ps1 # Set up Windows Task Scheduler
│   └── ...
├── templates/
│   ├── CLAUDE.md.template    # Project CLAUDE.md starter
│   ├── config.json.template  # Quality checks config
│   └── priority_report.md.template
└── docs/
    ├── process_overview.md   # Detailed process docs
    ├── how_it_works.md       # User-facing explanation
    └── ...
```

---

## Scripts Reference

### loop.ps1 (Core Engine)

The execution loop that processes tasks one at a time.

```powershell
.\scripts\loop.ps1 `
    -TasksFile "path\to\tasks.json" `
    -MaxIterations 25 `
    -TaskTimeoutSeconds 600 `
    -TranscriptDir "logs\transcripts" `
    -QualityChecks @("npm test", "npm run typecheck") `
    -ArchiveDir "archive"
```

**Parameters:**
| Parameter | Default | Description |
|-----------|---------|-------------|
| TasksFile | required | Path to tasks JSON file |
| MaxIterations | 25 | Stop after N iterations |
| TaskTimeoutSeconds | 600 | Hard timeout per task (kills process if exceeded) |
| TranscriptDir | auto | Directory for Claude session transcripts (prompt + output + stderr) |
| QualityChecks | @() | Commands to run after each task |
| ArchiveDir | "" | Archive previous runs when branch changes |
| LogFile | auto | Override log file path |

**Task JSON Format:**
```json
{
  "metadata": {
    "project": "project-name",
    "branch": "feature/xyz",
    "created": "2026-01-30T12:00:00Z"
  },
  "tasks": [
    {
      "id": 1,
      "title": "Create component",
      "status": "pending",
      "acceptance_criteria": "File exists at src/Component.tsx"
    }
  ]
}
```

### auto-compound.ps1 (Full Pipeline)

Runs the complete pipeline: analyze report → generate PRD → create tasks → execute loop.

```powershell
.\scripts\auto-compound.ps1 `
    -ProjectPath "C:\your-project" `
    -MaxIterations 25 `
    -QualityChecks @("npm test")
```

**Behavior (2026-01-31 improvements):**
- Stage 1 forces clean workspace: `git reset --hard HEAD && git clean -fd`
- Git errors checked by exit code (not stderr parsing)
- Empty branch names from LLM get auto-generated fallback
- Invalid branch name characters are sanitized

### overnight.ps1 (Fire and Forget)

Wrapper that adds keep-awake, retry logic, and clear status reporting.

```powershell
.\scripts\overnight.ps1 `
    -ProjectPath "C:\your-project" `
    -MaxIterations 25 `
    -MaxRetries 3 `
    -RetryDelaySeconds 30
```

**Parameters:**
| Parameter | Default | Description |
|-----------|---------|-------------|
| ProjectPath | required | Path to project directory |
| MaxIterations | 25 | Max iterations per attempt |
| MaxRetries | 3 | Retry attempts if build crashes |
| RetryDelaySeconds | 30 | Initial retry delay (exponential backoff to 5 min max) |
| QualityChecks | @() | Commands to run after each task |

**Logs:**
- `logs/retry.log` — retry attempts and backoff timing
- `logs/error.log` — errors per failed attempt

### compound-review.ps1 (Learning Extraction)

Reviews Claude Code sessions and extracts learnings into CLAUDE.md.

```powershell
.\scripts\compound-review.ps1 -ProjectPath "C:\your-project"
```

---

## Project Setup Checklist

For each new project:

1. **Create CLAUDE.md** in project root (use `templates/CLAUDE.md.template`)
2. **Create reports/** directory with a priority.md
3. **Create tasks/** directory (auto-compound will populate it)
4. **Test manually** before scheduling:
   ```powershell
   C:\ship_asleep\scripts\auto-compound.ps1 -ProjectPath "C:\your-project" -DryRun
   ```
5. **Install scheduler** when ready for overnight runs

---

## Recommended Quality Checks

For Next.js projects, use these quality checks to catch common issues:

```powershell
.\scripts\overnight.ps1 `
    -ProjectPath "C:\your-project" `
    -QualityChecks @("npm run build")
```

**Why `npm run build`?**
- Catches missing image hostname whitelists in `next.config.js`
- Catches TypeScript errors
- Catches broken imports
- Catches SSR hydration issues

The overnight agent may create code that works in dev but fails in production. A build check catches these before you wake up.

**Common issues caught by build:**
| Error | Root Cause |
|-------|------------|
| `hostname not configured under images` | New image source not in `remotePatterns` |
| `Module not found` | Wrong import path or missing dependency |
| `Type error` | TypeScript strict mode violations |

---

## Troubleshooting

### "Files not being created"

1. Check working directory is set correctly in loop.ps1
2. Verify the task prompt includes the correct absolute paths
3. Check Claude's output for errors (logged to tasks/*.output)

### "Claude claims done but nothing changed"

1. Verify you're using stdin for prompts: `$prompt | claude --print`
2. Check file verification is running after each task
3. Look for error messages in Claude's raw output

### "Task keeps failing"

1. Check the acceptance criteria are specific and verifiable
2. Ensure the task is scoped small enough for one iteration
3. Review progress.txt for patterns from previous attempts

### "Scheduler not running"

1. Check Task Scheduler is enabled
2. Verify machine doesn't sleep during automation window
3. Check logs at `logs/compound-review.log` and `logs/auto-compound.log`

---

## Reference Repositories

These are Ryan Carson's original implementations that we studied:

- **[Ralph](https://github.com/snarktank/ralph)** - Fresh-instance loop pattern
- **[compound-product](https://github.com/snarktank/compound-product)** - Full compound engineering workflow
- **[compound-engineering-plugin](https://github.com/EveryInc/compound-engineering-plugin)** - Claude Code plugin with skills

Key patterns borrowed:
- Stdin prompt delivery (`< CLAUDE.md` or pipe)
- `--print` flag for non-interactive mode
- Fresh Claude instance per iteration
- External progress tracking (tasks.json, progress.txt)
- `<promise>COMPLETE</promise>` early exit signal

---

## Test Results

**2026-01-30 Test Run (test_orchids project):**

```
[18:42:45] === Execution Loop Started ===
[18:43:13] Task 4 completed - next.config.js
[18:44:02] Task 5 completed - tailwind.config.js
[18:44:55] Task 6 completed - ProductCard.tsx
[18:46:06] Task 7 completed - catalog/page.tsx
[18:47:02] Task 8 completed - catalog/loading.tsx
[18:47:04] All tasks processed!
Final: 8 completed, 0 failed, 0 pending
```

All files verified as created with correct content.

---

## Contributing

This is part of the [Computronium](file:///C:/computronium) methodology. Patterns that work get documented. Failures get analyzed.

When something breaks:
1. Fix it
2. Document why it broke
3. Update this README

---

## License

MIT
