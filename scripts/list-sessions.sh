#!/usr/bin/env bash
# list-sessions.sh
# List recent Claude Code sessions for review
#
# Usage: ./list-sessions.sh [--hours 24] [--path ".claude-sessions"]

set -euo pipefail
source "$(dirname "$0")/common.sh"

hours=24
session_path=".claude-sessions"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hours) hours="$2"; shift 2 ;;
        --path)  session_path="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -d "$session_path" ]]; then
    color_echo "$_CLR_YELLOW" "No sessions found at: $session_path"
    exit 0
fi

# Calculate cutoff (macOS date syntax)
cutoff_epoch=$(date -v-"${hours}H" +%s 2>/dev/null || date -d "$hours hours ago" +%s 2>/dev/null)

color_echo "$_CLR_CYAN" ""
color_echo "$_CLR_CYAN" "Sessions from last $hours hours:"
echo "" >&2

session_count=0

# List sessions sorted by modification time (newest first)
for session_dir in $(ls -dt "$session_path"/*/ 2>/dev/null); do
    [[ -d "$session_dir" ]] || continue

    dir_epoch=$(stat -f %m "$session_dir" 2>/dev/null || stat -c %Y "$session_dir" 2>/dev/null || echo 0)
    if [[ $dir_epoch -lt $cutoff_epoch ]]; then
        continue
    fi

    session_count=$((session_count + 1))
    dir_name=$(basename "$session_dir")
    meta_path="$session_dir/meta.json"

    if [[ -f "$meta_path" ]]; then
        repo=$(jq -r '.repo // "unknown"' "$meta_path")
        branch=$(jq -r '.branch // "unknown"' "$meta_path")
        claude_args=$(jq -r '.claude_args // ""' "$meta_path")
        head_start=$(jq -r '.head_start // ""' "$meta_path")
        head_end=$(jq -r '.head_end // ""' "$meta_path")

        duration=""
        ts_start=$(jq -r '.timestamp_start // ""' "$meta_path")
        ts_end=$(jq -r '.timestamp_end // ""' "$meta_path")
        if [[ -n "$ts_start" && -n "$ts_end" && "$ts_end" != "null" ]]; then
            start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts_start" +%s 2>/dev/null || echo 0)
            end_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts_end" +%s 2>/dev/null || echo 0)
            if [[ $start_epoch -gt 0 && $end_epoch -gt 0 ]]; then
                dur_min=$(( (end_epoch - start_epoch) / 60 ))
                duration=" (${dur_min}m)"
            fi
        fi

        commit_info=""
        if [[ -n "$head_start" && -n "$head_end" && "$head_start" != "$head_end" ]]; then
            commit_info=" [commits: ${head_start}..${head_end}]"
        fi

        color_echo "$_CLR_WHITE" "  ${dir_name}${duration}${commit_info}"
        color_echo "$_CLR_GRAY" "    Repo: $repo | Branch: $branch"
        [[ -n "$claude_args" ]] && color_echo "$_CLR_GRAY" "    Args: $claude_args"
        echo "" >&2
    else
        color_echo "$_CLR_WHITE" "  $dir_name"
        color_echo "$_CLR_GRAY" "    (no metadata)"
        echo "" >&2
    fi
done

color_echo "$_CLR_CYAN" "Total: $session_count session(s)"
echo "" >&2
