#!/bin/bash
# Agent Relay — cross-platform entry point
# Requires PowerShell 7+: brew install powershell (Mac) or sudo apt install powershell (Linux)

if ! command -v pwsh &> /dev/null; then
    echo "Error: PowerShell 7+ (pwsh) is required."
    echo "  Mac:   brew install powershell"
    echo "  Linux: sudo apt install powershell"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
pwsh "$SCRIPT_DIR/scripts/auto-compound.ps1" "$@"
