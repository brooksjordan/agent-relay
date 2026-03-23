#!/usr/bin/env bash
# claude-session.sh
# Wrapper for Claude Code that logs sessions for nightly compound review
#
# Usage: ./claude-session.sh [any claude arguments]
# Example: ./claude-session.sh -p "Fix the login bug"
#
# Sessions are stored in: .claude-sessions/<timestamp>_<repo>_<branch>/

set -euo pipefail

sessions_root=".claude-sessions"

# --- Git context ---
get_git_context() {
    _GIT_IS_REPO=false
    _GIT_REPO_NAME="no-repo"
    _GIT_BRANCH="no-branch"
    _GIT_HEAD="no-head"
    _GIT_REMOTE_URL=""

    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0

    if [[ -n "$git_root" ]]; then
        _GIT_IS_REPO=true
        _GIT_REPO_NAME=$(basename "$git_root")
        _GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        _GIT_HEAD=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        _GIT_REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
    fi
}

# --- Sanitize for folder name ---
safe_folder_name() {
    echo "$1" | sed 's/[\\/:*?"<>|]/_/g'
}

# --- Redact secrets ---
redact_secrets() {
    local text="$1"
    echo "$text" | \
        sed -E 's/(AKIA[0-9A-Z]{16})/[REDACTED]/gi' | \
        sed -E 's/(ghp_[a-zA-Z0-9]{36})/[REDACTED]/gi' | \
        sed -E 's/(github_pat_[a-zA-Z0-9_]{22,})/[REDACTED]/gi' | \
        sed -E 's/(api[_-]?key["[:space:]:=]+)[a-zA-Z0-9]{20,}/\1[REDACTED]/gi' | \
        sed -E 's/(secret[_-]?key["[:space:]:=]+)[a-zA-Z0-9]{20,}/\1[REDACTED]/gi' | \
        sed -E 's/(password["[:space:]:=]+)[^[:space:]"]{8,}/\1[REDACTED]/gi' | \
        sed -E 's/(Bearer[[:space:]]+)[a-zA-Z0-9_.:-]{20,}/\1[REDACTED]/gi'
}

# --- Main ---
get_git_context

timestamp=$(date +"%Y-%m-%d_%H%M%S")
folder_name="${timestamp}_$(safe_folder_name "$_GIT_REPO_NAME")_$(safe_folder_name "$_GIT_BRANCH")"
session_path="$sessions_root/$folder_name"
mkdir -p "$session_path"

echo "Session logging to: $session_path" >&2

# Capture pre-session git state
if [[ "$_GIT_IS_REPO" == "true" ]]; then
    git status --porcelain > "$session_path/git_status_before.txt" 2>/dev/null || true
    git diff > "$session_path/git_diff_before.patch" 2>/dev/null || true
    git diff --staged > "$session_path/git_diff_staged_before.patch" 2>/dev/null || true
fi

# Write metadata
head_start="$_GIT_HEAD"
start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
    --arg ts_start "$start_time" \
    --arg repo "$_GIT_REPO_NAME" \
    --arg branch "$_GIT_BRANCH" \
    --arg head_start "$_GIT_HEAD" \
    --arg remote_url "$_GIT_REMOTE_URL" \
    --arg working_dir "$(pwd)" \
    --arg claude_args "$*" \
    '{
        timestamp_start: $ts_start,
        timestamp_end: null,
        repo: $repo,
        branch: $branch,
        head_start: $head_start,
        head_end: null,
        remote_url: $remote_url,
        working_directory: $working_dir,
        claude_args: $claude_args,
        exit_code: null
    }' > "$session_path/meta.json"

# Run Claude with transcript capture using script command
transcript_path="$session_path/transcript.txt"
set +e
script -q "$transcript_path" claude "$@"
claude_exit=$?
set -e

# Update metadata with end state
end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
head_end="$_GIT_HEAD"

if [[ "$_GIT_IS_REPO" == "true" ]]; then
    head_end=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    # Capture post-session git state
    git status --porcelain > "$session_path/git_status_after.txt" 2>/dev/null || true
    git diff > "$session_path/git_diff_after.patch" 2>/dev/null || true
    git diff --staged > "$session_path/git_diff_staged_after.patch" 2>/dev/null || true

    # Capture commits made during session
    if [[ "$head_start" != "$head_end" ]]; then
        git log --oneline "${head_start}..${head_end}" > "$session_path/commits_during_session.txt" 2>/dev/null || true
    fi
fi

# Update meta.json
tmp_meta=$(mktemp)
jq --arg ts_end "$end_time" --arg head_end "$head_end" --argjson exit_code "$claude_exit" \
    '.timestamp_end = $ts_end | .head_end = $head_end | .exit_code = $exit_code' \
    "$session_path/meta.json" > "$tmp_meta"
mv "$tmp_meta" "$session_path/meta.json"

# Redact secrets from transcript
if [[ -f "$transcript_path" ]]; then
    transcript_content=$(cat "$transcript_path")
    redacted=$(redact_secrets "$transcript_content")
    echo "$redacted" > "$transcript_path"
fi

echo "" >&2
echo "Session saved to: $session_path" >&2
