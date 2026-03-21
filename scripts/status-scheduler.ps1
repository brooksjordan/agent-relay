# status-scheduler.ps1
# Shows status of Agent Relay scheduled tasks
#
# Usage: .\status-scheduler.ps1 [-TaskPrefix "AgentRelay"]

param(
    [string]$TaskPrefix = "AgentRelay"
)

Write-Host "Agent Relay - Scheduler Status" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$tasks = Get-ScheduledTask -TaskName "$TaskPrefix*" -ErrorAction SilentlyContinue

if (-not $tasks) {
    Write-Host "No scheduled tasks found with prefix: $TaskPrefix" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Run install-scheduler.ps1 to set up scheduled tasks."
    exit 0
}

foreach ($task in $tasks) {
    $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -ErrorAction SilentlyContinue

    $stateColor = switch ($task.State) {
        "Ready" { "Green" }
        "Running" { "Cyan" }
        "Disabled" { "Yellow" }
        default { "White" }
    }

    Write-Host "Task: $($task.TaskName)" -ForegroundColor $stateColor
    Write-Host "  State: $($task.State)"

    if ($info.LastRunTime -and $info.LastRunTime -ne [DateTime]::MinValue) {
        Write-Host "  Last run: $($info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss'))"

        $resultText = switch ($info.LastTaskResult) {
            0 { "Success" }
            1 { "Incorrect function" }
            2 { "File not found" }
            267009 { "Task is running" }
            267011 { "Task has not run" }
            default { "Exit code: $($info.LastTaskResult)" }
        }

        $resultColor = if ($info.LastTaskResult -eq 0) { "Green" } else { "Yellow" }
        Write-Host "  Last result: $resultText" -ForegroundColor $resultColor
    } else {
        Write-Host "  Last run: Never" -ForegroundColor DarkGray
    }

    if ($info.NextRunTime -and $info.NextRunTime -ne [DateTime]::MinValue) {
        Write-Host "  Next run: $($info.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    }

    Write-Host ""
}

# Show recent log entries if available
Write-Host "Recent Activity:" -ForegroundColor Cyan
Write-Host "----------------"

$logPaths = @(
    "logs\compound-review-scheduled.log",
    "logs\auto-compound-scheduled.log"
)

$foundLogs = $false
foreach ($logPath in $logPaths) {
    # Check common project locations
    $possiblePaths = @(
        (Join-Path (Get-Location) $logPath),
        (Join-Path $env:USERPROFILE "projects\*\$logPath")
    )

    foreach ($path in $possiblePaths) {
        $files = Get-Item $path -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            if (Test-Path $file) {
                $foundLogs = $true
                Write-Host ""
                Write-Host "  $($file.FullName):" -ForegroundColor DarkGray
                Get-Content $file -Tail 5 | ForEach-Object {
                    Write-Host "    $_"
                }
            }
        }
    }
}

if (-not $foundLogs) {
    Write-Host "  No log files found yet." -ForegroundColor DarkGray
}

Write-Host ""
