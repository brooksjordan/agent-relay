# loop.ps1
# Execution loop: runs Claude iteratively on tasks until complete
#
# Usage: .\loop.ps1 -TasksFile "tasks/prd.json" [-MaxIterations 25] [-Verbose]

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TasksFile,

    [int]$MaxIterations = 25,

    [string]$LogFile = "",

    # Quality gate commands to run after each successful task (e.g., "npm run typecheck", "npm test")
    [string[]]$QualityChecks = @(),

    # Archive directory for previous runs
    [string]$ArchiveDir = "",

    # Timeout per task in seconds (default: 15 minutes)
    [int]$TaskTimeoutSeconds = 900,

    # Directory to save Claude session transcripts
    [string]$TranscriptDir = ""
)

$ErrorActionPreference = "Stop"

# Load shared utilities (Invoke-Native, Invoke-SafeExpression)
. "$PSScriptRoot\common.ps1"

# Force CI mode to prevent build tools from hanging in watch mode
$env:CI = "true"

if (-not (Test-Path $TasksFile)) {
    Write-Error "Tasks file not found: $TasksFile"
    exit 1
}

# Setup logging
if (-not $LogFile) {
    # Log lives OUTSIDE the workspace (in agent-relay/logs/) so git clean -fd can't delete it
    $logDir = Join-Path $PSScriptRoot "..\logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $LogFile = Join-Path $logDir "loop.log"
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logLine

    # Use Write-Verbose for INFO, Write-Host for errors/success
    switch ($Level) {
        "ERROR"   { Write-Host $logLine -ForegroundColor Red }
        "WARN"    { Write-Host $logLine -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logLine -ForegroundColor Green }
        "ITER"    { Write-Host $logLine -ForegroundColor Cyan }
        default   { Write-Verbose $logLine }
    }
}

function Get-Tasks {
    $content = Get-Content $TasksFile -Raw | ConvertFrom-Json
    return $content.tasks
}

function Save-Tasks {
    param($Tasks)
    $content = @{ tasks = $Tasks }
    $content | ConvertTo-Json -Depth 10 | Out-File $TasksFile -Encoding UTF8
}

function Get-NextPendingTask {
    param($Tasks)
    return $Tasks | Where-Object { $_.status -eq "pending" } | Select-Object -First 1
}

function Get-CompletedCount {
    param($Tasks)
    return @($Tasks | Where-Object { $_.status -eq "completed" }).Count
}

function Get-FailedCount {
    param($Tasks)
    return @($Tasks | Where-Object { $_.status -eq "failed" }).Count
}

function Invoke-QualityChecks {
    param(
        [string[]]$Checks,
        [string]$WorkingDir
    )

    if ($Checks.Count -eq 0) {
        Write-Log "No quality checks configured, skipping"
        return @{ passed = $true; reason = "" }
    }

    Write-Log "Running $($Checks.Count) quality check(s)..."
    $originalLocation = Get-Location
    try {
        Set-Location $WorkingDir

        foreach ($check in $Checks) {
            Write-Log "Quality check: $check"
            # Use Invoke-SafeExpression to prevent stderr warnings (npm EBADENGINE, tsc
            # deprecations, etc.) from becoming terminating exceptions. Trust exit codes.
            $safeResult = Invoke-SafeExpression $check
            if ($safeResult.ExitCode -ne 0) {
                Write-Log "Quality check FAILED: $check (exit code $($safeResult.ExitCode))" "WARN"
                return @{
                    passed = $false
                    reason = "Quality check failed: $check (exit code $($safeResult.ExitCode))"
                }
            }
            Write-Log "Quality check passed: $check"
        }

        return @{ passed = $true; reason = "" }
    } catch {
        Write-Log "Quality check error: $($_.Exception.Message)" "ERROR"
        return @{
            passed = $false
            reason = "Quality check error: $($_.Exception.Message)"
        }
    } finally {
        Set-Location $originalLocation
    }
}

