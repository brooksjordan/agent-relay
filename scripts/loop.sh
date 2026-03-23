#!/usr/bin/env bash
# loop.sh
# Execution loop: runs Claude iteratively on tasks until complete
#
# Usage: ./loop.sh --tasks-file "tasks/prd.json" [--max-iterations 25] [--verbose]

set -euo pipefail
source "$(dirname "$0")/common.sh"

# Force CI mode to prevent build tools from hanging in watch mode
export CI=true

# --- Argument parsing ---
tasks_file=""
max_iterations=25
log_file=""
quality_checks=()
archive_dir=""
task_timeout_seconds=900
transcript_dir=""
verbose=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tasks-file)         tasks_file="$2"; shift 2 ;;
        --max-iterations)     max_iterations="$2"; shift 2 ;;
        --log-file)           log_file="$2"; shift 2 ;;
        --quality-checks)     IFS=',' read -ra quality_checks <<< "$2"; shift 2 ;;
        --archive-dir)        archive_dir="$2"; shift 2 ;;
        --task-timeout)       task_timeout_seconds="$2"; shift 2 ;;
        --transcript-dir)     transcript_dir="$2"; shift 2 ;;
        --verbose|-v)         verbose=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$tasks_file" ]]; then
    echo "ERROR: --tasks-file is required" >&2
    exit 1
fi

if [[ ! -f "$tasks_file" ]]; then
    echo "ERROR: Tasks file not found: $tasks_file" >&2
    exit 1
fi

# Setup logging - log lives OUTSIDE the workspace (in agent-relay/logs/)
# so git clean -fd can't delete it
if [[ -z "$log_file" ]]; then
    log_dir="$(dirname "$0")/../logs"
    mkdir -p "$log_dir"
    log_file="$log_dir/loop.log"
fi

# --- Logging ---
write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local log_line="[$timestamp] [$level] $message"
    echo "$log_line" >> "$log_file"

    case "$level" in
        ERROR)   color_echo "$_CLR_RED" "$log_line" ;;
        WARN)    color_echo "$_CLR_YELLOW" "$log_line" ;;
        SUCCESS) color_echo "$_CLR_GREEN" "$log_line" ;;
        ITER)    color_echo "$_CLR_CYAN" "$log_line" ;;
        *)       [[ "$verbose" == "true" ]] && color_echo "$_CLR_WHITE" "$log_line" ;;
    esac
}

# --- Task JSON helpers (using jq) ---
get_tasks() {
    jq -c '.tasks' "$tasks_file"
}

save_tasks() {
    local tasks_json="$1"
    local tmp_file="${tasks_file}.tmp"
    jq -n --argjson tasks "$tasks_json" '{ tasks: $tasks }' > "$tmp_file"
    mv "$tmp_file" "$tasks_file"
}

get_next_pending_task() {
    jq -c '[.tasks[] | select(.status == "pending")] | first // empty' "$tasks_file"
}

get_completed_count() {
    jq '[.tasks[] | select(.status == "completed")] | length' "$tasks_file"
}

get_failed_count() {
    jq '[.tasks[] | select(.status == "failed")] | length' "$tasks_file"
}

get_total_count() {
    jq '.tasks | length' "$tasks_file"
}

update_task_field() {
    local task_id="$1"
    local field="$2"
    local value="$3"
    local tmp_file="${tasks_file}.tmp"
    jq --argjson id "$task_id" --arg field "$field" --arg value "$value" \
        '.tasks |= map(if .id == $id then .[$field] = $value else . end)' \
        "$tasks_file" > "$tmp_file"
    mv "$tmp_file" "$tasks_file"
}

update_task_status() {
    local task_id="$1"
    local status="$2"
    local tmp_file="${tasks_file}.tmp"
    jq --argjson id "$task_id" --arg status "$status" \
        '.tasks |= map(if .id == $id then .status = $status else . end)' \
        "$tasks_file" > "$tmp_file"
    mv "$tmp_file" "$tasks_file"
}

