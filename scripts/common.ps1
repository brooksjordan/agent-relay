# common.ps1
# Shared utilities for Agent Relay pipeline scripts
#
# Dot-source this file at the top of auto-compound.ps1 and loop.ps1:
#   . "$PSScriptRoot\common.ps1"

function Invoke-Native {
    <#
    .SYNOPSIS
    Run an external command safely, preventing stderr from becoming a terminating exception.

    .DESCRIPTION
    PowerShell's $ErrorActionPreference = "Stop" converts stderr output from native commands
    into terminating exceptions. This function temporarily lowers it to "Continue" and relies
    on exit codes instead. Use this for ALL external commands (git, npm, gh, etc.).
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments
    )
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = & $Exe @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    [pscustomobject]@{ ExitCode = $code; Output = ($out -join "`n") }
}

function Invoke-SafeExpression {
    <#
    .SYNOPSIS
    Run an Invoke-Expression command safely, preventing stderr from becoming a terminating exception.

    .DESCRIPTION
    Same as Invoke-Native but for Invoke-Expression calls (quality checks, verify commands).
    Build tools (npm, pip, tsc, cargo) routinely emit warnings to stderr that don't indicate
    failure. We trust exit codes, not stderr content.
    #>
    param([Parameter(Mandatory)][string]$Expression)
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = Invoke-Expression $Expression 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    [pscustomobject]@{ ExitCode = $code; Output = ($out -join "`n") }
}