function Get-ClaudeUsageFromOutput {
    param([string]$Output)
    $usage = @{ total_tokens = 0; input_tokens = 0; output_tokens = 0; cost_usd = 0.0 }

    # Claude Code outputs usage stats in various formats. Try common patterns.
    if ($Output -match 'Total tokens[:\s]+([0-9,]+)') {
        $usage.total_tokens = [int]($Matches[1] -replace ',', '')
    }
    if ($Output -match 'Input tokens[:\s]+([0-9,]+)') {
        $usage.input_tokens = [int]($Matches[1] -replace ',', '')
    }
    if ($Output -match 'Output tokens[:\s]+([0-9,]+)') {
        $usage.output_tokens = [int]($Matches[1] -replace ',', '')
    }
    if ($Output -match 'Total cost[:\s]+\$?([0-9.]+)') {
        $usage.cost_usd = [double]$Matches[1]
    }
    # Also try "cost: $X.XX" pattern
    if ($usage.cost_usd -eq 0 -and $Output -match '(?i)cost[:\s]+\$([0-9.]+)') {
        $usage.cost_usd = [double]$Matches[1]
    }

    return $usage
}

function Initialize-Archive {
    param(
        [string]$TasksFile,
        [string]$ArchiveDir,
        [string]$WorkspaceRoot
    )

    if ([string]::IsNullOrWhiteSpace($ArchiveDir)) {
        $ArchiveDir = Join-Path $WorkspaceRoot "archive"
    }

    # Check if there's a previous run to archive
    $progressFile = Join-Path (Split-Path $TasksFile -Parent) "progress.txt"
    $lastBranchFile = Join-Path $WorkspaceRoot ".last-branch"

    if ((Test-Path $TasksFile) -and (Test-Path $lastBranchFile)) {
        try {
            $tasksContent = Get-Content $TasksFile -Raw | ConvertFrom-Json
            $currentBranch = if ($tasksContent.branchName) { $tasksContent.branchName } else { "" }
            $lastBranch = Get-Content $lastBranchFile -Raw -ErrorAction SilentlyContinue

            if ($currentBranch -and $lastBranch -and ($currentBranch -ne $lastBranch.Trim())) {
                $date = Get-Date -Format "yyyy-MM-dd"
                $folderName = $lastBranch.Trim() -replace "^(feature|compound)/", ""
                $archiveFolder = Join-Path $ArchiveDir "$date-$folderName"

                Write-Log "Archiving previous run: $lastBranch -> $archiveFolder"
                New-Item -ItemType Directory -Path $archiveFolder -Force | Out-Null

                if (Test-Path $TasksFile) {
                    Copy-Item $TasksFile -Destination $archiveFolder -Force
                }
                if (Test-Path $progressFile) {
                    Copy-Item $progressFile -Destination $archiveFolder -Force
                }

                # Reset progress file for new run
                $newProgress = @"
# Progress Log
Started: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Branch: $currentBranch

## Codebase Patterns
(Patterns discovered during this run will be added here)

---

"@
                $newProgress | Out-File $progressFile -Encoding UTF8
                Write-Log "Progress file reset for new run"
            }
        } catch {
            Write-Log "Archive check failed: $($_.Exception.Message)" "WARN"
        }
    }

    # Track current branch
    if (Test-Path $TasksFile) {
        try {
            $tasksContent = Get-Content $TasksFile -Raw | ConvertFrom-Json
            if ($tasksContent.branchName) {
                $tasksContent.branchName | Out-File $lastBranchFile -Encoding UTF8 -NoNewline
            }
        } catch {
            # Ignore errors
        }
    }

    return $ArchiveDir
}

