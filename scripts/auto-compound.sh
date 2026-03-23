#!/usr/bin/env bash
# auto-compound.sh
# Job 2: Full pipeline from priority report to PR (macOS/Linux)
#
# Usage: Launched via launch-auto-compound.sh (the ONLY correct way)
#   ./launch-auto-compound.sh --project-path "./your-project" --verbose
#
# Pipeline: preflight -> safety stash -> git reset -> report -> PRD -> validate PRD -> tasks -> implementation -> PR -> mark complete

set -euo pipefail
source "$(dirname "$0")/common.sh"

# --- Argument parsing ---
project_path="."
project_name=""
reports_dir="reports"
tasks_dir="tasks"
report_file="PRIORITIES.md"
max_iterations=25
dry_run=false
force_reset=false
allow_inline=false
resume=false
quality_checks=()
verbose=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-path)    project_path="$2"; shift 2 ;;
        --project-name)    project_name="$2"; shift 2 ;;
        --reports-dir)     reports_dir="$2"; shift 2 ;;
        --tasks-dir)       tasks_dir="$2"; shift 2 ;;
        --report-file)     report_file="$2"; shift 2 ;;
        --max-iterations)  max_iterations="$2"; shift 2 ;;
        --dry-run)         dry_run=true; shift ;;
        --force-reset)     force_reset=true; shift ;;
        --allow-inline)    allow_inline=true; shift ;;
        --resume)          resume=true; shift ;;
        --quality-checks)  IFS=',' read -ra quality_checks <<< "$2"; shift 2 ;;
        --verbose|-v)      verbose=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Resolve paths
project_path=$(cd "$project_path" && pwd)
scripts_dir="$(cd "$(dirname "$0")" && pwd)"
analyze_script="$scripts_dir/analyze-report.sh"
loop_script="$scripts_dir/loop.sh"
log_file="$project_path/logs/auto-compound.log"
state_file="$project_path/logs/pipeline-state.json"

# Ensure directories exist
logs_dir="$project_path/logs"
tasks_full_dir="$project_path/$tasks_dir"
mkdir -p "$logs_dir" "$tasks_full_dir"

# --- Logging ---
write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local log_line="[$timestamp] [$level] $message"
    echo "$log_line" >> "$log_file"

    if [[ "$verbose" == "true" || "$level" == "ERROR" || "$level" == "SUCCESS" || "$level" == "STAGE" ]]; then
        case "$level" in
            ERROR)   color_echo "$_CLR_RED" "$log_line" ;;
            WARN)    color_echo "$_CLR_YELLOW" "$log_line" ;;
            SUCCESS) color_echo "$_CLR_GREEN" "$log_line" ;;
            STAGE)   color_echo "$_CLR_CYAN" "$log_line" ;;
            *)       color_echo "$_CLR_WHITE" "$log_line" ;;
        esac
    fi
}

# --- Resume infrastructure ---
stage_order=("0" "1" "2" "3" "4" "4v" "5" "6" "7" "8" "9")
run_id=$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)
started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
pipeline_start_epoch=$(date +%s)
# Stage timings stored as a flat string "stage=seconds;stage=seconds;..."
# (bash 3.2 on macOS doesn't support associative arrays)
_stage_timings=""
resume_state=""

# State variables populated during pipeline
default_branch=""
branch_name=""
prd_path=""
tasks_path=""
analysis_priority_item=""
analysis_description=""
analysis_branch_name=""
analysis_reasoning=""

stage_start_epoch=0
start_stage_timer() { stage_start_epoch=$(date +%s); }
stop_stage_timer() {
    local stage="$1"
    local elapsed=$(( $(date +%s) - stage_start_epoch ))
    _stage_timings="${_stage_timings}${stage}=${elapsed};"
}

# Get timing for a stage from _stage_timings string
get_stage_timing() {
    local stage="$1"
    echo "$_stage_timings" | tr ';' '\n' | grep "^${stage}=" | cut -d= -f2
}

# Get index of a stage in stage_order
stage_index() {
    local target="$1"
    for i in "${!stage_order[@]}"; do
        if [[ "${stage_order[$i]}" == "$target" ]]; then
            echo "$i"
            return
        fi
    done
    echo "-1"
}

test_stage_complete() {
    local stage="$1"
    if [[ -z "$resume_state" ]]; then
        return 1  # false
    fi
    local last_completed
    last_completed=$(echo "$resume_state" | jq -r '.last_completed_stage // ""')
    local last_idx
    last_idx=$(stage_index "$last_completed")
    local current_idx
    current_idx=$(stage_index "$stage")
    [[ $current_idx -le $last_idx ]]
}

save_pipeline_state() {
    local completed_stage="$1"
    local elapsed=$(( $(date +%s) - pipeline_start_epoch ))

    # Build stage_timings JSON from flat string
    local timings_json="{"
    local first=true
    local IFS_OLD="$IFS"
    IFS=";"
    for entry in $_stage_timings; do
        if [[ -z "$entry" ]]; then continue; fi
        local key="${entry%%=*}"
        local val="${entry#*=}"
        if [[ "$first" == "true" ]]; then first=false; else timings_json+=","; fi
        timings_json+="\"$key\":$val"
    done
    IFS="$IFS_OLD"
    timings_json+="}"

    jq -n \
        --arg run_id "$run_id" \
        --arg started_at "$started_at" \
        --arg stage "$completed_stage" \
        --arg default_branch "$default_branch" \
        --arg priority_item "$analysis_priority_item" \
        --arg description "$analysis_description" \
        --arg branch_name "$branch_name" \
        --arg prd_path "$prd_path" \
        --arg tasks_path "$tasks_path" \
        --argjson stage_timings "$timings_json" \
        --argjson elapsed "$elapsed" \
        '{
            run_id: $run_id,
            started_at: $started_at,
            last_completed_stage: $stage,
            default_branch: $default_branch,
            priority_item: $priority_item,
            description: $description,
            branch_name: $branch_name,
            prd_path: $prd_path,
            tasks_path: $tasks_path,
            stage_timings: $stage_timings,
            elapsed_seconds: $elapsed
        }' > "$state_file"
    write_log "State saved: stage $completed_stage complete"
}

