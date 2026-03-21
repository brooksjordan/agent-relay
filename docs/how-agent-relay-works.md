# How Agent Relay Works

If you want an AI to build software autonomously while you sleep, you cannot just hand it a prompt and cross your fingers. You have to build a factory floor that assumes the AI will fail, contains the blast radius of those failures, and mechanically recovers.

Here is how that factory works.

## The Architecture: Three Scripts and a State Machine

The system is deliberately kept outside of the codebase it modifies. If the AI lived inside the project folder, a hallucinating model might accidentally rewrite or delete its own orchestration instructions. Instead, the pipeline operates the AI from the outside using a hierarchy of three scripts:

**overnight.ps1 (The Night Watchman):** The outermost wrapper. It starts a background job to mimic keystrokes so the computer doesn't go to sleep, and launches the main pipeline. If a catastrophic network error kills the process at 2:00 AM, the Watchman catches the failure and triggers an exponential-backoff retry.

**auto-compound.ps1 (The Brain):** The main orchestrator. It executes an 11-stage CI/CD pipeline, handling the full lifecycle from reading the initial requirements to publishing the final Pull Request.

**loop.ps1 (The Engine):** The execution loop. When it's time to actually write code, this script manages the AI directly, handing it one atomic task at a time, verifying the output, and managing the version control ledger.

Because APIs time out and unexpected errors happen, the Brain operates as a rigid state machine. After every successful stage, it saves its progress to a pipeline-state.json file. If the system crashes halfway through the night, the Watchman restarts it with a -Resume command. The Brain reads the state file, skips the stages it has already finished, restores its memory, and picks up exactly where it left off.

## The Assembly Line (Stages 0-5)

The pipeline moves through 11 distinct stages. The first half of the night is spent entirely on preparation and planning.

### Stage 0: Preflight & The Safety Stash

The system opens PRIORITIES.md -- a simple numbered markdown backlog committed to the repository -- and finds the first item that isn't crossed off. But before it does any work, it establishes a disaster recovery net. It runs a "Safety Stash" (git stash --all), capturing everything currently in the workspace, including untracked code and local configuration files (like a .env database string). It packs this state into a labeled box on a shelf. The pipeline never automatically unpacks this box; it exists purely so a human can manually recover uncommitted work if they left something on the server. If the stash fails, the pipeline aborts.

### Stage 1: The Clean Room

Imagine a woodworking shop. If yesterday's sawdust and half-finished cuts are still on the bench, today's project starts contaminated. You might accidentally glue the wrong pieces together. To prevent AI context-contamination, the pipeline sweeps the bench completely clean. It executes a scorched-earth reset (git reset --hard origin/main and git clean -fdX), forcing the local workspace to perfectly match the published, known-good version of the software. A mathematically sterile starting point.

### Stages 2 & 3: The Branch

The pipeline asks the AI to extract the priority item, sanitizes a name for it, and checks out a fresh git branch (e.g., feature/cost-tracking-dashboard). All work for the night is quarantined here.

### Stages 4 & 4v: The Contract and the Critic

You don't hand an AI a one-sentence priority and expect perfect software. In Stage 4, Claude writes a comprehensive Product Requirements Document (PRD). This establishes the scope, the acceptance criteria, and what not to build.

Because AI is prone to optimistic hallucination, the system immediately runs Stage 4v (Validation). A second, independent AI process is spawned to aggressively critique the PRD. Are the success criteria vague? Is the scope too large for one night? Are there ambiguities that will force the builder to guess? If the critic finds issues, the PRD is rejected, rewritten, and validated again. Only a watertight contract moves forward.

### Stage 5: Break It Down

A PRD is still too massive to hand to an AI all at once. The pipeline feeds the approved PRD back to the AI to generate a JSON array of 8 to 14 atomic tasks. Think of building a house. You don't hand a worker the blueprint and say "build." You say: pour the foundation, frame the walls, run the electrical. The pipeline creates a punch list where each task targets just one or two files and can be finished in under 15 minutes. All tasks are marked "pending."

## The Execution Engine (Stage 6)

Now, the Brain hands control to loop.ps1 (The Engine) to execute the tasks. This is Stage 6, where the engineering discipline becomes critical.

For each pending task, the Engine spawns a brand new, completely isolated process of the Claude Code CLI.

This sounds inefficient. Wouldn't it be better to have one persistent AI agent that remembers the whole night? In practice, no. AI memory is a liability. A builder with a long context window accumulates hallucinated assumptions. It remembers the shortcut it took on Task 3 and assumes it applies to Task 7, drifting further from reality. By spawning a fresh process for every task, we treat amnesia as a feature. The AI must read the codebase exactly as it exists on disk right now.

The AI works inside a sandbox. It can read files, write files, and run tests. But the pipeline explicitly forbids the AI from committing its own code to version control. The AI does the labor; the pipeline holds the stamp of approval.

## Paranoia as a Service: Safety Mechanisms

When the AI claims a task is done, the pipeline does not take its word for it.

### The Inspector (Git as the Source of Truth)

Early versions of this system checked file timestamps to verify work, but the AI would sometimes write an empty file, declare success, and the timestamp check would pass. Now, verification is anchored to git. The pipeline runs git status --porcelain. If the git tree is perfectly clean, the AI didn't actually change anything. Verification fails. If files did change, the pipeline runs the automated test suite. Only if both checks pass does the code move forward.

### The Phantom Commit Trap

