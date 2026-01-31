# Scheduler Setup (Windows)

Automated nightly execution using Windows Task Scheduler.

---

## Quick Start

```powershell
# Install (run from PowerShell as your user)
.\scripts\install-scheduler.ps1 -ProjectPath "C:\projects\myapp"

# Check status
.\scripts\status-scheduler.ps1

# Test manually
Start-ScheduledTask -TaskName "ShipAsleep-CompoundReview"

# Uninstall
.\scripts\uninstall-scheduler.ps1
```

---

## What Gets Scheduled

| Task | Time | Purpose | Duration |
|------|------|---------|----------|
| `ShipAsleep-KeepAwake` | 10:00 PM | Prevent sleep | 4 hours |
| `ShipAsleep-CompoundReview` | 10:30 PM | Extract learnings | ~30 min |
| `ShipAsleep-AutoCompound` | 11:00 PM | Implement + PR | ~1-2 hours |

```
10:00 PM ─── KeepAwake starts (prevents sleep)
             │
10:30 PM ─── CompoundReview runs
             │  └─► Reviews sessions, updates CLAUDE.md
             │
11:00 PM ─── AutoCompound runs
             │  └─► Picks priority, implements, opens PR
             │
~1:00 AM ─── AutoCompound typically finishes
             │
 2:00 AM ─── KeepAwake ends (sleep allowed)
```

---

## Installation

### Basic Setup

```powershell
.\scripts\install-scheduler.ps1 -ProjectPath "C:\projects\myapp"
```

### Custom Times

```powershell
.\scripts\install-scheduler.ps1 `
    -ProjectPath "C:\projects\myapp" `
    -CompoundReviewHour 21 `
    -CompoundReviewMinute 30 `
    -AutoCompoundHour 22 `
    -AutoCompoundMinute 0 `
    -KeepAwakeStartHour 21
```

### Custom Task Prefix

```powershell
# Useful for multiple projects
.\scripts\install-scheduler.ps1 `
    -ProjectPath "C:\projects\myapp" `
    -TaskPrefix "MyApp"
```

### Force Overwrite

```powershell
.\scripts\install-scheduler.ps1 -ProjectPath "C:\projects\myapp" -Force
```

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ProjectPath` | (required) | Path to project with reports/ and CLAUDE.md |
| `-TaskPrefix` | `ShipAsleep` | Prefix for task names |
| `-CompoundReviewHour` | 22 | Hour (24h) for compound review |
| `-CompoundReviewMinute` | 30 | Minute for compound review |
| `-AutoCompoundHour` | 23 | Hour (24h) for auto-compound |
| `-AutoCompoundMinute` | 0 | Minute for auto-compound |
| `-KeepAwakeStartHour` | 22 | Hour (24h) to start preventing sleep |
| `-Force` | false | Overwrite existing tasks |

---

## Verification

### Check Task Status

```powershell
# Quick status
.\scripts\status-scheduler.ps1

# Or use Windows built-in
Get-ScheduledTask -TaskName "ShipAsleep*" | Format-Table TaskName, State, LastRunTime
```

### Test Manually

```powershell
# Run compound review now
Start-ScheduledTask -TaskName "ShipAsleep-CompoundReview"

# Watch the log
Get-Content "C:\projects\myapp\logs\compound-review-scheduled.log" -Wait
```

### View in Task Scheduler GUI

1. Press `Win + R`, type `taskschd.msc`
2. Navigate to Task Scheduler Library
3. Find tasks starting with your prefix

---

## Logs

Scheduled runs log to:

```
<ProjectPath>\logs\compound-review-scheduled.log
<ProjectPath>\logs\auto-compound-scheduled.log
```

```powershell
# View recent compound review logs
Get-Content .\logs\compound-review-scheduled.log -Tail 50

# View recent auto-compound logs
Get-Content .\logs\auto-compound-scheduled.log -Tail 50

# Follow in real-time
Get-Content .\logs\auto-compound-scheduled.log -Wait
```

---

## Power Management

### How KeepAwake Works

The `ShipAsleep-KeepAwake` task uses Windows API (`SetThreadExecutionState`) to:
- Prevent system sleep
- Allow display to turn off (saves power)
- Runs for 4 hours (10 PM - 2 AM)

### If Your Machine Still Sleeps

1. **Check power settings:**
   ```powershell
   powercfg /query
   ```

2. **Disable hibernate:**
   ```powershell
   powercfg /hibernate off
   ```

3. **Create a power plan (optional):**
   ```powershell
   # Create "Night Worker" plan that never sleeps
   powercfg /duplicatescheme 381b4222-f694-41f0-9685-ff5bb260df2e 12345678-1234-1234-1234-123456789abc
   powercfg /changename 12345678-1234-1234-1234-123456789abc "Night Worker" "Never sleeps"
   powercfg /change -standby-timeout-ac 0
   ```

4. **Verify WakeToRun is enabled:**
   ```powershell
   Get-ScheduledTask -TaskName "ShipAsleep*" |
       ForEach-Object { $_.Settings } |
       Select-Object WakeToRun
   ```

---

## Troubleshooting

### "Task is not running"

1. Check task state:
   ```powershell
   Get-ScheduledTask -TaskName "ShipAsleep-CompoundReview"
   ```

2. If disabled, enable it:
   ```powershell
   Enable-ScheduledTask -TaskName "ShipAsleep-CompoundReview"
   ```

### "Access denied" on install

Run PowerShell as Administrator, or ensure your user has rights to create scheduled tasks.

### Task runs but nothing happens

1. Check the log file exists and has recent entries
2. Verify Claude Code is in PATH:
   ```powershell
   Get-Command claude
   ```
3. Verify GitHub CLI is authenticated:
   ```powershell
   gh auth status
   ```

### Task shows "Last result: 1"

Usually means the script hit an error. Check:
1. The scheduled log file for details
2. That the project path is correct
3. That `reports/` directory has at least one `.md` file

---

## Multiple Projects

Run separate schedules for different projects:

```powershell
# Project A at 10:30 PM
.\scripts\install-scheduler.ps1 `
    -ProjectPath "C:\projects\app-a" `
    -TaskPrefix "AppA" `
    -CompoundReviewHour 22 -CompoundReviewMinute 30 `
    -AutoCompoundHour 23 -AutoCompoundMinute 0

# Project B at 1:00 AM (after A finishes)
.\scripts\install-scheduler.ps1 `
    -ProjectPath "C:\projects\app-b" `
    -TaskPrefix "AppB" `
    -CompoundReviewHour 1 -CompoundReviewMinute 0 `
    -AutoCompoundHour 1 -AutoCompoundMinute 30
```

---

## Uninstallation

```powershell
# Remove all ShipAsleep tasks
.\scripts\uninstall-scheduler.ps1

# Remove specific prefix
.\scripts\uninstall-scheduler.ps1 -TaskPrefix "MyApp"
```

Or manually in Task Scheduler GUI.
