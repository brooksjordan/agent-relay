# auto-compound.ps1
# Job 2: Full pipeline from priority report to PR
#
# Usage: Launched via launch-auto-compound.ps1 (the ONLY correct way)
#   .\launch-auto-compound.ps1 -ProjectPath "C:\your-project" -Verbose
#
# This is Job 2 of the Agent Relay loop.
# Run at 11:00 PM, after compound-review.
#
# Pipeline: preflight -> safety stash -> git reset -> report -> PRD -> validate PRD -> tasks -> implementation -> PR -> mark complete

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
    [switch]$Resume,
    # Quality gate commands (e.g., "npm run typecheck", "npm test")
    [string[]]$QualityChecks = @()
)

$ErrorActionPreference = "Stop"

# Load shared utilities (Invoke-Native, Invoke-SafeExpression)
. "$PSScriptRoot\common.ps1"

# Resolve paths
$ProjectPath = Resolve-Path $ProjectPath
$ScriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AnalyzeScript = Join-Path $ScriptsDir "analyze-report.ps1"
$LoopScript = Join-Path $ScriptsDir "loop.ps1"
$LogFile = Join-Path $ProjectPath "logs\auto-compound.log"
$StateFile = Join-Path $ProjectPath "logs\pipeline-state.json"

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

# --- Resume infrastructure ---

$stageOrder = @("0", "1", "2", "3", "4", "4v", "5", "6", "7", "8", "9")
$runId = [guid]::NewGuid().ToString().Substring(0, 8)
$startedAt = (Get-Date).ToString("o")
$pipelineStartTime = Get-Date
$stageTimings = @{}
$resumeState = $null

function Start-StageTimer { $script:stageStart = Get-Date }
function Stop-StageTimer { param([string]$Stage); $script:stageTimings[$Stage] = [math]::Round(((Get-Date) - $script:stageStart).TotalSeconds, 1) }

function Test-StageComplete {
    param([string]$Stage)
    if (-not $script:resumeState) { return $false }
    $lastIdx = $script:stageOrder.IndexOf([string]$script:resumeState.last_completed_stage)
    $currentIdx = $script:stageOrder.IndexOf($Stage)
    return ($currentIdx -le $lastIdx)
}