function Invoke-ClaudeWithTimeout {
    param(
        [string]$Prompt,
        [string]$WorkingDir,
        [int]$TimeoutSeconds,
        [string]$TranscriptPath
    )

    $result = @{
        Output = ""
        ExitCode = -1
        TimedOut = $false
        Error = $null
    }

    # Create temp files for prompt and output (GUID-based to avoid collisions on rapid retry)
    $uniqueId = [guid]::NewGuid().ToString("N")
    $promptFile = Join-Path $env:TEMP "claude_prompt_$uniqueId.txt"
    $outputFile = Join-Path $env:TEMP "claude_output_$uniqueId.txt"
    $exitCodeFile = Join-Path $env:TEMP "claude_exitcode_$uniqueId.txt"

    # Write prompt without BOM -- Node.js (Claude Code) can choke on BOM
    [System.IO.File]::WriteAllText($promptFile, $Prompt, (New-Object System.Text.UTF8Encoding $false))

    # Find Claude executable
    $claudePath = "claude"
    $whereResult = & where.exe claude 2>$null
    if ($whereResult) {
        $cmdPath = $whereResult | Where-Object { $_ -like "*.cmd" } | Select-Object -First 1
        if ($cmdPath) {
            $claudePath = $cmdPath
        } else {
            $claudePath = $whereResult | Select-Object -First 1
        }
        Write-Log "Found Claude at: $claudePath"
    } elseif (Test-Path "C:\Program Files\nodejs\claude.cmd") {
        $claudePath = "C:\Program Files\nodejs\claude.cmd"
        Write-Log "Using fallback Claude path: $claudePath"
    } else {
        Write-Log "WARNING: Claude not found in PATH or default location" "WARN"
    }

    # Create a wrapper script that runs Claude in a visible window and captures output
    $wrapperScript = Join-Path $env:TEMP "claude_wrapper_$uniqueId.ps1"

    # Write wrapper script that:
    # 1. Sets window title for easy identification
    # 2. Runs Claude with prompt piped in
    # 3. Tees output to file AND console (so user can watch)
    # 4. Saves exit code
    $wrapperContent = @"
`$Host.UI.RawUI.WindowTitle = "Claude Task - PID `$PID"
`$ErrorActionPreference = "Continue"
`$OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "=== Claude Task Started ===" -ForegroundColor Cyan
Write-Host "Working Directory: $WorkingDir" -ForegroundColor Gray
Write-Host "Timeout: $TimeoutSeconds seconds" -ForegroundColor Gray
Write-Host "=============================`n" -ForegroundColor Cyan

Set-Location "$WorkingDir"

# Run Claude with TRUE STREAMING - output displays line-by-line as it happens
try {
    Get-Content "$promptFile" -Raw | & "$claudePath" --dangerously-skip-permissions 2>&1 | Tee-Object -FilePath "$outputFile"
    `$LASTEXITCODE | Out-File "$exitCodeFile" -Encoding UTF8
} catch {
    Write-Host "`nERROR: `$_" -ForegroundColor Red
    `$_.ToString() | Out-File "$outputFile"
    "1" | Out-File "$exitCodeFile" -Encoding UTF8
}

Write-Host "`n=== Claude Task Finished ===" -ForegroundColor Cyan
# Window closes automatically - no blocking for overnight runs
"@

    # Write wrapper script without BOM
    [System.IO.File]::WriteAllText($wrapperScript, $wrapperContent, (New-Object System.Text.UTF8Encoding $false))

    try {
        # Launch in a NEW VISIBLE WINDOW so user can observe
        Write-Log "Launching Claude in visible window..."
        $process = Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $wrapperScript `
            -WorkingDirectory $WorkingDir `
            -PassThru

        $claudePid = $process.Id
        Write-Log "Claude window started with PID: $claudePid"

        # Wait for process with timeout
        $completed = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $completed) {
            Write-Log "TIMEOUT after $TimeoutSeconds seconds - killing process tree PID $claudePid" "WARN"
            $result.TimedOut = $true

            try {
                & taskkill /F /T /PID $claudePid 2>$null
                Start-Sleep -Seconds 2
            } catch {
                Write-Log "Failed to kill process tree: $_" "WARN"
            }

            $result.ExitCode = -1
            $result.Error = "Task timed out after $TimeoutSeconds seconds"
        } else {
            # Read exit code from file
            if (Test-Path $exitCodeFile) {
                $exitCodeStr = (Get-Content $exitCodeFile -Raw).Trim()
                $result.ExitCode = [int]$exitCodeStr
            } else {
                $result.ExitCode = $process.ExitCode
            }
        }

        # Read captured output
        Start-Sleep -Milliseconds 500
        if (Test-Path $outputFile) {
            $result.Output = Get-Content $outputFile -Raw -Encoding UTF8
        }

        # Save transcript
        if ($TranscriptPath) {
            $transcript = @"
================================================================================
CLAUDE SESSION TRANSCRIPT
================================================================================
Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Working Directory: $WorkingDir
Timeout: $TimeoutSeconds seconds
Timed Out: $($result.TimedOut)
Exit Code: $($result.ExitCode)

--- PROMPT ---
$Prompt

--- OUTPUT ---
$($result.Output)

--- STDERR ---

================================================================================
"@
            $transcript | Out-File $TranscriptPath -Encoding UTF8
            Write-Log "Transcript saved to: $TranscriptPath"
        }

    } catch {
        $result.Error = $_.Exception.Message
        Write-Log "Claude execution error: $($result.Error)" "ERROR"
    } finally {
        if ($process -and -not $process.HasExited) {
            try {
                & taskkill /F /T /PID $process.Id 2>$null
            } catch {}
        }
        # Clean up temp files
        Remove-Item $promptFile -ErrorAction SilentlyContinue
        Remove-Item $outputFile -ErrorAction SilentlyContinue
        Remove-Item $exitCodeFile -ErrorAction SilentlyContinue
        Remove-Item $wrapperScript -ErrorAction SilentlyContinue
    }

    return $result
}

