# Agent Relay — Roadmap

Remaining recommendations from the architecture review (2026-02-05). High-priority items (safety stash, resumable pipeline, PRD validation) have been implemented.

---

## Medium Priority

### Task dependency graph + parallel execution

**Problem:** All tasks execute sequentially even when they're independent. A 6-task pipeline where 3 tasks have no dependencies could run 2x faster with parallelism.

**Approach:** Extend the task JSON schema with a `depends_on` field (array of task IDs). Modify `loop.ps1` to identify tasks with satisfied dependencies and execute independent tasks in parallel (multiple Claude sessions). Convergence step waits for all parallel tasks before proceeding to dependent tasks.

**Complexity:** Medium-high. Requires changes to task JSON schema, `loop.ps1` execution model, and Stage 5's task generation prompt.

### Token/cost tracking with budget ceiling

**Problem:** No visibility into how much each overnight run costs. A runaway loop could burn through API credits without any guard rail.

**Approach:** Wrap Claude invocations to capture token usage from `--usage` output. Accumulate per-stage and per-run totals. Write to `logs/cost-tracking.json`. Add a `-MaxCost` parameter that aborts the run if the ceiling is exceeded. Report costs in the PR body and completion summary.

**Complexity:** Medium. Main challenge is parsing Claude CLI's usage output format reliably.

### Task-specific verification prompts

**Problem:** The loop uses a generic "is this task done?" check. Tasks with specific acceptance criteria (e.g., "API returns 200 for valid input") could be verified more precisely with a targeted prompt.

**Approach:** Add an optional `verification_prompt` field to the task JSON. When present, the loop uses it instead of the generic check. Stage 5's prompt should generate these for tasks with concrete, testable criteria.

**Complexity:** Low-medium. Small schema extension + prompt modification.

---

## Low Priority

### Platform abstraction for cross-platform support

**Problem:** Pipeline is PowerShell-only (Windows). macOS/Linux users can't use it without WSL or manual adaptation.

**Approach:** Extract platform-specific operations (window spawning, keep-awake, path handling) into a platform abstraction layer. Consider a shell-agnostic orchestrator (e.g., Node.js or Python) that calls platform-specific helpers, or provide bash equivalents of each script.

**Complexity:** High. Significant rewrite with many platform-specific edge cases (path separators, process management, terminal behavior).

### Dry-run-with-real-PRD mode

**Problem:** `-DryRun` currently exits after Stage 2 (report analysis). There's no way to test PRD generation + validation + task breakdown without actually running the implementation loop.

**Approach:** Add a `-DryRunThrough <stage>` parameter that runs the pipeline through the specified stage and then exits. For example, `-DryRunThrough 5` would generate the PRD, validate it, create the task JSON, and stop — useful for reviewing the plan before committing to an overnight run.

**Complexity:** Low. The stage skip infrastructure already exists; just add an exit gate after the specified stage.

---

*Generated from architecture review on 2026-02-05.*