function Save-PipelineState {
    param([string]$CompletedStage)
    $state = @{
        run_id              = $script:runId
        started_at          = $script:startedAt
        last_completed_stage = $CompletedStage
        default_branch      = if ($script:defaultBranch) { $script:defaultBranch } else { "" }
        priority_item       = if ($script:analysis) { $script:analysis.priority_item } else { "" }
        description         = if ($script:analysis) { $script:analysis.description } else { "" }
        branch_name         = if ($script:branchName) { $script:branchName } else { "" }
        prd_path            = if ($script:prdPath) { $script:prdPath } else { "" }
        tasks_path          = if ($script:tasksPath) { $script:tasksPath } else { "" }
        stage_timings       = $script:stageTimings
        elapsed_seconds     = [math]::Round(((Get-Date) - $script:pipelineStartTime).TotalSeconds, 0)
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content $script:StateFile -Encoding UTF8
    Write-Log "State saved: stage $CompletedStage complete"
}

# --- Main Execution ---

Write-Log "=== Auto-Compound Started ===" "STAGE"
$displayName = if ($ProjectName) { $ProjectName } else { Split-Path $ProjectPath -Leaf }
Write-Log "Project: $displayName"
Write-Log "Path: $ProjectPath"
Write-Log "Max iterations: $MaxIterations"

Push-Location $ProjectPath

try {
    # --- Resume: load state and restore variables ---
    if ($Resume -and (Test-Path $StateFile)) {
        $resumeState = Get-Content $StateFile -Raw | ConvertFrom-Json
        $runId = $resumeState.run_id
        $startedAt = $resumeState.started_at
        Write-Log "RESUMING from after stage $($resumeState.last_completed_stage) (run $runId)" "STAGE"

        # Restore persisted variables
        $defaultBranch = $resumeState.default_branch
        $branchName = $resumeState.branch_name
        $prdPath = $resumeState.prd_path
        $tasksPath = $resumeState.tasks_path

        # Reconstruct analysis object for stages that reference it
        $analysis = [pscustomobject]@{
            priority_item = $resumeState.priority_item
            description   = $resumeState.description
            branch_name   = $resumeState.branch_name
            reasoning     = ""
        }

        # Derived paths
        $reportsFullDir = Join-Path $ProjectPath $ReportsDir
        $activeReport = Join-Path $reportsFullDir $ReportFile

        # Derive filenames from full paths (needed for PR body in Stage 7)
        if ($prdPath) { $prdFilename = Split-Path $prdPath -Leaf }
        if ($tasksPath) { $tasksFilename = Split-Path $tasksPath -Leaf }

        # If resuming past stage 3, checkout the existing feature branch
        $lastStageIdx = $stageOrder.IndexOf([string]$resumeState.last_completed_stage)
        $stage3Idx = $stageOrder.IndexOf("3")
        if ($lastStageIdx -ge $stage3Idx -and $branchName) {
            Write-Log "Resuming: checking out existing branch $branchName"
            $ErrorActionPreference = "Continue"
            git checkout $branchName 2>&1 | Out-Null
            $ErrorActionPreference = "Stop"
        }

        # If resuming past stage 5, re-read tasks JSON
        $stage5Idx = $stageOrder.IndexOf("5")
        if ($lastStageIdx -ge $stage5Idx -and $tasksPath -and (Test-Path $tasksPath)) {
            $tasksData = Get-Content $tasksPath -Raw | ConvertFrom-Json
            Write-Log "Resuming: loaded $($tasksData.tasks.Count) tasks from $tasksPath"
        }

        # If resuming past stage 6, derive loop results from tasks JSON
        $stage6Idx = $stageOrder.IndexOf("6")
        if ($lastStageIdx -ge $stage6Idx -and $tasksData) {
            $doneCount = @($tasksData.tasks | Where-Object { $_.status -eq "done" -or $_.status -eq "completed" }).Count
            $failCount = @($tasksData.tasks | Where-Object { $_.status -eq "failed" }).Count
            $pendCount = @($tasksData.tasks | Where-Object { $_.status -eq "pending" }).Count
            $loopResult = [pscustomobject]@{
                completed       = $doneCount
                failed          = $failCount
                pending         = $pendCount
                iterations_used = "resumed"
                max_iterations  = $MaxIterations
            }
            Write-Log "Resuming: derived loop results ($doneCount completed, $failCount failed, $pendCount pending)"
        }
    } elseif ($Resume) {
        Write-Log "Resume requested but no state file found at $StateFile. Starting fresh." "WARN"
    }

    # ========================================
    # STAGE 0: Preflight (BEFORE destructive reset)
    # ========================================
    if (-not (Test-StageComplete "0")) {
        Write-Log "STAGE 0: Preflight" "STAGE"
        Start-StageTimer

        # 0a. Enforce visible-window launch
        if (-not $env:AGENT_RELAY_VISIBLE_LAUNCH -and -not $AllowInline) {
            Write-Log "Pipeline must be launched via launch-auto-compound.ps1 (not inline)." "ERROR"
            Write-Log "Run: .\launch-auto-compound.ps1 -ProjectPath `"$ProjectPath`" -Verbose" "ERROR"
            Write-Log "Or use -AllowInline to override (not recommended)." "ERROR"
            exit 2
        }

        # 0b. Must be a git repo
        if (-not (Test-Path (Join-Path $ProjectPath ".git"))) {
            Write-Log "Not a git repository: $ProjectPath" "ERROR"
            exit 1
        }

        # 0c. Auth preflight -- fail fast before any destructive operations
        Write-Log "Checking Claude CLI authentication..."
        $authTest = "ping" | & claude --print 2>&1
        if ($LASTEXITCODE -ne 0 -or ($authTest -join "`n") -match "(?i)not logged in|login") {
            Write-Log "Claude auth failed. Run 'claude login' in your terminal, then relaunch." "ERROR"; exit 1
        }

        # 0d. Safety stash BEFORE any destructive git operations
        #     --include-untracked captures tracked + untracked files, but leaves gitignored files
        #     (node_modules, .venv, etc.) alone. This avoids choking on 100K+ gitignored files.
        $stashTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $stashMessage = "agent-relay-safety-$stashTimestamp"
        Write-Log "Safety stash: creating '$stashMessage' before destructive operations"

        $stashResult = Invoke-Native git stash push --include-untracked -m $stashMessage
        if ($stashResult.ExitCode -ne 0 -and $stashResult.Output -notmatch "No local changes to save") {
            Write-Log "Safety stash FAILED: $($stashResult.Output)" "ERROR"
            Write-Log "Aborting BEFORE destructive reset to protect uncommitted files." "ERROR"
            exit 1
        }
        if ($stashResult.Output -match "No local changes to save") {
            Write-Log "Safety stash: nothing to stash (clean tree confirmed)"
        } else {
            $stashRef = Invoke-Native git stash list --max-count=1
            Write-Log "Safety stash created: $($stashRef.Output)" "WARN"
            Write-Log "Recovery: git stash pop (or git stash apply)" "WARN"
        }

        # 0d. Auto-clean gitignored build artifacts (now safe -- state is stashed)
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

        # 0e. Fetch from origin (non-destructive)
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

        # 0f. Verify report exists on remote (before we reset and potentially lose local-only files)
        $gitReportPath = ($ReportsDir.TrimEnd('\','/') + "/" + $ReportFile)
        $show = Invoke-Native git show "origin/${defaultBranch}:${gitReportPath}"
        if ($show.ExitCode -ne 0) {
            Write-Log "Report not found on origin/$defaultBranch at: $gitReportPath" "ERROR"
            Write-Log "The report must be committed and pushed before launching the pipeline." "ERROR"
            Write-Log "Fix: git add $gitReportPath && git commit -m 'Add priority report' && git push" "ERROR"
            exit 1
        }

        # 0g. Check for open priorities (before destructive reset)
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

        Stop-StageTimer "0"
        Save-PipelineState "0"
    } else {
        Write-Log "STAGE 0: Preflight (skipped - resuming)" "STAGE"
    }

    # ========================================
    # STAGE 1: Git setup - destructive reset
    # ========================================
    if (-not (Test-StageComplete "1")) {
        Write-Log "STAGE 1: Git setup (destructive reset)" "STAGE"
        Start-StageTimer

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

        Stop-StageTimer "1"
        Save-PipelineState "1"
    } else {
        Write-Log "STAGE 1: Git setup (skipped - resuming)" "STAGE"
    }

    # ========================================
    # STAGE 2: Load priority report (deterministic)
    # ========================================
    if (-not (Test-StageComplete "2")) {
        Write-Log "STAGE 2: Load priority report" "STAGE"
        Start-StageTimer

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

        Stop-StageTimer "2"
        Save-PipelineState "2"
    } else {
        Write-Log "STAGE 2: Load priority report (skipped - resuming)" "STAGE"
    }

    # ========================================
    # STAGE 3: Create feature branch
    # ========================================
    if (-not (Test-StageComplete "3")) {
        Write-Log "STAGE 3: Create feature branch" "STAGE"
        Start-StageTimer

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

        Stop-StageTimer "3"
        Save-PipelineState "3"
    } else {
        Write-Log "STAGE 3: Create feature branch (skipped - resuming)" "STAGE"
    }

    # ========================================
    # STAGE 4: Create PRD
    # ========================================
    if (-not (Test-StageComplete "4")) {
        Write-Log "STAGE 4: Create PRD" "STAGE"
        Start-StageTimer

        $prdFilename = "prd-$($branchName -replace '/', '-').md"
        $prdPath = Join-Path $tasksFullDir $prdFilename

        # Read prior post-mortems to feed forward into PRD creation
        $priorLearnings = ""
        $priorPMFiles = Get-ChildItem -Path (Join-Path $ProjectPath "logs") -Filter "post-mortem-*.md" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 3
        foreach ($pmFile in $priorPMFiles) {
            $priorLearnings += "`n--- From: $($pmFile.Name) ---`n$(Get-Content $pmFile.FullName -Raw)`n"
        }

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
$(if ($priorLearnings) { @"

LESSONS FROM PRIOR BUILDS (incorporate relevant learnings):
$priorLearnings
"@ })
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

        Stop-StageTimer "4"
        Save-PipelineState "4"
    } else {
        Write-Log "STAGE 4: Create PRD (skipped - resuming)" "STAGE"
    }

    # ========================================
    # STAGE 4v: Validate PRD
    # ========================================
    if (-not (Test-StageComplete "4v")) {
        Write-Log "STAGE 4v: Validate PRD" "STAGE"
        Start-StageTimer

        $prdContent = Get-Content $prdPath -Raw

        $validationPrompt = @"
You are a PRD quality gate. Read the PRD below and validate it against these criteria:

1. Are acceptance criteria specific and machine-testable? (Not vague like "works well" or "is fast")
2. Are there missing requirements implied by the feature description that aren't captured in the PRD?
3. Is scope appropriately bounded? (Achievable in one overnight build session with ~25 task iterations)
4. Are there ambiguities that would cause an implementing agent to guess rather than know what to build?

PRD CONTENT:
$prdContent

Respond with EXACTLY one of these formats:
- If the PRD passes all checks, your FIRST line must be: PRD_VALID
- If there are issues, your FIRST line must be: PRD_ISSUES
  Then list each issue on its own numbered line.

Be strict but practical. Minor style issues are not grounds for rejection.
Focus on problems that would waste build time or produce wrong output.
"@

        Write-Log "Validating PRD..."
        $validationOutput = $validationPrompt | & claude --print --dangerously-skip-permissions 2>&1
        $validationText = $validationOutput -join "`n"

        if ($validationText -match "PRD_VALID") {
            Write-Log "PRD validation passed" "SUCCESS"
        } else {
            Write-Log "PRD validation found issues - regenerating with feedback" "WARN"
            Write-Log "Issues:`n$validationText"

            # Regenerate PRD with critic feedback
            $regenPrompt = @"
The PRD at $prdPath was reviewed and found to have issues. Regenerate it, fixing these problems:

CRITIC FEEDBACK:
$validationText

ORIGINAL CONTEXT:
Feature: $($analysis.priority_item)
Description: $($analysis.description)

Write the improved PRD to: $prdPath

The PRD should include:
1. Overview - What we're building and why
2. Requirements - Specific, testable requirements
3. Acceptance Criteria - How we know it's done (be specific and machine-testable!)
4. Out of Scope - What we're NOT building
5. Technical Notes - Any implementation guidance

Fix every issue the critic identified. Make acceptance criteria specific and testable.
"@

            Write-Log "Regenerating PRD with critic feedback..."
            $regenPrompt | & claude --print --dangerously-skip-permissions 2>&1 | Out-Null

            # Second validation
            $prdContent2 = Get-Content $prdPath -Raw
            $validationPrompt2 = @"
You are a PRD quality gate. Read the PRD below and validate it against these criteria:

1. Are acceptance criteria specific and machine-testable?
2. Are there missing requirements implied by the feature description?
3. Is scope appropriately bounded for one overnight build session?
4. Are there ambiguities that would cause an implementing agent to guess?

PRD CONTENT:
$prdContent2

Respond with EXACTLY one of these formats:
- If the PRD passes: PRD_VALID (first line)
- If there are issues: PRD_ISSUES (first line), then numbered issues

Be strict but practical.
"@

            $validation2Output = $validationPrompt2 | & claude --print --dangerously-skip-permissions 2>&1
            $validation2Text = $validation2Output -join "`n"

            if ($validation2Text -match "PRD_VALID") {
                Write-Log "PRD validation passed on retry" "SUCCESS"
            } else {
                Write-Log "PRD validation failed on retry - proceeding anyway (mediocre PRD > no run)" "WARN"
                Write-Log "Remaining issues:`n$validation2Text"
            }
        }

        Stop-StageTimer "4v"
        Save-PipelineState "4v"
    } else {
        Write-Log "STAGE 4v: Validate PRD (skipped - resuming)" "STAGE"
    }

    # ========================================
    # STAGE 5: Convert PRD to tasks
    # ========================================
    if (-not (Test-StageComplete "5")) {
        Write-Log "STAGE 5: Convert PRD to tasks" "STAGE"
        Start-StageTimer

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
      "file": "path/to/primary_file.py",
      "acceptanceCriteria": [
        "Specific, testable criterion 1",
        "Specific, testable criterion 2"
      ],
      "status": "pending"
    }
  ]
}

GUIDELINES:
- Break into 8-14 small, atomic tasks (prefer more smaller tasks over fewer large ones)
- Each task must specify EXACTLY one primary target file in the "file" field
- Each task should touch at most 2 files total (one source file + one test file)
- NEVER combine "create new module" with "wire into existing API/imports" in the same task
- Integration tasks (updating api.py routes, adding imports, RBAC allowlist) are ALWAYS a separate task
- Content-heavy tasks (templates, large test suites, config files) get their own task
- No task should produce more than ~200 lines of code or more than 12 test cases; split if larger
- If a task description exceeds 10 lines, it is too big -- split it
- acceptanceCriteria must be an array of strings, each verifiable without human input
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

        # Validate: force all task statuses to "pending" (LLM sometimes generates wrong status or omits it)
        foreach ($task in $tasksData.tasks) {
            $task | Add-Member -NotePropertyName "status" -NotePropertyValue "pending" -Force
        }
        $tasksData | ConvertTo-Json -Depth 10 | Set-Content $tasksPath -Encoding UTF8
        Write-Log "Validated: all $taskCount task statuses set to 'pending'" "INFO"

        Stop-StageTimer "5"
        Save-PipelineState "5"
    } else {
        Write-Log "STAGE 5: Convert PRD to tasks (skipped - resuming)" "STAGE"
    }

    # ========================================
    # STAGE 6: Run execution loop
    # ========================================
    if (-not (Test-StageComplete "6")) {
        Write-Log "STAGE 6: Execute tasks" "STAGE"
        Start-StageTimer

        $maxReplans = 2
        $replanCount = 0
        $cumulativeTokens = 0
        $cumulativeCost = 0.0

        do {
            if ($replanCount -gt 0) {
                Write-Log "REPLAN $replanCount of ${maxReplans}: Regenerating tasks from current codebase state..." "STAGE"

                # Re-run Stage 5 inline: regenerate tasks based on current codebase
                $prdContent = Get-Content $prdPath -Raw
                $tasksFilename = "tasks-$($branchName -replace '/', '-').json"
                $tasksPath = Join-Path $tasksFullDir $tasksFilename

                $tasksPrompt = @"
TASK: Convert this PRD into a structured task list JSON file.

IMPORTANT: You MUST write the output to this exact file path:
$tasksPath

The codebase has been PARTIALLY IMPLEMENTED. Read the current state of the code before generating tasks.
Only generate tasks for work that STILL NEEDS TO BE DONE based on the current codebase state.

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
      "file": "path/to/primary_file.py",
      "acceptanceCriteria": [
        "Specific, testable criterion 1",
        "Specific, testable criterion 2"
      ],
      "status": "pending"
    }
  ]
}

GUIDELINES:
- Break into 8-14 small, atomic tasks
- Each task must specify EXACTLY one primary target file
- Each task should touch at most 2 files total
- acceptanceCriteria must be an array of strings
- Order tasks logically (dependencies first)
- ONLY include tasks for work not yet completed in the codebase

Write the JSON file now.
"@

                Write-Log "Regenerating tasks..."
                $replanLogFile = Join-Path $logsDir "replan-$replanCount.log"
                $tasksPrompt | & claude --dangerously-skip-permissions 2>&1 | Tee-Object -FilePath $replanLogFile

                if (Test-Path $tasksPath) {
                    $tasksData = Get-Content $tasksPath -Raw | ConvertFrom-Json
                    foreach ($t in $tasksData.tasks) {
                        $t | Add-Member -NotePropertyName "status" -NotePropertyValue "pending" -Force
                    }
                    $tasksData | ConvertTo-Json -Depth 10 | Set-Content $tasksPath -Encoding UTF8
                    Write-Log "Replan generated $($tasksData.tasks.Count) new tasks"
                } else {
                    Write-Log "Replan failed: tasks file not created. Proceeding with remaining tasks." "WARN"
                    break
                }
            }

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

            # Accumulate token/cost across replan iterations
            if ($loopResult.PSObject.Properties.Name -contains 'total_tokens') { $cumulativeTokens += $loopResult.total_tokens }
            if ($loopResult.PSObject.Properties.Name -contains 'total_cost_usd') { $cumulativeCost += $loopResult.total_cost_usd }

            # Check if replan was requested
            $needsReplan = $false
            if ($loopResult.PSObject.Properties.Name -contains 'replan_needed' -and $loopResult.replan_needed -eq $true) {
                $replanCount++
                if ($replanCount -le $maxReplans) {
                    Write-Log "Replan requested by execution loop (replan $replanCount of $maxReplans)" "WARN"
                    $needsReplan = $true
                } else {
                    Write-Log "Replan requested but max replans ($maxReplans) exceeded. Proceeding with current results." "WARN"
                }
            }

        } while ($needsReplan)

        Stop-StageTimer "6"
        Save-PipelineState "6"
    } else {
        Write-Log "STAGE 6: Execute tasks (skipped - resuming)" "STAGE"
    }

    # Gate: skip Stages 7-9 if no tasks completed (nothing to push/PR/mark)
    if ([int]$loopResult.completed -eq 0) {
        Write-Log "No tasks completed. Skipping Stages 7-9. State preserved for resume." "ERROR"
        Save-PipelineState "6"
        exit 1
    }

    # ========================================
    # STAGE 7: Create PR
    # ========================================
    if (-not (Test-StageComplete "7")) {
        Write-Log "STAGE 7: Create PR" "STAGE"
        Start-StageTimer

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

        Stop-StageTimer "7"
        Save-PipelineState "7"
    } else {
        Write-Log "STAGE 7: Create PR (skipped - resuming)" "STAGE"
    }

    # ========================================
    # STAGE 8: Mark priority complete in report
    # ========================================
    Write-Log "STAGE 8: Mark priority complete" "STAGE"
    Start-StageTimer

    # Gate: only mark complete if ALL tasks succeeded
    # If any tasks are not completed, preserve state and exit for manual remediation
    $totalTasks = [int]$loopResult.completed + [int]$loopResult.failed + [int]$loopResult.pending
    if ($totalTasks -gt 0 -and [int]$loopResult.completed -lt $totalTasks) {
        Write-Log "Priority incomplete ($([int]$loopResult.completed)/$totalTasks tasks completed). Needs remediation." "WARN"
        Write-Log "PR was created for partial work. Fix failed tasks, then mark complete manually." "WARN"
        Stop-StageTimer "8"
        Save-PipelineState "8"
        exit 1
    } else {

    # Ensure $hasRemote is set (may not be if Stage 7 was skipped via resume)
    if (-not $hasRemote) { $hasRemote = git remote 2>$null }

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
    Stop-StageTimer "8"
    } # end of success gate else block

    # ========================================
    # STAGE 9: Post-Mortem (Analyst Pattern)
    # ========================================
    if (-not (Test-StageComplete "9")) {
        Write-Log "STAGE 9: Post-Mortem (Analyst)" "STAGE"
        Start-StageTimer

        $postMortemDate = Get-Date -Format "yyyy-MM-dd"
        $postMortemPath = Join-Path $ProjectPath "logs\post-mortem-$postMortemDate.md"

        # Gather SUMMARIZED context for the Analyst (not full PRD/tasks -- those are too large)
        $taskSummaryLines = @()
        if ($tasksPath -and (Test-Path $tasksPath)) {
            $tasksJson = Get-Content $tasksPath -Raw | ConvertFrom-Json
            foreach ($t in $tasksJson.tasks) {
                $line = "  Task $($t.id): $($t.title) -- $($t.status)"
                if ($t.failure_reason) { $line += " ($($t.failure_reason -replace 'Check transcript:.*','timeout'))" }
                $taskSummaryLines += $line
            }
        }
        $taskSummary = $taskSummaryLines -join "`n"

        # Read only the Synthesis section from the most recent prior post-mortem (not full content)
        $priorSynthesis = ""
        $priorFiles = Get-ChildItem -Path (Join-Path $ProjectPath "logs") -Filter "post-mortem-*.md" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "post-mortem-$postMortemDate.md" } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        foreach ($pf in $priorFiles) {
            $pfContent = Get-Content $pf.FullName -Raw
            # Extract just the Synthesis section
            if ($pfContent -match '(?s)## 5\. Synthesis.*?$') {
                $priorSynthesis = "Prior build ($($pf.BaseName)) synthesis:`n$($Matches[0])"
            } else {
                # Fallback: take last 500 chars
                $priorSynthesis = "Prior build ($($pf.BaseName)): $(($pfContent -replace '(?s).+## 5','## 5').Substring(0, [Math]::Min(500, $pfContent.Length)))"
            }
        }

        $postMortemPrompt = @"
