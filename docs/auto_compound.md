# Auto-Compound (Job 2)

The nightly implementation engine. Runs at 11:00 PM, after Compound Review.

---

## What It Does

```
┌─────────────────────────────────────────────────────────────────┐
│                    AUTO-COMPOUND PIPELINE                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  STAGE 1: Git Setup                                             │
│     └─► git fetch && git reset --hard origin/main               │
│                                                                 │
│  STAGE 2: Find Priority                                         │
│     └─► Find latest report in reports/                          │
│     └─► Analyze for #1 priority item                            │
│                                                                 │
│  STAGE 3: Create Branch                                         │
│     └─► git checkout -b feature/priority-item                   │
│                                                                 │
│  STAGE 4: Create PRD                                            │
│     └─► Claude writes PRD to tasks/prd-*.md                     │
│                                                                 │
│  STAGE 5: Convert to Tasks                                      │
│     └─► Claude converts PRD to tasks/tasks-*.json               │
│                                                                 │
│  STAGE 6: Execute Loop                                          │
│     └─► loop.ps1 runs tasks one by one                          │
│     └─► Each task: implement → test → commit                    │
│                                                                 │
│  STAGE 7: Create PR                                             │
│     └─► git push -u origin <branch>                             │
│     └─► gh pr create --draft                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Usage

### Manual Run

```powershell
# Standard run
.\scripts\auto-compound.ps1

# Dry run (analyze without implementing)
.\scripts\auto-compound.ps1 -DryRun

# Verbose output
.\scripts\auto-compound.ps1 -Verbose

# Custom iterations limit
.\scripts\auto-compound.ps1 -MaxIterations 50

# Specify project
.\scripts\auto-compound.ps1 -ProjectPath "C:\projects\myapp"
```

### Scheduled Run

See [Scheduler Setup](scheduler_setup.md) for Task Scheduler configuration.

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ProjectPath` | `.` | Path to project root |
| `-ReportsDir` | `reports` | Directory containing priority reports |
| `-TasksDir` | `tasks` | Directory for PRDs and task files |
| `-MaxIterations` | 25 | Max loop iterations before stopping |
| `-DryRun` | false | Analyze only, don't implement |
| `-Verbose` | false | Show detailed output |

---

## Priority Reports

Auto-compound reads from `reports/` directory. Create markdown files with prioritized items:

```markdown
# Priority Report - 2026-01-30

## Priority 1: Add user authentication
Critical for launch. Users need to log in before accessing dashboard.
- OAuth with Google
- Session management
- Protected routes

## Priority 2: Fix cart calculation bug
Customer-reported issue where discounts aren't applied correctly.

## Priority 3: Refactor payment module
Tech debt - current implementation is hard to test.
```

**Naming:** Any `.md` file works. The script picks the most recently modified one.

---

## Generated Artifacts

Each run creates:

```
tasks/
  prd-feature-auth.md       # Product Requirements Document
  tasks-feature-auth.json   # Structured task list

logs/
  auto-compound.log         # Run log
  loop.log                  # Execution loop log
```

### Task JSON Format

```json
{
  "prd_source": "prd-feature-auth.md",
  "created_at": "2026-01-30T23:00:00Z",
  "tasks": [
    {
      "id": 1,
      "title": "Create auth middleware",
      "description": "Implement middleware that checks for valid session",
      "acceptance_criteria": "Requests without valid session return 401. Requests with valid session proceed.",
      "status": "pending"
    },
    {
      "id": 2,
      "title": "Add login endpoint",
      "description": "POST /api/auth/login that validates credentials and creates session",
      "acceptance_criteria": "Valid credentials return 200 + session cookie. Invalid return 401.",
      "status": "pending"
    }
  ]
}
```

---

## The Execution Loop

`loop.ps1` runs Claude iteratively:

1. Load task list
2. Find first `pending` task
3. Build prompt with task details + acceptance criteria
4. Run Claude with `--dangerously-skip-permissions`
5. Check output for `TASK_COMPLETE` or `TASK_BLOCKED`
6. Update task status
7. Repeat until no pending tasks or max iterations

### Safety Rails

- **Max iterations:** Stops after N iterations (default 25)
- **Consecutive failures:** Stops after 3 failures in a row
- **Task isolation:** Each iteration focuses on ONE task only

---

## Logs

```powershell
# Auto-compound log
Get-Content .\logs\auto-compound.log -Tail 50

# Execution loop log
Get-Content .\logs\loop.log -Tail 50
```

---

## Prerequisites

1. **GitHub CLI (`gh`)** — For PR creation
   ```powershell
   winget install GitHub.cli
   gh auth login
   ```

2. **Git configured** — Push access to repo

3. **Claude Code** — Installed and authenticated

4. **Priority report** — At least one `.md` file in `reports/`

---

## Troubleshooting

### "No priority reports found"
Create a report in `reports/`:
```powershell
New-Item -Path reports -ItemType Directory -Force
"# Priority`n`n1. First priority item" | Out-File reports/priority.md
```

### "Failed to create PR"
- Ensure `gh` is installed and authenticated: `gh auth status`
- Check branch protection rules allow draft PRs
- Verify you have push access

### Tasks not completing
- Check `logs/loop.log` for Claude's output
- Acceptance criteria may be too vague
- Task may be too large — break into smaller pieces

### Loop hits max iterations
- Increase with `-MaxIterations 50`
- Or break feature into smaller priority items
