#!/usr/bin/env bash
# overnight.sh
# Overnight Build Script - Agent Relay (macOS)
# Runs caffeinate in background + executes the auto-compound pipeline with retry
#
# Usage: ./overnight.sh --project-path "./your-project"

set -euo pipefail
source "$(dirname "$0")/common.sh"

# --- Argument parsing ---
project_path=""
project_name=""
max_iterations=25
quality_checks=""
max_retries=3
retry_delay_seconds=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-path)     project_path="$2"; shift 2 ;;
        --project-name)     project_name="$2"; shift 2 ;;
        --max-iterations)   max_iterations="$2"; shift 2 ;;
        --quality-checks)   quality_checks="$2"; shift 2 ;;
        --max-retries)      max_retries="$2"; shift 2 ;;
        --retry-delay)      retry_delay_seconds="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$project_path" ]]; then
    echo "ERROR: --project-path is required" >&2
    exit 1
fi

display_name="${project_name:-$(basename "$project_path")}"

color_echo "$_CLR_MAGENTA" ""
color_echo "$_CLR_MAGENTA" "============================================"
color_echo "$_CLR_MAGENTA" "   AGENT RELAY - Overnight Build (macOS)"
color_echo "$_CLR_MAGENTA" "============================================"
color_echo "$_CLR_MAGENTA" ""
color_echo "$_CLR_CYAN" "Project: $display_name"
color_echo "$_CLR_GRAY" "Path: $project_path"
color_echo "$_CLR_CYAN" "Max iterations: $max_iterations"
echo "" >&2

# Verify project path exists
if [[ ! -d "$project_path" ]]; then
    color_echo "$_CLR_RED" "ERROR: Project path does not exist: $project_path"
    exit 1
fi

# Check for priority report
reports_dir="$project_path/reports"
if [[ ! -d "$reports_dir" ]]; then
    color_echo "$_CLR_RED" "ERROR: No reports directory found at: $reports_dir"
    color_echo "$_CLR_YELLOW" "Create a PRIORITIES.md file there first."
    exit 1
fi

report_count=$(ls "$reports_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "$report_count" -eq 0 ]]; then
    color_echo "$_CLR_RED" "ERROR: No .md files found in reports directory"
    exit 1
fi

color_echo "$_CLR_GREEN" "Found priority report(s) in $reports_dir"
echo "" >&2

# Start caffeinate in background (prevents sleep)
color_echo "$_CLR_YELLOW" "Starting caffeinate in background (prevents sleep)..."
caffeinate -dims &
caffeine_pid=$!
color_echo "$_CLR_GREEN" "Caffeinate running (PID: $caffeine_pid)"
echo "" >&2

# Cleanup function
cleanup_overnight() {
    kill $caffeine_pid 2>/dev/null || true
}
trap cleanup_overnight EXIT

# Display start message
start_time=$(date +%s)
start_str=$(date +"%H:%M:%S")
color_echo "$_CLR_GREEN" "============================================"
color_echo "$_CLR_GREEN" "  BUILD STARTING at $start_str"
color_echo "$_CLR_GREEN" "============================================"
echo "" >&2
color_echo "$_CLR_CYAN" "Go to sleep! Check back in the morning."
echo "" >&2
color_echo "$_CLR_GRAY" "Logs will be written to:"
color_echo "$_CLR_GRAY" "  $project_path/logs/auto-compound.log"
echo "" >&2

# Run auto-compound with retry logic
scripts_dir="$(cd "$(dirname "$0")" && pwd)"
auto_compound_script="$scripts_dir/auto-compound.sh"

exit_code=1
attempt=0
current_delay=$retry_delay_seconds

while [[ $attempt -lt $max_retries && $exit_code -ne 0 ]]; do
    attempt=$((attempt + 1))

    if [[ $attempt -gt 1 ]]; then
        color_echo "$_CLR_YELLOW" ""
        color_echo "$_CLR_YELLOW" "============================================"
        color_echo "$_CLR_YELLOW" "  RETRY ATTEMPT $attempt of $max_retries"
        color_echo "$_CLR_YELLOW" "  Previous attempt failed. Retrying in $current_delay seconds..."
        color_echo "$_CLR_YELLOW" "============================================"
        echo "" >&2

        # Log retry
        retry_log="$project_path/logs/retry.log"
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Retry attempt $attempt after failure" >> "$retry_log" 2>/dev/null || true

        sleep "$current_delay"
        # Exponential backoff (max 5 minutes)
        current_delay=$((current_delay * 2))
        [[ $current_delay -gt 300 ]] && current_delay=300
    fi

    color_echo "$_CLR_CYAN" "Starting build attempt $attempt..."

    # Build args
    compound_args="--project-path \"$project_path\" --max-iterations $max_iterations --allow-inline --verbose"
    [[ -n "$project_name" ]] && compound_args+=" --project-name \"$project_name\""
    [[ -n "$quality_checks" ]] && compound_args+=" --quality-checks \"$quality_checks\""
    [[ $attempt -gt 1 ]] && compound_args+=" --resume"

    set +e
    eval "\"$auto_compound_script\" $compound_args"
    exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
        color_echo "$_CLR_GREEN" "Build attempt $attempt succeeded!"
    else
        color_echo "$_CLR_RED" "Build attempt $attempt failed with exit code: $exit_code"

        # Log the error
        error_log="$project_path/logs/error.log"
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Attempt $attempt failed with exit code $exit_code" >> "$error_log" 2>/dev/null || true
    fi
done

if [[ $exit_code -ne 0 ]]; then
    color_echo "$_CLR_RED" ""
    color_echo "$_CLR_RED" "============================================"
    color_echo "$_CLR_RED" "  BUILD FAILED after $max_retries attempts"
    color_echo "$_CLR_RED" "============================================"
    echo "" >&2
    color_echo "$_CLR_YELLOW" "Check logs at: $project_path/logs/"
fi

# Summary
end_time=$(date +%s)
end_str=$(date +"%H:%M:%S")
elapsed=$((end_time - start_time))
duration_str=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $(((elapsed%3600)/60)) $((elapsed%60)))

color_echo "$_CLR_GREEN" ""
color_echo "$_CLR_GREEN" "============================================"
color_echo "$_CLR_GREEN" "  BUILD COMPLETE at $end_str"
color_echo "$_CLR_GREEN" "  Duration: $duration_str"
color_echo "$_CLR_GREEN" "============================================"
echo "" >&2

exit $exit_code