You are the Analyst -- a reflective agent that runs AFTER execution to extract compounding learnings.

Write a five-point post-mortem for tonight's build. Output ONLY the markdown content -- no preamble, no commentary.

CONTEXT:
- Priority item: $($analysis.priority_item)
- Description: $($analysis.description)
- Branch: $branchName
- Tasks completed: $($loopResult.completed)
- Tasks failed: $($loopResult.failed)
- Tasks pending: $($loopResult.pending)
- Iterations used: $($loopResult.iterations_used) / $($loopResult.max_iterations)
- Total duration: $((Get-Date) - $pipelineStartTime | ForEach-Object { '{0:00}:{1:00}:{2:00}' -f $_.Hours, $_.Minutes, $_.Seconds })

TASK RESULTS:
$taskSummary

$priorSynthesis

OUTPUT FORMAT (keep each section to 2-4 sentences):

# Post-Mortem: $($analysis.priority_item)
Date: $postMortemDate

## 1. Intent vs. Implementation Gap
Did the build match the PRD? Where did implementation diverge from requirements?

## 2. What Caused What (Ablation)
Which specific tasks or decisions caused which outcomes? What would we remove/change?

## 3. Expectation vs. Reality
What did we expect to happen vs. what actually happened? Task completion rate, failures, surprises.

