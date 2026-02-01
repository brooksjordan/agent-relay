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

---

## 2026-01-31 — PowerShell Quote Stripping in Start-Process

### Problem: ProjectName parameter with spaces broke argument parsing

When launching the overnight build in a separate window:

```powershell
Start-Process powershell -ArgumentList '-NoExit', '-Command', 'cd C:/ship_asleep/scripts; ./overnight.ps1 -ProjectPath C:/test_orchids -ProjectName "Rare Orchid Store" -MaxIterations 30'
```

Produced this error:
```
Cannot process argument transformation on parameter 'MaxRetries'. Cannot convert value "Store" to type "System.Int32".
```

The string `"Rare Orchid Store"` was being split into three separate arguments. `Store` then bound to the next parameter (`-MaxRetries`), which expects an integer.

### Root Cause: Quote Stripping

When `Start-Process` launches a new `powershell.exe` instance, the child PowerShell **consumes one layer of quotes** when parsing the `-Command` argument.

1. We pass: `-ProjectName "Rare Orchid Store"`
2. Child PowerShell parses it, treats `"` as string delimiters, removes them
3. Engine receives: `-ProjectName Rare Orchid Store` (three separate tokens)
4. `Rare` binds to `-ProjectName`, `Orchid` is orphaned, `Store` binds to next param

### Solution: Use single quotes inside double quotes

Single quotes `'` are treated as literal strings. Wrap the outer command in double quotes, use single quotes for the inner string:

```powershell
# WRONG - double quotes get stripped
Start-Process powershell -ArgumentList '... -ProjectName "Rare Orchid Store" ...'

# RIGHT - single quotes survive
Start-Process powershell -ArgumentList '-NoExit', '-Command', "cd C:/ship_asleep/scripts; ./overnight.ps1 -ProjectPath C:/test_orchids -ProjectName 'Rare Orchid Store' -MaxIterations 30"
```

Note the outer wrapper changed from `'...'` to `"..."` and the inner string changed from `"Rare Orchid Store"` to `'Rare Orchid Store'`.

### Alternative: Escape with backslash

For cases where you need double quotes (e.g., variable expansion), escape with `\"`:

```powershell
Start-Process powershell -ArgumentList '... -ProjectName \"Rare Orchid Store\" ...'
```