# --- Main Execution ---
write_log "=== Auto-Compound Started ===" "STAGE"
display_name="${project_name:-$(basename "$project_path")}"
write_log "Project: $display_name"
write_log "Path: $project_path"
write_log "Max iterations: $max_iterations"

pushd "$project_path" > /dev/null

cleanup() {
    popd > /dev/null 2>&1 || true
}
trap cleanup EXIT

# Track loop result for later stages
loop_result_completed=0
loop_result_failed=0
loop_result_pending=0
loop_result_iterations="0"
push_succeeded=false
gh_output=""

# --- Resume: load state and restore variables ---
if [[ "$resume" == "true" && -f "$state_file" ]]; then
    resume_state=$(cat "$state_file")
    run_id=$(echo "$resume_state" | jq -r '.run_id')
    started_at=$(echo "$resume_state" | jq -r '.started_at')
    write_log "RESUMING from after stage $(echo "$resume_state" | jq -r '.last_completed_stage') (run $run_id)" "STAGE"

    # Restore persisted variables
    default_branch=$(echo "$resume_state" | jq -r '.default_branch // ""')
    branch_name=$(echo "$resume_state" | jq -r '.branch_name // ""')
    prd_path=$(echo "$resume_state" | jq -r '.prd_path // ""')
    tasks_path=$(echo "$resume_state" | jq -r '.tasks_path // ""')
    analysis_priority_item=$(echo "$resume_state" | jq -r '.priority_item // ""')
    analysis_description=$(echo "$resume_state" | jq -r '.description // ""')
    analysis_branch_name="$branch_name"

    # Derived paths
    reports_full_dir="$project_path/$reports_dir"
    active_report="$reports_full_dir/$report_file"

    # Derive filenames from full paths
    [[ -n "$prd_path" ]] && prd_filename=$(basename "$prd_path")
    [[ -n "$tasks_path" ]] && tasks_filename=$(basename "$tasks_path")

    # If resuming past stage 3, checkout the existing feature branch
    last_stage_idx=$(stage_index "$(echo "$resume_state" | jq -r '.last_completed_stage')")
    stage3_idx=$(stage_index "3")
    if [[ $last_stage_idx -ge $stage3_idx && -n "$branch_name" ]]; then
        write_log "Resuming: checking out existing branch $branch_name"
        git checkout "$branch_name" 2>&1 || true
    fi

    # If resuming past stage 5, re-read tasks JSON
    stage5_idx=$(stage_index "5")
    if [[ $last_stage_idx -ge $stage5_idx && -n "$tasks_path" && -f "$tasks_path" ]]; then
        task_count=$(jq '.tasks | length' "$tasks_path")
        write_log "Resuming: loaded $task_count tasks from $tasks_path"
    fi

    # If resuming past stage 6, derive loop results from tasks JSON
    stage6_idx=$(stage_index "6")
    if [[ $last_stage_idx -ge $stage6_idx && -n "$tasks_path" && -f "$tasks_path" ]]; then
        loop_result_completed=$(jq '[.tasks[] | select(.status == "completed" or .status == "done")] | length' "$tasks_path")
        loop_result_failed=$(jq '[.tasks[] | select(.status == "failed")] | length' "$tasks_path")
        loop_result_pending=$(jq '[.tasks[] | select(.status == "pending")] | length' "$tasks_path")
        loop_result_iterations="resumed"
        write_log "Resuming: derived loop results ($loop_result_completed completed, $loop_result_failed failed, $loop_result_pending pending)"
    fi
elif [[ "$resume" == "true" ]]; then
    write_log "Resume requested but no state file found at $state_file. Starting fresh." "WARN"
fi

