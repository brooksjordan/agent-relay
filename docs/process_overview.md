# Ship While You Sleep: Process Overview

A nightly automation loop where your AI agent reviews the day's work, extracts learnings, updates its own instructions, and ships the next priority item — all while you sleep.

**Source:** Ryan Carson's methodology (Jan 2026)

---

## Core Concept

Most developers use AI agents reactively: prompt → response → move on. This system inverts that pattern:

1. **Agent learns** from every session (not just the ones you remember to summarize)
2. **Knowledge compounds** into persistent memory (CLAUDE.md files)
3. **Agent ships** the next priority using that accumulated context

The agent gets smarter every day because it reads its own updated instructions before each implementation run.

---

## The Two-Part Loop

Two jobs run in sequence every night:

| Time | Job | Purpose |
|------|-----|---------|
| 10:30 PM | **Compound Review** | Review day's threads → extract learnings → update CLAUDE.md |
| 11:00 PM | **Auto-Compound** | Pull fresh context → pick #1 priority → implement → create PR |

**Order matters.** The review job updates CLAUDE.md with patterns and gotchas. The implementation job then benefits from those learnings.

### Job 1: Compound Review (10:30 PM)

The agent:
1. Finds all threads from the last 24 hours
2. Checks if each thread ended with a "compound" step (extracting learnings)
3. For threads that didn't, retroactively extracts the learnings
4. Updates relevant CLAUDE.md files with patterns, gotchas, context
5. Commits and pushes to main

**Output:** CLAUDE.md files become a living knowledge base that grows every night.

### Job 2: Auto-Compound (11:00 PM)

The agent:
1. Pulls latest main (now with fresh CLAUDE.md updates)
2. Reads the prioritized reports directory
3. Picks the #1 priority item
4. Creates a PRD for that item
5. Converts PRD to task list
6. Runs execution loop (one task at a time until complete)
7. Creates a draft PR

**Output:** A PR implementing your top priority, ready for review when you wake up.

---

## Components

### 1. Compound Engineering Skill
Gives the agent the ability to extract and persist learnings from each session. The skill identifies:
- Patterns that worked
- Gotchas and edge cases hit
- Context future sessions need

### 2. Priority Reports
Markdown files in a `reports/` directory containing prioritized work items. The auto-compound script reads the latest report and picks #1.

Format example:
```markdown
# Priority Report - 2026-01-30

1. **Add user authentication** - Critical for launch
2. **Fix cart calculation bug** - Customer-reported
3. **Refactor payment module** - Tech debt
```

### 3. PRD + Tasks Pipeline
- **PRD Skill:** Creates a Product Requirements Document for the selected priority
- **Tasks Skill:** Converts PRD into a structured task list (JSON)
- **Execution Loop:** Iterates through tasks, implementing one at a time

### 4. Execution Loop (loop.sh equivalent)
Runs the agent iteratively:
1. Pick next incomplete task
2. Implement it
3. Test/verify against acceptance criteria
4. Commit
5. Repeat until all tasks pass or iteration limit hit

---

## Script Structure

```
project/
├── scripts/
│   └── compound/
│       ├── daily-compound-review.sh   # Job 1: Learning extraction
│       ├── auto-compound.sh           # Job 2: Implementation pipeline
│       ├── analyze-report.sh          # Picks #1 priority from reports
│       └── loop.sh                    # Iterative execution engine
├── reports/
│   └── priority-2026-01-30.md         # Prioritized work items
├── tasks/
│   └── prd-*.md                       # Generated PRDs
├── logs/
│   ├── compound-review.log
│   └── auto-compound.log
└── CLAUDE.md                          # Living knowledge base
```

---

## Claude Code Adaptation

Original (Amp):
```bash
amp execute "Load the compound-engineering skill..."
```

Claude Code equivalent:
```bash
# Prompt via stdin, --print is a flag (not an argument)
echo "Your prompt here" | claude --print --dangerously-skip-permissions

# Or with file redirection
claude --print --dangerously-skip-permissions < prompt.txt
```

**IMPORTANT:** The `-p` / `--print` flag is a boolean flag, NOT an argument. The prompt must be delivered via stdin (pipe or redirect).

Key differences:
- `AGENTS.md` → `CLAUDE.md`
- Amp skills → Claude Code skills or inline prompts
- Thread review mechanism needs adaptation (Claude Code doesn't have native thread history access)
- Working directory must be set before running Claude (it resolves paths from cwd)

---

## Scheduler Setup (Windows)

Windows uses **Task Scheduler** instead of launchd.

Requirements:
1. Two scheduled tasks (Compound Review at 10:30 PM, Auto-Compound at 11:00 PM)
2. Machine must stay awake during automation window
3. Proper PATH and environment variables for Claude CLI

Power settings:
- Disable sleep during automation window (10 PM - 2 AM)
- Or use `powercfg` to create a power plan that prevents sleep

---

## What You Wake Up To

Each morning:
1. **Updated CLAUDE.md** with patterns learned yesterday
2. **Draft PR** implementing your top priority
3. **Logs** showing exactly what happened

The compound effect: patterns discovered Monday inform Tuesday's work. Gotchas hit Wednesday are avoided Thursday.

---

## Implementation Status

### Completed (Phase 1 MVP)

| Component | Script | Status |
|-----------|--------|--------|
| Session logging wrapper | `scripts/claude-session.ps1` | Done |
| List sessions | `scripts/list-sessions.ps1` | Done |
| Gather sessions for review | `scripts/gather-sessions.ps1` | Done |
| Compound review (Job 1) | `scripts/compound-review.ps1` | Done |
| Priority report analyzer | `scripts/analyze-report.ps1` | Done |
| Execution loop | `scripts/loop.ps1` | Done |
| Auto-compound (Job 2) | `scripts/auto-compound.ps1` | Done |
| CLAUDE.md template | `templates/CLAUDE.md.template` | Done |
| Priority report template | `templates/priority_report.md.template` | Done |

| Scheduler install | `scripts/install-scheduler.ps1` | Done |
| Scheduler uninstall | `scripts/uninstall-scheduler.ps1` | Done |
| Scheduler status | `scripts/status-scheduler.ps1` | Done |
| Power management | Built into KeepAwake task | Done |

---

## Quick Start

```powershell
# 1. Create a priority report in your project
New-Item -Path "C:\your-project\reports" -ItemType Directory -Force
"1. Your first priority" | Out-File "C:\your-project\reports\priority.md"

# 2. Test manually first
C:\ship_asleep\scripts\auto-compound.ps1 -ProjectPath "C:\your-project" -DryRun

# 3. Run for real
C:\ship_asleep\scripts\auto-compound.ps1 -ProjectPath "C:\your-project"

# 4. When ready, install the scheduler for overnight runs
C:\ship_asleep\scripts\install-scheduler.ps1 -ProjectPath "C:\your-project"

# 5. Wake up to PRs
```

See `README.md` for full documentation and `docs/LESSONS_LEARNED.md` for debugging notes.

---

## Next Steps

1. ~~Test on a real project~~ **DONE** - Tested on sample Next.js e-commerce project 2026-01-30
2. Fine-tune based on learnings - See `docs/LESSONS_LEARNED.md`

---

## Version History

| Date | Change |
|------|--------|
| 2026-01-30 | Fixed CLI invocation (stdin not -p argument), added working directory fix, tested successfully |