There is a fascinating behavioral quirk in modern Large Language Models: they are heavily conditioned to "finish the job." Even when explicitly prompted with "Do NOT commit. The orchestrator will commit after verification," the AI will sometimes use its terminal tool to run git commit anyway.

If the AI commits its own code, it bypasses the pipeline's verification checks and breaks the system's ability to roll back mistakes.

To fix this, loop.ps1 implements a Phantom Commit Trap. Before the AI starts, the orchestrator records the current cryptographic git hash (HEAD). When the AI finishes, it checks the hash again. If the hash moved, the pipeline knows the AI went rogue.

Like a warehouse manager catching an eager employee signing for a delivery they aren't authorized to accept, the pipeline mechanically unrolls the unauthorized action. It runs git reset --mixed, a specific git command that erases the AI's commit from the ledger but leaves the actual code sitting untouched on the workbench. The pipeline then properly inspects the code, runs the tests, and if everything passes, the orchestrator officially signs for it with a legitimate commit.

### Cascade Cleanup vs. Orchestrator Failure

Things go wrong constantly. The AI writes syntax errors or times out after 15 minutes of silence. If a task fails, the pipeline allows up to two retries with a fresh AI process, feeding it the error message.

If it still fails, the task is marked as blocked, and the pipeline runs a Cascade Cleanup (git reset --hard HEAD and git clean -fd). This instantly and permanently wipes the AI's broken code out of the workspace. You never want tomorrow's work built on top of today's mistakes.

Crucially, the system knows the difference between an AI failure and an infrastructure failure. If the AI writes great code that passes the tests, but the orchestrator fails to commit it (say, due to a Windows file lock or a formatting hook), the pipeline halts. It doesn't wipe the workspace; it preserves the verified code and waits for a human to untangle the mechanical error in the morning.

### Dynamic Replanning

What happens if the plan is wrong?

Imagine Task 4 is to update a database schema, and Task 5 is to update the API to match. But while working on Task 4, the AI realizes the schema doesn't need updating at all. Suddenly, Tasks 5 through 8 are architecturally invalid.

If the pipeline forces the AI to execute an obsolete plan, the codebase turns to spaghetti. To solve this, the AI is given an escape hatch. If it realizes the remaining tasks no longer make sense based on the current reality of the codebase, it can output a signal: TASK_BLOCKED: REPLAN_NEEDED.

When the orchestrator sees this signal, it cleanly exits the execution loop. The Brain catches the exit, looks at the current state of the code, and runs a miniature version of Stage 5 inline. It dynamically regenerates a brand new JSON task list for whatever work remains, then restarts the execution loop. It is an autonomous, mid-flight pivot (capped at two replans per night to prevent infinite loops).

## The Morning Report (Stages 7-9 & Telemetry)

Once the execution loop finishes, the pipeline wraps up the night.

**Stage 7:** It pushes the branch to GitHub and uses the GitHub CLI to open a draft Pull Request.

**Stage 8:** If every task succeeded, it switches back to the main branch, applies a markdown strikethrough to the completed priority in PRIORITIES.md, and commits the updated to-do list.

**Stage 9:** Claude writes a structured post-mortem detailing what was built, what failed, and what architectural patterns emerged. This report feeds into the next night's Stage 4 PRD generation, creating a continuous learning loop.

Finally, the orchestrator records operational telemetry. By using regular expressions to parse the AI's terminal output, it extracts the exact number of API tokens consumed and the fractional cost in USD. It appends a row to build-history.csv logging the date, the priority item, the wall-clock duration, the task success ratio, the tokens, and the cost. The state file is deleted, and the program goes to sleep.

## The Three-Layer Review System

When I sit down with my coffee the next morning, I don't just blindly merge the Pull Request. Autonomous code requires adversarial scrutiny.

Before a line of code reaches the main branch, it goes through a three-layer review model:

**The Tribunal (Mechanical + Adversarial):** Two different AI models run in parallel. GPT-5.2 Codex acts as a strict, mechanical code critic, looking for unhandled errors, state leaks, and syntax flaws. Gemini 3 Pro acts as an adversarial skeptic, looking for security vulnerabilities and faulty assumptions.

**Deep Think (Architecture & Arbitration):** Because the Tribunal models often disagree, I feed their findings -- along with the entire codebase -- into a frontier model with a massive context window (like Gemini Ultra). It acts as the referee, filtering out false positives and checking if the new code structurally aligns with the broader system architecture.

**The Architect (Human):** Finally, I read the code, the Tribunal's red flags, and the Arbitrator's summary. I make the final call on taste, strategy, and business logic.

This review model is ruthlessly effective. In fact, it is what hardened the Agent Relay pipeline itself. During a recent audit, I subjected the pipeline's own source code to this exact tribunal. After three grueling rounds of adversarial review -- catching race conditions, state leaks, and a silent bug in the replan mechanism -- the pipeline earned a definitive A+ engineering grade.

## The Track Record

The system has completed 26 overnight builds against a single target project: a stdlib-only Python codebase with zero external dependencies. Across those builds, it has autonomously written and shipped over 2,500 tests. A typical night runs two to four hours, processes eight to twelve tasks, and lands a 70-85% first-attempt success rate per task. The remaining tasks either succeed on retry or are cleanly marked as failed for morning triage.

Every build appends a row to the telemetry ledger. Every build writes its own post-mortem. Every post-mortem feeds forward into the next build's planning stage. The system does not get smarter in the way a human does -- it has no persistent memory between nights. But the artifacts it leaves behind get richer, and the human reading them in the morning gets a compounding informational advantage. The factory floor stays the same. The blueprints it receives keep improving.
