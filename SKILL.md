---
name: codex-clean-subagents
description: Safely audit and permanently delete local Codex histories belonging only to closed leaf subagents under explicitly selected main threads. Use when Codex subagent rollout files consume substantial disk space and the user wants to reclaim it without deleting main conversations, open subagents, caches, databases, or unrelated thread families.
---

# Clean Codex Subagents

Reclaim disk space from closed Codex subagent histories while preserving selected main conversations. Treat every deletion as permanent and require separate user approval for the canary and the batch.

## Safety contract

- Operate only on exact main-thread UUIDs approved by the user.
- Select only descendants whose `thread_source` is `subagent`, whose incoming edge status is only `closed`, and which have no outgoing spawn edges.
- Exclude open subagents, main/user threads, unrelated families, caches, databases, and all data outside the explicitly audited Codex subagent histories.
- Use only `codex delete --force <UUID>` for deletion. Never delete rollout files directly, mutate SQLite, run `VACUUM`, or parallelize database writes.
- Run Codex while cleaning if needed. Hash each main rollout through a shared-read handle and verify that its original byte prefix remains unchanged; allow only append-only growth caused by an active conversation.
- Freeze the audited target IDs in a manifest. Never add newly eligible descendants to that manifest after the canary.
- Stop on the first delete failure or verification failure. Report partial completion and do not guess, retry globally, or broaden scope.
- Explain before approval that removed child histories cannot be restored and cease to be individually inspectable. The main thread retains only information already incorporated into its own history.

OpenAI documents that subagent activity is inspectable as separate threads while the main thread collects their results. It does not document local deletion guarantees, so verify the installed CLI and local state rather than assuming semantics: https://learn.chatgpt.com/docs/agent-configuration/subagents

## Use the bundled workflow

Run `scripts/clean_subagents.ps1` from this skill directory. The script reads `state_*.sqlite` through Python's standard-library SQLite driver but never writes to it.

### 1. Discover candidate main threads

Run a read-only summary when the user has not supplied exact root UUIDs:

```powershell
& "$PSScriptRoot/scripts/clean_subagents.ps1" -Mode Discover -Top 25
```

Show the user the root UUID, title, eligible closed-leaf count, and reclaimable size. Do not infer approval from a title match.

### 2. Audit an approved scope

Run `Audit` with one or more exact root IDs:

```powershell
& "$PSScriptRoot/scripts/clean_subagents.ps1" -Mode Audit `
  -RootThreadId '<root-uuid-1>','<root-uuid-2>'
```

Report:

- selected main threads;
- eligible target count and bytes;
- open and non-leaf subagents excluded;
- largest eligible child histories;
- the generated manifest path.

Do not proceed until the user explicitly approves one permanent canary deletion.

### 3. Delete one canary

Use the exact manifest emitted by `Audit`:

```powershell
& "$PSScriptRoot/scripts/clean_subagents.ps1" -Mode Canary `
  -ManifestPath '<manifest.json>' -ConfirmPermanentDeletion
```

The script chooses the smallest existing eligible rollout, deletes it sequentially through the installed Codex CLI, verifies removal of its row, spawn edge, and rollout file, and verifies every main rollout prefix.

Report the canary ID, reclaimed size, and main-thread verification. Obtain a second explicit approval for the remaining frozen batch.

### 4. Apply the frozen batch

Only after that second approval, run:

```powershell
& "$PSScriptRoot/scripts/clean_subagents.ps1" -Mode Apply `
  -ManifestPath '<manifest.json>' -ConfirmPermanentDeletion
```

The script refuses to apply a manifest without a verified canary. It revalidates every pending ID as a closed leaf, deletes sequentially with bounded retries, records progress in the manifest, and verifies all deleted rows, edges, files, and main rollout prefixes.

## Interpret outcomes

- `Audit` and `Discover` make no changes to Codex state. `Audit` writes only a small manifest to the system temp directory unless `-ManifestPath` is supplied.
- `Canary` and `Apply` are irreversible. Treat `delete_command_succeeded`, `delete_failed`, or a verification error as partial completion that needs inspection before any new audit.
- A successful `Apply` reports deleted count, logical rollout bytes, actual free-space change, and preserved main roots.
- If the state schema, `codex delete --force`, root identity, path, eligibility, or prefix hash differs from expectations, stop and explain the mismatch.

## Requirements

- PowerShell 7 or Windows PowerShell 5.1
- Python 3.9+ with the standard `sqlite3` module
- the local `codex` executable for destructive modes