# ========================================
# STAGE 0: Preflight (BEFORE destructive reset)
# ========================================
if ! test_stage_complete "0"; then
    write_log "STAGE 0: Preflight" "STAGE"
    start_stage_timer

    # 0a. Enforce visible-window launch
    if [[ -z "${AGENT_RELAY_VISIBLE_LAUNCH:-}" && "$allow_inline" != "true" ]]; then
        write_log "Pipeline must be launched via launch-auto-compound.sh (not inline)." "ERROR"
        write_log "Run: ./launch-auto-compound.sh --project-path \"$project_path\" --verbose" "ERROR"
        write_log "Or use --allow-inline to override (not recommended)." "ERROR"
        exit 2
    fi

    # 0b. Must be a git repo
    if [[ ! -d "$project_path/.git" ]]; then
        write_log "Not a git repository: $project_path" "ERROR"
        exit 1
    fi

    # 0c. Auth preflight
    write_log "Checking Claude CLI authentication..."
    set +e
    auth_test=$(echo "ping" | claude --print 2>&1)
    auth_exit=$?
    set -e
    if [[ $auth_exit -ne 0 ]] || echo "$auth_test" | grep -qi "not logged in\|login"; then
        write_log "Claude auth failed. Run 'claude login' in your terminal, then relaunch." "ERROR"
        exit 1
    fi

    # 0d. Safety stash BEFORE any destructive git operations
    stash_timestamp=$(date +%Y%m%d-%H%M%S)
    stash_message="agent-relay-safety-$stash_timestamp"
    write_log "Safety stash: creating '$stash_message' before destructive operations"

    invoke_native git stash push --include-untracked -m "$stash_message"
    if [[ $_NATIVE_EXIT_CODE -ne 0 ]] && ! echo "$_NATIVE_OUTPUT" | grep -q "No local changes to save"; then
        write_log "Safety stash FAILED: $_NATIVE_OUTPUT" "ERROR"
        write_log "Aborting BEFORE destructive reset to protect uncommitted files." "ERROR"
        exit 1
    fi
    if echo "$_NATIVE_OUTPUT" | grep -q "No local changes to save"; then
        write_log "Safety stash: nothing to stash (clean tree confirmed)"
    else
        invoke_native git stash list --max-count=1
        write_log "Safety stash created: $_NATIVE_OUTPUT" "WARN"
        write_log "Recovery: git stash pop (or git stash apply)" "WARN"
    fi

    # 0d. Auto-clean gitignored build artifacts
    git clean -fdX 2>&1 > /dev/null || true

    # Ensure logs/ exists after cleaning
    mkdir -p "$logs_dir"

    # Check for tracked changes
    invoke_native git diff --name-only
    if [[ "$force_reset" != "true" && -n "$(echo "$_NATIVE_OUTPUT" | tr -d '[:space:]')" ]]; then
        write_log "Tracked file changes found. Aborting BEFORE destructive reset." "ERROR"
        write_log "Changed files: $_NATIVE_OUTPUT" "WARN"
        exit 1
    fi

    # Check for untracked non-ignored files
    invoke_native git ls-files --others --exclude-standard
    if [[ "$force_reset" != "true" && -n "$(echo "$_NATIVE_OUTPUT" | tr -d '[:space:]')" ]]; then
        write_log "Untracked non-ignored files found. Aborting BEFORE destructive reset." "ERROR"
        write_log "Untracked files: $_NATIVE_OUTPUT" "WARN"
        exit 1
    fi

    # 0e. Fetch from origin
    default_branch="main"
    invoke_native git fetch origin main
    if [[ $_NATIVE_EXIT_CODE -ne 0 ]]; then
        invoke_native git fetch origin master
        if [[ $_NATIVE_EXIT_CODE -ne 0 ]]; then
            write_log "Failed to fetch origin/main or origin/master" "ERROR"
            exit 1
        fi
        default_branch="master"
    fi
    write_log "Fetched origin/$default_branch"

    # 0f. Verify report exists on remote
    git_report_path="${reports_dir%/}/$report_file"
    invoke_native git show "origin/${default_branch}:${git_report_path}"
    if [[ $_NATIVE_EXIT_CODE -ne 0 ]]; then
        write_log "Report not found on origin/$default_branch at: $git_report_path" "ERROR"
        write_log "The report must be committed and pushed before launching the pipeline." "ERROR"
        write_log "Fix: git add $git_report_path && git commit -m 'Add priority report' && git push" "ERROR"
        exit 1
    fi

    # 0g. Check for open priorities
    tmp_report=$(mktemp)
    echo "$_NATIVE_OUTPUT" > "$tmp_report"

    write_log "Checking origin/${default_branch}:${git_report_path} for open priorities..."
    set +e
    preflight_json=$("$analyze_script" --report-path "$tmp_report")
    preflight_exit=$?
    set -e
    rm -f "$tmp_report"

    if [[ $preflight_exit -ne 0 ]]; then
        write_log "Failed to analyze priority report" "ERROR"
        exit 1
    fi

    preflight_priority=$(echo "$preflight_json" | jq -r '.priority_item // ""')
    if [[ -z "$preflight_priority" || "$preflight_priority" == "null" ]]; then
        write_log "All priorities are complete in $report_file. Nothing to build." "SUCCESS"
        write_log "To add new work: edit $git_report_path, commit, and push."
        exit 0
    fi

    write_log "Next priority: $preflight_priority" "SUCCESS"
    write_log "Preflight passed. Proceeding to build." "SUCCESS"

    stop_stage_timer "0"
    save_pipeline_state "0"
else
    write_log "STAGE 0: Preflight (skipped - resuming)" "STAGE"
fi

# ========================================
# STAGE 1: Git setup - destructive reset
# ========================================
if ! test_stage_complete "1"; then
    write_log "STAGE 1: Git setup (destructive reset)" "STAGE"
    start_stage_timer

    write_log "Resetting to origin/$default_branch..."
    git reset --hard "origin/$default_branch" 2>&1 > /dev/null || true
    git clean -fd 2>&1 > /dev/null || true
    git clean -fdX 2>&1 > /dev/null || true

    # Recreate logs/ IMMEDIATELY after cleans, before any Write-Log call
    mkdir -p "$logs_dir"

    write_log "Reset to origin/$default_branch. Clean slate established."

    stop_stage_timer "1"
    save_pipeline_state "1"
else
    write_log "STAGE 1: Git setup (skipped - resuming)" "STAGE"
fi

# ========================================
# STAGE 2: Load priority report (deterministic)
# ========================================
if ! test_stage_complete "2"; then
    write_log "STAGE 2: Load priority report" "STAGE"
    start_stage_timer

    reports_full_dir="$project_path/$reports_dir"
    active_report="$reports_full_dir/$report_file"

    if [[ ! -f "$active_report" ]]; then
        write_log "Report missing after reset: $active_report" "ERROR"
        exit 1
    fi

    write_log "Active report: $report_file"
    write_log "Analyzing report for #1 priority..."

    set +e
    analysis_json=$("$analyze_script" --report-path "$active_report")
    analysis_exit=$?
    set -e

    if [[ $analysis_exit -ne 0 ]]; then
        write_log "Failed to analyze priority report" "ERROR"
        exit 1
    fi

    analysis_priority_item=$(echo "$analysis_json" | jq -r '.priority_item // ""')
    analysis_description=$(echo "$analysis_json" | jq -r '.description // ""')
    analysis_branch_name=$(echo "$analysis_json" | jq -r '.branch_name // ""')
    analysis_reasoning=$(echo "$analysis_json" | jq -r '.reasoning // ""')

    if [[ -z "$analysis_priority_item" || "$analysis_priority_item" == "null" ]]; then
        write_log "All priorities complete in $report_file. Nothing to build." "SUCCESS"
        exit 0
    fi

    write_log "Priority item: $analysis_priority_item"
    write_log "Branch: $analysis_branch_name"

    if [[ "$dry_run" == "true" ]]; then
        write_log "DRY RUN - Would create branch and implement: $analysis_priority_item" "WARN"
        write_log "Analysis: $analysis_json"
        exit 0
    fi

    stop_stage_timer "2"
    save_pipeline_state "2"
