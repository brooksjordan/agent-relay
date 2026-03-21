# Agent Relay

An autonomous build pipeline for AI coding agents.

> **Warning:** Agent Relay runs AI agents autonomously. It consumes API credits and modifies code in your repository. Always run on a feature branch, never on main.

> **Destructive Operations:** The pipeline runs `git reset --hard` and `git clean -fd` to ensure a clean workspace. This deletes uncommitted changes. Commit your work before running.

> **Disclaimer:** This project is not affiliated with or endorsed by Anthropic. Users must comply with Anthropic's terms of service and usage policies.

---

## What It Does

You give it a priority list. It picks the top item, generates a plan, breaks it into tasks, executes them with AI agents, runs quality checks, and opens a PR.

Each run makes future runs smarter. Learnings from every session get extracted into the project's CLAUDE.md. The methodology compounds.

Agent Relay works overnight or during the day.

---

## Quick Start

```powershell
# Clone
git clone https://github.com/brooksjordan/agent-relay.git

# Create a priority report in your project
mkdir ./your-project/reports
"1. Build the user dashboard`n2. Add authentication`n3. Fix cart bug" | Out-File ./your-project/reports/priority.md

# Dry run first (no changes)
.\scripts\auto-compound.ps1 -ProjectPath "./your-project" -DryRun

# Run for real (creates branch, builds #1 priority, opens PR)
.\scripts\auto-compound.ps1 -ProjectPath "./your-project"

# For overnight automation (Windows only)
.\scripts\install-scheduler.ps1 -ProjectPath "./your-project"
```

---

## How It Works

The pipeline runs through 9 stages:

1. **Clean workspace** — reset to a known state
2. **Analyze report** — pick the top priority
3. **Generate PRD** — turn the priority into a spec
4. **Create tasks** — break the spec into bounded work items
5. **Execute** — run 3-5 AI agents in parallel, each with exclusive file ownership
6. **Quality checks** — run tests, type checks, builds
7. **Adversarial review** — multiple AI models critique the work
8. **Fix** — address review findings
9. **Post-mortem** — extract learnings for the next cycle

Each stage gates the next. If a stage fails, the pipeline retries or stops.

**Why PowerShell?** Started on a Windows laptop and kept going. Once there, PowerShell was the right choice for Task Scheduler integration and for orchestrating interactive CLI processes like Claude Code — it handles them natively, without the subprocess and pseudo-terminal boilerplate Python requires. Cross-platform via PowerShell 7+ (`pwsh`).

---

## Prerequisites

- **PowerShell:**
  - Windows: 5.1+ (built-in)
  - Mac: `brew install powershell`
  - Linux: `sudo apt install powershell` or [install guide](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux)
- **Claude Code CLI** installed and authenticated (`claude --version`)
- **Git** configured with user.name and user.email
- **ANTHROPIC_API_KEY** environment variable set
- **GitHub CLI** (`gh`) for automatic PR creation (optional)

> **Mac/Linux scheduling:** `install-scheduler.ps1` uses Windows Task Scheduler. Use cron instead:
> ```bash
> # Example: run at 11 PM every weekday
> 0 23 * * 1-5 pwsh /path/to/agent-relay/scripts/overnight.ps1 -ProjectPath "/path/to/project"
> ```

---

## Scripts

### auto-compound.ps1

The full pipeline: analyze report, generate PRD, create tasks, execute.

```powershell
.\scripts\auto-compound.ps1 -ProjectPath "./your-project"
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| ProjectPath | required | Path to your project |
| MaxIterations | 25 | Max task iterations |
| QualityChecks | @() | Commands to run after each task |
| DryRun | false | Preview without changes |
| Resume | false | Resume from last checkpoint |
| ProjectName | auto | Override project name |
| ReportFile | auto | Path to priority report |

### loop.ps1

The core execution engine. Processes tasks one at a time from a JSON file.

```powershell
.\scripts\loop.ps1 -TasksFile "./your-project/tasks/tasks.json"
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| TasksFile | required | Path to tasks JSON file |
| MaxIterations | 25 | Stop after N iterations |
| TaskTimeoutSeconds | 900 | Hard timeout per task |
| TranscriptDir | auto | Directory for session transcripts |
| QualityChecks | @() | Commands to run after each task |
| ArchiveDir | "" | Archive previous runs |

