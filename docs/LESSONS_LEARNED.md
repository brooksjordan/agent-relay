# Lessons Learned: Debugging the Ship While You Sleep Loop

**Date:** 2026-01-30
**Project:** Ship While You Sleep automation
**Outcome:** Successfully fixed and tested

---

## The Problem

The execution loop was running, Claude was claiming tasks complete, but **no files were actually being created**. The loop would iterate through all tasks, mark them "completed", but the project directory remained empty.

---

## Root Causes (in order of discovery)

### 1. Wrong CLI Invocation Pattern

**What we had:**
```powershell
$output = & claude -p $prompt --dangerously-skip-permissions
```

**What it should be:**
```powershell
$output = $prompt | & claude --print --dangerously-skip-permissions
```

**Why this matters:**

The `-p` / `--print` flag is a **boolean flag** that tells Claude to output to stdout rather than an interactive session. It does NOT accept an argument.

We were treating it like:
```
-p <value>   # WRONG - -p doesn't take a value
```

When it's actually:
```
--print      # RIGHT - it's a flag, prompt comes via stdin
```

**How we found it:**

Analyzed Ryan Carson's [Ralph repository](https://github.com/snarktank/ralph):
```bash
claude --dangerously-skip-permissions --print < CLAUDE.md
```

The `< CLAUDE.md` is stdin redirection. The prompt is delivered via stdin, not as an argument.

### 2. Working Directory Not Set

**What we had:**
```powershell
# Loop running from C:\scripts
$output = $prompt | claude --print --dangerously-skip-permissions
# Claude creates files in C:\scripts (wrong!)
```

**What it should be:**
```powershell
Set-Location $WorkspaceRoot  # C:\your-project
$output = $prompt | claude --print --dangerously-skip-permissions
# Claude creates files in C:\your-project (correct!)
```

**Why this matters:**

Claude Code resolves relative paths from its current working directory. If you run `loop.ps1` from `C:\ship_asleep\scripts`, Claude will try to create `src/components/Foo.tsx` at `C:\ship_asleep\scripts\src\components\Foo.tsx`.

Even with absolute paths in the prompt, Claude may still use relative paths internally.

**How we found it:**

Direct testing showed files WERE being created - just in the wrong place. We found malformed directories from path concatenation errors when the working directory wasn't set correctly.

---

## Secondary Issues (Fixed Along the Way)

### 3. Missing Completion Signal

The original loop would iterate all `MaxIterations` even if all tasks completed early.

**Fix:** Check for all tasks complete after each success, emit `<promise>COMPLETE</promise>` and break:

```powershell
$allCompleted = ($tasks | Where-Object { $_.status -ne "completed" }).Count -eq 0
if ($allCompleted) {
    Write-Host "<promise>COMPLETE</promise>"
    break
}
```

### 4. No Quality Gates

The original loop had no mechanism to run tests or linting after each task.

**Fix:** Added `-QualityChecks` parameter:

```powershell
.\loop.ps1 -TasksFile "tasks.json" -QualityChecks @("npm test", "npm run typecheck")
```

Quality checks run after each successful task. If they fail, the task is marked failed and the loop continues.

### 5. No Archiving

When switching branches or starting fresh, old task files and progress could pollute the new run.

**Fix:** Added `-ArchiveDir` parameter that archives previous runs when branch changes:

```powershell
.\loop.ps1 -TasksFile "tasks.json" -ArchiveDir "archive"
```

---

## Debugging Methodology

### Step 1: Compare with Working Reference

We analyzed three GitHub repositories from Ryan Carson's implementation:
- `snarktank/ralph` - The core loop pattern
- `snarktank/compound-product` - Full workflow
- `EveryInc/compound-engineering-plugin` - Plugin architecture

Key insight: **Don't guess. Read working code.**

### Step 2: Isolate Variables

We tested Claude directly:
```powershell
$testPrompt = "Create a file called test.txt with content 'hello'"
$testPrompt | claude --print --dangerously-skip-permissions
```

This proved Claude COULD create files. The problem was in our invocation.

### Step 3: Check File Locations

```powershell
Get-ChildItem -Recurse -Filter "*.tsx"
```

This revealed files were being created - just in wrong directories.

### Step 4: Add Verification

After each task, verify the work:
```powershell
if (Test-Path $expectedFile) {
    $content = Get-Content $expectedFile -Raw
    if ($content.Length -gt 0) {
        # Actually worked
    }
}
```

---

## Key Takeaways

### 1. Stdin is the Standard

For non-interactive CLI tools, prompts should go via stdin:
```bash
echo "prompt" | tool
# or
tool < file.txt
```

Not as command-line arguments:
```bash
tool -p "prompt"  # Only if explicitly documented
```

### 2. Working Directory Matters

Always set working directory before spawning subprocesses that create files:
```powershell
Push-Location $ProjectRoot
try {
    # run commands
} finally {
    Pop-Location
}
```

### 3. Trust But Verify

Don't trust process claims. Verify outcomes:
- Did the file get created?
- Is it non-empty?
- Was it modified recently?
- Does it contain expected content?

### 4. Fresh Instance Pattern

Each iteration should be a fresh process:
- No state pollution
- Clear context boundaries
- External progress tracking

This is more robust than maintaining a long-running session.

---

## Files Modified