function Test-TaskVerification {
    param(
        $Task,
        [string]$WorkspaceRoot,
        [datetime]$TaskStartTime
    )

    # Git-based verification: check if Claude actually changed anything in the working tree.
    # This replaces brittle file-existence / LastWriteTime checks with a single source of truth.
    $originalLocation = Get-Location
    try {
        Set-Location $WorkspaceRoot

        $gitStatusResult = Invoke-Native git status --porcelain
        $gitStatus = $gitStatusResult.Output
        $gitExitCode = $gitStatusResult.ExitCode

        if ($gitExitCode -ne 0) {
            Write-Log "VERIFICATION ERROR: git status failed (exit $gitExitCode): $gitStatus" "ERROR"
            return @{
                passed = $false
                reason = "git status failed -- not a git repo or git error"
            }
        }

        # If git status output is empty, Claude made no changes at all
        if ([string]::IsNullOrWhiteSpace($gitStatus)) {
            Write-Log "VERIFICATION FAILED: git status is clean -- no changes were made" "WARN"
            return @{
                passed = $false
                reason = "No changes detected in working tree (git status clean)"
            }
        }

        # Changes exist -- verification passes
        $changeCount = ($gitStatus -split "`n" | Where-Object { $_.Trim() -ne "" }).Count
        Write-Log "VERIFICATION PASSED: $changeCount file(s) changed in working tree"

        # Also honor verify_command if the task defines one
        if ($Task.PSObject.Properties.Name -contains 'verify_command' -and -not [string]::IsNullOrWhiteSpace($Task.verify_command)) {
            Write-Log "Running task verify_command: $($Task.verify_command)"
            $verifyResult = Invoke-SafeExpression $Task.verify_command
            if ($verifyResult.ExitCode -ne 0) {
                Write-Log "VERIFICATION FAILED: verify_command exited $($verifyResult.ExitCode)" "WARN"
                return @{
                    passed = $false
                    reason = "verify_command failed (exit $($verifyResult.ExitCode)): $($Task.verify_command)"
                }
            }
            Write-Log "verify_command passed"
        }

        return @{ passed = $true; reason = "" }

    } catch {
        Write-Log "VERIFICATION ERROR: $($_.Exception.Message)" "ERROR"
        return @{
            passed = $false
            reason = "Verification error: $($_.Exception.Message)"
        }
    } finally {
        Set-Location $originalLocation
    }
}

# --- Main Loop ---

# Workspace root is the directory containing the tasks file
$WorkspaceRoot = (Get-Item $TasksFile).Directory.Parent.FullName
Write-Log "=== Execution Loop Started ===" "ITER"
Write-Log "Tasks file: $TasksFile"
Write-Log "Workspace root: $WorkspaceRoot"
Write-Log "Max iterations: $MaxIterations"
Write-Log "Task timeout: $TaskTimeoutSeconds seconds"
Write-Log "Quality checks: $($QualityChecks -join ', ')"

# Setup transcript directory
if (-not $TranscriptDir) {
    $TranscriptDir = Join-Path $WorkspaceRoot "logs\transcripts"
}
if (-not (Test-Path $TranscriptDir)) {
    New-Item -ItemType Directory -Force -Path $TranscriptDir | Out-Null
}
Write-Log "Transcripts will be saved to: $TranscriptDir"

# Initialize archiving (archives previous run if branch changed)
$ArchiveDir = Initialize-Archive -TasksFile $TasksFile -ArchiveDir $ArchiveDir -WorkspaceRoot $WorkspaceRoot

$iteration = 0
$consecutiveFailures = 0
$maxConsecutiveFailures = 3
$maxRetryPerTask = 2  # Retry verification failures before marking as failed
$totalTokens = 0
$totalCost = 0.0

