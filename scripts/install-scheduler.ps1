# install-scheduler.ps1
# Sets up Windows Task Scheduler jobs for Agent Relay
#
# Usage: .\install-scheduler.ps1 -ProjectPath "C:\projects\myapp"
#
# Creates three scheduled tasks:
#   1. Compound Review (10:30 PM) - Extract learnings
#   2. Auto-Compound (11:00 PM) - Implement #1 priority
#   3. Keep Awake (10:00 PM - 2:00 AM) - Prevent sleep during automation
#
# Run as Administrator for best results (required for power settings)

param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectPath,

    [string]$TaskPrefix = "AgentRelay",

    [int]$CompoundReviewHour = 22,
    [int]$CompoundReviewMinute = 30,

    [int]$AutoCompoundHour = 23,
    [int]$AutoCompoundMinute = 0,

    [int]$KeepAwakeStartHour = 22,
    [int]$KeepAwakeEndHour = 2,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Resolve paths
$ProjectPath = Resolve-Path $ProjectPath
$ScriptsDir = $PSScriptRoot

# Validate
if (-not (Test-Path $ProjectPath)) {
    Write-Error "Project path does not exist: $ProjectPath"
    exit 1
}

if (-not (Test-Path $ScriptsDir)) {
    Write-Error "Agent Relay scripts not found at: $ScriptsDir"
    exit 1
}

Write-Host "Agent Relay - Scheduler Setup" -ForegroundColor Cyan
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Project: $ProjectPath"
Write-Host "Task prefix: $TaskPrefix"
Write-Host ""

# Check for existing tasks
$existingTasks = Get-ScheduledTask -TaskName "$TaskPrefix*" -ErrorAction SilentlyContinue

if ($existingTasks -and -not $Force) {
    Write-Host "Existing tasks found:" -ForegroundColor Yellow
    $existingTasks | ForEach-Object { Write-Host "  - $($_.TaskName)" }
    Write-Host ""
    Write-Host "Use -Force to overwrite, or run uninstall-scheduler.ps1 first."
    exit 1
}

if ($existingTasks -and $Force) {
    Write-Host "Removing existing tasks..." -ForegroundColor Yellow
    $existingTasks | Unregister-ScheduledTask -Confirm:$false
}

# ========================================
# Task 1: Compound Review (10:30 PM)
# ========================================

Write-Host "Creating: $TaskPrefix-CompoundReview" -ForegroundColor Green

$compoundReviewScript = @"
Set-Location '$ProjectPath'
& '$ScriptsDir\compound-review.ps1' -ProjectPath '$ProjectPath' -Verbose *>> '$ProjectPath\logs\compound-review-scheduled.log'
"@

$compoundReviewAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$compoundReviewScript`"" `
    -WorkingDirectory $ProjectPath

$compoundReviewTrigger = New-ScheduledTaskTrigger `
    -Daily `
    -At "$($CompoundReviewHour):$($CompoundReviewMinute.ToString('00'))"

$compoundReviewSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -WakeToRun `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$compoundReviewPrincipal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName "$TaskPrefix-CompoundReview" `
    -Action $compoundReviewAction `
    -Trigger $compoundReviewTrigger `
    -Settings $compoundReviewSettings `
    -Principal $compoundReviewPrincipal `
    -Description "Agent Relay: Extract learnings from today's Claude Code sessions" `
    | Out-Null

Write-Host "  Scheduled for $($CompoundReviewHour):$($CompoundReviewMinute.ToString('00')) daily" -ForegroundColor DarkGray

# ========================================
# Task 2: Auto-Compound (11:00 PM)
# ========================================

Write-Host "Creating: $TaskPrefix-AutoCompound" -ForegroundColor Green

$autoCompoundScript = @"
Set-Location '$ProjectPath'
& '$ScriptsDir\auto-compound.ps1' -ProjectPath '$ProjectPath' -Verbose *>> '$ProjectPath\logs\auto-compound-scheduled.log'
"@

$autoCompoundAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$autoCompoundScript`"" `
    -WorkingDirectory $ProjectPath

$autoCompoundTrigger = New-ScheduledTaskTrigger `
    -Daily `
    -At "$($AutoCompoundHour):$($AutoCompoundMinute.ToString('00'))"

$autoCompoundSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -WakeToRun `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)