The backslash escape works because `Start-Process` hands arguments to the Windows API, which uses `\"` for escaping (not PowerShell's backtick).

### Additional Escape Method: Double Single Quotes

When the outer wrapper is already using complex quoting, use `''` (two single quotes) which PowerShell interprets as a literal single quote:

```powershell
# Double single quotes survive the hop
Start-Process powershell -ArgumentList '-NoExit -Command "cd C:/scripts; ./overnight.ps1 -ProjectName ''Rare Orchid Store'' -MaxIterations 30"'
```

### The Definitive Solution: Use `-File` Instead of `-Command`

After multiple failed attempts with `-Command`, the reliable solution is to use `-File` and pass each argument as a separate array element with quotes embedded:

```powershell
Start-Process -FilePath powershell.exe -ArgumentList @(
    '-NoExit'
    '-File', 'C:\ship_asleep\scripts\overnight.ps1'
    '-ProjectPath', 'C:\test_orchids'
    '-ProjectName', '"Rare Orchid Store"'
    '-MaxIterations', '30'
)
```

**Why `-File` works better than `-Command`:**
- `-Command` concatenates all arguments into a single string, then re-parses it
- `-File` passes arguments directly to the script's parameter binder
- With `-File`, embedded quotes in `'"Rare Orchid Store"'` survive intact

### Key Takeaway

**Nested PowerShell invocations strip one layer of quotes.** When passing strings with spaces through `Start-Process`:

1. **Best:** Use `-File` with separate array elements (GPT 5.2 recommendation)
2. Use single quotes inside double quotes: `"... -Name 'Value' ..."`
3. Or use double single-quotes inside: `'... -Name ''Value'' ...'`
4. Or escape double quotes with backslash: `'... -Name \"Value\" ...'`
5. Never assume double quotes will survive the hop with `-Command`

*Initial diagnosis by Gemini 3 Pro. Definitive solution by GPT 5.2 Pro.*

---

## 2026-01-31 — Claude CLI Not Found in Spawned Windows

### Problem: "The system cannot find the file specified"

When the overnight build ran in a spawned PowerShell window, the execution loop failed with:
```
Exception calling "Start" with "0" argument(s): "The system cannot find the file specified"
```

The script was using `$psi.FileName = "claude"` which relies on PATH resolution.

### Root Cause

Spawned PowerShell windows via `Start-Process` may not inherit the same PATH as the parent session, especially for tools installed via npm that add themselves to user-specific PATH locations.

### Solution

Added explicit Claude path resolution in `loop.ps1`:

```powershell
$claudePath = "claude"
$whereResult = & where.exe claude 2>$null
if ($whereResult) {
    $cmdPath = $whereResult | Where-Object { $_ -like "*.cmd" } | Select-Object -First 1
    if ($cmdPath) { $claudePath = $cmdPath }
    else { $claudePath = $whereResult | Select-Object -First 1 }
} elseif (Test-Path "C:\Program Files\nodejs\claude.cmd") {
    $claudePath = "C:\Program Files\nodejs\claude.cmd"
}
$psi.FileName = $claudePath
```

### Key Takeaway

Don't assume PATH is consistent across spawned processes. For critical executables, resolve the full path explicitly or provide a hardcoded fallback.

---

## 2026-01-31 — Silent PowerShell Crashes from Non-Thread-Safe StringBuilder

### Problem: PowerShell window disappears silently during Claude execution

The overnight build process would run Claude, Claude would create files successfully, but then the entire PowerShell window would vanish with no error message. Logs showed "Claude started with PID: XXXX" but nothing after.

### Root Cause: StringBuilder is NOT Thread-Safe

When using `BeginOutputReadLine()` with event handlers, the callbacks run on thread pool threads, not the main PowerShell thread. If Claude outputs to stdout and stderr simultaneously (common), two threads call `StringBuilder.AppendLine()` concurrently.

`StringBuilder` is **not thread-safe**. Concurrent writes cause:
- Internal array corruption
- `IndexOutOfRangeException` or `AccessViolationException`
- Immediate process termination (unhandled exception on background thread)

Standard `try-catch` blocks **cannot** catch exceptions in async event handlers because they run on different threads.

### Solution: Use ConcurrentQueue Instead of StringBuilder

Replace StringBuilder with thread-safe `ConcurrentQueue[string]`:

```powershell
# BEFORE (crashes)
$outputBuilder = New-Object System.Text.StringBuilder
$process.add_OutputDataReceived({
    param($sender, $e)
    if ($e.Data) { $outputBuilder.AppendLine($e.Data) }  # NOT THREAD-SAFE!
})

# AFTER (stable)
$stdOutQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$process.add_OutputDataReceived({
    param($sender, $e)
    if ($null -ne $e.Data) { $stdOutQueue.Enqueue($e.Data) }  # Thread-safe
})

# Drain to StringBuilder ON MAIN THREAD after process exits
$process.WaitForExit()
$process.WaitForExit()  # Second call drains async callbacks

$sb = [System.Text.StringBuilder]::new()
$line = $null
while ($stdOutQueue.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
$output = $sb.ToString()
```

### Additional Fixes Applied

1. **Wrap event handler internals in try-catch** — Prevents any remaining edge cases from crashing
2. **Add try-catch around Invoke-ClaudeWithTimeout** — Catches exceptions and logs them
3. **Use `[void]` on AppendLine** — Prevents return value from polluting output

### Diagnostic Tip

To confirm this issue, check **Windows Event Viewer** → **Windows Logs** → **Application** for "Application Error" at the crash time. Look for `System.IndexOutOfRangeException` in `System.Text.StringBuilder`.

*Diagnosis by Gemini 3 Pro.*

---

## 2026-01-31 — PowerShell Async Event Handlers Don't Fire

### Problem: ConcurrentQueue remains empty despite process producing output

After implementing the ConcurrentQueue fix (above), output was still empty. Testing revealed:
- `add_OutputDataReceived` event handlers **never fire**
- Queue remains at count 0 despite the child process successfully outputting text
- This isn't a scoping issue — even with `$script:`, `GetNewClosure()`, or file logging, callbacks don't execute

### Root Cause: PowerShell's Event Handler Implementation is Broken

PowerShell's `add_OutputDataReceived` and `add_ErrorDataReceived` methods don't reliably invoke scriptblock callbacks. This is a known limitation where:
1. The .NET event fires correctly
2. But PowerShell's scriptblock marshaling to handle the event fails silently
3. No error is thrown — the callback simply never runs

### Verification Test

```powershell
$p.add_OutputDataReceived({
    param($sender, $eventArgs)
    "Event fired: $($eventArgs.Data)" | Out-File "C:\test\event_log.txt" -Append
    $queue.Enqueue($eventArgs.Data)
})
$p.BeginOutputReadLine()
$p.WaitForExit()
# Result: log file never updated, queue empty
```

### Solution: Use Runspaces for Parallel Synchronous Reading

Replace async events with synchronous `ReadToEnd()` calls running in parallel runspaces:

```powershell
# Create runspace pool for parallel reading
$runspacePool = [runspacefactory]::CreateRunspacePool(1, 2)
$runspacePool.Open()

# Runspace for stdout
$stdoutScript = { param($reader); $reader.ReadToEnd() }
$stdoutPS = [powershell]::Create().AddScript($stdoutScript).AddArgument($process.StandardOutput)
$stdoutPS.RunspacePool = $runspacePool
$stdoutAsync = $stdoutPS.BeginInvoke()

# Runspace for stderr
$stderrScript = { param($reader); $reader.ReadToEnd() }
$stderrPS = [powershell]::Create().AddScript($stderrScript).AddArgument($process.StandardError)
$stderrPS.RunspacePool = $runspacePool
$stderrAsync = $stderrPS.BeginInvoke()

# Wait for process
$process.WaitForExit($TimeoutMs)

# Collect results (with timeout to prevent hang)
if ($stdoutAsync.AsyncWaitHandle.WaitOne(5000)) {
    $stdoutContent = $stdoutPS.EndInvoke($stdoutAsync)
}
if ($stderrAsync.AsyncWaitHandle.WaitOne(5000)) {
    $stderrContent = $stderrPS.EndInvoke($stderrAsync)
}

# Cleanup
$stdoutPS.Dispose(); $stderrPS.Dispose()
$runspacePool.Close(); $runspacePool.Dispose()
```

### Why Runspaces Work

1. **No deadlock** — stdout and stderr are read in parallel, preventing buffer deadlock
2. **Synchronous reading** — `ReadToEnd()` is reliable and well-tested
3. **Proper isolation** — each runspace is a separate PowerShell instance
4. **Timeout safety** — `AsyncWaitHandle.WaitOne()` prevents infinite waits

### Key Takeaway

**Never use PowerShell's async event handlers (`add_OutputDataReceived`, `add_ErrorDataReceived`) for capturing process output.** They're unreliable. Use:
1. Runspaces with synchronous `ReadToEnd()` (best)
2. Jobs with `Start-Job` (alternative)
3. Temp files with redirection (simple but slower)

*Discovered through systematic testing.*

---

## 2026-02-01 — Always Launch Ship Asleep in a Visible Window

### Requirement

When running ship_asleep from Claude Code or any automated context, **always launch it in a separate visible PowerShell window** so the user can monitor progress in real-time.

### Why

- Background processes hide progress from the user
- Users want to see the PRD generation, task execution, and any errors live
- Debugging is much easier when you can watch the output stream

### How

```powershell
# Launch in new visible window
Start-Process powershell -ArgumentList @(
    '-ExecutionPolicy', 'Bypass'
    '-NoExit'
    '-Command', "cd C:\ship_asleep\scripts; .\auto-compound.ps1 -ProjectPath 'C:\your-project' -Verbose"
)
```

**Key flags:**
- `-NoExit` keeps window open after completion (for reviewing results)
- `-Verbose` shows detailed progress
- Separate window = user can watch while doing other work

### Document This

Add to any Claude Code instructions or CLAUDE.md files that use ship_asleep:
```
When running ship_asleep, always launch in a separate visible window using Start-Process powershell with -NoExit flag.
```

---

## 2026-02-01 — Age-Based Process Cleanup Was Killing Active Tasks (THE BUG)

### Problem: 3 of 8 tasks failed with ZERO output captured

During an overnight run implementing the Plant Passport feature, tasks 4, 7, and 8 all failed with:
- Timed out after 600 seconds OR exited with code 1
- **Empty stdout/stderr** - no output captured at all
- Process PIDs were assigned and logged, but nothing was ever written

The code was actually working - files were created, build passed - but the task statuses showed "failed".

### Root Cause: The cleanup code was killing active processes

The loop had "proactive cleanup" that killed node processes older than 5 minutes:

```powershell
# THE BUG - in loop.ps1 before each task
$nodeProcesses = Get-Process -Name node -ErrorAction SilentlyContinue
if ($nodeProcesses.Count -gt 5) {
    foreach ($proc in $nodeProcesses) {
        if ((Get-Date) - $proc.StartTime -gt [TimeSpan]::FromMinutes(5)) {
            & taskkill /F /T /PID $proc.Id 2>$null  # KILLS ACTIVE TASKS!
        }
    }
}
```

**Why this killed tasks:**
- Integration-heavy tasks (API endpoints, DB work, npm build) take >5 minutes
- A task starting at 11:30 would have its node process killed at 11:35 by cleanup
- With `--print` flag, killing mid-execution = zero output (buffer never flushes)

**Evidence that confirmed this:**
- Log showed "Cleaning up 6-7 stale node processes" right before failures
- Failed tasks were all long-running (API endpoints, npm build)
- Successful tasks were short (create types, create components)

### The Fix

**Removed the age-based cleanup entirely.** Process cleanup now only happens:
1. Via `taskkill /T /PID` on the specific PID when a task times out
2. Never based on process age
3. Never by process name globally

```powershell
# REMOVED - this was the bug
# $nodeProcesses = Get-Process -Name node ...
# foreach ($proc in $nodeProcesses) { taskkill... }

# NOTE in loop.ps1:
# Removed age-based "stale node process" cleanup
# This was THE BUG - it killed long-running tasks mid-execution!
```

### Multi-Model Diagnosis

This bug was diagnosed by consulting both **Gemini 3 Pro** and **GPT 5.2 Pro**:

**Gemini's diagnosis:** `--print` buffering hides crashes/hangs
- True but not the root cause

**GPT's diagnosis:** The cleanup is killing still-active processes
- Correct! This explained the pattern perfectly:
  - "Cleanup" log entries right before failures
  - Long tasks failing, short tasks succeeding
  - Code actually working despite "failed" status

**Key insight from GPT:**
> "Integration-heavy tasks run >5 minutes. Your cleanup kills processes older than 5 minutes. So a long-running task's own Node process becomes 'stale' by your definition and gets killed mid-flight."

### Additional Fixes Applied

1. **Removed `--print` flag** — enables streaming output instead of buffered
2. **Added visible window launch** — user can observe Claude running in separate window
3. **Event-based output capture** — replaced runspaces with `Register-ObjectEvent` (though later switched to file-based capture for visible window mode)
4. **Double WaitForExit pattern** — ensures async readers flush completely

### Key Takeaway

**Never kill processes by age or name in a parallel/concurrent system.** Only kill:
- The specific PID you spawned
- Using process tree kill (`taskkill /T`)
- When that specific task times out or errors

*Diagnosed by GPT 5.2 Pro, confirmed by Gemini 3 Pro, fixed 2026-02-01.*

---

## 2026-02-01 — Visible Window Mode for Observability

### Requirement

When running auto-compound from Claude Code, launch Claude tasks in a **separate visible PowerShell window** so the user can watch progress in real-time.

### Why

- Hidden background processes make debugging impossible
- Users want to see what Claude is doing during long tasks
- Cancelled bash commands from Claude Code would kill background processes mid-task

### Implementation

The `Invoke-ClaudeWithTimeout` function now:
1. Creates a wrapper PowerShell script
2. Launches it in a new visible window via `Start-Process`
3. The wrapper runs Claude and tees output to a temp file
4. Main script reads the temp file after completion

```powershell
# Wrapper script shows output AND captures it
$wrapperContent = @"
`$Host.UI.RawUI.WindowTitle = "Claude Task - PID `$PID"
Write-Host "=== Claude Task Started ===" -ForegroundColor Cyan
Get-Content "$promptFile" -Raw | & "$claudePath" --dangerously-skip-permissions 2>&1 |
    Tee-Object -FilePath "$outputFile"
Write-Host "=== Claude Task Finished ===" -ForegroundColor Cyan
"@

# Launch in visible window
Start-Process -FilePath "powershell.exe" `
    -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $wrapperScript `
    -PassThru
```

### Benefits

- User sees Claude's work in real-time
- Output is still captured for logging/verification
- Process survives if Claude Code bash command is cancelled
- Window stays open with "press any key" for post-mortem review

*Implemented 2026-02-01.*

---

## 2026-02-01 — Build Incrementally, Merge Before Moving On

### Problem: Feature branches get orphaned and work is lost

During overnight runs, the auto-compound pipeline:
1. Creates a feature branch for Priority 1
2. Builds the feature (e.g., admin passport pages)
3. Moves to Priority 2 **without merging Priority 1**
4. Next run does `git reset --hard` to start clean
5. Priority 1 work is orphaned — still in git history but not on main

**Example:** Admin passport management pages (`/admin/passports`, `/admin/passports/new`, create/edit forms) were built in commits around `1c8ff87` but never merged. Subsequent runs started fresh from main, leaving that work stranded.

### Root Cause: No merge gate between priorities

The pipeline assumes each run is independent. But features build on each other:
- Priority 1 builds foundational pages
- Priority 2 extends them
- If Priority 1 isn't merged, Priority 2 either duplicates work or builds on nothing

### The Principle

> **Build incrementally. Merge before moving on.**

Each completed feature should be:
1. **Committed** to its feature branch ✓ (already happens)
2. **PR created** ✓ (already happens)
3. **Merged to main** before the next priority starts ← MISSING

### Recommended Fix

Add a merge gate to `auto-compound.ps1`:

```powershell
# After PR creation, wait for merge or auto-merge if tests pass
if ($AutoMerge -and $TestsPassed) {
    gh pr merge --auto --squash
    # Wait for merge to complete before starting next priority
}
```

Or require manual merge review:
```
[GATE] Priority 1 complete. PR #42 ready for review.
       Merge to main before running next priority.
```

### Workaround Until Fixed

Before starting a new auto-compound run:
1. Check for open PRs: `gh pr list`
2. Review and merge completed work
3. Then start the next priority

### Key Takeaway

**Overnight automation should compound, not reset.** Each night's work should build on the previous night's merged code. Orphan branches are wasted compute.

*Discovered 2026-02-01 when admin pages were found orphaned in git history.*

---
