#!/usr/bin/env bash
# gather-sessions.sh
# Gather session data from the last N hours for compound review
# Outputs a consolidated summary that can be fed to an LLM
#
# Usage: ./gather-sessions.sh [--hours 24] [--path ".claude-sessions"] [--output-file "summary.md"]

set -euo pipefail

hours=24
session_path=".claude-sessions"
output_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hours)       hours="$2"; shift 2 ;;
        --path)        session_path="$2"; shift 2 ;;
        --output-file) output_file="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -d "$session_path" ]]; then
    echo "No sessions found at: $session_path" >&2
    exit 0
fi

# Calculate cutoff time (macOS date syntax)
cutoff_epoch=$(date -v-"${hours}H" +%s 2>/dev/null || date -d "$hours hours ago" +%s 2>/dev/null)

# Find sessions newer than cutoff
session_count=0
summary=""
summary+="# Claude Code Sessions - Last $hours Hours\n\n"
summary+="Generated: $(date +"%Y-%m-%d %H:%M")\n\n"
summary+="---\n\n"

for session_dir in "$session_path"/*/; do
    [[ -d "$session_dir" ]] || continue

    # Check modification time
    dir_epoch=$(stat -f %m "$session_dir" 2>/dev/null || stat -c %Y "$session_dir" 2>/dev/null || echo 0)
    if [[ $dir_epoch -lt $cutoff_epoch ]]; then
        continue
    fi

    session_count=$((session_count + 1))
    dir_name=$(basename "$session_dir")

    summary+="## Session: $dir_name\n\n"

    # Metadata
    meta_path="$session_dir/meta.json"
    if [[ -f "$meta_path" ]]; then
        repo=$(jq -r '.repo // "unknown"' "$meta_path")
        branch=$(jq -r '.branch // "unknown"' "$meta_path")
        working_dir=$(jq -r '.working_directory // "unknown"' "$meta_path")
        ts_start=$(jq -r '.timestamp_start // "unknown"' "$meta_path")
        ts_end=$(jq -r '.timestamp_end // "unknown"' "$meta_path")
        claude_args=$(jq -r '.claude_args // ""' "$meta_path")
        head_start=$(jq -r '.head_start // ""' "$meta_path")
        head_end=$(jq -r '.head_end // ""' "$meta_path")

        summary+="- **Repo:** $repo\n"
        summary+="- **Branch:** $branch\n"
        summary+="- **Working Dir:** $working_dir\n"
        summary+="- **Start:** $ts_start\n"
        summary+="- **End:** $ts_end\n"

        [[ -n "$claude_args" ]] && summary+="- **Args:** \`$claude_args\`\n"
        [[ "$head_start" != "$head_end" ]] && summary+="- **Commits:** $head_start -> $head_end\n"
    fi
    summary+="\n"

    # Commits during session
    commits_path="$session_dir/commits_during_session.txt"
    if [[ -f "$commits_path" ]]; then
        commits=$(cat "$commits_path" | tr -d '\0')
        if [[ -n "$(echo "$commits" | tr -d '[:space:]')" ]]; then
            summary+="### Commits During Session\n\`\`\`\n$commits\n\`\`\`\n\n"
        fi
    fi

    # Transcript (truncated)
    transcript_path="$session_dir/transcript.txt"
    if [[ -f "$transcript_path" ]]; then
        transcript=$(cat "$transcript_path" | tr -d '\0')
        max_length=10000

        summary+="### Transcript (truncated)\n\`\`\`\n"
        if [[ ${#transcript} -gt $max_length ]]; then
            summary+="${transcript:0:$max_length}\n... [TRUNCATED - $((${#transcript} - max_length)) more characters]\n"
        else
            summary+="$transcript\n"
        fi
        summary+="\`\`\`\n\n"
    fi

    # Git diff after session
    diff_path="$session_dir/git_diff_after.patch"
    if [[ -f "$diff_path" ]]; then
        diff_content=$(cat "$diff_path" | tr -d '\0')
        if [[ -n "$(echo "$diff_content" | tr -d '[:space:]')" ]]; then
            max_diff=5000
            summary+="### Uncommitted Changes After Session\n\`\`\`diff\n"
            if [[ ${#diff_content} -gt $max_diff ]]; then
                summary+="${diff_content:0:$max_diff}\n... [TRUNCATED - $((${#diff_content} - max_diff)) more characters]\n"
            else
                summary+="$diff_content\n"
            fi
            summary+="\`\`\`\n\n"
        fi
    fi

    summary+="---\n\n"
done

# Update session count in header
summary=$(echo -e "$summary" | sed "s/^---$/Sessions found: $session_count\n\n---/" | head -n 5)

if [[ $session_count -eq 0 ]]; then
    echo "No sessions in the last $hours hours." >&2
    exit 0
fi

# Output
full_output=$(printf '%b' "$summary")

if [[ -n "$output_file" ]]; then
    printf '%b' "$summary" > "$output_file"
    echo "Summary written to: $output_file ($session_count sessions)" >&2
else
    printf '%b' "$summary"
fi
