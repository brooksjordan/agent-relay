# claude-session.ps1
# Wrapper for Claude Code that logs sessions for nightly compound review
#
# Usage: .\claude-session.ps1 [any claude arguments]
# Example: .\claude-session.ps1 -p "Fix the login bug"
#
# Sessions are stored in: .claude-sessions/<timestamp>_<repo>_<branch>/

param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$ClaudeArgs
)

# Configuration
$SessionsRoot = ".claude-sessions"

# Get git context (or defaults if not in a repo)
function Get-GitContext {
    $context = @{
        IsRepo = $false
        RepoName = "no-repo"
        Branch = "no-branch"
        Head = "no-head"
        RemoteUrl = ""
    }

    try {
        $gitRoot = git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $gitRoot) {
            $context.IsRepo = $true
            $context.RepoName = Split-Path $gitRoot -Leaf
            $context.Branch = git rev-parse --abbrev-ref HEAD 2>$null
            $context.Head = git rev-parse --short HEAD 2>$null
            $context.RemoteUrl = git remote get-url origin 2>$null
        }
    } catch {
        # Not a git repo, use defaults
    }

    return $context
}

# Sanitize string for folder name
function Get-SafeFolderName {
    param([string]$Name)
    return $Name -replace '[\\/:*?"<>|]', '_'
}

# Redact potential secrets from text
function Remove-Secrets {
    param([string]$Text)

    # Common secret patterns
    $patterns = @(
        # AWS keys
        '(?i)(AKIA[0-9A-Z]{16})',
        # GitHub tokens
        '(?i)(ghp_[a-zA-Z0-9]{36})',
        '(?i)(github_pat_[a-zA-Z0-9_]{22,})',
        # Generic API keys (long alphanumeric strings after common key words)
        '(?i)(api[_-]?key["\s:=]+)[a-zA-Z0-9]{20,}',
        '(?i)(secret[_-]?key["\s:=]+)[a-zA-Z0-9]{20,}',
        '(?i)(password["\s:=]+)[^\s"]{8,}',
        # Bearer tokens
        '(?i)(Bearer\s+)[a-zA-Z0-9\-_.]{20,}'
    )

    $redacted = $Text
    foreach ($pattern in $patterns) {
        $redacted = $redacted -replace $pattern, '$1[REDACTED]'
    }

    return $redacted
}

# --- Main Execution ---

# Get git context
$git = Get-GitContext

# Create session folder
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$folderName = "${timestamp}_$(Get-SafeFolderName $git.RepoName)_$(Get-SafeFolderName $git.Branch)"
$sessionPath = Join-Path $SessionsRoot $folderName

# Ensure sessions directory exists
New-Item -ItemType Directory -Force -Path $sessionPath | Out-Null

Write-Host "Session logging to: $sessionPath" -ForegroundColor DarkGray

# Capture pre-session git state
if ($git.IsRepo) {
    git status --porcelain > (Join-Path $sessionPath "git_status_before.txt") 2>$null
    git diff > (Join-Path $sessionPath "git_diff_before.patch") 2>$null
    git diff --staged > (Join-Path $sessionPath "git_diff_staged_before.patch") 2>$null
}

# Write metadata
$meta = @{
    timestamp_start = (Get-Date).ToString("o")
    timestamp_end = $null
    repo = $git.RepoName
    branch = $git.Branch
    head_start = $git.Head
    head_end = $null
    remote_url = $git.RemoteUrl
    working_directory = (Get-Location).Path
    claude_args = $ClaudeArgs -join " "
    exit_code = $null
}

# Start transcript
$transcriptPath = Join-Path $sessionPath "transcript.txt"
Start-Transcript -Path $transcriptPath -Force | Out-Null

try {
    # Run Claude Code with all passed arguments
    if ($ClaudeArgs) {
        & claude @ClaudeArgs
    } else {
        & claude
    }
    $meta.exit_code = $LASTEXITCODE
}
finally {
    # Stop transcript
    Stop-Transcript | Out-Null

    # Update metadata with end state
    $meta.timestamp_end = (Get-Date).ToString("o")

    if ($git.IsRepo) {
        $meta.head_end = git rev-parse --short HEAD 2>$null

        # Capture post-session git state
        git status --porcelain > (Join-Path $sessionPath "git_status_after.txt") 2>$null
        git diff > (Join-Path $sessionPath "git_diff_after.patch") 2>$null
        git diff --staged > (Join-Path $sessionPath "git_diff_staged_after.patch") 2>$null

        # Capture commits made during session
        if ($meta.head_start -ne $meta.head_end) {
            git log --oneline "$($meta.head_start)..$($meta.head_end)" > (Join-Path $sessionPath "commits_during_session.txt") 2>$null
        }
    }

    # Save metadata as JSON
    $meta | ConvertTo-Json -Depth 3 | Out-File (Join-Path $sessionPath "meta.json") -Encoding UTF8

    # Redact secrets from transcript
    $transcriptContent = Get-Content $transcriptPath -Raw -ErrorAction SilentlyContinue
    if ($transcriptContent) {
        $redactedContent = Remove-Secrets -Text $transcriptContent
        $redactedContent | Out-File $transcriptPath -Encoding UTF8 -Force
    }

    Write-Host "`nSession saved to: $sessionPath" -ForegroundColor Green
}
