# analyze-report.ps1
# Analyzes a priority report and extracts the next priority item to work on.
# Deterministically strips completed priorities BEFORE sending to Claude.
#
# Usage: .\analyze-report.ps1 -ReportPath "reports/priority-2026-01-30.md"
# Output: JSON with priority_item, branch_name, description

param(
    [Parameter(Mandatory=$true)]
    [string]$ReportPath,

    [Parameter(Mandatory=$false)]
    [string[]]$CompletedBranches = @()
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ReportPath)) {
    Write-Error "Report not found: $ReportPath"
    exit 1
}

$reportContent = Get-Content $ReportPath -Raw

# ============================================================
# DETERMINISTIC PRE-FILTER: Strip completed priorities before
# sending to Claude. This ensures Claude only sees what's left.
# ============================================================

# Split report into sections by ## headers
$lines = $reportContent -split "`n"
$sections = @()
$currentSection = @()
$currentHeader = ""

foreach ($line in $lines) {
    if ($line -match '^##\s') {
        if ($currentHeader -or $currentSection.Count -gt 0) {
            $sections += [pscustomobject]@{
                Header = $currentHeader
                Lines = $currentSection
            }
        }
        $currentHeader = $line
        $currentSection = @($line)
    } else {
        $currentSection += $line
    }
}
# Add final section
if ($currentHeader -or $currentSection.Count -gt 0) {
    $sections += [pscustomobject]@{
        Header = $currentHeader
        Lines = $currentSection
    }
}

# Filter out completed sections
$filteredSections = @()
foreach ($section in $sections) {
    $header = $section.Header

    # Skip if header contains completion markers
    $isComplete = $false

    # Check for strikethrough (~~...~~)
    if ($header -match '~~.*~~') { $isComplete = $true }

    # Check for checkmarks or COMPLETE/DONE markers
    if ($header -match '(COMPLETE|DONE|✓|✅)') { $isComplete = $true }

    # Check if this section's content matches a merged branch
    $sectionText = ($section.Lines -join "`n")
    foreach ($branch in $CompletedBranches) {
        # Extract the descriptive part of the branch name (e.g., "python-calculation-engine" from "feature/python-calculation-engine")
        $branchSlug = ($branch -replace '^(feature|fix|refactor)/', '') -replace '-', '[ -]'
        if ($sectionText -match $branchSlug) {
            $isComplete = $true
            break
        }
    }

    if (-not $isComplete) {
        $filteredSections += $section
    }
}

# Reconstruct the report with only uncompleted priorities
$filteredContent = ($filteredSections | ForEach-Object { ($_.Lines -join "`n") }) -join "`n---`n"

if ([string]::IsNullOrWhiteSpace($filteredContent) -or $filteredContent.Trim().Length -lt 20) {
    Write-Error "All priorities appear to be complete. No remaining work found."
    exit 1
}

# ============================================================
# LLM EXTRACTION: Claude only sees uncompleted priorities.
# Its job is to extract details, NOT to decide what's next.
# ============================================================

$prompt = @"
Extract the FIRST priority item from this report. The report has already been filtered to only show uncompleted items, so pick the first one you see.

REPORT:
$filteredContent

---

INSTRUCTIONS:
1. Extract the FIRST priority section from the report above
2. Create a JSON object with the extracted information
3. IMPORTANT: Wrap your JSON output inside <json_output> tags
4. The JSON must be valid and complete

Output format (wrap in tags exactly like this):
<json_output>
{
  "priority_item": "Brief title of the priority",
  "description": "Full description from the report including deliverables and acceptance criteria",
  "branch_name": "feature/kebab-case-branch-name",
  "reasoning": "Why this is the next priority to build"
}
</json_output>

Rules for branch_name:
- Use kebab-case (lowercase with hyphens)
- Prefix with feature/, fix/, or refactor/ as appropriate
- Keep it short but descriptive (e.g., feature/product-catalog-page)
- No special characters except hyphens
"@

# Call Claude to extract details from filtered report
$result = $prompt | & claude --print 2>&1
$resultText = $result -join "`n"

# Extract JSON from XML tags using single-line regex mode
if ($resultText -match '(?s)<json_output>(?<content>.*?)</json_output>') {
    $jsonString = $Matches['content'].Trim()

    try {
        $parsed = $jsonString | ConvertFrom-Json

        # Create output with defaults for any missing fields
        $output = @{
            priority_item = if ($parsed.priority_item) { $parsed.priority_item } else { "Unknown priority" }
            description = if ($parsed.description) { $parsed.description } else { $parsed.priority_item }
            branch_name = if ($parsed.branch_name) { $parsed.branch_name } else { "feature/auto-compound-$(Get-Date -Format 'yyyyMMdd')" }
            reasoning = if ($parsed.reasoning) { $parsed.reasoning } else { "Next priority from report" }
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
        try {
            $parsed = $jsonString | ConvertFrom-Json
            $output = @{
                priority_item = if ($parsed.priority_item) { $parsed.priority_item } else { "Unknown priority" }
                description = if ($parsed.description) { $parsed.description } else { $parsed.priority_item }
                branch_name = if ($parsed.branch_name) { $parsed.branch_name } else { "feature/auto-compound-$(Get-Date -Format 'yyyyMMdd')" }
                reasoning = if ($parsed.reasoning) { $parsed.reasoning } else { "Next priority from report" }
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
