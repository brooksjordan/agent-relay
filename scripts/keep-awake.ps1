# Keep-Awake Script for Ship While You Sleep
# Prevents the computer from sleeping by simulating activity
#
# Usage: .\keep-awake.ps1
# Press Ctrl+C to stop

param(
    [int]$IntervalSeconds = 60,
    [switch]$Quiet
)

$host.UI.RawUI.WindowTitle = "Keep Awake - Ship While You Sleep"

if (-not $Quiet) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  KEEP AWAKE - Ship While You Sleep" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This script prevents your computer from sleeping."
    Write-Host "Leave this window open overnight."
    Write-Host ""
    Write-Host "Press Ctrl+C to stop." -ForegroundColor Yellow
    Write-Host ""
}

# Load the required assembly for sending keys
Add-Type -AssemblyName System.Windows.Forms

$startTime = Get-Date
$tickCount = 0

while ($true) {
    $tickCount++
    $elapsed = (Get-Date) - $startTime
    $elapsedStr = "{0:hh\:mm\:ss}" -f $elapsed

    # Send F15 key (does nothing visible but prevents sleep)
    [System.Windows.Forms.SendKeys]::SendWait("{F15}")

    if (-not $Quiet) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-Host "[$timestamp] Awake - Running for $elapsedStr (tick #$tickCount)" -ForegroundColor DarkGray
    }

    Start-Sleep -Seconds $IntervalSeconds
}
