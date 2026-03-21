# list-sessions.ps1
# List recent Claude Code sessions for review
#
# Usage: .\list-sessions.ps1 [-Hours 24] [-Path ".claude-sessions"]

param(
    [int]$Hours = 24,
    [string]$Path = ".claude-sessions"
)

if (-not (Test-Path $Path)) {
    Write-Host "No sessions found at: $Path" -ForegroundColor Yellow
    exit 0
}

$cutoff = (Get-Date).AddHours(-$Hours)

$sessions = Get-ChildItem -Path $Path -Directory |
    Where-Object { $_.CreationTime -gt $cutoff } |
    Sort-Object CreationTime -Descending

if ($sessions.Count -eq 0) {
    Write-Host "No sessions in the last $Hours hours." -ForegroundColor Yellow
    exit 0
}

Write-Host "`nSessions from last $Hours hours:`n" -ForegroundColor Cyan

foreach ($session in $sessions) {
    $metaPath = Join-Path $session.FullName "meta.json"

    if (Test-Path $metaPath) {
        $meta = Get-Content $metaPath -Raw | ConvertFrom-Json

        $duration = ""
        if ($meta.timestamp_start -and $meta.timestamp_end) {
            $start = [DateTime]::Parse($meta.timestamp_start)
            $end = [DateTime]::Parse($meta.timestamp_end)
            $duration = [math]::Round(($end - $start).TotalMinutes, 1)
            $duration = " (${duration}m)"
        }

        $commitInfo = ""
        if ($meta.head_start -ne $meta.head_end) {
            $commitInfo = " [commits: $($meta.head_start)..$($meta.head_end)]"
        }

        Write-Host "  $($session.Name)$duration$commitInfo" -ForegroundColor White
        Write-Host "    Repo: $($meta.repo) | Branch: $($meta.branch)" -ForegroundColor DarkGray
        if ($meta.claude_args) {
            Write-Host "    Args: $($meta.claude_args)" -ForegroundColor DarkGray
        }
        Write-Host ""
    } else {
        Write-Host "  $($session.Name)" -ForegroundColor White
        Write-Host "    (no metadata)" -ForegroundColor DarkGray
        Write-Host ""
    }
}

Write-Host "Total: $($sessions.Count) session(s)`n" -ForegroundColor Cyan