else
    write_log "STAGE 2: Load priority report (skipped - resuming)" "STAGE"
fi

# ========================================
# STAGE 3: Create feature branch
# ========================================
if ! test_stage_complete "3"; then
    write_log "STAGE 3: Create feature branch" "STAGE"
    start_stage_timer

    branch_name="$analysis_branch_name"

    # Fallback if LLM returned empty branch name
    if [[ -z "$branch_name" ]]; then
        branch_name="feature/auto-build-$(date +%Y%m%d-%H%M%S)"
        write_log "Empty branch name from LLM, using fallback: $branch_name" "WARN"
    fi

    # Sanitize branch name
    branch_name=$(echo "$branch_name" | sed 's/[^a-zA-Z0-9/_-]/-/g')

    invoke_native git checkout -b "$branch_name"
    if [[ $_NATIVE_EXIT_CODE -ne 0 ]]; then
        # Branch might already exist
        invoke_native git checkout "$branch_name"
        if [[ $_NATIVE_EXIT_CODE -ne 0 ]]; then
            write_log "Failed to create or checkout branch: $branch_name" "ERROR"
            exit 1
        fi
        write_log "Branch already exists, checked out: $branch_name" "WARN"
    else
        write_log "Created branch: $branch_name"
    fi

    # Verify
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ "$current_branch" != "$branch_name" ]]; then
        write_log "Branch mismatch: expected $branch_name, got $current_branch" "ERROR"
        exit 1
    fi

    stop_stage_timer "3"
    save_pipeline_state "3"
else
    write_log "STAGE 3: Create feature branch (skipped - resuming)" "STAGE"
fi

# ========================================
# STAGE 4: Create PRD
# ========================================
if ! test_stage_complete "4"; then
    write_log "STAGE 4: Create PRD" "STAGE"
    start_stage_timer

    prd_filename="prd-$(echo "$branch_name" | sed 's/\//-/g').md"
    prd_path="$tasks_full_dir/$prd_filename"

    # Read prior post-mortems
    prior_learnings=""
    if [[ -d "$project_path/logs" ]]; then
        for pm_file in $(ls -t "$project_path/logs"/post-mortem-*.md 2>/dev/null | head -3); do
            pm_name=$(basename "$pm_file")
            pm_content=$(cat "$pm_file")
            prior_learnings+="
--- From: $pm_name ---
$pm_content
"
        done
    fi

    learnings_section=""
    if [[ -n "$prior_learnings" ]]; then
        learnings_section="

LESSONS FROM PRIOR BUILDS (incorporate relevant learnings):
$prior_learnings"
    fi

    prd_prompt="Create a detailed Product Requirements Document (PRD) for this feature:

**Feature:** $analysis_priority_item

**Description:** $analysis_description

**Context:** $analysis_reasoning

Write the PRD to: $prd_path

The PRD should include:
1. Overview - What we're building and why
2. Requirements - Specific, testable requirements
3. Acceptance Criteria - How we know it's done (be specific!)
4. Out of Scope - What we're NOT building
5. Technical Notes - Any implementation guidance

Make the acceptance criteria very specific and testable - the agent needs to be able to verify completion autonomously.
$learnings_section"

    write_log "Generating PRD..."
    printf '%s' "$prd_prompt" | claude --print --dangerously-skip-permissions 2>&1 > /dev/null || true

    if [[ ! -f "$prd_path" ]]; then
        write_log "PRD was not created at expected path: $prd_path" "ERROR"
        found_prd=$(ls -t "$tasks_full_dir"/prd-*.md 2>/dev/null | head -1)
        if [[ -n "$found_prd" ]]; then
            prd_path="$found_prd"
            write_log "Found PRD at: $prd_path" "WARN"
        else
            write_log "Could not find generated PRD" "ERROR"
            exit 1
        fi
    fi

    write_log "PRD created: $prd_path"

    stop_stage_timer "4"
    save_pipeline_state "4"
else
    write_log "STAGE 4: Create PRD (skipped - resuming)" "STAGE"
fi

# ========================================
# STAGE 4v: Validate PRD
# ========================================
if ! test_stage_complete "4v"; then
    write_log "STAGE 4v: Validate PRD" "STAGE"
    start_stage_timer

    prd_content=$(cat "$prd_path")

    validation_prompt="You are a PRD quality gate. Read the PRD below and validate it against these criteria:

