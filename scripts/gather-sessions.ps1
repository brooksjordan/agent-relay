# gather-sessions.ps1
# Gather session data from the last N hours for compound review
# Outputs a consolidated summary that can be fed to an LLM
#
# Usage: .\gather-sessions.ps1 [-Hours 24] [-Path ".claude-sessions"] [-OutputFile "sessions_summary.md"]

param(
    [int]$Hours = 24,
    [string]$Path = ".claude-sessions",
    [string]$OutputFile = ""
)

if (-not (Test-Path $Path)) {
    Write-Host "No sessions found at: $Path" -ForegroundColor Yellow
    exit 0
}

$cutoff = (Get-Date).AddHours(-$Hours)

$sessions = Get-ChildItem -Path $Path -Directory |
    Where-Object { $_.CreationTime -gt $cutoff } |
    Sort-Object CreationTime

if ($sessions.Count -eq 0) {
    Write-Host "No sessions in the last $Hours hours." -ForegroundColor Yellow
    exit 0
}

# Build the summary
$summary = @()
$summary += "# Claude Code Sessions - Last $Hours Hours"
$summary += ""
$summary += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$summary += "Sessions found: $($sessions.Count)"
$summary += ""
$summary += "---"
$summary += ""

foreach ($session in $sessions) {
    $sessionPath = $session.FullName
    $metaPath = Join-Path $sessionPath "meta.json"
    $transcriptPath = Join-Path $sessionPath "transcript.txt"
    $diffAfterPath = Join-Path $sessionPath "git_diff_after.patch"
    $commitsPath = Join-Path $sessionPath "commits_during_session.txt"

    $summary += "## Session: $($session.Name)"
    $summary += ""

    # Metadata
    if (Test-Path $metaPath) {
        $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
        $summary += "- **Repo:** $($meta.repo)"
        $summary += "- **Branch:** $($meta.branch)"
        $summary += "- **Working Dir:** $($meta.working_directory)"
        $summary += "- **Start:** $($meta.timestamp_start)"
        $summary += "- **End:** $($meta.timestamp_end)"

        if ($meta.claude_args) {
            $summary += "- **Args:** ``$($meta.claude_args)``"
        }

        if ($meta.head_start -ne $meta.head_end) {
            $summary += "- **Commits:** $($meta.head_start) -> $($meta.head_end)"
        }
    }
    $summary += ""

    # Commits made during session
    if (Test-Path $commitsPath) {
        $commits = Get-Content $commitsPath -Raw
        if ($commits.Trim()) {
            $summary += "### Commits During Session"
            $summary += '```'
            $summary += $commits.Trim()
            $summary += '```'
            $summary += ""
        }
    }

    # Transcript (truncated to avoid huge files)
    if (Test-Path $transcriptPath) {
        $transcript = Get-Content $transcriptPath -Raw
        $maxLength = 10000

        $summary += "### Transcript (truncated)"
        $summary += '```'
        if ($transcript.Length -gt $maxLength) {
            $summary += $transcript.Substring(0, $maxLength)
            $summary += "`n... [TRUNCATED - $(($transcript.Length - $maxLength)) more characters]"
        } else {
            $summary += $transcript
        }
        $summary += '```'
        $summary += ""
    }

    # Git diff after session (truncated)
    if (Test-Path $diffAfterPath) {
        $diff = Get-Content $diffAfterPath -Raw
        if ($diff.Trim()) {
            $maxDiffLength = 5000
            $summary += "### Uncommitted Changes After Session"
            $summary += '```diff'
            if ($diff.Length -gt $maxDiffLength) {
                $summary += $diff.Substring(0, $maxDiffLength)
                $summary += "`n... [TRUNCATED - $(($diff.Length - $maxDiffLength)) more characters]"
            } else {
                $summary += $diff.Trim()
            }
            $summary += '```'
            $summary += ""
        }
    }

    $summary += "---"
    $summary += ""
}

# Output
$output = $summary -join "`n"

if ($OutputFile) {
    $output | Out-File $OutputFile -Encoding UTF8
    Write-Host "Summary written to: $OutputFile" -ForegroundColor Green
} else {
    Write-Output $output
}