**Task JSON format:**
```json
{
  "metadata": {
    "project": "project-name",
    "branch": "feature/xyz",
    "created": "2026-01-30T12:00:00Z"
  },
  "tasks": [
    {
      "id": 1,
      "title": "Create component",
      "status": "pending",
      "acceptance_criteria": "File exists at src/Component.tsx"
    }
  ]
}
```

### overnight.ps1

Wrapper that adds retry logic, exponential backoff, and keep-awake.

```powershell
.\scripts\overnight.ps1 -ProjectPath "./your-project"
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| ProjectPath | required | Path to project |
| MaxIterations | 25 | Max iterations per attempt |
| MaxRetries | 3 | Retry attempts on failure |
| RetryDelaySeconds | 30 | Initial retry delay (backs off to 5 min) |
| QualityChecks | @() | Commands to run after each task |

### compound-review.ps1

Extracts learnings from Claude Code sessions into your project's CLAUDE.md.

```powershell
.\scripts\compound-review.ps1 -ProjectPath "./your-project"
```

---

## Project Setup

For each new project:

1. Create `CLAUDE.md` in project root (see `templates/CLAUDE.md.template`)
2. Create `reports/` directory with a `priority.md`
3. Create `tasks/` directory (auto-compound populates it)
4. Test with `-DryRun` before running for real
5. Install scheduler when ready for overnight runs (Windows) or set up cron (Mac/Linux)

---

## Built On

Agent Relay combines and extends three open-source projects:

| Component | Source | What It Does |
|-----------|--------|-------------|
| Fresh-instance loop | [Ralph](https://github.com/snarktank/ralph) by Ryan Carson | Spawns a fresh Claude CLI process per task. No context pollution between tasks. |
| Compound learning | [compound-product](https://github.com/snarktank/compound-product) by Ryan Carson | Extracts learnings into CLAUDE.md. Each run makes future runs smarter. |
| Skills plugin | [compound-engineering-plugin](https://github.com/EveryInc/compound-engineering-plugin) by Every Inc | Claude Code plugin architecture with reusable skills. |

### What Agent Relay Adds

- **Full autonomous pipeline** — 9-stage state machine from priority report to merged PR
- **Multi-agent parallelism** — 3-5 agents with exclusive file ownership, no merge conflicts
- **Adversarial review** — multiple AI models critique the build before it ships
- **Overnight wrapper** — retry logic with exponential backoff and keep-awake
- **Quality gates** — configurable checks (tests, type checks, builds) between stages
- **Task verification** — checks file existence and modification time, not just agent claims

See [NOTICES](NOTICES) for upstream license attributions.

---

## Implementation Details

Hard-won lessons about Claude Code CLI invocation, working directory, task verification, and the fresh-instance pattern: [docs/implementation-details.md](docs/implementation-details.md).

---

## Troubleshooting

**Files not being created** — Check working directory. Verify task prompts include correct paths. Check agent output in `tasks/*.output`.

**Agent claims done but nothing changed** — Verify stdin prompt delivery (`$prompt | claude --print`). Check file verification is running.

**Task keeps failing** — Make acceptance criteria specific and verifiable. Scope tasks smaller. Check `progress.txt` for patterns.

**Scheduler not running** — Check Task Scheduler is enabled. Verify machine doesn't sleep during automation. Check `logs/` for errors.

---

## Security

1. **`--dangerously-skip-permissions`** bypasses Claude Code confirmation prompts. Only run on code you trust.
2. **Quality checks execute arbitrary commands** via `Invoke-Expression`. Only pass trusted commands.
3. **Git operations** create branches, commit, and push. Always use feature branches.
4. **API costs** — set `MaxIterations` for your budget.
5. **Transcripts may contain sensitive data** — saved to `logs/transcripts/`. Secret redaction is attempted but incomplete. Never share logs without review.

---

## License

MIT — See [LICENSE](LICENSE) and [NOTICES](NOTICES) for upstream attributions.

## Contributing

Contributions welcome. Bash ports of the PowerShell scripts would be especially valuable for Mac/Linux users. When something breaks: fix it, document why in `docs/lessons-learned.md`, and update this README.
