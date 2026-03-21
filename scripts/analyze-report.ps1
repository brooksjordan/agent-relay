# analyze-report.ps1
# Analyzes a priority report and extracts the #1 priority item
#
# Usage: .\analyze-report.ps1 -ReportPath "reports/priority-2026-01-30.md"
# Output: JSON with priority_item, branch_name, description

param(
    [Parameter(Mandatory=$true)]
    [string]$ReportPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ReportPath)) {
    Write-Error "Report not found: $ReportPath"
    exit 1
}

$reportContent = Get-Content $ReportPath -Raw

# Use XML fence strategy for reliable JSON extraction
$prompt = @"
Analyze this priority report and extract the #1 (highest priority) item.

REPORT:
$reportContent

---

INSTRUCTIONS:
1. Find the FIRST priority that is NOT marked COMPLETE. Priorities are numbered (P11, P12, ... P23, P24, etc.). Completed priorities have "COMPLETE" in their heading or are struck through with ~~. The FIRST priority whose heading does NOT contain "COMPLETE" or strikethrough is the one to extract. Do NOT skip ahead to later priorities.
2. Create a JSON object with the extracted information
3. IMPORTANT: Wrap your JSON output inside <json_output> tags
4. The JSON must be valid and complete

Output format (wrap in tags exactly like this):
<json_output>
{
  "priority_item": "Brief title of the #1 priority",
  "description": "Full description from the report",
  "branch_name": "feature/kebab-case-branch-name",
  "reasoning": "Why this is the top priority"
}
</json_output>

Rules for branch_name:
- Use kebab-case (lowercase with hyphens)
- Prefix with feature/, fix/, or refactor/ as appropriate
- Keep it short but descriptive (e.g., feature/product-catalog-page)
- No special characters except hyphens
"@

# Call Claude to analyze (pipe prompt via stdin, --print is a flag not an arg)
$result = $prompt | & claude --print --dangerously-skip-permissions 2>&1
$resultText = $result -join "`n"

# Extract JSON from XML tags using single-line regex mode
if ($resultText -match '(?s)<json_output>(?<content>.*?)</json_output>') {
    $jsonString = $Matches['content'].Trim()

    # Strip markdown backtick fences if Claude wrapped JSON in ```json ... ```
    $jsonString = $jsonString -replace '```json', '' -replace '```', ''
    $jsonString = $jsonString.Trim()

    try {
        $parsed = $jsonString | ConvertFrom-Json

        # Create output with defaults for any missing fields
        $output = @{
            priority_item = if ($parsed.priority_item) { $parsed.priority_item } else { "Unknown priority" }
            description = if ($parsed.description) { $parsed.description } else { $parsed.priority_item }
            branch_name = if ($parsed.branch_name) { $parsed.branch_name } else { "feature/auto-compound-$(Get-Date -Format 'yyyyMMdd')" }
            reasoning = if ($parsed.reasoning) { $parsed.reasoning } else { "Top priority from report" }
            source_report = $ReportPath
            analyzed_at = (Get-Date).ToString("o")
        }

        $output | ConvertTo-Json -Depth 3
    } catch {
        Write-Error "Found tags but content was not valid JSON: $jsonString"
        exit 1
    }
} else {
    # Fallback: try to find raw JSON if tags weren't used
    if ($resultText -match '(?s)\{[^{}]*"priority_item"[^{}]*\}') {
        $jsonString = $Matches[0]
        # Strip markdown backtick fences just in case
        $jsonString = $jsonString -replace '```json', '' -replace '```', ''
        $jsonString = $jsonString.Trim()
        try {
            $parsed = $jsonString | ConvertFrom-Json
            $output = @{
                priority_item = if ($parsed.priority_item) { $parsed.priority_item } else { "Unknown priority" }
                description = if ($parsed.description) { $parsed.description } else { $parsed.priority_item }
                branch_name = if ($parsed.branch_name) { $parsed.branch_name } else { "feature/auto-compound-$(Get-Date -Format 'yyyyMMdd')" }
                reasoning = if ($parsed.reasoning) { $parsed.reasoning } else { "Top priority from report" }
                source_report = $ReportPath
                analyzed_at = (Get-Date).ToString("o")
            }
            $output | ConvertTo-Json -Depth 3
        } catch {
            Write-Error "Failed to parse JSON: $jsonString"
            exit 1
        }
    } else {
        Write-Error "Could not find <json_output> tags or valid JSON in Claude's response."
        Write-Error "Response was: $resultText"
        exit 1
    }
}