while ($iteration -lt $MaxIterations) {
    $iteration++
    Write-Log "--- Iteration $iteration of $MaxIterations ---" "ITER"

    # Load current task state
    $tasks = Get-Tasks
    $totalTasks = $tasks.Count
    $completedCount = Get-CompletedCount -Tasks $tasks
    $failedCount = Get-FailedCount -Tasks $tasks
    $pendingCount = $totalTasks - $completedCount - $failedCount

    Write-Log "Status: $completedCount completed, $failedCount failed, $pendingCount pending"

    # Check if we're done
    if ($pendingCount -eq 0) {
        Write-Log "All tasks processed!" "SUCCESS"
        break
    }

    # Get next task
    $task = Get-NextPendingTask -Tasks $tasks
    if (-not $task) {
        Write-Log "No pending tasks found." "SUCCESS"
        break
    }

    Write-Log "Working on task $($task.id): $($task.title)" "ITER"

    # Track retry attempts for this task
    $taskRetryCount = 0
    if ($task.PSObject.Properties.Name -contains 'retry_count') {
        $taskRetryCount = [int]$task.retry_count
    }

    # Record task start time for verification
    $taskStartTime = Get-Date

    # Build retry feedback section if this is a retry
    $retrySection = ""
    if ($taskRetryCount -gt 0 -and $task.PSObject.Properties.Name -contains 'last_failure') {
        $retrySection = @"

## IMPORTANT: Previous Attempt Failed

This is retry attempt $($taskRetryCount + 1). Your previous attempt claimed TASK_COMPLETE but verification failed:

**Failure reason:** $($task.last_failure)

You MUST actually create/modify the file. Do not just say you will - USE THE WRITE TOOL to create the file.
"@
    }

    # Build the prompt for this task
    $prompt = @"
You are implementing a task from a PRD. Work autonomously until the task is complete.

## Current Task

**ID:** $($task.id)
**Title:** $($task.title)
**Description:** $($task.description)
**Target File:** $($task.file)
$retrySection

## Acceptance Criteria

$($task.acceptanceCriteria -join "`n")

## Instructions

1. Implement this task completely - ACTUALLY CREATE THE FILE using the Write tool
2. Test your implementation against the acceptance criteria
3. Write your code changes but do NOT commit. The orchestrator will commit after verification.
4. If you hit a blocker you cannot resolve, explain what's blocking you

Do NOT move to other tasks. Focus only on this one.

When done, output one of:
- "TASK_COMPLETE" if all acceptance criteria are met AND the file exists
- "TASK_BLOCKED: <reason>" if you cannot proceed
- "TASK_BLOCKED: REPLAN_NEEDED" if the pending tasks are architecturally invalid based on current codebase state
"@

    # Run Claude on this task with timeout
    Write-Log "Executing Claude for task $($task.id) (timeout: $TaskTimeoutSeconds sec)..."

    # Generate transcript filename
    $transcriptFile = Join-Path $TranscriptDir "task-$($task.id)-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

    # NOTE: Removed age-based "stale node process" cleanup
    # This was THE BUG - it killed long-running tasks mid-execution!
    # Integration-heavy tasks (API endpoints, DB work, npm build) take >5 minutes,
    # so they were being killed by the "older than 5 minutes" cleanup.
    # Process cleanup now only happens via taskkill /T on specific PIDs during timeout.

    # Capture HEAD before task to detect phantom commits (Claude committing despite instructions)
    $preTaskHeadResult = Invoke-Native git -C $WorkspaceRoot rev-parse HEAD
    $preTaskHead = $preTaskHeadResult.Output.Trim()

    # Run Claude with timeout and PID tracking
    # Wrap in try-catch to prevent script crash on unexpected errors
    try {
        $claudeResult = Invoke-ClaudeWithTimeout `
            -Prompt $prompt `
            -WorkingDir $WorkspaceRoot `
            -TimeoutSeconds $TaskTimeoutSeconds `
            -TranscriptPath $transcriptFile

        $claudeOutput = $claudeResult.Output
        $claudeExitCode = $claudeResult.ExitCode
        $claudeTimedOut = $claudeResult.TimedOut
    } catch {
        Write-Log "CRITICAL: Invoke-ClaudeWithTimeout threw exception: $_" "ERROR"
        Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
        $claudeOutput = ""
        $claudeExitCode = -99
        $claudeTimedOut = $false

        # Save error to transcript file
        if ($transcriptFile) {
            "EXCEPTION during Claude execution:`n$_`n`nStack:`n$($_.ScriptStackTrace)" | Out-File $transcriptFile -Encoding UTF8
        }
    }

    # Detect phantom commits: if Claude committed despite "do NOT commit" instruction,
    # unroll the commit but keep the file changes so verification can evaluate them.
    $postTaskHeadResult = Invoke-Native git -C $WorkspaceRoot rev-parse HEAD
    $postTaskHead = $postTaskHeadResult.Output.Trim()
    if ($preTaskHead -ne $postTaskHead) {
        Write-Log "PHANTOM COMMIT DETECTED: HEAD moved from $preTaskHead to $postTaskHead" "WARN"
        Write-Log "Unrolling commit with git reset --mixed to restore orchestrator control..." "WARN"
        Invoke-Native git -C $WorkspaceRoot reset --mixed $preTaskHead | Out-Null
        Write-Log "Phantom commit unrolled. File changes preserved in working directory."
    }

    # Log output (truncated)
    $outputPreview = if ($claudeOutput.Length -gt 500) {
        $claudeOutput.Substring(0, 500) + "... [truncated]"
    } else {
        $claudeOutput
    }
    Write-Log "Claude output: $outputPreview"

    # Parse token usage from Claude output (moved up so it runs even on early exits like replan)
    $taskUsage = Get-ClaudeUsageFromOutput -Output $claudeOutput
    if ($taskUsage.total_tokens -gt 0 -or $taskUsage.cost_usd -gt 0) {
        Write-Log "Token usage: $($taskUsage.total_tokens) tokens, cost: `$$($taskUsage.cost_usd)"
    }
    $totalTokens += $taskUsage.total_tokens
    $totalCost += $taskUsage.cost_usd

    # Determine task outcome
    $taskCompleted = $false
    $taskBlocked = $false
    $taskNeedsRetry = $false
    $blockReason = ""
    $retryFeedback = ""

    # Handle timeout first - this is a hard failure
    if ($claudeTimedOut) {
        Write-Log "Task $($task.id) TIMED OUT after $TaskTimeoutSeconds seconds" "ERROR"
        $taskBlocked = $true
        $blockReason = "Task timed out after $TaskTimeoutSeconds seconds. Check transcript: $transcriptFile"
    }
    elseif ($claudeOutput -match "TASK_COMPLETE") {
        # Don't trust text output alone - verify the work was actually done
        $verification = Test-TaskVerification -Task $task -WorkspaceRoot $WorkspaceRoot -TaskStartTime $taskStartTime
        if ($verification.passed) {
            $taskCompleted = $true
            Write-Log "Task $($task.id) claims complete AND verification passed"
        } else {
            # Claude claimed complete but verification failed
            Write-Log "Task $($task.id) claimed TASK_COMPLETE but verification FAILED: $($verification.reason)" "WARN"

            if ($taskRetryCount -lt $maxRetryPerTask) {
                # Retry: keep as pending, increment retry count, add feedback
                Write-Log "Will retry task $($task.id) (attempt $($taskRetryCount + 1) of $maxRetryPerTask)" "WARN"
                $taskNeedsRetry = $true
                $retryFeedback = $verification.reason
            } else {
                # Max retries exceeded, mark as failed
                Write-Log "Task $($task.id) exceeded max retries, marking as failed" "ERROR"
                $taskBlocked = $true
                $blockReason = "Verification failed after $maxRetryPerTask retries: $($verification.reason)"
            }
        }
    } elseif ($claudeOutput -match "TASK_BLOCKED:\s*REPLAN_NEEDED") {
        Write-Log "Task $($task.id) requests REPLAN -- tasks may be architecturally invalid" "WARN"
        # Don't mark the task as failed -- the tasks themselves are the problem, not this task's execution
        # Exit the loop and signal to the caller that re-planning is needed
        Save-Tasks -Tasks $tasks
        $summary = @{
            completed = (Get-CompletedCount -Tasks $tasks)
            failed = (Get-FailedCount -Tasks $tasks)
            pending = ($tasks.Count - (Get-CompletedCount -Tasks $tasks) - (Get-FailedCount -Tasks $tasks))
            iterations_used = $iteration
            max_iterations = $MaxIterations
            replan_needed = $true
            total_tokens = $totalTokens
            total_cost_usd = $totalCost
        }
        $summary | ConvertTo-Json
        exit 0
    } elseif ($claudeOutput -match "TASK_BLOCKED:\s*(.+)") {
        $taskBlocked = $true
        $blockReason = $Matches[1]
    } elseif ($claudeExitCode -eq -99) {
        # Our exception marker
        $taskBlocked = $true
        $blockReason = "Claude execution threw an exception - check transcript"
        Write-Log "Task $($task.id) blocked due to exception" "ERROR"
    } elseif ($claudeExitCode -ne 0) {
        $taskBlocked = $true
        $blockReason = "Claude exited with code $claudeExitCode"
    }

    # Update task status
    $tasks = Get-Tasks  # Reload in case Claude modified it
    $taskIndex = [array]::FindIndex($tasks, [Predicate[object]]{ param($t) $t.id -eq $task.id })

    if ($taskCompleted) {
        # Run quality checks before marking complete
        $qualityResult = Invoke-QualityChecks -Checks $QualityChecks -WorkingDir $WorkspaceRoot
        if (-not $qualityResult.passed) {
            Write-Log "Task $($task.id) passed verification but FAILED quality checks" "WARN"
            if ($taskRetryCount -lt $maxRetryPerTask) {
                $taskNeedsRetry = $true
                $taskCompleted = $false
                $retryFeedback = $qualityResult.reason
            } else {
                $taskBlocked = $true
                $taskCompleted = $false
                $blockReason = "Quality check failed after $maxRetryPerTask retries: $($qualityResult.reason)"
            }
        }
    }

    if ($taskCompleted) {
        # Orchestrator commits -- Claude was told NOT to commit, so we do it here
        # after both verification and quality checks have passed.
        $taskNum = $task.id
        $commitMsg = "Task ${taskNum}: $($task.title)"
        Write-Log "Orchestrator committing: $commitMsg"
        $commitSucceeded = $false
        $addResult = Invoke-Native git -C $WorkspaceRoot add .
        if ($addResult.ExitCode -ne 0) {
            Write-Log "Orchestrator git add FAILED (exit $($addResult.ExitCode)): $($addResult.Output)" "ERROR"
            $taskCompleted = $false
            $taskBlocked = $true
            $blockReason = "Orchestrator git add failed (exit $($addResult.ExitCode))"
        } else {
            $commitResult = Invoke-Native git -C $WorkspaceRoot commit -m $commitMsg
            if ($commitResult.ExitCode -ne 0) {
                Write-Log "Orchestrator commit FAILED (exit $($commitResult.ExitCode)): $($commitResult.Output)" "ERROR"
                $taskCompleted = $false
                $taskBlocked = $true
                $blockReason = "Orchestrator git commit failed (exit $($commitResult.ExitCode)). Check for locked files or pre-commit hooks."
            } else {
                Write-Log "Orchestrator commit succeeded"
                $commitSucceeded = $true
            }
        }
    }

    if ($taskCompleted) {
        Write-Log "Task $($task.id) completed!" "SUCCESS"
        $tasks[$taskIndex].status = "completed"
        # Add property if it doesn't exist
        if (-not ($tasks[$taskIndex].PSObject.Properties.Name -contains 'completed_at')) {
            $tasks[$taskIndex] | Add-Member -NotePropertyName 'completed_at' -NotePropertyValue $null
        }
        $tasks[$taskIndex].completed_at = (Get-Date).ToString("o")
        $consecutiveFailures = 0

        # Check if ALL tasks are now complete (completion signal)
        $allTasks = Get-Tasks
        $allCompleted = ($allTasks | Where-Object { $_.status -ne "completed" }).Count -eq 0
        if ($allCompleted) {
            Write-Log "ALL TASKS COMPLETE!" "SUCCESS"
            Save-Tasks -Tasks $tasks
            # Output completion signal (Ralph pattern)
            Write-Host "<promise>COMPLETE</promise>"
            Write-Log "<promise>COMPLETE</promise>" "SUCCESS"
            break
        }
    } elseif ($taskNeedsRetry) {
        # Verification failed but retries remain - keep pending with feedback
        Write-Log "Task $($task.id) needs retry, keeping as pending" "WARN"
        # Increment retry count
        if (-not ($tasks[$taskIndex].PSObject.Properties.Name -contains 'retry_count')) {
            $tasks[$taskIndex] | Add-Member -NotePropertyName 'retry_count' -NotePropertyValue 0
        }
        $tasks[$taskIndex].retry_count = $taskRetryCount + 1
        # Store feedback for next attempt
        if (-not ($tasks[$taskIndex].PSObject.Properties.Name -contains 'last_failure')) {
            $tasks[$taskIndex] | Add-Member -NotePropertyName 'last_failure' -NotePropertyValue $null
        }
        $tasks[$taskIndex].last_failure = $retryFeedback
        # Keep status as pending
        $tasks[$taskIndex].status = "pending"
        $consecutiveFailures = 0  # Retry is progress, not a failure
    } elseif ($taskBlocked) {
        Write-Log "Task $($task.id) blocked: $blockReason" "WARN"
        $tasks[$taskIndex].status = "failed"
        # Add properties if they don't exist
        if (-not ($tasks[$taskIndex].PSObject.Properties.Name -contains 'failure_reason')) {
            $tasks[$taskIndex] | Add-Member -NotePropertyName 'failure_reason' -NotePropertyValue $null
        }
        if (-not ($tasks[$taskIndex].PSObject.Properties.Name -contains 'failed_at')) {
            $tasks[$taskIndex] | Add-Member -NotePropertyName 'failed_at' -NotePropertyValue $null
        }
        if (-not ($tasks[$taskIndex].PSObject.Properties.Name -contains 'transcript')) {
            $tasks[$taskIndex] | Add-Member -NotePropertyName 'transcript' -NotePropertyValue $null
        }
        $tasks[$taskIndex].failure_reason = $blockReason
        $tasks[$taskIndex].failed_at = (Get-Date).ToString("o")
        $tasks[$taskIndex].transcript = $transcriptFile
        $consecutiveFailures++

        # Differentiate agent failures (wipe tree) from orchestrator failures (halt + preserve)
        if ($blockReason -match "Orchestrator") {
            Write-Log "Orchestrator commit failed. Preserving verified work in working tree." "WARN"
            Write-Log "ABORTING LOOP. Human intervention required to resolve mechanical Git state." "ERROR"
            Save-Tasks -Tasks $tasks
            break
        }

        # Fix: Dirty Tree Cascade -- wipe broken code so the next task starts clean.
        # Without this, syntax errors and hallucinated logic from a failed task
        # pollute the working directory for subsequent tasks.
        Write-Log "Cleaning working tree after failed task $($task.id)..." "WARN"
        Invoke-Native git -C $WorkspaceRoot reset --hard HEAD | Out-Null
        Invoke-Native git -C $WorkspaceRoot clean -fd | Out-Null
        Write-Log "Working tree cleaned (git reset --hard + git clean -fd)"
    } else {
        # Ambiguous outcome - assume progress was made, keep as pending
        Write-Log "Task $($task.id) outcome unclear, keeping as pending" "WARN"
        $consecutiveFailures++
    }

    Save-Tasks -Tasks $tasks

    # Safety: bail if too many consecutive failures
    if ($consecutiveFailures -ge $maxConsecutiveFailures) {
        Write-Log "Too many consecutive failures ($consecutiveFailures). Stopping." "ERROR"
        break
    }

    # Brief pause between iterations
    Start-Sleep -Seconds 2
}

# Final summary
$tasks = Get-Tasks
$completedCount = Get-CompletedCount -Tasks $tasks
$failedCount = Get-FailedCount -Tasks $tasks
$pendingCount = $tasks.Count - $completedCount - $failedCount

Write-Log "=== Execution Loop Finished ===" "ITER"
Write-Log "Final: $completedCount completed, $failedCount failed, $pendingCount pending" "SUCCESS"
Write-Log "Iterations used: $iteration of $MaxIterations"

# Output summary as JSON for caller
$summary = @{
    completed = $completedCount
    failed = $failedCount
    pending = $pendingCount
    iterations_used = $iteration
    max_iterations = $MaxIterations
    total_tokens = $totalTokens
    total_cost_usd = $totalCost
}

$summary | ConvertTo-Json
