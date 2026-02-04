# launch-auto-compound.ps1
# The ONLY correct way to launch the build pipeline.
# Spawns a visible PowerShell window with the required env var.
#
# Usage:
#   .\launch-auto-compound.ps1 -ProjectPath "C:\agent_roi" -Verbose
#   .\launch-auto-compound.ps1 -ProjectPath "C:\agent_roi" -DryRun

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectPath,

    [string]$ProjectName = "",

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Resolve to absolute path
$ProjectPath = (Resolve-Path $ProjectPath).Path

# Build argument string for the inner script
$innerArgs = "-ProjectPath `"$ProjectPath`""
if ($ProjectName)          { $innerArgs += " -ProjectName `"$ProjectName`"" }
if ($VerbosePreference -eq "Continue" -or $PSBoundParameters.ContainsKey('Verbose')) {
    $innerArgs += " -Verbose"
}
if ($DryRun)               { $innerArgs += " -DryRun" }

# Write a temp wrapper that sets the env var and launches auto-compound
$wrapper = Join-Path $env:TEMP ("shipasleep-" + [guid]::NewGuid().ToString().Substring(0,8) + ".ps1")

@"
`$env:SHIP_ASLEEP_VISIBLE_LAUNCH = '1'
Set-Location 'C:\ship_asleep\scripts'
.\auto-compound.ps1 $innerArgs
"@ | Set-Content -Path $wrapper -Encoding UTF8

# Launch in a new visible window
Start-Process powershell -ArgumentList @(
    '-ExecutionPolicy', 'Bypass',
    '-NoExit',
    '-File', $wrapper
)

Write-Host "Pipeline launched in visible window for: $ProjectPath"