1. Are acceptance criteria specific and machine-testable? (Not vague like \"works well\" or \"is fast\")
2. Are there missing requirements implied by the feature description that aren't captured in the PRD?
3. Is scope appropriately bounded? (Achievable in one overnight build session with ~25 task iterations)
4. Are there ambiguities that would cause an implementing agent to guess rather than know what to build?

PRD CONTENT:
$prd_content

Respond with EXACTLY one of these formats:
- If the PRD passes all checks, your FIRST line must be: PRD_VALID
- If there are issues, your FIRST line must be: PRD_ISSUES
  Then list each issue on its own numbered line.

Be strict but practical. Minor style issues are not grounds for rejection.
Focus on problems that would waste build time or produce wrong output."

    write_log "Validating PRD..."
    set +e
    validation_text=$(printf '%s' "$validation_prompt" | claude --print --dangerously-skip-permissions 2>&1)
    set -e

    if echo "$validation_text" | grep -q "PRD_VALID"; then
        write_log "PRD validation passed" "SUCCESS"
    else
        write_log "PRD validation found issues - regenerating with feedback" "WARN"

        regen_prompt="The PRD at $prd_path was reviewed and found to have issues. Regenerate it, fixing these problems:

CRITIC FEEDBACK:
$validation_text

ORIGINAL CONTEXT:
Feature: $analysis_priority_item
Description: $analysis_description

Write the improved PRD to: $prd_path

The PRD should include:
1. Overview - What we're building and why
2. Requirements - Specific, testable requirements
3. Acceptance Criteria - How we know it's done (be specific and machine-testable!)
4. Out of Scope - What we're NOT building
5. Technical Notes - Any implementation guidance

Fix every issue the critic identified. Make acceptance criteria specific and testable."

        write_log "Regenerating PRD with critic feedback..."
        printf '%s' "$regen_prompt" | claude --print --dangerously-skip-permissions 2>&1 > /dev/null || true

        # Second validation
        prd_content2=$(cat "$prd_path")
        validation_prompt2="You are a PRD quality gate. Read the PRD below and validate it against these criteria:

1. Are acceptance criteria specific and machine-testable?
2. Are there missing requirements implied by the feature description?
3. Is scope appropriately bounded for one overnight build session?
4. Are there ambiguities that would cause an implementing agent to guess?

PRD CONTENT:
$prd_content2

Respond with EXACTLY one of these formats:
- If the PRD passes: PRD_VALID (first line)
- If there are issues: PRD_ISSUES (first line), then numbered issues

Be strict but practical."

        set +e
        validation2_text=$(printf '%s' "$validation_prompt2" | claude --print --dangerously-skip-permissions 2>&1)
        set -e

        if echo "$validation2_text" | grep -q "PRD_VALID"; then
            write_log "PRD validation passed on retry" "SUCCESS"
        else
            write_log "PRD validation failed on retry - proceeding anyway (mediocre PRD > no run)" "WARN"
        fi
    fi

    stop_stage_timer "4v"
    save_pipeline_state "4v"
else
    write_log "STAGE 4v: Validate PRD (skipped - resuming)" "STAGE"
fi

# ========================================
# STAGE 5: Convert PRD to tasks
# ========================================
if ! test_stage_complete "5"; then
    write_log "STAGE 5: Convert PRD to tasks" "STAGE"
    start_stage_timer

    tasks_filename="tasks-$(echo "$branch_name" | sed 's/\//-/g').json"
    tasks_path="$tasks_full_dir/$tasks_filename"

    prd_content=$(cat "$prd_path")
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    tasks_prompt="TASK: Convert this PRD into a structured task list JSON file.

IMPORTANT: You MUST write the output to this exact file path:
$tasks_path

Read the PRD below, break it into small implementation tasks, and write the JSON file.

---

PRD CONTENT:
$prd_content

---

JSON FORMAT (write to $tasks_path):
{
  \"prd_source\": \"$prd_filename\",
  \"created_at\": \"$created_at\",
  \"tasks\": [
    {
      \"id\": 1,
      \"title\": \"Short task title\",
      \"description\": \"What to implement\",
      \"file\": \"path/to/primary_file.py\",
      \"acceptanceCriteria\": [
        \"Specific, testable criterion 1\",
        \"Specific, testable criterion 2\"
      ],
      \"status\": \"pending\"
    }
  ]
}

GUIDELINES:
- Break into 8-14 small, atomic tasks (prefer more smaller tasks over fewer large ones)
- Each task must specify EXACTLY one primary target file in the \"file\" field
- Each task should touch at most 2 files total (one source file + one test file)
- NEVER combine \"create new module\" with \"wire into existing API/imports\" in the same task
- Integration tasks (updating api.py routes, adding imports, RBAC allowlist) are ALWAYS a separate task
- Content-heavy tasks (templates, large test suites, config files) get their own task
- No task should produce more than ~200 lines of code or more than 12 test cases; split if larger
- If a task description exceeds 10 lines, it is too big -- split it
- acceptanceCriteria must be an array of strings, each verifiable without human input
- Order tasks logically (dependencies first)

Write the JSON file now."

    write_log "Generating tasks..."
    printf '%s' "$tasks_prompt" | claude --print --dangerously-skip-permissions 2>&1 > /dev/null || true

    if [[ ! -f "$tasks_path" ]]; then
        write_log "Tasks file was not created at expected path: $tasks_path" "ERROR"
        found_tasks=$(ls -t "$tasks_full_dir"/tasks-*.json 2>/dev/null | head -1)
        if [[ -n "$found_tasks" ]]; then
            tasks_path="$found_tasks"
            write_log "Found tasks at: $tasks_path" "WARN"
        else
            write_log "Could not find generated tasks file" "ERROR"
            exit 1
        fi
    fi

    task_count=$(jq '.tasks | length' "$tasks_path")
    write_log "Tasks created: $task_count tasks in $tasks_path"

    # Force all task statuses to "pending"
    tmp_file="${tasks_path}.tmp"
    jq '.tasks |= map(.status = "pending")' "$tasks_path" > "$tmp_file"
    mv "$tmp_file" "$tasks_path"
    write_log "Validated: all $task_count task statuses set to 'pending'"

    stop_stage_timer "5"
    save_pipeline_state "5"
else
    write_log "STAGE 5: Convert PRD to tasks (skipped - resuming)" "STAGE"
fi

# ========================================
# STAGE 6: Run execution loop
# ========================================
if ! test_stage_complete "6"; then
    write_log "STAGE 6: Execute tasks" "STAGE"
    start_stage_timer

    max_replans=2
    replan_count=0
    cumulative_tokens=0
    cumulative_cost=0

    needs_replan=true
    while [[ "$needs_replan" == "true" ]]; do
        needs_replan=false

        if [[ $replan_count -gt 0 ]]; then
            write_log "REPLAN $replan_count of $max_replans: Regenerating tasks from current codebase state..." "STAGE"

            prd_content=$(cat "$prd_path")
            tasks_filename="tasks-$(echo "$branch_name" | sed 's/\//-/g').json"
            tasks_path="$tasks_full_dir/$tasks_filename"
            created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

            replan_prompt="TASK: Convert this PRD into a structured task list JSON file.

IMPORTANT: You MUST write the output to this exact file path:
$tasks_path

