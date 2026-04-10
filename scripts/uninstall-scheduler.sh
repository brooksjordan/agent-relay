#!/usr/bin/env bash
# uninstall-scheduler.sh
# Removes Agent Relay launchd agents
#
# Usage: ./uninstall-scheduler.sh [--label-prefix "com.agentrelay"]

set -euo pipefail
source "$(dirname "$0")/common.sh"

label_prefix="com.agentrelay"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label-prefix) label_prefix="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

launch_agents_dir="$HOME/Library/LaunchAgents"

color_echo "$_CLR_YELLOW" "Removing Agent Relay scheduled agents..."
echo "" >&2

found=false
for plist in "$launch_agents_dir"/${label_prefix}*.plist; do
    if [[ -f "$plist" ]]; then
        found=true
        label=$(basename "$plist" .plist)
        color_echo "$_CLR_RED" "Removing: $label"
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
    fi
done

if [[ "$found" != "true" ]]; then
    color_echo "$_CLR_GRAY" "No agents found with prefix: $label_prefix"
    exit 0
fi

echo "" >&2
color_echo "$_CLR_GREEN" "Done. All $label_prefix agents removed."
