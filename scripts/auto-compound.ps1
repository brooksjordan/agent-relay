# auto-compound.ps1
# Job 2: Full pipeline from priority report to PR
#
# Usage: Launched via launch-auto-compound.ps1 (the ONLY correct way)
#   .\launch-auto-compound.ps1 -ProjectPath "C:\agent_roi" -Verbose
#
# This is Job 2 of the "Ship While You Sleep" loop.
# Run at 11:00 PM, after compound-review.
#
# Pipeline: preflight -> git reset -> report -> PRD -> tasks -> implementation -> PR -> mark complete

[CmdletBinding()]
param(
    [string]$ProjectPath = ".",
    [string]$ProjectName = "",
    [string]$ReportsDir = "reports",
    [string]$TasksDir = "tasks",
    [string]$ReportFile = "PRIORITIES.md",
    [int]$MaxIterations = 25,
    [switch]$DryRun,
    [switch]$ForceReset,
    [switch]$AllowInline,
    # Quality gate commands (e.g., "npm run typecheck", "npm test")
    [string[]]$QualityChecks = @()
)

$ErrorActionPreference = "Stop"

# Resolve paths
$ProjectPath = Resolve-Path $ProjectPath
$ScriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AnalyzeScript = Join-Path $ScriptsDir "analyze-report.ps1"
$LoopScript = Join-Path $ScriptsDir "loop.ps1"
$LogFile = Join-Path $ProjectPath "logs\auto-compound.log"

# Ensure directories exist
$logsDir = Join-Path $ProjectPath "logs"
$tasksFullDir = Join-Path $ProjectPath $TasksDir
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Force -Path $logsDir | Out-Null }
if (-not (Test-Path $tasksFullDir)) { New-Item -ItemType Directory -Force -Path $tasksFullDir | Out-Null }

# Check if verbose was passed
$isVerbose = $PSBoundParameters.ContainsKey('Verbose')

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logLine
    if ($script:isVerbose -or $Level -eq "ERROR" -or $Level -eq "SUCCESS" -or $Level -eq "STAGE") {
        $color = switch ($Level) {
            "ERROR" { "Red" }
            "WARN"  { "Yellow" }
            "SUCCESS" { "Green" }
            "STAGE" { "Cyan" }
            default { "White" }
        }
        Write-Host $logLine -ForegroundColor $color
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments
    )
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = & $Command @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    [pscustomobject]@{ ExitCode = $code; Output = ($out -join "`n") }
}

# --- Main Execution ---

Write-Log "=== Auto-Compound Started ===" "STAGE"
$displayName = if ($ProjectName) { $ProjectName } else { Split-Path $ProjectPath -Leaf }
Write-Log "Project: $displayName"
Write-Log "Path: $ProjectPath"
Write-Log "Max iterations: $MaxIterations"

Push-Location $ProjectPath