The codebase has been PARTIALLY IMPLEMENTED. Read the current state of the code before generating tasks.
Only generate tasks for work that STILL NEEDS TO BE DONE based on the current codebase state.

---

PRD CONTENT:
$prd_content

---

JSON FORMAT (write to $tasks_path):
{
  \"prd_source\": \"$prd_filename\",
  \"created_at\": \"$created_at\",
  \"tasks\": [
    {
      \"id\": 1,
      \"title\": \"Short task title\",
      \"description\": \"What to implement\",
      \"file\": \"path/to/primary_file.py\",
      \"acceptanceCriteria\": [
        \"Specific, testable criterion 1\",
        \"Specific, testable criterion 2\"
      ],
      \"status\": \"pending\"
    }
  ]
}

GUIDELINES:
- Break into 8-14 small, atomic tasks
- Each task must specify EXACTLY one primary target file
- Each task should touch at most 2 files total
- acceptanceCriteria must be an array of strings
- Order tasks logically (dependencies first)
- ONLY include tasks for work not yet completed in the codebase

Write the JSON file now."

            write_log "Regenerating tasks..."
            replan_log_file="$logs_dir/replan-$replan_count.log"
            printf '%s' "$replan_prompt" | claude --dangerously-skip-permissions 2>&1 | tee "$replan_log_file" > /dev/null || true

            if [[ -f "$tasks_path" ]]; then
                tmp_file="${tasks_path}.tmp"
                jq '.tasks |= map(.status = "pending")' "$tasks_path" > "$tmp_file"
                mv "$tmp_file" "$tasks_path"
                new_task_count=$(jq '.tasks | length' "$tasks_path")
                write_log "Replan generated $new_task_count new tasks"
            else
                write_log "Replan failed: tasks file not created. Proceeding with remaining tasks." "WARN"
                break
            fi
        fi

        write_log "Starting execution loop (max $max_iterations iterations)..."

        loop_args="--tasks-file \"$tasks_path\" --max-iterations $max_iterations"
        if [[ ${#quality_checks[@]} -gt 0 ]]; then
            loop_args+=" --quality-checks $(IFS=','; echo "${quality_checks[*]}")"
        fi
        [[ "$verbose" == "true" ]] && loop_args+=" --verbose"

        set +e
        loop_output=$(eval "\"$loop_script\" $loop_args")
        loop_exit=$?
        set -e

        # Parse the JSON summary — find the last valid JSON object in stdout
        # loop.sh sends logs to stderr (via color_echo) and JSON to stdout
        loop_json=""
        while IFS= read -r line; do
            if echo "$line" | jq -e '.' > /dev/null 2>&1; then
                loop_json="$line"
            fi
        done <<< "$loop_output"

        # Fallback: if we couldn't find JSON in stdout, derive from tasks file
        if [[ -z "$loop_json" ]] && [[ -f "$tasks_path" ]]; then
            write_log "Could not parse loop JSON output, deriving results from tasks file" "WARN"
            loop_result_completed=$(jq '[.tasks[] | select(.status == "completed")] | length' "$tasks_path")
            loop_result_failed=$(jq '[.tasks[] | select(.status == "failed")] | length' "$tasks_path")
            loop_result_pending=$(jq '[.tasks[] | select(.status == "pending")] | length' "$tasks_path")
            loop_result_iterations="unknown"
            write_log "Derived: $loop_result_completed completed, $loop_result_failed failed, $loop_result_pending pending"
        fi

        if [[ -n "$loop_json" ]] && echo "$loop_json" | jq -e '.' > /dev/null 2>&1; then
            loop_result_completed=$(echo "$loop_json" | jq -r '.completed // 0')
            loop_result_failed=$(echo "$loop_json" | jq -r '.failed // 0')
            loop_result_pending=$(echo "$loop_json" | jq -r '.pending // 0')
            loop_result_iterations=$(echo "$loop_json" | jq -r '.iterations_used // 0')

            write_log "Loop complete: $loop_result_completed completed, $loop_result_failed failed, $loop_result_pending pending"

            # Accumulate tokens/cost
            loop_tokens=$(echo "$loop_json" | jq -r '.total_tokens // 0')
            loop_cost=$(echo "$loop_json" | jq -r '.total_cost_usd // 0')
            cumulative_tokens=$((cumulative_tokens + loop_tokens))
            cumulative_cost=$(awk "BEGIN {printf \"%.4f\", $cumulative_cost + $loop_cost}")

            # Check if replan was requested
            replan_flag=$(echo "$loop_json" | jq -r '.replan_needed // false')
            if [[ "$replan_flag" == "true" ]]; then
                replan_count=$((replan_count + 1))
                if [[ $replan_count -le $max_replans ]]; then
                    write_log "Replan requested by execution loop (replan $replan_count of $max_replans)" "WARN"
                    needs_replan=true
                else
                    write_log "Replan requested but max replans ($max_replans) exceeded." "WARN"
                fi
            fi
        else
            write_log "Could not parse loop output as JSON" "WARN"
        fi
    done

    stop_stage_timer "6"
    save_pipeline_state "6"
else
    write_log "STAGE 6: Execute tasks (skipped - resuming)" "STAGE"
fi

# Gate: skip Stages 7-9 if no tasks completed
if [[ "$loop_result_completed" -eq 0 ]]; then
    write_log "No tasks completed. Skipping Stages 7-9. State preserved for resume." "ERROR"
    save_pipeline_state "6"
    exit 1
fi

# ========================================
# STAGE 7: Create PR
# ========================================
if ! test_stage_complete "7"; then
    write_log "STAGE 7: Create PR" "STAGE"
    start_stage_timer

    has_remote=$(git remote 2>/dev/null || echo "")
    push_succeeded=false

    if [[ -n "$has_remote" ]]; then
        invoke_native git push -u origin "$branch_name"
        if [[ $_NATIVE_EXIT_CODE -eq 0 ]]; then
            write_log "Branch pushed: $branch_name"
            push_succeeded=true
        else
            write_log "Failed to push branch (exit $_NATIVE_EXIT_CODE): $_NATIVE_OUTPUT" "WARN"
        fi
    else
        write_log "No remote configured, skipping push" "WARN"
    fi

    # Build PR body
    pr_body="## Summary

Automated implementation of: **$analysis_priority_item**

$analysis_description

## Implementation Stats

- Tasks completed: $loop_result_completed
- Tasks failed: $loop_result_failed
- Tasks pending: $loop_result_pending
- Iterations used: $loop_result_iterations / $max_iterations

## Source

- Priority report: \`$report_file\`
- PRD: \`${prd_filename:-unknown}\`
- Tasks: \`${tasks_filename:-unknown}\`

---

*Generated by Auto-Compound at $(date +"%Y-%m-%d %H:%M")*"

    # Create draft PR
    gh_output=""
    if [[ -n "$has_remote" && "$push_succeeded" == "true" ]]; then
        pr_title="Compound: $analysis_priority_item"

        pr_body_file=$(mktemp)
        echo "$pr_body" > "$pr_body_file"

        invoke_native gh pr create --draft --title "$pr_title" --body-file "$pr_body_file" --base "$default_branch"
        if [[ $_NATIVE_EXIT_CODE -eq 0 ]]; then
            gh_output="$_NATIVE_OUTPUT"
            write_log "PR created: $gh_output" "SUCCESS"
        else
            write_log "Failed to create PR (exit $_NATIVE_EXIT_CODE): $_NATIVE_OUTPUT" "WARN"
            write_log "Branch pushed but PR creation failed. Create manually."
        fi

        rm -f "$pr_body_file"
    elif [[ -n "$has_remote" && "$push_succeeded" != "true" ]]; then
        write_log "Skipping PR creation - push failed" "WARN"
    else
        write_log "No remote configured, skipping PR creation" "WARN"
        write_log "Changes committed to branch: $branch_name" "SUCCESS"
    fi

    stop_stage_timer "7"
    save_pipeline_state "7"
else
    write_log "STAGE 7: Create PR (skipped - resuming)" "STAGE"
fi

# ========================================
# STAGE 8: Mark priority complete in report
# ========================================
write_log "STAGE 8: Mark priority complete" "STAGE"
start_stage_timer

# Gate: only mark complete if ALL tasks succeeded
total_tasks=$((loop_result_completed + loop_result_failed + loop_result_pending))
if [[ $total_tasks -gt 0 && $loop_result_completed -lt $total_tasks ]]; then
    write_log "Priority incomplete ($loop_result_completed/$total_tasks tasks completed). Needs remediation." "WARN"
    write_log "PR was created for partial work. Fix failed tasks, then mark complete manually." "WARN"
    stop_stage_timer "8"
    save_pipeline_state "8"
    exit 1
fi

# Ensure has_remote is set (may not be if Stage 7 was skipped via resume)
has_remote="${has_remote:-$(git remote 2>/dev/null || echo "")}"

# Switch to main/master to update the priority report
invoke_native git checkout "$default_branch"
if [[ -n "$has_remote" ]]; then
    invoke_native git pull origin "$default_branch"
fi

if [[ $_NATIVE_EXIT_CODE -ne 0 ]]; then
    write_log "Could not switch to $default_branch to mark priority complete" "WARN"
else
    report_path="$reports_full_dir/$report_file"
    if [[ -f "$report_path" ]]; then
        # Extract PR number from gh output
        pr_number=""
        if [[ -n "$gh_output" ]]; then
            pr_number=$(echo "$gh_output" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
            if [[ -z "$pr_number" ]]; then
                pr_number=$(echo "$gh_output" | grep -oE '/pull/[0-9]+' | head -1 | sed 's/\/pull\///')
            fi
        fi

        # Build completion note
        if [[ -n "$pr_number" ]]; then
            completion_note="Merged via PR #$pr_number. Branch: \`$branch_name\`."
        else
            completion_note="Branch: \`$branch_name\`."
        fi

        # Extract priority ID (e.g., "P08" from "P08 - Wider Monte Carlo")
        priority_id=""
        if [[ "$analysis_priority_item" =~ (P[0-9]+) ]]; then
            priority_id="${BASH_REMATCH[1]}"
        fi

        if [[ -z "$priority_id" ]]; then
            write_log "Could not extract priority ID (e.g. P08) from: $analysis_priority_item" "WARN"
        fi

        # Mark heading as complete using perl (handles multiline regex)
        if [[ -n "$priority_id" ]]; then
            perl -0777 -i -pe "s/(## )(Priority \\d+ \\[$priority_id[^\\]]*\\]: [^\\n]*)\\n\\n/\$1~~\$2~~ COMPLETE\\n\\n$completion_note\\n\\n/s" "$report_path" 2>/dev/null

            # Commit and push
            invoke_native git add "$report_path"
            invoke_native git commit -m "Mark $analysis_priority_item complete"
            if [[ -n "$has_remote" ]]; then
                invoke_native git push origin "$default_branch"
                if [[ $_NATIVE_EXIT_CODE -eq 0 ]]; then
                    write_log "Priority marked complete in report and pushed to $default_branch" "SUCCESS"
                else
                    write_log "Priority marked complete locally but push failed" "WARN"
                fi
            else
                write_log "Priority marked complete in report" "SUCCESS"
            fi
        else
            write_log "Could not find priority heading to mark complete (may already be marked)" "WARN"
        fi
    else
        write_log "Report file not found at $report_path" "WARN"
    fi
fi
stop_stage_timer "8"

# ========================================
# STAGE 9: Post-Mortem (Analyst Pattern)
# ========================================
if ! test_stage_complete "9"; then
    write_log "STAGE 9: Post-Mortem (Analyst)" "STAGE"
    start_stage_timer

    post_mortem_date=$(date +%Y-%m-%d)
    post_mortem_path="$project_path/logs/post-mortem-$post_mortem_date.md"

    # Gather summarized context
    task_summary=""
    if [[ -n "$tasks_path" && -f "$tasks_path" ]]; then
        task_summary=$(jq -r '.tasks[] | "  Task \(.id): \(.title) -- \(.status)\(if .failure_reason then " (\(.failure_reason | gsub("Check transcript:.*";"timeout")))" else "" end)"' "$tasks_path" 2>/dev/null || echo "")
    fi

    # Read synthesis from most recent prior post-mortem
    prior_synthesis=""
    prior_pm=$(ls -t "$project_path/logs"/post-mortem-*.md 2>/dev/null | grep -v "$post_mortem_date" | head -1)
    if [[ -n "$prior_pm" ]]; then
        pm_name=$(basename "$prior_pm")
        pm_content=$(cat "$prior_pm")
        if echo "$pm_content" | grep -q "## 5\. Synthesis"; then
            prior_synthesis="Prior build ($pm_name) synthesis:
$(echo "$pm_content" | sed -n '/## 5\. Synthesis/,$p')"
        fi
    fi

    elapsed_total=$(( $(date +%s) - pipeline_start_epoch ))
    duration_str=$(printf '%02d:%02d:%02d' $((elapsed_total/3600)) $(((elapsed_total%3600)/60)) $((elapsed_total%60)))

    post_mortem_prompt="You are the Analyst -- a reflective agent that runs AFTER execution to extract compounding learnings.

Write a five-point post-mortem for tonight's build. Output ONLY the markdown content -- no preamble, no commentary.

CONTEXT:
- Priority item: $analysis_priority_item
- Description: $analysis_description
- Branch: $branch_name
- Tasks completed: $loop_result_completed
- Tasks failed: $loop_result_failed
- Tasks pending: $loop_result_pending
- Iterations used: $loop_result_iterations / $max_iterations
- Total duration: $duration_str

TASK RESULTS:
$task_summary

$prior_synthesis

OUTPUT FORMAT (keep each section to 2-4 sentences):

# Post-Mortem: $analysis_priority_item
Date: $post_mortem_date

## 1. Intent vs. Implementation Gap
Did the build match the PRD? Where did implementation diverge from requirements?

## 2. What Caused What (Ablation)
Which specific tasks or decisions caused which outcomes? What would we remove/change?

## 3. Expectation vs. Reality
What did we expect to happen vs. what actually happened? Task completion rate, failures, surprises.

## 4. Mechanistic Explanation
Why did things work or fail? Root causes, not symptoms.

## 5. Synthesis & Next Steps
What to preserve, what to discard, what to try differently tomorrow night. If prior post-mortems show recurring patterns, call them out."

    write_log "Running post-mortem analysis..."
    # Timeout after 120 seconds to prevent Stage 9 from hanging
    set +e
    post_mortem_output=$(printf '%s' "$post_mortem_prompt" | timeout 120 claude --print 2>&1 || true)
    set -e

    if [[ -n "$post_mortem_output" ]]; then
        echo "$post_mortem_output" > "$post_mortem_path"
        write_log "Post-mortem saved: $post_mortem_path" "SUCCESS"
    else
        write_log "Post-mortem generation timed out or returned empty (non-critical)" "WARN"
    fi

    stop_stage_timer "9"
    save_pipeline_state "9"
else
    write_log "STAGE 9: Post-Mortem (skipped - resuming)" "STAGE"
fi

# --- Duration summary ---
elapsed_total=$(( $(date +%s) - pipeline_start_epoch ))
duration_str=$(printf '%02d:%02d:%02d' $((elapsed_total/3600)) $(((elapsed_total%3600)/60)) $((elapsed_total%60)))
write_log "Total duration: $duration_str" "SUCCESS"

for stage in "${stage_order[@]}"; do
    local timing
    timing=$(get_stage_timing "$stage")
    if [[ -n "$timing" ]]; then
        mins=$(awk "BEGIN {printf \"%.1f\", $timing / 60}")
        write_log "  Stage $stage: ${mins}m"
    fi
done

# --- Persist build-history.csv ---
history_file="$project_path/logs/build-history.csv"
if [[ ! -f "$history_file" ]]; then
    echo "date,priority,duration_seconds,completed,failed,pending,iterations,branch,tokens,cost_usd" > "$history_file"
fi
history_date=$(date +"%Y-%m-%d %H:%M:%S")
echo "$history_date,$analysis_priority_item,$elapsed_total,$loop_result_completed,$loop_result_failed,$loop_result_pending,$loop_result_iterations,$branch_name,${cumulative_tokens:-0},${cumulative_cost:-0}" >> "$history_file"
write_log "Build history appended to $history_file"

# Clean up state file on successful completion
if [[ -f "$state_file" ]]; then
    rm -f "$state_file"
    write_log "Pipeline state file cleaned up (successful completion)"
fi

write_log "=== Auto-Compound Complete ===" "SUCCESS"

# Output summary
jq -n \
    --arg priority "$analysis_priority_item" \
    --arg branch "$branch_name" \
    --argjson completed "$loop_result_completed" \
    --argjson failed "$loop_result_failed" \
    --argjson pending "$loop_result_pending" \
    --arg iterations "$loop_result_iterations" \
    --argjson pr_created "$(if [[ "$push_succeeded" == "true" && -n "$gh_output" ]]; then echo true; else echo false; fi)" \
    --argjson duration "$elapsed_total" \
    --argjson tokens "${cumulative_tokens:-0}" \
    --arg cost "${cumulative_cost:-0}" \
    '{
        priority_item: $priority,
        branch: $branch,
        tasks_completed: $completed,
        tasks_failed: $failed,
        tasks_pending: $pending,
        iterations_used: $iterations,
        pr_created: $pr_created,
        duration_seconds: $duration,
        total_tokens: $tokens,
        total_cost_usd: ($cost | tonumber)
    }'
