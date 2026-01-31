# Overnight Build Script - Ship While You Sleep
# Runs keep-awake in background + executes the auto-compound pipeline
#
# Usage: .\overnight.ps1 -ProjectPath "C:\your-project"

param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectPath,

    [int]$MaxIterations = 25,

    [string[]]$QualityChecks = @(),

    # Maximum retry attempts if build crashes
    [int]$MaxRetries = 3,

    # Initial delay between retries in seconds (doubles each retry)
    [int]$RetryDelaySeconds = 30
)

$host.UI.RawUI.WindowTitle = "Overnight Build - Ship While You Sleep"

Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "   SHIP WHILE YOU SLEEP - Overnight Build" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "Project: $ProjectPath" -ForegroundColor Cyan
Write-Host "Max iterations: $MaxIterations" -ForegroundColor Cyan
Write-Host ""

# Verify project path exists
if (-not (Test-Path $ProjectPath)) {
    Write-Host "ERROR: Project path does not exist: $ProjectPath" -ForegroundColor Red
    exit 1
}

# Check for priority report
$reportsDir = Join-Path $ProjectPath "reports"
if (-not (Test-Path $reportsDir)) {
    Write-Host "ERROR: No reports directory found at: $reportsDir" -ForegroundColor Red
    Write-Host "Create a priority.md file there first." -ForegroundColor Yellow
    exit 1
}

$reportFiles = Get-ChildItem -Path $reportsDir -Filter "*.md" -ErrorAction SilentlyContinue
if ($reportFiles.Count -eq 0) {
    Write-Host "ERROR: No .md files found in reports directory" -ForegroundColor Red
    Write-Host "Create a priority.md file with your priorities." -ForegroundColor Yellow
    exit 1
}

Write-Host "Found priority report: $($reportFiles[0].Name)" -ForegroundColor Green
Write-Host ""

# Start keep-awake in background
Write-Host "Starting keep-awake in background..." -ForegroundColor Yellow
$keepAwakeScript = Join-Path $PSScriptRoot "keep-awake.ps1"
$keepAwakeJob = Start-Job -ScriptBlock {
    param($script)
    Add-Type -AssemblyName System.Windows.Forms
    while ($true) {
        [System.Windows.Forms.SendKeys]::SendWait("{F15}")
        Start-Sleep -Seconds 60
    }
} -ArgumentList $keepAwakeScript

Write-Host "Keep-awake running (Job ID: $($keepAwakeJob.Id))" -ForegroundColor Green
Write-Host ""

# Display start message
$startTime = Get-Date
Write-Host "============================================" -ForegroundColor Green
Write-Host "  BUILD STARTING at $($startTime.ToString('HH:mm:ss'))" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Go to sleep! Check back in the morning." -ForegroundColor Cyan
Write-Host ""
Write-Host "Logs will be written to:" -ForegroundColor DarkGray
Write-Host "  $ProjectPath\logs\auto-compound.log" -ForegroundColor DarkGray
Write-Host ""

# Run auto-compound with retry logic
$autoCompoundScript = Join-Path $PSScriptRoot "auto-compound.ps1"
$autoCompoundArgs = @{
    ProjectPath = $ProjectPath
    MaxIterations = $MaxIterations
}
if ($QualityChecks.Count -gt 0) {
    $autoCompoundArgs['QualityChecks'] = $QualityChecks
}

$exitCode = 1
$attempt = 0
$currentDelay = $RetryDelaySeconds

while ($attempt -lt $MaxRetries -and $exitCode -ne 0) {
    $attempt++

    if ($attempt -gt 1) {
        Write-Host ""
        Write-Host "============================================" -ForegroundColor Yellow
        Write-Host "  RETRY ATTEMPT $attempt of $MaxRetries" -ForegroundColor Yellow
        Write-Host "  Previous attempt failed. Retrying in $currentDelay seconds..." -ForegroundColor Yellow
        Write-Host "============================================" -ForegroundColor Yellow
        Write-Host ""

        # Log retry to file
        $retryLog = Join-Path $ProjectPath "logs\retry.log"
        $retryEntry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Retry attempt $attempt after failure"
        Add-Content -Path $retryLog -Value $retryEntry -ErrorAction SilentlyContinue

        Start-Sleep -Seconds $currentDelay
        # Exponential backoff (double delay each time, max 5 minutes)
        $currentDelay = [Math]::Min($currentDelay * 2, 300)
    }

    Write-Host "Starting build attempt $attempt..." -ForegroundColor Cyan

    try {
        & $autoCompoundScript @autoCompoundArgs
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Host "Build attempt $attempt succeeded!" -ForegroundColor Green
        } else {
            Write-Host "Build attempt $attempt failed with exit code: $exitCode" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "ERROR in attempt $attempt : $($_.Exception.Message)" -ForegroundColor Red
        $exitCode = 1

        # Log the error
        $errorLog = Join-Path $ProjectPath "logs\error.log"
        $errorEntry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Attempt $attempt error: $($_.Exception.Message)"
        Add-Content -Path $errorLog -Value $errorEntry -ErrorAction SilentlyContinue
    }
}

if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "  BUILD FAILED after $MaxRetries attempts" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Check logs at: $ProjectPath\logs\" -ForegroundColor Yellow
}

# Stop keep-awake job
Stop-Job -Job $keepAwakeJob -ErrorAction SilentlyContinue
Remove-Job -Job $keepAwakeJob -ErrorAction SilentlyContinue

# Summary
$endTime = Get-Date
$duration = $endTime - $startTime
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  BUILD COMPLETE at $($endTime.ToString('HH:mm:ss'))" -ForegroundColor Green
Write-Host "  Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

exit $exitCode
