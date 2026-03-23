#!/usr/bin/env bash
# analyze-report.sh
# Analyzes a priority report and extracts the #1 priority item
#
# Usage: ./analyze-report.sh --report-path "reports/PRIORITIES.md"
# Output: JSON with priority_item, branch_name, description

set -euo pipefail
source "$(dirname "$0")/common.sh"

# --- Argument parsing ---
report_path=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --report-path) report_path="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$report_path" ]]; then
    echo "ERROR: --report-path is required" >&2
    exit 1
fi

if [[ ! -f "$report_path" ]]; then
    echo "ERROR: Report not found: $report_path" >&2
    exit 1
fi

report_content=$(cat "$report_path")

# Build prompt with XML fence strategy for reliable JSON extraction
prompt="Analyze this priority report and extract the #1 (highest priority) item.

REPORT:
${report_content}

---

INSTRUCTIONS:
1. Find the FIRST priority that is NOT marked COMPLETE. Priorities are numbered (P11, P12, ... P23, P24, etc.). Completed priorities have \"COMPLETE\" in their heading or are struck through with ~~. The FIRST priority whose heading does NOT contain \"COMPLETE\" or strikethrough is the one to extract. Do NOT skip ahead to later priorities.
2. Create a JSON object with the extracted information
3. IMPORTANT: Wrap your JSON output inside <json_output> tags
4. The JSON must be valid and complete

Output format (wrap in tags exactly like this):
<json_output>
{
  \"priority_item\": \"Brief title of the #1 priority\",
  \"description\": \"Full description from the report\",
  \"branch_name\": \"feature/kebab-case-branch-name\",
  \"reasoning\": \"Why this is the top priority\"
}
</json_output>

Rules for branch_name:
- Use kebab-case (lowercase with hyphens)
- Prefix with feature/, fix/, or refactor/ as appropriate
- Keep it short but descriptive (e.g., feature/product-catalog-page)
- No special characters except hyphens"

# Call Claude to analyze (pipe prompt via stdin, --print is a flag not an arg)
set +e
result_text=$(printf '%s' "$prompt" | claude --print --dangerously-skip-permissions 2>&1)
claude_exit=$?
set -e

if [[ $claude_exit -ne 0 ]]; then
    echo "ERROR: Claude CLI failed with exit code $claude_exit" >&2
    exit 1
fi

# Extract JSON from <json_output> tags
json_string=""

if printf '%s' "$result_text" | grep -q '<json_output>'; then
    # Extract content between tags using perl (handles multiline)
    json_string=$(printf '%s' "$result_text" | perl -0777 -ne 'print $1 if /<json_output>\s*(.*?)\s*<\/json_output>/s')
elif printf '%s' "$result_text" | grep -q '"priority_item"'; then
    # Fallback: try to find raw JSON with priority_item
    json_string=$(printf '%s' "$result_text" | perl -0777 -ne 'print $1 if /(\{[^{}]*"priority_item"[^{}]*\})/s')
else
    echo "ERROR: Could not find <json_output> tags or valid JSON in Claude's response." >&2
    echo "Response was: $result_text" >&2
    exit 1
fi

# Strip markdown backtick fences if present
json_string=$(printf '%s' "$json_string" | sed 's/```json//g' | sed 's/```//g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

# Validate JSON with jq
if ! printf '%s' "$json_string" | jq -e '.' > /dev/null 2>&1; then
    echo "ERROR: Found tags but content was not valid JSON: $json_string" >&2
    exit 1
fi

# Build output with defaults for missing fields
analyzed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
fallback_branch="feature/auto-compound-$(date +%Y%m%d)"

printf '%s' "$json_string" | jq \
    --arg source_report "$report_path" \
    --arg analyzed_at "$analyzed_at" \
    --arg fallback_branch "$fallback_branch" \
    '{
        priority_item: (if .priority_item and .priority_item != "" then .priority_item else "Unknown priority" end),
        description: (if .description and .description != "" then .description else (.priority_item // "Unknown") end),
        branch_name: (if .branch_name and .branch_name != "" then .branch_name else $fallback_branch end),
        reasoning: (if .reasoning and .reasoning != "" then .reasoning else "Top priority from report" end),
        source_report: $source_report,
        analyzed_at: $analyzed_at
    }'