| File | Changes |
|------|---------|
| `scripts/loop.ps1` | Invocation fix, working directory, quality checks, archiving, completion signal |
| `scripts/auto-compound.ps1` | Invocation fix, quality checks parameter |
| `scripts/compound-review.ps1` | Invocation fix |
| `scripts/analyze-report.ps1` | Invocation fix |

---

## Verification

Final test run: **8 tasks, 8 completed, 0 failed**

Example files created:
- `next.config.js`
- `tailwind.config.js`
- `src/components/ProductCard.tsx`
- `src/app/catalog/page.tsx`
- `src/app/catalog/loading.tsx`

All files verified as existing with correct content.

---

## Future Recommendations

1. **Test new projects manually** before scheduling overnight runs
2. **Check logs** at `tasks/*.output` for Claude's raw output
3. **Start small** - one priority item, few tasks, verify each step
4. **Read reference implementations** when stuck - don't reinvent

The system works. The key was understanding exactly how the CLI expects input.

---

## 2026-01-31 — Hard timeouts, clean retries, and post-mortem visibility

### Problem: Overnight runs could hang for hours, then crash
We observed a ~2 hour stall before an eventual crash (unhandled promise rejection). The hang blocked the entire overnight pipeline.

**Solution: Add a hard task timeout in `loop.ps1`.**
- New `TaskTimeoutSeconds` parameter (default `600`)
- Claude runs as a tracked child process
- If the timeout is hit, we kill only that PID tree (`taskkill /F /T /PID <pid>`)
- Timeout is logged and the full transcript is saved for debugging

```powershell
.\loop.ps1 -TaskTimeoutSeconds 600
```

---

### Problem: No way to debug failures after you wake up
When the run failed overnight, there was no durable record of the full prompt/output/error context.

**Solution: Persist Claude transcripts in `loop.ps1`.**
- New `TranscriptDir` parameter to store:
  - prompt
  - stdout output
  - stderr output
- On failures (including timeouts), logs include the transcript path.

```powershell
.\loop.ps1 -TranscriptDir .\logs\transcripts
```

---

### Problem: False-positive git failures (stderr treated as error)
Some git commands write non-fatal info/warnings to stderr. Treating any stderr output as a failure produced noisy and incorrect "git error" handling.

**Solution: Check git exit codes instead of parsing stderr (`auto-compound.ps1`).**
- Git success/failure now determined by exit code only.

---

### Problem: Dirty repo state after mid-task crashes
Failed runs left behind modified/untracked files which contaminated subsequent stages.

**Solution: Force a clean state at Stage 1 (`auto-compound.ps1`).**
```powershell
git reset --hard HEAD
git clean -fd
```

---

### Problem: Branch creation could fail on empty/invalid LLM output
Occasionally the LLM returned an empty branch name, or included invalid characters.

**Solution: Add branch name fallback + sanitization (`auto-compound.ps1`).**
- Generates a fallback branch name if the model returns empty
- Sanitizes invalid characters before attempting `git checkout -b`

---

### Problem: Stale node processes accumulated across runs
We saw 5–9 lingering node processes after failures.

**Solution: Smarter node cleanup (`loop.ps1`).**
- Only kills node processes older than 5 minutes
- Avoids nuking unrelated/active node work

---

### Problem: One crash wasted the whole night
A single transient failure at 3 AM could stop the entire overnight run.

**Solution: Add retry + backoff in `overnight.ps1`.**
- New `MaxRetries` (default `3`)
- New `RetryDelaySeconds` (default `30`; exponential backoff capped at 5 minutes)
- Logs:
  - `logs/retry.log` (attempts/backoff)
  - `logs/error.log` (failures)
- Clear final reporting once retries are exhausted

```powershell
.\overnight.ps1 -MaxRetries 3 -RetryDelaySeconds 30
```

---

### Gemini 3 Pro Review

These fixes were reviewed by Gemini 3 Pro before implementation. Key additions from the review:

1. **The "hang" wasn't a crash** — it was likely a socket or stdin waiting for input that never arrived
2. **PID-specific kills** instead of blanket `taskkill /IM node.exe` to avoid killing unrelated processes
3. **Timeout beats heartbeat** — a heartbeat tells you it's stuck but doesn't fix it; a hard timeout does
4. **Containerization** recommended for future — guarantees clean filesystem, safe process killing, no dependency drift

---

## 2026-01-31 — Post-Build Review: Shopping Cart Feature

### Problem: Cart page crashed with image hostname error
The overnight build created a working catalog but the cart page threw:
```
Error: Invalid src prop (https://picsum.photos/...) hostname "picsum.photos" is not configured under images in your next.config.js
```

**Root cause:** The agent added `picsum.photos` URLs in `src/data/orchids.ts` but only whitelisted `unsplash.com` in `next.config.js`. Inconsistency between data and config.

### Problem: Cart item links went to wrong route
CartItem component linked to `/product/{id}` but the actual route was `/catalog/[id]`.

**Root cause:** The agent created the detail page at `/catalog/[id]` but when creating CartItem, hallucinated a `/product/` route that doesn't exist.

### Solution: Add `npm run build` as quality check
A production build would have caught the image hostname error immediately:
```powershell
-QualityChecks @("npm run build")
```

**Lesson:** Dev server is forgiving. Production builds catch config mismatches. Always run build as a quality gate for Next.js projects.

### Solution: Document routes in CLAUDE.md
Added explicit route documentation to project CLAUDE.md:
```
Routes: Catalog at /catalog, detail pages at /catalog/[id], cart at /cart
```

When routes are documented, the agent is less likely to hallucinate alternative paths.