try {
    # ========================================
    # STAGE 0: Preflight (BEFORE destructive reset)
    # ========================================
    Write-Log "STAGE 0: Preflight" "STAGE"

    # 0a. Enforce visible-window launch
    if (-not $env:SHIP_ASLEEP_VISIBLE_LAUNCH -and -not $AllowInline) {
        Write-Log "Pipeline must be launched via launch-auto-compound.ps1 (not inline)." "ERROR"
        Write-Log "Run: C:\ship_asleep\scripts\launch-auto-compound.ps1 -ProjectPath `"$ProjectPath`" -Verbose" "ERROR"
        Write-Log "Or use -AllowInline to override (not recommended)." "ERROR"
        exit 2
    }

    # 0b. Must be a git repo
    if (-not (Test-Path (Join-Path $ProjectPath ".git"))) {
        Write-Log "Not a git repository: $ProjectPath" "ERROR"
        exit 1
    }

    # 0c. Auto-clean gitignored build artifacts, then check for real uncommitted work
    #     git clean -fdX removes ONLY ignored files (uppercase X). Safe for build leftovers.
    $ErrorActionPreference = "Continue"
    git clean -fdX 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"

    # Ensure logs/ exists for Write-Log after cleaning
    $logsDir = Join-Path $ProjectPath "logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }

    # Now check for tracked changes (real user work)
    $diffResult = Invoke-Native git diff --name-only
    if (-not $ForceReset -and -not [string]::IsNullOrWhiteSpace($diffResult.Output)) {
        Write-Log "Tracked file changes found. Aborting BEFORE destructive reset." "ERROR"
        Write-Log "Changed files:`n$($diffResult.Output)" "WARN"
        exit 1
    }

    # Check for untracked non-ignored files
    $untrackedResult = Invoke-Native git ls-files --others --exclude-standard
    if (-not $ForceReset -and -not [string]::IsNullOrWhiteSpace($untrackedResult.Output)) {
        Write-Log "Untracked non-ignored files found. Aborting BEFORE destructive reset." "ERROR"
        Write-Log "Untracked files:`n$($untrackedResult.Output)" "WARN"
        exit 1
    }

    # 0d. Fetch from origin (non-destructive)
    $defaultBranch = "main"
    $fetch = Invoke-Native git fetch origin main
    if ($fetch.ExitCode -ne 0) {
        $fetch2 = Invoke-Native git fetch origin master
        if ($fetch2.ExitCode -ne 0) {
            Write-Log "Failed to fetch origin/main or origin/master" "ERROR"
            exit 1
        }
        $defaultBranch = "master"
    }
    Write-Log "Fetched origin/$defaultBranch"

    # 0e. Verify report exists on remote (before we reset and potentially lose local-only files)
    $gitReportPath = ($ReportsDir.TrimEnd('\','/') + "/" + $ReportFile)
    $show = Invoke-Native git show "origin/${defaultBranch}:${gitReportPath}"
    if ($show.ExitCode -ne 0) {
        Write-Log "Report not found on origin/$defaultBranch at: $gitReportPath" "ERROR"
        Write-Log "The report must be committed and pushed before launching the pipeline." "ERROR"
        Write-Log "Fix: git add $gitReportPath && git commit -m 'Add priority report' && git push" "ERROR"
        exit 1
    }

    # 0f. Check for open priorities (before destructive reset)
    $tmpReport = New-TemporaryFile
    Set-Content -Path $tmpReport -Value $show.Output -Encoding UTF8

    Write-Log "Checking origin/${defaultBranch}:${gitReportPath} for open priorities..."
    $preflight = & $AnalyzeScript -ReportPath $tmpReport
    $preflightAnalysis = $preflight | ConvertFrom-Json
    Remove-Item $tmpReport -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($preflightAnalysis.priority_item)) {
        Write-Log "All priorities are complete in $ReportFile. Nothing to build." "SUCCESS"
        Write-Log "To add new work: edit $gitReportPath, commit, and push." "INFO"
        exit 0
    }

    Write-Log "Next priority: $($preflightAnalysis.priority_item)" "SUCCESS"
    Write-Log "Preflight passed. Proceeding to build." "SUCCESS"

    # ========================================
    # STAGE 1: Git setup - destructive reset
    # ========================================
    Write-Log "STAGE 1: Git setup (destructive reset)" "STAGE"

    $ErrorActionPreference = "Continue"

    Write-Log "Resetting to origin/$defaultBranch..."
    git reset --hard "origin/$defaultBranch" 2>&1 | Out-Null
    git clean -fd 2>&1 | Out-Null
    git clean -fdX 2>&1 | Out-Null

    # Recreate logs/ IMMEDIATELY after cleans, before any Write-Log call
    $logsDir = Join-Path $ProjectPath "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

    Write-Log "Reset to origin/$defaultBranch. Clean slate established."

    $ErrorActionPreference = "Stop"

    # ========================================
    # STAGE 2: Load priority report (deterministic)
    # ========================================
    Write-Log "STAGE 2: Load priority report" "STAGE"

    $reportsFullDir = Join-Path $ProjectPath $ReportsDir
    $activeReport = Join-Path $reportsFullDir $ReportFile

    if (-not (Test-Path $activeReport)) {
        Write-Log "Report missing after reset: $activeReport" "ERROR"
        exit 1
    }

    Write-Log "Active report: $ReportFile"
    Write-Log "Analyzing report for #1 priority..."

    $analysisJson = & $AnalyzeScript -ReportPath $activeReport
    $analysis = $analysisJson | ConvertFrom-Json

    if ([string]::IsNullOrWhiteSpace($analysis.priority_item)) {
        Write-Log "All priorities complete in $ReportFile. Nothing to build." "SUCCESS"
        exit 0
    }

    Write-Log "Priority item: $($analysis.priority_item)"
    Write-Log "Branch: $($analysis.branch_name)"

    if ($DryRun) {
        Write-Log "DRY RUN - Would create branch and implement: $($analysis.priority_item)" "WARN"
        Write-Log "Analysis: $analysisJson"
        exit 0
    }

    # ========================================
    # STAGE 3: Create feature branch
    # ========================================
    Write-Log "STAGE 3: Create feature branch" "STAGE"

    $branchName = $analysis.branch_name

    # FALLBACK: If LLM returned empty branch name, auto-generate one
    if ([string]::IsNullOrWhiteSpace($branchName)) {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $branchName = "feature/auto-build-$timestamp"
        Write-Log "Empty branch name from LLM, using fallback: $branchName" "WARN"
    }

    # Sanitize branch name (remove invalid characters)
    $branchName = $branchName -replace '[^a-zA-Z0-9/_-]', '-'

    # Temporarily allow errors for git command (it outputs to stderr even on success)
    $ErrorActionPreference = "Continue"
    $gitOutput = git checkout -b $branchName 2>&1
    $gitExitCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"

    # Check exit code, NOT stderr (git writes success messages to stderr)
    if ($gitExitCode -ne 0) {
        # Branch might already exist, try to check it out
        $ErrorActionPreference = "Continue"
        git checkout $branchName 2>&1 | Out-Null
        $gitExitCode = $LASTEXITCODE
        $ErrorActionPreference = "Stop"

        if ($gitExitCode -ne 0) {
            Write-Log "Failed to create or checkout branch: $branchName" "ERROR"
            exit 1
        }
        Write-Log "Branch already exists, checked out: $branchName" "WARN"
    } else {
        Write-Log "Created branch: $branchName"
    }

    # Verify we're on the right branch
    $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
    if ($currentBranch -ne $branchName) {
        Write-Log "Branch mismatch: expected $branchName, got $currentBranch" "ERROR"
        exit 1
    }

    # ========================================
    # STAGE 4: Create PRD
    # ========================================
    Write-Log "STAGE 4: Create PRD" "STAGE"

    $prdFilename = "prd-$($branchName -replace '/', '-').md"
    $prdPath = Join-Path $tasksFullDir $prdFilename

    $prdPrompt = @"
Create a detailed Product Requirements Document (PRD) for this feature:

**Feature:** $($analysis.priority_item)

**Description:** $($analysis.description)

**Context:** $($analysis.reasoning)

Write the PRD to: $prdPath

The PRD should include:
1. Overview - What we're building and why
2. Requirements - Specific, testable requirements
3. Acceptance Criteria - How we know it's done (be specific!)
4. Out of Scope - What we're NOT building
5. Technical Notes - Any implementation guidance

Make the acceptance criteria very specific and testable - the agent needs to be able to verify completion autonomously.
"@

    Write-Log "Generating PRD..."
    $prdPrompt | & claude --print --dangerously-skip-permissions 2>&1 | Out-Null

    if (-not (Test-Path $prdPath)) {
        Write-Log "PRD was not created at expected path: $prdPath" "ERROR"
        # Try to find it
        $foundPrd = Get-ChildItem -Path $tasksFullDir -Filter "prd-*.md" |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($foundPrd) {
            $prdPath = $foundPrd.FullName
            Write-Log "Found PRD at: $prdPath" "WARN"
        } else {
            Write-Log "Could not find generated PRD" "ERROR"
            exit 1
        }
    }

    Write-Log "PRD created: $prdPath"

    # ========================================
    # STAGE 5: Convert PRD to tasks
    # ========================================
    Write-Log "STAGE 5: Convert PRD to tasks" "STAGE"

    $tasksFilename = "tasks-$($branchName -replace '/', '-').json"
    $tasksPath = Join-Path $tasksFullDir $tasksFilename

    $prdContent = Get-Content $prdPath -Raw

    $tasksPrompt = @"
TASK: Convert this PRD into a structured task list JSON file.

IMPORTANT: You MUST write the output to this exact file path:
$tasksPath

Read the PRD below, break it into small implementation tasks, and write the JSON file.

---

PRD CONTENT:
$prdContent

---

JSON FORMAT (write to $tasksPath):
{
  "prd_source": "$prdFilename",
  "created_at": "$(Get-Date -Format 'o')",
  "tasks": [
    {
      "id": 1,
      "title": "Short task title",
      "description": "What to implement",
      "acceptance_criteria": "Specific, testable criteria",
      "status": "pending"
    }
  ]
}

GUIDELINES:
- Break into 5-8 small, atomic tasks
- Each task independently completable
- Acceptance criteria must be verifiable without human input
- Order tasks logically (dependencies first)

Write the JSON file now.
"@

    Write-Log "Generating tasks..."
    $tasksPrompt | & claude --print --dangerously-skip-permissions 2>&1 | Out-Null

    if (-not (Test-Path $tasksPath)) {
        Write-Log "Tasks file was not created at expected path: $tasksPath" "ERROR"
        $foundTasks = Get-ChildItem -Path $tasksFullDir -Filter "tasks-*.json" |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($foundTasks) {
            $tasksPath = $foundTasks.FullName
            Write-Log "Found tasks at: $tasksPath" "WARN"
        } else {
            Write-Log "Could not find generated tasks file" "ERROR"
            exit 1
        }
    }

    $tasksData = Get-Content $tasksPath -Raw | ConvertFrom-Json
    $taskCount = $tasksData.tasks.Count
    Write-Log "Tasks created: $taskCount tasks in $tasksPath"

    # ========================================
    # STAGE 6: Run execution loop
    # ========================================
    Write-Log "STAGE 6: Execute tasks" "STAGE"

    Write-Log "Starting execution loop (max $MaxIterations iterations)..."

    $loopArgs = @{
        TasksFile = $tasksPath
        MaxIterations = $MaxIterations
    }
    if ($QualityChecks.Count -gt 0) {
        $loopArgs['QualityChecks'] = $QualityChecks
    }
    if ($PSBoundParameters.ContainsKey('Verbose')) {
        $loopArgs['Verbose'] = $true
    }
    $loopOutput = & $LoopScript @loopArgs

    # Check for completion signal
    if ($loopOutput -match "<promise>COMPLETE</promise>") {
        Write-Log "Received completion signal - all tasks done!" "SUCCESS"
    }
    $loopResult = $loopOutput | Select-Object -Last 1 | ConvertFrom-Json

    Write-Log "Loop complete: $($loopResult.completed) completed, $($loopResult.failed) failed, $($loopResult.pending) pending"

    # ========================================
    # STAGE 7: Create PR
    # ========================================
    Write-Log "STAGE 7: Create PR" "STAGE"

    $hasRemote = git remote 2>$null
    $pushSucceeded = $false
    if ($hasRemote) {
        $pushResult = Invoke-Native git push -u origin $branchName

        if ($pushResult.ExitCode -eq 0) {
            Write-Log "Branch pushed: $branchName"
            $pushSucceeded = $true
        } else {
            Write-Log "Failed to push branch (exit $($pushResult.ExitCode)): $($pushResult.Output)" "WARN"
        }
    } else {
        Write-Log "No remote configured, skipping push" "WARN"
    }

    # Build PR body
    $prBody = @"
## Summary

Automated implementation of: **$($analysis.priority_item)**

$($analysis.description)

## Implementation Stats

- Tasks completed: $($loopResult.completed)
- Tasks failed: $($loopResult.failed)
- Tasks pending: $($loopResult.pending)
- Iterations used: $($loopResult.iterations_used) / $($loopResult.max_iterations)

## Source

- Priority report: ``$ReportFile``
- PRD: ``$prdFilename``
- Tasks: ``$tasksFilename``

---

*Generated by Auto-Compound at $(Get-Date -Format 'yyyy-MM-dd HH:mm')*
"@

    # Create draft PR (if remote exists and push succeeded)
    $ghOutput = ""
    if ($hasRemote -and $pushSucceeded) {
        $prTitle = "Compound: $($analysis.priority_item)"

        # Write body to temp file for proper escaping
        $prBodyFile = Join-Path $env:TEMP "pr_body_$(Get-Date -Format 'yyyyMMdd_HHmmss').md"
        $prBody | Out-File $prBodyFile -Encoding UTF8

        $prResult = Invoke-Native gh pr create --draft --title $prTitle --body-file $prBodyFile --base $defaultBranch

        if ($prResult.ExitCode -eq 0) {
            $ghOutput = $prResult.Output
            Write-Log "PR created: $ghOutput" "SUCCESS"
        } else {
            Write-Log "Failed to create PR (exit $($prResult.ExitCode)): $($prResult.Output)" "WARN"
            Write-Log "Branch pushed but PR creation failed. Create manually."
        }

        Remove-Item $prBodyFile -ErrorAction SilentlyContinue
    } elseif ($hasRemote -and -not $pushSucceeded) {
        Write-Log "Skipping PR creation - push failed" "WARN"
    } else {
        Write-Log "No remote configured, skipping PR creation" "WARN"
        Write-Log "Changes committed to branch: $branchName" "SUCCESS"
    }

    # ========================================
    # STAGE 8: Mark priority complete in report
    # ========================================
    Write-Log "STAGE 8: Mark priority complete" "STAGE"

    # Switch to main/master to update the priority report
    $checkoutResult = Invoke-Native git checkout $defaultBranch
    if ($hasRemote) {
        Invoke-Native git pull origin $defaultBranch | Out-Null
    }

    if ($checkoutResult.ExitCode -ne 0) {
        Write-Log "Could not switch to $defaultBranch to mark priority complete" "WARN"
    } else {
        $reportPath = Join-Path $reportsFullDir $ReportFile
        if (Test-Path $reportPath) {
            $reportContent = Get-Content $reportPath -Raw
            $prNumber = ""

            # Extract PR number from gh output if available
            if ($ghOutput -match '#(\d+)') {
                $prNumber = $Matches[1]
            } elseif ($ghOutput -match '/pull/(\d+)') {
                $prNumber = $Matches[1]
            }

            # Build completion line
            $completionNote = "Merged via PR #$prNumber. Branch: ``$branchName``."
            if (-not $prNumber) {
                $completionNote = "Branch: ``$branchName``."
            }

            # Extract priority ID from priority_item (e.g., "P08" from "P08 - Wider Monte Carlo")
            $priorityId = ""
            if ($analysis.priority_item -match '(P\d+)') {
                $priorityId = $Matches[1]
            }

            if (-not $priorityId) {
                Write-Log "Could not extract priority ID (e.g. P08) from: $($analysis.priority_item)" "WARN"
            }

            # Match heading by priority ID in brackets (e.g., ## Priority 8 [P08-WIDER-MC]: ...)
            $pattern = "(?ms)(## )(Priority \d+ \[$priorityId[^\]]*\]: [^\r\n]*)\r?\n\r?\n(.*?)(?=\r?\n---|\r?\n## |$)"
            if ($priorityId -and $reportContent -match $pattern) {
                $fullMatch = $Matches[0]
                $headingPrefix = $Matches[1]
                $headingText = $Matches[2]
                $replacement = "${headingPrefix}~~${headingText}~~ COMPLETE`n`n${completionNote}"
                $newContent = $reportContent.Replace($fullMatch, $replacement)
                $newContent | Set-Content $reportPath -NoNewline

                # Commit and push
                $addResult = Invoke-Native git add $reportPath
                $commitResult = Invoke-Native git commit -m "Mark $($analysis.priority_item) complete"
                if ($hasRemote) {
                    $pushMain = Invoke-Native git push origin $defaultBranch
                }

                if ($hasRemote -and $pushMain.ExitCode -eq 0) {
                    Write-Log "Priority marked complete in report and pushed to $defaultBranch" "SUCCESS"
                } elseif ($hasRemote) {
                    Write-Log "Priority marked complete locally but push failed" "WARN"
                } else {
                    Write-Log "Priority marked complete in report" "SUCCESS"
                }
            } else {
                Write-Log "Could not find priority heading to mark complete (may already be marked)" "WARN"
            }
        } else {
            Write-Log "Report file not found at $reportPath" "WARN"
        }
    }

    Write-Log "=== Auto-Compound Complete ===" "SUCCESS"

    # Output summary
    $summary = @{
        priority_item = $analysis.priority_item
        branch = $branchName
        tasks_completed = $loopResult.completed
        tasks_failed = $loopResult.failed
        tasks_pending = $loopResult.pending
        iterations_used = $loopResult.iterations_used
        pr_created = ($pushSucceeded -and $ghOutput)
    }

    $summary | ConvertTo-Json

} catch {
    Write-Log "Error: $_" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    exit 1
} finally {
    Pop-Location
}
