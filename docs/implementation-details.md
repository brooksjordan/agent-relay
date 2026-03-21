# Implementation Details

Hard-won lessons from debugging the pipeline. Read this if you are modifying the scripts or diagnosing failures.

## Claude Code CLI Invocation

**Wrong:**
```powershell
claude -p $prompt --dangerously-skip-permissions
```

**Right:**
```powershell
$prompt | claude --print --dangerously-skip-permissions
```

The `--print` flag is a boolean flag, not an argument that takes a value. The prompt goes via stdin (pipe or redirect), not as a flag argument.

This matches how [Ralph](https://github.com/snarktank/ralph) invokes Claude:
```bash
claude --dangerously-skip-permissions --print < CLAUDE.md
```

## Working Directory

The loop must set the working directory before running Claude:

```powershell
Set-Location $WorkspaceRoot
$output = $prompt | claude --print --dangerously-skip-permissions
```

Without this, Claude creates files wherever the loop script was invoked from, not in the project directory.

## Fresh Instance Pattern

Each iteration spawns a fresh Claude process. This is intentional:
- No context pollution between tasks
- Each task gets a clean slate
- Progress is tracked externally in tasks.json

## Task Verification

After each task, verify the work actually happened:
- Check file existence
- Check file is non-empty
- Check modification time is recent

Do not trust Claude's claim of "TASK_COMPLETE" alone.

## Completion Signal

When all tasks are done, emit:
```
<promise>COMPLETE</promise>
```

This lets parent scripts exit early rather than burning through remaining iterations.