$autoCompoundPrincipal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName "$TaskPrefix-AutoCompound" `
    -Action $autoCompoundAction `
    -Trigger $autoCompoundTrigger `
    -Settings $autoCompoundSettings `
    -Principal $autoCompoundPrincipal `
    -Description "Agent Relay: Implement #1 priority and create PR" `
    | Out-Null

Write-Host "  Scheduled for $($AutoCompoundHour):$($AutoCompoundMinute.ToString('00')) daily" -ForegroundColor DarkGray

# ========================================
# Task 3: Keep Awake (prevent sleep)
# ========================================

Write-Host "Creating: $TaskPrefix-KeepAwake" -ForegroundColor Green

# PowerShell script that prevents sleep for 4 hours
$keepAwakeScript = @"

# Prevent sleep for 4 hours (covers automation window)
`$duration = 4 * 60 * 60  # 4 hours in seconds

# Use SetThreadExecutionState to prevent sleep
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class PowerState {
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);

    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;
}
'@

# Prevent sleep (keep system awake, allow display to sleep)
[PowerState]::SetThreadExecutionState([PowerState]::ES_CONTINUOUS -bor [PowerState]::ES_SYSTEM_REQUIRED) | Out-Null

Write-Host "Preventing sleep for 4 hours (until $((Get-Date).AddHours(4).ToString('HH:mm')))"

# Wait for duration
Start-Sleep -Seconds `$duration

# Restore normal power state
[PowerState]::SetThreadExecutionState([PowerState]::ES_CONTINUOUS) | Out-Null

Write-Host "Sleep prevention ended"
"@

$keepAwakeAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$keepAwakeScript`""

$keepAwakeTrigger = New-ScheduledTaskTrigger `
    -Daily `
    -At "$($KeepAwakeStartHour):00"

$keepAwakeSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -WakeToRun `
    -ExecutionTimeLimit (New-TimeSpan -Hours 5)

$keepAwakePrincipal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName "$TaskPrefix-KeepAwake" `
    -Action $keepAwakeAction `
    -Trigger $keepAwakeTrigger `
    -Settings $keepAwakeSettings `
    -Principal $keepAwakePrincipal `
    -Description "Agent Relay: Keep system awake during automation window" `
    | Out-Null

Write-Host "  Scheduled for $($KeepAwakeStartHour):00 daily (runs for 4 hours)" -ForegroundColor DarkGray

# ========================================
# Summary
# ========================================

Write-Host ""
Write-Host "Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Scheduled tasks created:" -ForegroundColor Cyan
Write-Host "  1. $TaskPrefix-KeepAwake      - $($KeepAwakeStartHour):00 (prevents sleep)"
Write-Host "  2. $TaskPrefix-CompoundReview - $($CompoundReviewHour):$($CompoundReviewMinute.ToString('00')) (extract learnings)"
Write-Host "  3. $TaskPrefix-AutoCompound   - $($AutoCompoundHour):$($AutoCompoundMinute.ToString('00')) (implement + PR)"
Write-Host ""
Write-Host "Logs will be written to:" -ForegroundColor Cyan
Write-Host "  $ProjectPath\logs\compound-review-scheduled.log"
Write-Host "  $ProjectPath\logs\auto-compound-scheduled.log"
Write-Host ""
Write-Host "To verify:" -ForegroundColor Yellow
Write-Host "  Get-ScheduledTask -TaskName '$TaskPrefix*' | Format-Table TaskName, State"
Write-Host ""
Write-Host "To test manually:" -ForegroundColor Yellow
Write-Host "  Start-ScheduledTask -TaskName '$TaskPrefix-CompoundReview'"
Write-Host ""
Write-Host "To uninstall:" -ForegroundColor Yellow
Write-Host "  .\uninstall-scheduler.ps1 -TaskPrefix '$TaskPrefix'"
