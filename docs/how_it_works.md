# How Ship While You Sleep Works

A nightly automation loop that implements your priorities while you sleep.

---

## The Core Concept

You maintain a **priority backlog**. The system **executes it one item per night**.

```
┌─────────────────────────────────────────────────────────────────┐
│                         YOUR BACKLOG                            │
│                                                                 │
│   1. Product catalog page    ──► Night 1 builds, creates PR    │
│   2. Shopping cart           ──► Night 2 builds (after merge)  │
│   3. Checkout flow           ──► Night 3                       │
│   4. User authentication     ──► Night 4                       │
│   5. Order history           ──► Night 5                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

Each night, the system:
1. Picks #1 from your backlog
2. Creates a detailed PRD
3. Breaks it into tasks
4. Implements each task
5. Creates a PR for your review
6. Runs a structured post-mortem (what worked, what didn't, what to try next)

---

## The Two Nightly Jobs

| Time | Job | What Happens |
|------|-----|--------------|
| 10:30 PM | **Compound Review** | Reviews your Claude Code sessions from the day, extracts learnings, updates CLAUDE.md |
| 11:00 PM | **Auto-Compound** | Picks #1 priority, builds it, opens PR, runs post-mortem |

The order matters — learnings from Job 1 inform Job 2. The post-mortem at the end of Job 2 feeds forward into the next night's build.

---

## The Priority Report

Your backlog lives in `reports/` as a markdown file.

### Minimum Viable Report

```markdown
1. Add user authentication
```

One line works.

### Recommended Format

```markdown
# Priority Report - 2026-01-30

## Priority 1: Add user authentication

Users need to log in before accessing the dashboard.

- OAuth with Google
- Session management
- Protected routes

## Priority 2: Fix cart calculation bug

Discounts aren't applying correctly.

## Priority 3: Refactor payment module
```

### How the System Picks #1

1. Finds the most recently modified `.md` file in `reports/`
2. Claude analyzes it and extracts the top priority
3. That item becomes tonight's work

---

## Your Role (The Human Loop)

| When | What You Do |
|------|-------------|
| **Occasionally** | Update the priority report when priorities change |
| **Each morning** | Review the PR, merge or request changes |
| **When stuck** | Debug, add context to CLAUDE.md, refine the report |

### You Update the Report When:

- Priorities change ("authentication is now urgent")
- New work emerges ("add this feature")
- You want to reorder the backlog
- Something shipped and you want to remove it

### You Don't Touch It When:

- Priorities are stable
- Let it churn through the list automatically

---

## The Daily Rhythm

```
MORNING
  └─► Review last night's PR
  └─► Merge (or reject + refine)
  └─► Optionally update priorities

DAYTIME
  └─► Work normally using claude-session.ps1
  └─► Your sessions are logged for learning extraction

EVENING
  └─► Go to sleep

10:30 PM - Compound Review
  └─► Extracts learnings from today's sessions
  └─► Updates CLAUDE.md with patterns, gotchas, context

11:00 PM - Auto-Compound
  └─► Picks #1 from your report
  └─► Creates PRD with detailed requirements
  └─► Breaks into 5-10 small tasks
  └─► Implements each task, commits along the way
  └─► Opens draft PR
  └─► Runs five-point post-mortem (Analyst pattern)
  └─► Persists learnings to logs/post-mortem-YYYY-MM-DD.md

NEXT MORNING
  └─► PR waiting for review
  └─► Post-mortem waiting alongside it
  └─► Repeat (next night's build reads prior post-mortems)
```

---

## What Gets Built Each Night

One priority item = One PR containing:

- All code changes needed
- Commits for each sub-task
- Draft PR with summary

The scope depends on how you write the priority. Be specific:

| Priority Description | Likely Outcome |
|---------------------|----------------|
| "Add auth" | Might be too vague |
| "Add Google OAuth login with session management" | Clear scope |
| "Add login button to header that redirects to /login" | Very specific, quick win |

---

## The Compound Effect

Each night makes future nights smarter through two feedback loops:

**Loop 1: Compound Review (patterns, gotchas, context)**
1. **Day 1:** You hit a bug with Next.js Image component
2. **Night 1:** Compound Review extracts this as a "gotcha" → updates CLAUDE.md
3. **Night 2+:** Agent reads CLAUDE.md before building, avoids the same bug

**Loop 2: Post-Mortem (structured reflection)**
1. **Night 1:** Auto-Compound builds feature, then runs five-point post-mortem
2. **Post-mortem captures:** What matched the PRD vs. didn't, which tasks caused issues, what the agent learned
3. **Night 2+:** Builder reads prior post-mortems during PRD creation, avoids repeating mistakes

The difference: Compound Review captures *what happened today*. Post-mortems capture *why it happened and what to do differently*. Research shows top-performing systems drew 44.8% of ideas from structured reflection vs. 37.7% for average. Reflection is the wedge between good and great.

Your CLAUDE.md + post-mortems become institutional memory that accumulates over time.

---

## File Structure

```
your-project/
├── reports/
│   └── priority.md           # Your backlog (you maintain this)
├── tasks/
│   ├── prd-*.md              # Generated PRDs
│   └── tasks-*.json          # Generated task lists
├── .claude-sessions/         # Session logs (auto-generated)
├── logs/
│   ├── compound-review.log
│   ├── auto-compound.log
│   └── post-mortem-YYYY-MM-DD.md  # Structured five-point analysis (auto-generated)
└── CLAUDE.md                 # Living knowledge base (auto-updated)
```

---

## Quick Start

1. **Create a report:**
   ```
   your-project/reports/priority.md
   ```

2. **Add priorities:**
   ```markdown
   1. First thing to build
   2. Second thing
   3. Third thing
   ```

3. **Install scheduler:**
   ```powershell
   C:\ship_asleep\scripts\install-scheduler.ps1 -ProjectPath "C:\your-project"
   ```

4. **Go to sleep. Wake up to PRs.**

---

## Key Insight

This is a **self-executing backlog**:

- You maintain the queue (what to build, in what order)
- The system drains it (one item per night)
- You review and merge (quality gate)
- Learnings compound (each night gets smarter)

The human provides direction. The agent provides execution.
