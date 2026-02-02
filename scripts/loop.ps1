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

    # Timeout per task in seconds (default: 10 minutes)
    [int]$TaskTimeoutSeconds = 600,

    # Directory to save Claude session transcripts
    [string]$TranscriptDir = ""
)

$ErrorActionPreference = "Stop"

# Force CI mode to prevent build tools from hanging in watch mode
$env:CI = "true"

if (-not (Test-Path $TasksFile)) {
    Write-Error "Tasks file not found: $TasksFile"
    exit 1
}

# Setup logging
if (-not $LogFile) {
    $LogFile = Join-Path (Split-Path $TasksFile -Parent) "loop.log"
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
    return ($Tasks | Where-Object { $_.status -eq "completed" }).Count
}

function Get-FailedCount {
    param($Tasks)
    return ($Tasks | Where-Object { $_.status -eq "failed" }).Count
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
    Set-Location $WorkingDir

    try {
        foreach ($check in $Checks) {
            Write-Log "Quality check: $check"
            $result = Invoke-Expression $check 2>&1
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) {
                Write-Log "Quality check FAILED: $check (exit code $exitCode)" "WARN"
                Set-Location $originalLocation
                return @{
                    passed = $false
                    reason = "Quality check failed: $check"
                }
            }
            Write-Log "Quality check passed: $check"
        }

        Set-Location $originalLocation
        return @{ passed = $true; reason = "" }
    } catch {
        Set-Location $originalLocation
        Write-Log "Quality check error: $($_.Exception.Message)" "ERROR"
        return @{
            passed = $false
            reason = "Quality check error: $($_.Exception.Message)"
        }
    }
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

    # Create temp files for prompt and output
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $promptFile = Join-Path $env:TEMP "claude_prompt_$timestamp.txt"
    $outputFile = Join-Path $env:TEMP "claude_output_$timestamp.txt"
    $exitCodeFile = Join-Path $env:TEMP "claude_exitcode_$timestamp.txt"

    $Prompt | Out-File $promptFile -Encoding UTF8

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
    $wrapperScript = Join-Path $env:TEMP "claude_wrapper_$timestamp.ps1"

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

    $wrapperContent | Out-File $wrapperScript -Encoding UTF8

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

    # If no file specified, pass (verification tasks, build tasks, etc.)
    if ($null -eq $Task.file -or [string]::IsNullOrWhiteSpace($Task.file)) {
        Write-Log "No file specified for task, skipping file verification"
        return @{ passed = $true; reason = "" }
    }

    try {
        # Security: anchor to workspace, prevent path traversal
        $filePath = $Task.file
        if (-not [System.IO.Path]::IsPathRooted($filePath)) {
            $filePath = Join-Path $WorkspaceRoot $filePath
        }

        # Normalize and check it's still under workspace
        $fullPath = [System.IO.Path]::GetFullPath($filePath)
        $workspaceFullPath = [System.IO.Path]::GetFullPath($WorkspaceRoot)
        if (-not $fullPath.StartsWith($workspaceFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Log "VERIFICATION FAILED: Path escapes workspace: $($Task.file)" "ERROR"
            return @{
                passed = $false
                reason = "Security: path escapes workspace"
            }
        }

        # Check file exists (use -LiteralPath for special chars, -PathType Leaf for files only)
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            Write-Log "VERIFICATION FAILED: File does not exist: $($Task.file)" "WARN"
            return @{
                passed = $false
                reason = "Expected file not created: $($Task.file)"
            }
        }

        # Check file has content (use Get-Item for size, not Get-Content)
        $fileInfo = Get-Item -LiteralPath $fullPath
        if ($fileInfo.Length -eq 0) {
            Write-Log "VERIFICATION FAILED: File exists but is empty: $($Task.file)" "WARN"
            return @{
                passed = $false
                reason = "File created but empty: $($Task.file)"
            }
        }

        # Check file was modified during this task (catches stale files)
        if ($fileInfo.LastWriteTime -lt $TaskStartTime) {
            Write-Log "VERIFICATION FAILED: File not modified during task: $($Task.file)" "WARN"
            return @{
                passed = $false
                reason = "File exists but was not modified during task execution"
            }
        }

        Write-Log "VERIFICATION PASSED: $($Task.file) (size: $($fileInfo.Length) bytes, modified: $($fileInfo.LastWriteTime))"
        return @{ passed = $true; reason = "" }

    } catch {
        Write-Log "VERIFICATION ERROR: $($_.Exception.Message)" "ERROR"
        return @{
            passed = $false
            reason = "Verification error: $($_.Exception.Message)"
        }
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
3. If all criteria pass, commit your changes with a descriptive message
4. If you hit a blocker you cannot resolve, explain what's blocking you

Do NOT move to other tasks. Focus only on this one.

When done, output one of:
- "TASK_COMPLETE" if all acceptance criteria are met AND the file exists
- "TASK_BLOCKED: <reason>" if you cannot proceed
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

    # Log output (truncated)
    $outputPreview = if ($claudeOutput.Length -gt 500) {
        $claudeOutput.Substring(0, 500) + "... [truncated]"
    } else {
        $claudeOutput
    }
    Write-Log "Claude output: $outputPreview"

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
}

$summary | ConvertTo-Json