## 4. Mechanistic Explanation
Why did things work or fail? Root causes, not symptoms.

## 5. Synthesis & Next Steps
What to preserve, what to discard, what to try differently tomorrow night. If prior post-mortems show recurring patterns, call them out.
"@

        Write-Log "Running post-mortem analysis..."
        # Use claude --print (no permissions needed -- pure text generation, we write the file ourselves)
        # Timeout after 120 seconds to prevent Stage 9 from hanging the pipeline
        $postMortemJob = Start-Job -ScriptBlock {
            param($prompt)
            $prompt | & claude --print 2>&1
        } -ArgumentList $postMortemPrompt

        $postMortemOutput = $postMortemJob | Wait-Job -Timeout 120 | Receive-Job 2>&1
        Remove-Job $postMortemJob -Force -ErrorAction SilentlyContinue

        if ($postMortemOutput) {
            $postMortemOutput | Set-Content -Path $postMortemPath -Encoding UTF8
            Write-Log "Post-mortem saved: $postMortemPath" "SUCCESS"
        } else {
            Write-Log "Post-mortem generation timed out or returned empty (non-critical)" "WARN"
        }

        Stop-StageTimer "9"
        Save-PipelineState "9"
    } else {
        Write-Log "STAGE 9: Post-Mortem (skipped - resuming)" "STAGE"
    }

    # --- Duration summary ---
    $totalDuration = (Get-Date) - $pipelineStartTime
    $durationStr = '{0:00}:{1:00}:{2:00}' -f [int]$totalDuration.TotalHours, $totalDuration.Minutes, $totalDuration.Seconds
    Write-Log "Total duration: $durationStr" "SUCCESS"
    foreach ($stage in $stageOrder) {
        if ($stageTimings.ContainsKey($stage)) {
            $mins = [math]::Round($stageTimings[$stage] / 60, 1)
            Write-Log "  Stage ${stage}: ${mins}m"
        }
    }

    # --- Persist build-history.csv (survives state file deletion) ---
    $historyFile = Join-Path $ProjectPath "logs\build-history.csv"
    if (-not (Test-Path $historyFile)) {
        "date,priority,duration_seconds,completed,failed,pending,iterations,branch,tokens,cost_usd" | Set-Content $historyFile -Encoding UTF8
    }
    $historyDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $buildTokens = $cumulativeTokens
    $buildCost = $cumulativeCost
    $historyLine = "$historyDate,$($analysis.priority_item),$([math]::Round($totalDuration.TotalSeconds, 0)),$($loopResult.completed),$($loopResult.failed),$($loopResult.pending),$($loopResult.iterations_used),$branchName,$buildTokens,$buildCost"
    Add-Content -Path $historyFile -Value $historyLine
    Write-Log "Build history appended to $historyFile"

    # Clean up state file on successful completion
    if (Test-Path $StateFile) {
        Remove-Item $StateFile -ErrorAction SilentlyContinue
        Write-Log "Pipeline state file cleaned up (successful completion)"
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
        duration_seconds = [math]::Round($totalDuration.TotalSeconds, 0)
        stage_timings = $stageTimings
        total_tokens = $buildTokens
        total_cost_usd = $buildCost
    }

    $summary | ConvertTo-Json

} catch {
    Write-Log "Error: $_" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    # State file persists on error, enabling resume
    if (Test-Path $StateFile) {
        Write-Log "State file preserved at $StateFile for resume" "WARN"
    }
    exit 1
} finally {
    Pop-Location
}
