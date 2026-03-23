#!/usr/bin/env bash
# compound-review.sh
# Nightly compound review: extract learnings from sessions and update CLAUDE.md
#
# Usage: ./compound-review.sh [--hours 24] [--sessions-path ".claude-sessions"] [--dry-run]
#
# This is Job 1 of the Agent Relay loop.
# Run at 10:30 PM, before auto-compound.

set -euo pipefail
source "$(dirname "$0")/common.sh"

# --- Argument parsing ---
hours=24
sessions_path=".claude-sessions"
project_path="."
dry_run=false
verbose=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hours)          hours="$2"; shift 2 ;;
        --sessions-path)  sessions_path="$2"; shift 2 ;;
        --project-path)   project_path="$2"; shift 2 ;;
        --dry-run)        dry_run=true; shift ;;
        --verbose|-v)     verbose=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Resolve paths
project_path=$(cd "$project_path" && pwd)
scripts_dir="$(cd "$(dirname "$0")" && pwd)"
gather_script="$scripts_dir/gather-sessions.sh"
temp_summary="$TMPDIR/claude_sessions_summary_$(date +%Y%m%d_%H%M%S).md"
log_file="$project_path/logs/compound-review.log"

# Ensure logs directory exists
mkdir -p "$project_path/logs"

# --- Logging ---
write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local log_line="[$timestamp] [$level] $message"
    echo "$log_line" >> "$log_file"
    if [[ "$verbose" == "true" || "$level" == "ERROR" ]]; then
        case "$level" in
            ERROR)   color_echo "$_CLR_RED" "$log_line" ;;
            WARN)    color_echo "$_CLR_YELLOW" "$log_line" ;;
            SUCCESS) color_echo "$_CLR_GREEN" "$log_line" ;;
            *)       color_echo "$_CLR_WHITE" "$log_line" ;;
        esac
    fi
}

# --- Main ---
write_log "=== Compound Review Started ==="
write_log "Project: $project_path"
write_log "Sessions: $sessions_path"
write_log "Hours: $hours"

# Step 1: Ensure we're on main and up to date
write_log "Checking git status..."
pushd "$project_path" > /dev/null

cleanup_review() {
    popd > /dev/null 2>&1 || true
}
trap cleanup_review EXIT

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [[ "$branch" != "main" && "$branch" != "master" ]]; then
    write_log "Current branch is '$branch', switching to main..." "WARN"
    git checkout main 2>&1 > /dev/null || git checkout master 2>&1 > /dev/null || true
fi

has_remote=$(git remote 2>/dev/null || echo "")
if [[ -n "$has_remote" ]]; then
    write_log "Pulling latest..."
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    git pull origin "$current_branch" 2>&1 > /dev/null || true
else
    write_log "No remote configured, skipping pull" "WARN"
fi

# Step 2: Gather sessions
write_log "Gathering sessions from last $hours hours..."

full_sessions_path="$project_path/$sessions_path"
if [[ ! -d "$full_sessions_path" ]]; then
    write_log "No sessions directory found at: $full_sessions_path" "WARN"
    write_log "Nothing to review. Exiting."
    exit 0
fi

"$gather_script" --hours "$hours" --path "$full_sessions_path" --output-file "$temp_summary"

if [[ ! -f "$temp_summary" ]]; then
    write_log "No sessions summary generated. Exiting."
    exit 0
fi

summary_content=$(cat "$temp_summary")
session_count=$(echo "$summary_content" | grep -c "## Session:" || echo 0)

if [[ "$session_count" -eq 0 ]]; then
    write_log "No sessions found in the last $hours hours. Exiting."
    exit 0
fi

write_log "Found $session_count session(s) to review."

# Step 3: Build the compound review prompt
claude_md_path="$project_path/CLAUDE.md"
existing_claude_md=""
if [[ -f "$claude_md_path" ]]; then
    existing_claude_md=$(cat "$claude_md_path")
fi

prompt="You are performing a COMPOUND REVIEW of Claude Code sessions from the last $hours hours.

## Your Task

1. Read through each session transcript and git diff below
2. Extract KEY LEARNINGS: patterns that worked, gotchas discovered, context future sessions need
3. Update the project's CLAUDE.md file with these learnings

## Guidelines for Extraction

- **Patterns**: Reusable approaches that worked well (e.g., \"When modifying X, always update Y\")
- **Gotchas**: Edge cases, bugs hit, things that didn't work (e.g., \"The API returns 500 if Z is empty\")
- **Context**: Project-specific knowledge that helps future sessions (e.g., \"Auth is handled in /lib/auth, not /api\")
- **Commands**: Useful commands or workflows discovered

## Guidelines for CLAUDE.md Updates

- Add learnings to appropriate sections (create sections if needed)
- Be concise - bullet points, not paragraphs
- Include date discovered for time-sensitive learnings
- Don't duplicate existing content
- If a learning contradicts existing content, update the existing content

## Current CLAUDE.md Content

$existing_claude_md

---

## Sessions to Review

$summary_content

---

## Instructions

1. Analyze each session for learnings
2. Read the current CLAUDE.md (if any)
3. Update CLAUDE.md with new learnings (use the Edit tool or Write tool)
4. Commit your changes with message: \"compound: extract learnings from $(date +%Y-%m-%d) sessions\"
5. Push to the current branch

If there are no meaningful learnings to extract, say so and exit without changes."

# Step 4: Run Claude
write_log "Running Claude Code for compound review..."

if [[ "$dry_run" == "true" ]]; then
    write_log "DRY RUN - Would execute Claude with prompt:" "WARN"
    echo "$prompt" >&2
    write_log "DRY RUN complete. No changes made."
    exit 0
fi

# Write prompt to temp file
prompt_file="$TMPDIR/compound_review_prompt_$(date +%Y%m%d_%H%M%S).txt"
printf '%s' "$prompt" > "$prompt_file"

# Execute Claude
set +e
claude_output=$(cat "$prompt_file" | claude --print --dangerously-skip-permissions 2>&1)
claude_exit=$?
set -e

write_log "$claude_output"

if [[ $claude_exit -ne 0 ]]; then
    write_log "Claude Code exited with code $claude_exit" "ERROR"
    exit $claude_exit
fi

write_log "Compound review complete." "SUCCESS"

# Cleanup
rm -f "$temp_summary" "$prompt_file"

write_log "=== Compound Review Finished ==="
