# compound-review.ps1
# Nightly compound review: extract learnings from sessions and update CLAUDE.md
#
# Usage: .\compound-review.ps1 [-Hours 24] [-SessionsPath ".claude-sessions"] [-DryRun]
#
# This is Job 1 of the "Ship While You Sleep" loop.
# Run at 10:30 PM, before auto-compound.

param(
    [int]$Hours = 24,
    [string]$SessionsPath = ".claude-sessions",
    [string]$ProjectPath = ".",
    [switch]$DryRun,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

# Resolve paths
$ProjectPath = Resolve-Path $ProjectPath
$ScriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$GatherScript = Join-Path $ScriptsDir "gather-sessions.ps1"
$TempSummary = Join-Path $env:TEMP "claude_sessions_summary_$(Get-Date -Format 'yyyyMMdd_HHmmss').md"
$LogFile = Join-Path $ProjectPath "logs\compound-review.log"

# Ensure logs directory exists
$logsDir = Join-Path $ProjectPath "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logLine
    if ($Verbose -or $Level -eq "ERROR") {
        $color = switch ($Level) {
            "ERROR" { "Red" }
            "WARN"  { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
        Write-Host $logLine -ForegroundColor $color
    }
}

# --- Main Execution ---

Write-Log "=== Compound Review Started ==="
Write-Log "Project: $ProjectPath"
Write-Log "Sessions: $SessionsPath"
Write-Log "Hours: $Hours"

# Step 1: Ensure we're on main and up to date
Write-Log "Checking git status..."
Push-Location $ProjectPath

try {
    $branch = git rev-parse --abbrev-ref HEAD 2>$null
    if ($branch -ne "main" -and $branch -ne "master") {
        Write-Log "Current branch is '$branch', switching to main..." "WARN"
        git checkout main 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            git checkout master 2>&1 | Out-Null
        }
    }

    # Only pull if remote exists
    $hasRemote = git remote 2>$null
    if ($hasRemote) {
        Write-Log "Pulling latest..."
        git pull origin (git rev-parse --abbrev-ref HEAD) 2>&1 | Out-Null
    } else {
        Write-Log "No remote configured, skipping pull" "WARN"
    }

    # Step 2: Gather sessions
    Write-Log "Gathering sessions from last $Hours hours..."

    $fullSessionsPath = Join-Path $ProjectPath $SessionsPath
    if (-not (Test-Path $fullSessionsPath)) {
        Write-Log "No sessions directory found at: $fullSessionsPath" "WARN"
        Write-Log "Nothing to review. Exiting."
        exit 0
    }

    & $GatherScript -Hours $Hours -Path $fullSessionsPath -OutputFile $TempSummary

    if (-not (Test-Path $TempSummary)) {
        Write-Log "No sessions summary generated. Exiting."
        exit 0
    }

    $summaryContent = Get-Content $TempSummary -Raw
    $sessionCount = ([regex]::Matches($summaryContent, "## Session:")).Count

    if ($sessionCount -eq 0) {
        Write-Log "No sessions found in the last $Hours hours. Exiting."
        exit 0
    }

    Write-Log "Found $sessionCount session(s) to review."

    # Step 3: Build the compound review prompt
    $claudeMdPath = Join-Path $ProjectPath "CLAUDE.md"
    $existingClaudeMd = ""
    if (Test-Path $claudeMdPath) {
        $existingClaudeMd = Get-Content $claudeMdPath -Raw
    }

    $prompt = @"
You are performing a COMPOUND REVIEW of Claude Code sessions from the last $Hours hours.

## Your Task

1. Read through each session transcript and git diff below
2. Extract KEY LEARNINGS: patterns that worked, gotchas discovered, context future sessions need
3. Update the project's CLAUDE.md file with these learnings

## Guidelines for Extraction

- **Patterns**: Reusable approaches that worked well (e.g., "When modifying X, always update Y")
- **Gotchas**: Edge cases, bugs hit, things that didn't work (e.g., "The API returns 500 if Z is empty")
- **Context**: Project-specific knowledge that helps future sessions (e.g., "Auth is handled in /lib/auth, not /api")
- **Commands**: Useful commands or workflows discovered

## Guidelines for CLAUDE.md Updates

- Add learnings to appropriate sections (create sections if needed)
- Be concise - bullet points, not paragraphs
- Include date discovered for time-sensitive learnings
- Don't duplicate existing content
- If a learning contradicts existing content, update the existing content

## Current CLAUDE.md Content

$existingClaudeMd

---

## Sessions to Review

$summaryContent

---

## Instructions

1. Analyze each session for learnings
2. Read the current CLAUDE.md (if any)
3. Update CLAUDE.md with new learnings (use the Edit tool or Write tool)
4. Commit your changes with message: "compound: extract learnings from $(Get-Date -Format 'yyyy-MM-dd') sessions"
5. Push to the current branch

If there are no meaningful learnings to extract, say so and exit without changes.
"@

    # Step 4: Run Claude Code
    Write-Log "Running Claude Code for compound review..."

    if ($DryRun) {
        Write-Log "DRY RUN - Would execute Claude with prompt:" "WARN"
        Write-Host "`n$prompt`n" -ForegroundColor DarkGray
        Write-Log "DRY RUN complete. No changes made."
        exit 0
    }

    # Write prompt to temp file (handles escaping better than inline)
    $promptFile = Join-Path $env:TEMP "compound_review_prompt_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $prompt | Out-File $promptFile -Encoding UTF8

    # Execute Claude Code (pipe prompt via stdin, --print is a flag not an arg)
    $claudeOutput = Get-Content $promptFile -Raw | & claude --print --dangerously-skip-permissions 2>&1
    $claudeExitCode = $LASTEXITCODE

    # Log output
    $claudeOutput | ForEach-Object { Write-Log $_ }

    if ($claudeExitCode -ne 0) {
        Write-Log "Claude Code exited with code $claudeExitCode" "ERROR"
        exit $claudeExitCode
    }

    Write-Log "Compound review complete." "SUCCESS"

    # Cleanup temp files
    Remove-Item $TempSummary -ErrorAction SilentlyContinue
    Remove-Item $promptFile -ErrorAction SilentlyContinue

} catch {
    Write-Log "Error: $_" "ERROR"
    exit 1
} finally {
    Pop-Location
}

Write-Log "=== Compound Review Finished ==="