# --- Quality checks ---
invoke_quality_checks() {
    local working_dir="$1"

    if [[ ${#quality_checks[@]} -eq 0 ]]; then
        write_log "No quality checks configured, skipping"
        _QC_PASSED=true
        _QC_REASON=""
        return
    fi

    write_log "Running ${#quality_checks[@]} quality check(s)..."
    local original_dir
    original_dir=$(pwd)

    cd "$working_dir"

    for check in "${quality_checks[@]}"; do
        write_log "Quality check: $check"
        invoke_safe_expression "$check"
        if [[ $_NATIVE_EXIT_CODE -ne 0 ]]; then
            write_log "Quality check FAILED: $check (exit code $_NATIVE_EXIT_CODE)" "WARN"
            _QC_PASSED=false
            _QC_REASON="Quality check failed: $check (exit code $_NATIVE_EXIT_CODE)"
            cd "$original_dir"
            return
        fi
        write_log "Quality check passed: $check"
    done

    cd "$original_dir"
    _QC_PASSED=true
    _QC_REASON=""
}

# --- Claude usage extraction ---
get_claude_usage() {
    local output="$1"
    _USAGE_TOTAL_TOKENS=0
    _USAGE_COST=0.0

    local match
    match=$(echo "$output" | grep -oiE 'Total tokens[:\s]+[0-9,]+' | head -1 | grep -oE '[0-9,]+' | tr -d ',')
    [[ -n "$match" ]] && _USAGE_TOTAL_TOKENS="$match"

    match=$(echo "$output" | grep -oiE 'Total cost[:\s]+\$?[0-9.]+' | head -1 | grep -oE '[0-9.]+')
    [[ -n "$match" ]] && _USAGE_COST="$match"

    if [[ "$_USAGE_COST" == "0.0" ]]; then
        match=$(echo "$output" | grep -oiE 'cost[:\s]+\$[0-9.]+' | head -1 | grep -oE '[0-9.]+')
        [[ -n "$match" ]] && _USAGE_COST="$match"
    fi
}

# --- Archive initialization ---
initialize_archive() {
    local workspace_root="$1"

    if [[ -z "$archive_dir" ]]; then
        archive_dir="$workspace_root/archive"
    fi

    local last_branch_file="$workspace_root/.last-branch"

    if [[ -f "$tasks_file" && -f "$last_branch_file" ]]; then
        local current_branch
        current_branch=$(jq -r '.branchName // ""' "$tasks_file" 2>/dev/null || echo "")
        local last_branch
        last_branch=$(cat "$last_branch_file" 2>/dev/null | tr -d '[:space:]')

        if [[ -n "$current_branch" && -n "$last_branch" && "$current_branch" != "$last_branch" ]]; then
            local archive_date
            archive_date=$(date +%Y-%m-%d)
            local folder_name
            folder_name=$(echo "$last_branch" | sed 's/^feature\///' | sed 's/^compound\///')
            local archive_folder="$archive_dir/$archive_date-$folder_name"

            write_log "Archiving previous run: $last_branch -> $archive_folder"
            mkdir -p "$archive_folder"

            [[ -f "$tasks_file" ]] && cp "$tasks_file" "$archive_folder/"

            local progress_file
            progress_file="$(dirname "$tasks_file")/progress.txt"
            [[ -f "$progress_file" ]] && cp "$progress_file" "$archive_folder/"

            # Reset progress file for new run
            cat > "$progress_file" << PROGRESS_EOF
# Progress Log
Started: $(date +"%Y-%m-%d %H:%M:%S")
Branch: $current_branch

## Codebase Patterns
(Patterns discovered during this run will be added here)

---

PROGRESS_EOF
            write_log "Progress file reset for new run"
        fi
    fi

    # Track current branch
    if [[ -f "$tasks_file" ]]; then
        local branch_name
        branch_name=$(jq -r '.branchName // ""' "$tasks_file" 2>/dev/null || echo "")
        if [[ -n "$branch_name" ]]; then
            printf '%s' "$branch_name" > "$workspace_root/.last-branch"
        fi
    fi
}

# --- Claude with timeout ---
invoke_claude_with_timeout() {
    local prompt="$1"
    local working_dir="$2"
    local timeout_seconds="$3"
    local transcript_path="${4:-}"

    _CLAUDE_OUTPUT=""
    _CLAUDE_EXIT_CODE=-1
    _CLAUDE_TIMED_OUT=false
    _CLAUDE_ERROR=""

    # Create temp files (unique to avoid collisions)
    local unique_id
    unique_id=$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)
    local prompt_file="$TMPDIR/claude_prompt_${unique_id}.txt"
    local output_file="$TMPDIR/claude_output_${unique_id}.txt"
    local exitcode_file="$TMPDIR/claude_exitcode_${unique_id}.txt"

    # Write prompt (no BOM issues on macOS)
    printf '%s' "$prompt" > "$prompt_file"

    # Find Claude executable
    local claude_path
    claude_path=$(which claude 2>/dev/null || echo "claude")
    write_log "Using Claude at: $claude_path"

    # Create wrapper script for execution
    local wrapper_script="$TMPDIR/claude_wrapper_${unique_id}.sh"
    cat > "$wrapper_script" << WRAPPER_EOF
#!/usr/bin/env bash
echo "=== Claude Task Started ==="
echo "Working Directory: $working_dir"
echo "Timeout: $timeout_seconds seconds"
echo "============================="
echo ""

cd "$working_dir"

# Run Claude with TRUE STREAMING - output displays as it happens
cat "$prompt_file" | "$claude_path" --dangerously-skip-permissions 2>&1 | tee "$output_file"
echo \$? > "$exitcode_file"

echo ""
echo "=== Claude Task Finished ==="
WRAPPER_EOF
    chmod +x "$wrapper_script"

    write_log "Launching Claude for task (timeout: ${timeout_seconds}s)..."

    # Run the wrapper in background
    bash "$wrapper_script" &
    local claude_pid=$!
    write_log "Claude started with PID: $claude_pid"

    # Wait with timeout
    local elapsed=0
    while kill -0 $claude_pid 2>/dev/null && [[ $elapsed -lt $timeout_seconds ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if kill -0 $claude_pid 2>/dev/null; then
        # Timed out - kill process group
        write_log "TIMEOUT after $timeout_seconds seconds - killing PID $claude_pid" "WARN"
        _CLAUDE_TIMED_OUT=true

        # Kill the process and its children (NEVER by name/age - only specific PID)
        kill -TERM $claude_pid 2>/dev/null || true
        sleep 2
        kill -9 $claude_pid 2>/dev/null || true

        _CLAUDE_EXIT_CODE=-1
        _CLAUDE_ERROR="Task timed out after $timeout_seconds seconds"
    else
        # Process completed - read exit code
        wait $claude_pid 2>/dev/null || true

        if [[ -f "$exitcode_file" ]]; then
            _CLAUDE_EXIT_CODE=$(cat "$exitcode_file" | tr -d '[:space:]')
        fi
    fi

    # Read captured output
    sleep 0.5
    if [[ -f "$output_file" ]]; then
        _CLAUDE_OUTPUT=$(cat "$output_file")
    fi

    # Save transcript if requested
    if [[ -n "$transcript_path" ]]; then
        cat > "$transcript_path" << TRANSCRIPT_EOF
================================================================================
CLAUDE SESSION TRANSCRIPT
================================================================================
Timestamp: $(date +"%Y-%m-%d %H:%M:%S")
Working Directory: $working_dir
Timeout: $timeout_seconds seconds
Timed Out: $_CLAUDE_TIMED_OUT
Exit Code: $_CLAUDE_EXIT_CODE

--- PROMPT ---
$prompt

--- OUTPUT ---
$_CLAUDE_OUTPUT

--- STDERR ---

================================================================================
TRANSCRIPT_EOF
        write_log "Transcript saved to: $transcript_path"
    fi

    # Clean up temp files
    rm -f "$prompt_file" "$output_file" "$exitcode_file" "$wrapper_script"
}

# --- Task verification ---
test_task_verification() {
    local workspace_root="$1"

    # Git-based verification: check if Claude actually changed anything
    invoke_native git -C "$workspace_root" status --porcelain
    local git_status="$_NATIVE_OUTPUT"
    local git_exit_code=$_NATIVE_EXIT_CODE

    if [[ $git_exit_code -ne 0 ]]; then
        write_log "VERIFICATION ERROR: git status failed (exit $git_exit_code): $git_status" "ERROR"
        _VERIFY_PASSED=false
        _VERIFY_REASON="git status failed -- not a git repo or git error"
        return
    fi

    # If git status output is empty, Claude made no changes
    if [[ -z "$(echo "$git_status" | tr -d '[:space:]')" ]]; then
        write_log "VERIFICATION FAILED: git status is clean -- no changes were made" "WARN"
        _VERIFY_PASSED=false
        _VERIFY_REASON="No changes detected in working tree (git status clean)"
        return
    fi

    # Changes exist -- verification passes
    local change_count
    change_count=$(echo "$git_status" | grep -c '.' || echo 0)
    write_log "VERIFICATION PASSED: $change_count file(s) changed in working tree"

    _VERIFY_PASSED=true
    _VERIFY_REASON=""
}

# --- Main Loop ---

# Workspace root is the parent of the directory containing the tasks file
workspace_root=$(cd "$(dirname "$tasks_file")/.." && pwd)
write_log "=== Execution Loop Started ===" "ITER"
write_log "Tasks file: $tasks_file"
write_log "Workspace root: $workspace_root"
write_log "Max iterations: $max_iterations"
write_log "Task timeout: $task_timeout_seconds seconds"
write_log "Quality checks: ${quality_checks[*]:-none}"

# Setup transcript directory
if [[ -z "$transcript_dir" ]]; then
    transcript_dir="$workspace_root/logs/transcripts"
fi
mkdir -p "$transcript_dir"
write_log "Transcripts will be saved to: $transcript_dir"

# Initialize archiving
initialize_archive "$workspace_root"

iteration=0
consecutive_failures=0
max_consecutive_failures=3
max_retry_per_task=2
total_tokens=0
total_cost=0

while [[ $iteration -lt $max_iterations ]]; do
    iteration=$((iteration + 1))
    write_log "--- Iteration $iteration of $max_iterations ---" "ITER"

    # Load current task state
    total_tasks=$(get_total_count)
    completed_count=$(get_completed_count)
    failed_count=$(get_failed_count)
    pending_count=$((total_tasks - completed_count - failed_count))

    write_log "Status: $completed_count completed, $failed_count failed, $pending_count pending"

    # Check if we're done
    if [[ $pending_count -eq 0 ]]; then
        write_log "All tasks processed!" "SUCCESS"
        break
    fi

    # Get next task
    task=$(get_next_pending_task)
    if [[ -z "$task" ]]; then
        write_log "No pending tasks found." "SUCCESS"
        break
    fi

    task_id=$(echo "$task" | jq -r '.id')
    task_title=$(echo "$task" | jq -r '.title')
    task_description=$(echo "$task" | jq -r '.description')
    task_file=$(echo "$task" | jq -r '.file // ""')
    task_acceptance=$(echo "$task" | jq -r '.acceptanceCriteria // [] | join("\n")')

    write_log "Working on task $task_id: $task_title" "ITER"

    # Track retry attempts
    task_retry_count=$(echo "$task" | jq -r '.retry_count // 0')
    task_last_failure=$(echo "$task" | jq -r '.last_failure // ""')

    # Build retry feedback section
    retry_section=""
    if [[ "$task_retry_count" -gt 0 && -n "$task_last_failure" ]]; then
        retry_section="

## IMPORTANT: Previous Attempt Failed

This is retry attempt $((task_retry_count + 1)). Your previous attempt claimed TASK_COMPLETE but verification failed:

**Failure reason:** $task_last_failure

You MUST actually create/modify the file. Do not just say you will - USE THE WRITE TOOL to create the file."
    fi

    # Build the prompt
    prompt="You are implementing a task from a PRD. Work autonomously until the task is complete.

## Current Task

**ID:** $task_id
**Title:** $task_title
**Description:** $task_description
**Target File:** $task_file
$retry_section

## Acceptance Criteria

$task_acceptance

## Instructions

1. Implement this task completely - ACTUALLY CREATE THE FILE using the Write tool
2. Test your implementation against the acceptance criteria
3. Write your code changes but do NOT commit. The orchestrator will commit after verification.
4. If you hit a blocker you cannot resolve, explain what's blocking you

Do NOT move to other tasks. Focus only on this one.

When done, output one of:
- \"TASK_COMPLETE\" if all acceptance criteria are met AND the file exists
- \"TASK_BLOCKED: <reason>\" if you cannot proceed
- \"TASK_BLOCKED: REPLAN_NEEDED\" if the pending tasks are architecturally invalid based on current codebase state"

    # Generate transcript filename
    transcript_file="$transcript_dir/task-${task_id}-$(date +%Y%m%d-%H%M%S).txt"

    # NOTE: No age-based process cleanup - that was THE BUG on Windows.
    # Process cleanup only happens via kill on specific PIDs during timeout.

    # Capture HEAD before task to detect phantom commits
    invoke_native git -C "$workspace_root" rev-parse HEAD
    pre_task_head=$(echo "$_NATIVE_OUTPUT" | tr -d '[:space:]')

    # Run Claude with timeout
    write_log "Executing Claude for task $task_id (timeout: ${task_timeout_seconds}s)..."

    set +e
    invoke_claude_with_timeout "$prompt" "$workspace_root" "$task_timeout_seconds" "$transcript_file"
    set -e

    claude_output="$_CLAUDE_OUTPUT"
    claude_exit_code="$_CLAUDE_EXIT_CODE"
    claude_timed_out="$_CLAUDE_TIMED_OUT"

    # Detect phantom commits: if Claude committed despite "do NOT commit" instruction
    invoke_native git -C "$workspace_root" rev-parse HEAD
    post_task_head=$(echo "$_NATIVE_OUTPUT" | tr -d '[:space:]')
    if [[ "$pre_task_head" != "$post_task_head" ]]; then
        write_log "PHANTOM COMMIT DETECTED: HEAD moved from $pre_task_head to $post_task_head" "WARN"
        write_log "Unrolling commit with git reset --mixed to restore orchestrator control..." "WARN"
        invoke_native git -C "$workspace_root" reset --mixed "$pre_task_head"
        write_log "Phantom commit unrolled. File changes preserved in working directory."
    fi

    # Log output (truncated)
    output_preview="${claude_output:0:500}"
    [[ ${#claude_output} -gt 500 ]] && output_preview="${output_preview}... [truncated]"
    write_log "Claude output: $output_preview"

    # Parse token usage
    get_claude_usage "$claude_output"
    if [[ "$_USAGE_TOTAL_TOKENS" -gt 0 ]]; then
        write_log "Token usage: $_USAGE_TOTAL_TOKENS tokens, cost: \$$_USAGE_COST"
    fi
    total_tokens=$((total_tokens + _USAGE_TOTAL_TOKENS))
    # Note: bash can't do float math natively, use awk for cost
    total_cost=$(awk "BEGIN {printf \"%.4f\", $total_cost + $_USAGE_COST}")

    # Determine task outcome
    task_completed=false
    task_blocked=false
    task_needs_retry=false
    block_reason=""
    retry_feedback=""

    if [[ "$claude_timed_out" == "true" ]]; then
        write_log "Task $task_id TIMED OUT after $task_timeout_seconds seconds" "ERROR"
        task_blocked=true
        block_reason="Task timed out after $task_timeout_seconds seconds. Check transcript: $transcript_file"

    elif echo "$claude_output" | grep -q "TASK_COMPLETE"; then
        # Verify the work was actually done
        test_task_verification "$workspace_root"
        if [[ "$_VERIFY_PASSED" == "true" ]]; then
            task_completed=true
            write_log "Task $task_id claims complete AND verification passed"
        else
            write_log "Task $task_id claimed TASK_COMPLETE but verification FAILED: $_VERIFY_REASON" "WARN"
            if [[ "$task_retry_count" -lt "$max_retry_per_task" ]]; then
                write_log "Will retry task $task_id (attempt $((task_retry_count + 1)) of $max_retry_per_task)" "WARN"
                task_needs_retry=true
                retry_feedback="$_VERIFY_REASON"
            else
                write_log "Task $task_id exceeded max retries, marking as failed" "ERROR"
                task_blocked=true
                block_reason="Verification failed after $max_retry_per_task retries: $_VERIFY_REASON"
            fi
        fi

    elif echo "$claude_output" | grep -q "TASK_BLOCKED:.*REPLAN_NEEDED"; then
        write_log "Task $task_id requests REPLAN -- tasks may be architecturally invalid" "WARN"
        # Output summary with replan flag and exit
        completed_count=$(get_completed_count)
        failed_count=$(get_failed_count)
        pending_count=$((total_tasks - completed_count - failed_count))
        jq -n \
            --argjson completed "$completed_count" \
            --argjson failed "$failed_count" \
            --argjson pending "$pending_count" \
            --argjson iterations_used "$iteration" \
            --argjson max_iterations "$max_iterations" \
            --argjson total_tokens "$total_tokens" \
            --arg total_cost_usd "$total_cost" \
            '{
                completed: $completed,
                failed: $failed,
                pending: $pending,
                iterations_used: $iterations_used,
                max_iterations: $max_iterations,
                replan_needed: true,
                total_tokens: $total_tokens,
                total_cost_usd: ($total_cost_usd | tonumber)
            }'
        exit 0

    elif echo "$claude_output" | grep -q "TASK_BLOCKED:"; then
        task_blocked=true
        block_reason=$(echo "$claude_output" | grep -oE 'TASK_BLOCKED:\s*(.+)' | head -1 | sed 's/TASK_BLOCKED:\s*//')

    elif [[ "$claude_exit_code" == "-99" ]]; then
        task_blocked=true
        block_reason="Claude execution threw an exception - check transcript"
        write_log "Task $task_id blocked due to exception" "ERROR"

    elif [[ "$claude_exit_code" != "0" ]]; then
        task_blocked=true
        block_reason="Claude exited with code $claude_exit_code"
    fi

    # Run quality checks if task completed
    if [[ "$task_completed" == "true" ]]; then
        invoke_quality_checks "$workspace_root"
        if [[ "$_QC_PASSED" != "true" ]]; then
            write_log "Task $task_id passed verification but FAILED quality checks" "WARN"
            if [[ "$task_retry_count" -lt "$max_retry_per_task" ]]; then
                task_needs_retry=true
                task_completed=false
                retry_feedback="$_QC_REASON"
            else
                task_blocked=true
                task_completed=false
                block_reason="Quality check failed after $max_retry_per_task retries: $_QC_REASON"
            fi
        fi
    fi

    # Orchestrator commits if task completed
    if [[ "$task_completed" == "true" ]]; then
        commit_msg="Task ${task_id}: $task_title"
        write_log "Orchestrator committing: $commit_msg"

        invoke_native git -C "$workspace_root" add .
        if [[ $_NATIVE_EXIT_CODE -ne 0 ]]; then
            write_log "Orchestrator git add FAILED (exit $_NATIVE_EXIT_CODE): $_NATIVE_OUTPUT" "ERROR"
            task_completed=false
            task_blocked=true
            block_reason="Orchestrator git add failed (exit $_NATIVE_EXIT_CODE)"
        else
            invoke_native git -C "$workspace_root" commit -m "$commit_msg"
            if [[ $_NATIVE_EXIT_CODE -ne 0 ]]; then
                write_log "Orchestrator commit FAILED (exit $_NATIVE_EXIT_CODE): $_NATIVE_OUTPUT" "ERROR"
                task_completed=false
                task_blocked=true
                block_reason="Orchestrator git commit failed (exit $_NATIVE_EXIT_CODE). Check for locked files or pre-commit hooks."
            else
                write_log "Orchestrator commit succeeded"
            fi
        fi
    fi

    # Update task status in JSON
    if [[ "$task_completed" == "true" ]]; then
        write_log "Task $task_id completed!" "SUCCESS"
        completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        tmp_file="${tasks_file}.tmp"
        jq --argjson id "$task_id" --arg completed_at "$completed_at" \
            '.tasks |= map(if .id == $id then .status = "completed" | .completed_at = $completed_at else . end)' \
            "$tasks_file" > "$tmp_file"
        mv "$tmp_file" "$tasks_file"
        consecutive_failures=0

        # Check if ALL tasks are now complete
        local all_pending
        all_pending=$(jq '[.tasks[] | select(.status != "completed")] | length' "$tasks_file")
        if [[ "$all_pending" -eq 0 ]]; then
            write_log "ALL TASKS COMPLETE!" "SUCCESS"
            echo "<promise>COMPLETE</promise>"
            write_log "<promise>COMPLETE</promise>" "SUCCESS"
            break
        fi

    elif [[ "$task_needs_retry" == "true" ]]; then
        write_log "Task $task_id needs retry, keeping as pending" "WARN"
        tmp_file="${tasks_file}.tmp"
        jq --argjson id "$task_id" --argjson retry "$((task_retry_count + 1))" --arg feedback "$retry_feedback" \
            '.tasks |= map(if .id == $id then .status = "pending" | .retry_count = $retry | .last_failure = $feedback else . end)' \
            "$tasks_file" > "$tmp_file"
        mv "$tmp_file" "$tasks_file"
        consecutive_failures=0

    elif [[ "$task_blocked" == "true" ]]; then
        write_log "Task $task_id blocked: $block_reason" "WARN"
        failed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        tmp_file="${tasks_file}.tmp"
        jq --argjson id "$task_id" --arg reason "$block_reason" --arg failed_at "$failed_at" --arg transcript "$transcript_file" \
            '.tasks |= map(if .id == $id then .status = "failed" | .failure_reason = $reason | .failed_at = $failed_at | .transcript = $transcript else . end)' \
            "$tasks_file" > "$tmp_file"
        mv "$tmp_file" "$tasks_file"
        consecutive_failures=$((consecutive_failures + 1))

        # Differentiate agent failures from orchestrator failures
        if echo "$block_reason" | grep -q "Orchestrator"; then
            write_log "Orchestrator commit failed. Preserving verified work in working tree." "WARN"
            write_log "ABORTING LOOP. Human intervention required to resolve mechanical Git state." "ERROR"
            break
        fi

        # Clean working tree after failed task (Dirty Tree Cascade fix)
        write_log "Cleaning working tree after failed task $task_id..." "WARN"
        invoke_native git -C "$workspace_root" reset --hard HEAD
        invoke_native git -C "$workspace_root" clean -fd
        write_log "Working tree cleaned (git reset --hard + git clean -fd)"
    else
        # Ambiguous outcome
        write_log "Task $task_id outcome unclear, keeping as pending" "WARN"
        consecutive_failures=$((consecutive_failures + 1))
    fi

    # Safety: bail if too many consecutive failures
    if [[ $consecutive_failures -ge $max_consecutive_failures ]]; then
        write_log "Too many consecutive failures ($consecutive_failures). Stopping." "ERROR"
        break
    fi

    # Brief pause between iterations
    sleep 2
done

# Final summary
completed_count=$(get_completed_count)
failed_count=$(get_failed_count)
total_tasks=$(get_total_count)
pending_count=$((total_tasks - completed_count - failed_count))

write_log "=== Execution Loop Finished ===" "ITER"
write_log "Final: $completed_count completed, $failed_count failed, $pending_count pending" "SUCCESS"
write_log "Iterations used: $iteration of $max_iterations"

# Output summary as JSON for caller
jq -n \
    --argjson completed "$completed_count" \
    --argjson failed "$failed_count" \
    --argjson pending "$pending_count" \
    --argjson iterations_used "$iteration" \
    --argjson max_iterations "$max_iterations" \
    --argjson total_tokens "$total_tokens" \
    --arg total_cost_usd "$total_cost" \
    '{
        completed: $completed,
        failed: $failed,
        pending: $pending,
        iterations_used: $iterations_used,
        max_iterations: $max_iterations,
        total_tokens: $total_tokens,
        total_cost_usd: ($total_cost_usd | tonumber)
    }'
