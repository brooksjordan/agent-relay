#!/usr/bin/env bash
# status-scheduler.sh
# Shows status of Agent Relay launchd agents
#
# Usage: ./status-scheduler.sh [--label-prefix "com.agentrelay"]

set -euo pipefail
source "$(dirname "$0")/common.sh"

label_prefix="com.agentrelay"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label-prefix) label_prefix="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

color_echo "$_CLR_CYAN" "Agent Relay - Scheduler Status (macOS launchd)"
color_echo "$_CLR_CYAN" "========================================"
echo "" >&2

# List matching agents
agents=$(launchctl list 2>/dev/null | grep "$label_prefix" || true)

if [[ -z "$agents" ]]; then
    color_echo "$_CLR_YELLOW" "No scheduled agents found with prefix: $label_prefix"
    echo "" >&2
    echo "Run install-scheduler.sh to set up scheduled agents." >&2
    exit 0
fi

# Display each agent's status
while IFS= read -r line; do
    # launchctl list format: PID  Status  Label
    pid=$(echo "$line" | awk '{print $1}')
    status_code=$(echo "$line" | awk '{print $2}')
    label=$(echo "$line" | awk '{print $3}')

    if [[ "$pid" == "-" ]]; then
        state="Ready"
        state_color="$_CLR_GREEN"
    else
        state="Running (PID: $pid)"
        state_color="$_CLR_CYAN"
    fi

    if [[ "$status_code" != "0" && "$status_code" != "-" ]]; then
        state="Last exit: $status_code"
        state_color="$_CLR_YELLOW"
    fi

    color_echo "$state_color" "Agent: $label"
    echo "  State: $state" >&2

    # Check if plist exists
    plist="$HOME/Library/LaunchAgents/${label}.plist"
    if [[ -f "$plist" ]]; then
        # Extract schedule from plist
        hour=$(/usr/libexec/PlistBuddy -c "Print :StartCalendarInterval:Hour" "$plist" 2>/dev/null || echo "?")
        minute=$(/usr/libexec/PlistBuddy -c "Print :StartCalendarInterval:Minute" "$plist" 2>/dev/null || echo "?")
        echo "  Schedule: $hour:$(printf '%02s' "$minute") daily" >&2
    fi

    echo "" >&2
done <<< "$agents"

# Show recent log entries
color_echo "$_CLR_CYAN" "Recent Activity:"
echo "----------------" >&2

log_patterns=(
    "logs/compound-review-scheduled.log"
    "logs/auto-compound-scheduled.log"
    "logs/keep-awake-scheduled.log"
)

found_logs=false

# Try to find logs in the current directory or common project locations
for log_pattern in "${log_patterns[@]}"; do
    if [[ -f "$log_pattern" ]]; then
        found_logs=true
        echo "" >&2
        color_echo "$_CLR_GRAY" "  $log_pattern:"
        tail -5 "$log_pattern" 2>/dev/null | while IFS= read -r line; do
            echo "    $line" >&2
        done
    fi
done

if [[ "$found_logs" != "true" ]]; then
    color_echo "$_CLR_GRAY" "  No log files found yet."
fi

echo "" >&2
