# auto-compound.ps1
# Job 2: Full pipeline from priority report to PR
#
# Usage: .\auto-compound.ps1 [-ProjectPath "."] [-MaxIterations 25] [-DryRun] [-Verbose]
#
# This is Job 2 of the "Ship While You Sleep" loop.
# Run at 11:00 PM, after compound-review.
#
# Pipeline: report → PRD → tasks → implementation → PR

[CmdletBinding()]
param(
    [string]$ProjectPath = ".",
    [string]$ProjectName = "",
    [string]$ReportsDir = "reports",
    [string]$TasksDir = "tasks",
    [int]$MaxIterations = 25,
    [switch]$DryRun,
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

# --- Main Execution ---

Write-Log "=== Auto-Compound Started ===" "STAGE"
$displayName = if ($ProjectName) { $ProjectName } else { Split-Path $ProjectPath -Leaf }
Write-Log "Project: $displayName"
Write-Log "Path: $ProjectPath"
Write-Log "Max iterations: $MaxIterations"

Push-Location $ProjectPath

try {
    # ========================================
    # STAGE 1: Git setup - ensure clean state
    # ========================================
    Write-Log "STAGE 1: Git setup" "STAGE"

    # Temporarily allow errors for git commands
    $ErrorActionPreference = "Continue"

    # CRITICAL: Always reset to clean state first to prevent dirty state contamination
    # This handles cases where a previous run failed mid-file-modification
    Write-Log "Ensuring clean workspace state..."
    git reset --hard HEAD 2>&1 | Out-Null
    git clean -fd 2>&1 | Out-Null
    Write-Log "Workspace reset to clean state"

    # Only fetch/reset if remote exists
    $hasRemote = git remote 2>$null
    if ($hasRemote) {
        git fetch origin main 2>&1 | Out-Null
        git reset --hard origin/main 2>&1 | Out-Null

        if ($LASTEXITCODE -ne 0) {
            # Try master if main doesn't exist
            git fetch origin master 2>&1 | Out-Null
            git reset --hard origin/master 2>&1 | Out-Null
        }
        Write-Log "Reset to latest main/master"
    } else {
        Write-Log "No remote configured, using local state" "WARN"
        # Ensure we're on main/master
        $branch = git rev-parse --abbrev-ref HEAD 2>$null
        if ($branch -ne "main" -and $branch -ne "master") {
            git checkout main 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                git checkout master 2>&1 | Out-Null
            }
        }
    }

    $ErrorActionPreference = "Stop"

    # ========================================
    # STAGE 2: Find and analyze priority report
    # ========================================
    Write-Log "STAGE 2: Find priority report" "STAGE"

    $reportsFullDir = Join-Path $ProjectPath $ReportsDir
    if (-not (Test-Path $reportsFullDir)) {
        Write-Log "Reports directory not found: $reportsFullDir" "ERROR"
        Write-Log "Create a priority report in $ReportsDir/ to get started."
        exit 1
    }

    $latestReport = Get-ChildItem -Path $reportsFullDir -Filter "*.md" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latestReport) {
        Write-Log "No priority reports found in $reportsFullDir" "ERROR"
        exit 1
    }

    Write-Log "Latest report: $($latestReport.Name)"

    # Analyze to get #1 priority
    Write-Log "Analyzing report for #1 priority..."

    $analysisJson = & $AnalyzeScript -ReportPath $latestReport.FullName
    $analysis = $analysisJson | ConvertFrom-Json

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

    # Push branch (if remote exists)
    # NOTE: Native commands (git, gh) write progress to stderr even on success.
    # We must use ErrorActionPreference=Continue and check $LASTEXITCODE to avoid
    # false termination. See LESSONS_LEARNED.md for details.
    $hasRemote = git remote 2>$null
    $pushSucceeded = $false
    if ($hasRemote) {
        $oldEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $pushOutput = & git push -u origin $branchName 2>&1
            $pushExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldEap
        }

        if ($pushExitCode -eq 0) {
            Write-Log "Branch pushed: $branchName"
            $pushSucceeded = $true
        } else {
            Write-Log "Failed to push branch (exit $pushExitCode): $($pushOutput -join ' ')" "WARN"
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

- Priority report: ``$($latestReport.Name)``
- PRD: ``$prdFilename``
- Tasks: ``$tasksFilename``

---

*Generated by Auto-Compound at $(Get-Date -Format 'yyyy-MM-dd HH:mm')*
"@

    # Create draft PR (if remote exists and push succeeded)
    if ($hasRemote -and $pushSucceeded) {
        $prTitle = "Compound: $($analysis.priority_item)"

        # Write body to temp file for proper escaping
        $prBodyFile = Join-Path $env:TEMP "pr_body_$(Get-Date -Format 'yyyyMMdd_HHmmss').md"
        $prBody | Out-File $prBodyFile -Encoding UTF8

        $oldEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $ghOutput = & gh pr create --draft --title $prTitle --body-file $prBodyFile --base main 2>&1
            $ghExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldEap
        }

        if ($ghExitCode -eq 0) {
            Write-Log "PR created: $ghOutput" "SUCCESS"
        } else {
            # Try with master
            $oldEap = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Continue"
                $ghOutput = & gh pr create --draft --title $prTitle --body-file $prBodyFile --base master 2>&1
                $ghExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $oldEap
            }

            if ($ghExitCode -eq 0) {
                Write-Log "PR created: $ghOutput" "SUCCESS"
            } else {
                Write-Log "Failed to create PR (exit $ghExitCode): $($ghOutput -join ' ')" "WARN"
                Write-Log "Branch pushed but PR creation failed. Create manually."
            }
        }

        Remove-Item $prBodyFile -ErrorAction SilentlyContinue
    } elseif ($hasRemote -and -not $pushSucceeded) {
        Write-Log "Skipping PR creation — push failed" "WARN"
    } else {
        Write-Log "No remote configured, skipping PR creation" "WARN"
        Write-Log "Changes committed to branch: $branchName" "SUCCESS"
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
        pr_created = ($LASTEXITCODE -eq 0)
    }

    $summary | ConvertTo-Json

} catch {
    Write-Log "Error: $_" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    exit 1
} finally {
    Pop-Location
}
