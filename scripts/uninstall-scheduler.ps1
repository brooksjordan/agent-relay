# uninstall-scheduler.ps1
# Removes Agent Relay scheduled tasks
#
# Usage: .\uninstall-scheduler.ps1 [-TaskPrefix "AgentRelay"]

param(
    [string]$TaskPrefix = "AgentRelay"
)

Write-Host "Removing Agent Relay scheduled tasks..." -ForegroundColor Yellow
Write-Host ""

$tasks = Get-ScheduledTask -TaskName "$TaskPrefix*" -ErrorAction SilentlyContinue

if (-not $tasks) {
    Write-Host "No tasks found with prefix: $TaskPrefix" -ForegroundColor DarkGray
    exit 0
}

foreach ($task in $tasks) {
    Write-Host "Removing: $($task.TaskName)" -ForegroundColor Red
    Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
}

Write-Host ""
Write-Host "Done. All $TaskPrefix tasks removed." -ForegroundColor Green
