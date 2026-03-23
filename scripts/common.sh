#!/usr/bin/env bash
# common.sh
# Shared utilities for Agent Relay pipeline scripts (macOS/Linux)
#
# Source this file at the top of auto-compound.sh and loop.sh:
#   source "$(dirname "$0")/common.sh"

# --- invoke_native ---
# Run an external command safely, capturing stdout+stderr and exit code.
# Bash doesn't have PowerShell's $ErrorActionPreference problem, but we still
# need a consistent way to capture output + exit code for inspection by callers.
#
# Usage:
#   invoke_native git push -u origin main
#   if [[ $_NATIVE_EXIT_CODE -ne 0 ]]; then echo "Failed: $_NATIVE_OUTPUT"; fi
#
# Sets globals: _NATIVE_OUTPUT, _NATIVE_EXIT_CODE
invoke_native() {
    local old_e
    old_e=$(set +o | grep errexit)  # save current -e state
    set +e
    _NATIVE_OUTPUT=$("$@" 2>&1)
    _NATIVE_EXIT_CODE=$?
    eval "$old_e"  # restore -e state
}

# --- invoke_safe_expression ---
# Run a command string via eval safely (for dynamic commands like quality checks).
# Same pattern as invoke_native but accepts a string to eval.
#
# Usage:
#   invoke_safe_expression "npm run typecheck"
#   if [[ $_NATIVE_EXIT_CODE -ne 0 ]]; then echo "Failed"; fi
#
# Sets globals: _NATIVE_OUTPUT, _NATIVE_EXIT_CODE
invoke_safe_expression() {
    local old_e
    old_e=$(set +o | grep errexit)
    set +e
    _NATIVE_OUTPUT=$(eval "$1" 2>&1)
    _NATIVE_EXIT_CODE=$?
    eval "$old_e"
}

# --- Color output helpers ---
# ANSI color codes for terminal output
_CLR_RED='\033[31m'
_CLR_YELLOW='\033[33m'
_CLR_GREEN='\033[32m'
_CLR_CYAN='\033[36m'
_CLR_WHITE='\033[37m'
_CLR_GRAY='\033[90m'
_CLR_MAGENTA='\033[35m'
_CLR_RESET='\033[0m'

# Print colored text to stderr (so it doesn't pollute stdout for callers)
color_echo() {
    local color="$1"
    shift
    printf "%b%s%b\n" "$color" "$*" "$_CLR_RESET" >&2
}
