#!/usr/bin/env bash
# install-scheduler.sh
# Sets up macOS launchd jobs for Agent Relay
#
# Usage: ./install-scheduler.sh --project-path "/path/to/project"
#
# Creates three launchd agents:
#   1. Compound Review (10:30 PM) - Extract learnings
#   2. Auto-Compound (11:00 PM) - Implement #1 priority
#   3. Keep Awake (10:00 PM - 2:00 AM) - Prevent sleep during automation

set -euo pipefail
source "$(dirname "$0")/common.sh"

# --- Argument parsing ---
project_path=""
label_prefix="com.agentrelay"
review_hour=22
review_minute=30
compound_hour=23
compound_minute=0
awake_hour=22
force=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-path)     project_path="$2"; shift 2 ;;
        --label-prefix)     label_prefix="$2"; shift 2 ;;
        --review-time)      IFS=':' read -r review_hour review_minute <<< "$2"; shift 2 ;;
        --compound-time)    IFS=':' read -r compound_hour compound_minute <<< "$2"; shift 2 ;;
        --awake-time)       IFS=':' read -r awake_hour _ <<< "$2"; shift 2 ;;
        --force)            force=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$project_path" ]]; then
    echo "ERROR: --project-path is required" >&2
    echo "Usage: $0 --project-path \"/path/to/project\" [--force]" >&2
    exit 1
fi

project_path=$(cd "$project_path" && pwd)
scripts_dir="$(cd "$(dirname "$0")" && pwd)"
launch_agents_dir="$HOME/Library/LaunchAgents"

# Validate
if [[ ! -d "$project_path" ]]; then
    echo "ERROR: Project path does not exist: $project_path" >&2
    exit 1
fi

color_echo "$_CLR_CYAN" "Agent Relay - Scheduler Setup (macOS launchd)"
color_echo "$_CLR_CYAN" "======================================="
echo "" >&2
echo "Project: $project_path" >&2
echo "Label prefix: $label_prefix" >&2
echo "" >&2

# Check for existing agents
existing=$(launchctl list 2>/dev/null | grep "$label_prefix" || true)
if [[ -n "$existing" && "$force" != "true" ]]; then
    color_echo "$_CLR_YELLOW" "Existing agents found:"
    echo "$existing" >&2
    echo "" >&2
    echo "Use --force to overwrite, or run uninstall-scheduler.sh first." >&2
    exit 1
fi

if [[ -n "$existing" && "$force" == "true" ]]; then
    color_echo "$_CLR_YELLOW" "Removing existing agents..."
    for plist in "$launch_agents_dir"/${label_prefix}*.plist; do
        [[ -f "$plist" ]] && launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
    done
fi

mkdir -p "$launch_agents_dir"
mkdir -p "$project_path/logs"

# ========================================
# Agent 1: Compound Review (10:30 PM)
# ========================================
review_label="${label_prefix}.compound-review"
review_plist="$launch_agents_dir/${review_label}.plist"

color_echo "$_CLR_GREEN" "Creating: $review_label"

cat > "$review_plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$review_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$scripts_dir/compound-review.sh</string>
        <string>--project-path</string>
        <string>$project_path</string>
        <string>--verbose</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$project_path</string>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$review_hour</integer>
        <key>Minute</key>
        <integer>$review_minute</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$project_path/logs/compound-review-scheduled.log</string>
    <key>StandardErrorPath</key>
    <string>$project_path/logs/compound-review-scheduled.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:$HOME/.local/bin</string>
    </dict>
</dict>
</plist>
PLIST_EOF

launchctl load "$review_plist"
echo "  Scheduled for $review_hour:$(printf '%02d' $review_minute) daily" >&2

# ========================================
# Agent 2: Auto-Compound (11:00 PM)
# ========================================
compound_label="${label_prefix}.auto-compound"
compound_plist="$launch_agents_dir/${compound_label}.plist"

color_echo "$_CLR_GREEN" "Creating: $compound_label"

cat > "$compound_plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$compound_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$scripts_dir/overnight.sh</string>
        <string>--project-path</string>
        <string>$project_path</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$project_path</string>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$compound_hour</integer>
        <key>Minute</key>
        <integer>$compound_minute</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$project_path/logs/auto-compound-scheduled.log</string>
    <key>StandardErrorPath</key>
    <string>$project_path/logs/auto-compound-scheduled.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:$HOME/.local/bin</string>
        <key>AGENT_RELAY_VISIBLE_LAUNCH</key>
        <string>1</string>
    </dict>
</dict>
</plist>
PLIST_EOF

launchctl load "$compound_plist"
echo "  Scheduled for $compound_hour:$(printf '%02d' $compound_minute) daily" >&2

# ========================================
# Agent 3: Keep Awake (prevent sleep)
# ========================================
awake_label="${label_prefix}.keep-awake"
awake_plist="$launch_agents_dir/${awake_label}.plist"

color_echo "$_CLR_GREEN" "Creating: $awake_label"

# 4 hours = 14400 seconds
cat > "$awake_plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$awake_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$scripts_dir/keep-awake.sh</string>
        <string>--duration</string>
        <string>14400</string>
        <string>--quiet</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$awake_hour</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$project_path/logs/keep-awake-scheduled.log</string>
    <key>StandardErrorPath</key>
    <string>$project_path/logs/keep-awake-scheduled.log</string>
</dict>
</plist>
PLIST_EOF

launchctl load "$awake_plist"
echo "  Scheduled for $awake_hour:00 daily (runs for 4 hours)" >&2

# ========================================
# Summary
# ========================================
echo "" >&2
color_echo "$_CLR_GREEN" "Setup complete!"
echo "" >&2
color_echo "$_CLR_CYAN" "Scheduled agents created:"
echo "  1. $awake_label       - $awake_hour:00 (prevents sleep)" >&2
echo "  2. $review_label      - $review_hour:$(printf '%02d' $review_minute) (extract learnings)" >&2
echo "  3. $compound_label    - $compound_hour:$(printf '%02d' $compound_minute) (implement + PR)" >&2
echo "" >&2
color_echo "$_CLR_CYAN" "Logs will be written to:"
echo "  $project_path/logs/compound-review-scheduled.log" >&2
echo "  $project_path/logs/auto-compound-scheduled.log" >&2
echo "  $project_path/logs/keep-awake-scheduled.log" >&2
echo "" >&2
color_echo "$_CLR_YELLOW" "To verify:"
echo "  launchctl list | grep $label_prefix" >&2
echo "" >&2
color_echo "$_CLR_YELLOW" "To uninstall:"
echo "  ./uninstall-scheduler.sh --label-prefix '$label_prefix'" >&2
