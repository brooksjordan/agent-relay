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

### macOS / Linux (Bash)

```bash
# Clone
git clone https://github.com/brooksjordan/agent-relay.git

# Create a priority report in your project
mkdir -p ./your-project/reports
echo -e "1. Build the user dashboard\n2. Add authentication\n3. Fix cart bug" > ./your-project/reports/PRIORITIES.md

# Dry run first (no changes)
./scripts/launch-auto-compound.sh --project-path "./your-project" --dry-run --verbose

# Run for real (opens Terminal window, builds #1 priority, opens PR)
./scripts/launch-auto-compound.sh --project-path "./your-project" --verbose

# For overnight automation (macOS launchd)
./scripts/install-scheduler.sh --project-path "./your-project"
```

### Windows (PowerShell)

```powershell
# Clone
git clone https://github.com/brooksjordan/agent-relay.git

# Create a priority report in your project
mkdir ./your-project/reports
"1. Build the user dashboard`n2. Add authentication`n3. Fix cart bug" | Out-File ./your-project/reports/PRIORITIES.md

# Dry run first (no changes)
.\scripts\launch-auto-compound.ps1 -ProjectPath "./your-project" -DryRun -Verbose

# Run for real (opens PowerShell window, builds #1 priority, opens PR)
.\scripts\launch-auto-compound.ps1 -ProjectPath "./your-project" -Verbose

# For overnight automation (Windows Task Scheduler)
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

**Cross-platform:** Started on Windows with PowerShell, now has native Bash scripts for macOS/Linux. Both script sets are maintained side-by-side and are functionally identical. macOS uses `caffeinate` for sleep prevention and `launchd` for scheduling; Windows uses `SetThreadExecutionState` and Task Scheduler.

---

## Prerequisites

**All platforms:**
- **Claude Code CLI** installed and authenticated (`claude --version`)
- **Git** configured with user.name and user.email
- **ANTHROPIC_API_KEY** environment variable set
- **GitHub CLI** (`gh`) for automatic PR creation (optional)

**macOS / Linux (Bash scripts):**
- **Bash 4+** (macOS ships with 3.2 but scripts are compatible; Homebrew `bash` recommended)
- **jq** for JSON processing (`brew install jq` or `apt install jq`)
- **perl** (built-in on macOS and most Linux)
- macOS: `caffeinate` (built-in) for sleep prevention
- macOS: `osascript` (built-in) for opening terminal windows

**Windows (PowerShell scripts):**
- **PowerShell 5.1+** (built-in on Windows)

---

## Scripts

Every script has both a `.ps1` (Windows/PowerShell) and `.sh` (macOS/Linux/Bash) version. They are functionally identical.

### auto-compound (.ps1 / .sh)

The full pipeline: analyze report, generate PRD, create tasks, execute.

```bash
# macOS/Linux
./scripts/auto-compound.sh --project-path "./your-project"

# Windows
.\scripts\auto-compound.ps1 -ProjectPath "./your-project"
```

| Bash Flag | PS Flag | Default | Description |
|-----------|---------|---------|-------------|
| --project-path | -ProjectPath | required | Path to your project |
| --max-iterations | -MaxIterations | 25 | Max task iterations |
| --quality-checks | -QualityChecks | none | Comma-separated commands to run after each task |
| --dry-run | -DryRun | false | Preview without changes |
| --resume | -Resume | false | Resume from last checkpoint |
| --project-name | -ProjectName | auto | Override project name |
| --verbose | -Verbose | false | Show all log output |

### loop (.ps1 / .sh)

The core execution engine. Processes tasks one at a time from a JSON file.

```bash
# macOS/Linux
./scripts/loop.sh --tasks-file "./your-project/tasks/tasks.json"

# Windows
.\scripts\loop.ps1 -TasksFile "./your-project/tasks/tasks.json"
```

| Bash Flag | PS Flag | Default | Description |
|-----------|---------|---------|-------------|
| --tasks-file | -TasksFile | required | Path to tasks JSON file |
| --max-iterations | -MaxIterations | 25 | Stop after N iterations |
| --task-timeout | -TaskTimeoutSeconds | 900 | Hard timeout per task |
| --transcript-dir | -TranscriptDir | auto | Directory for session transcripts |
| --quality-checks | -QualityChecks | none | Comma-separated check commands |

**Task JSON format:**
```json
{
  "tasks": [
    {
      "id": 1,
      "title": "Create component",
      "description": "What to implement",
      "file": "src/Component.tsx",
      "acceptanceCriteria": ["File exists at src/Component.tsx", "Exports default component"],
      "status": "pending"
    }
  ]
}
```

### overnight (.ps1 / .sh)

Wrapper that adds retry logic, exponential backoff, and keep-awake (caffeinate on macOS, F15 key on Windows).

```bash
# macOS/Linux
./scripts/overnight.sh --project-path "./your-project"

# Windows
.\scripts\overnight.ps1 -ProjectPath "./your-project"
```

### compound-review (.ps1 / .sh)

Extracts learnings from Claude Code sessions into your project's CLAUDE.md.

```bash
# macOS/Linux
./scripts/compound-review.sh --project-path "./your-project"

# Windows
.\scripts\compound-review.ps1 -ProjectPath "./your-project"
```

### Scheduling

```bash
# macOS — install launchd agents (runs nightly)
./scripts/install-scheduler.sh --project-path "./your-project"
./scripts/status-scheduler.sh
./scripts/uninstall-scheduler.sh
```

```powershell
# Windows — install Task Scheduler jobs
.\scripts\install-scheduler.ps1 -ProjectPath "./your-project"
.\scripts\status-scheduler.ps1
.\scripts\uninstall-scheduler.ps1
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

**Scheduler not running** — Windows: check Task Scheduler is enabled. macOS: run `./scripts/status-scheduler.sh` or `launchctl list | grep agentrelay`. Verify machine doesn't sleep during automation. Check `logs/` for errors.

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

Contributions welcome. Both PowerShell (`.ps1`) and Bash (`.sh`) scripts are maintained side-by-side. When something breaks: fix it, document why in `docs/lessons-learned.md`, and update this README.
