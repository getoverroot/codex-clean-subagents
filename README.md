# codex-clean-subagents

[![Validate](https://github.com/getoverroot/codex-clean-subagents/actions/workflows/validate.yml/badge.svg)](https://github.com/getoverroot/codex-clean-subagents/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows-0078D4.svg)](#requirements)
[![Compatibility: Experimental](https://img.shields.io/badge/compatibility-experimental-orange.svg)](#project-status)

An unofficial Codex skill for safely reclaiming disk space occupied by closed subagent histories while preserving main conversations and active work.

The cleanup is deliberately conservative: it discovers candidates read-only, freezes an explicitly approved scope in a manifest, deletes one canary, and only then permits a separately approved batch.

## Safety model

The skill only considers a thread eligible when all of the following are true:

- it is a descendant of an explicitly selected main-thread UUID;
- its `thread_source` is `subagent`;
- all incoming spawn edges are `closed`;
- it has no outgoing spawn edges.

It intentionally excludes:

- main and user conversations;
- open or non-closed subagents;
- non-leaf subagents;
- unrelated thread families;
- Codex caches and databases;
- any data outside the explicitly audited Codex subagent histories.

Deletion is performed sequentially through the installed `codex delete --force <UUID>` command. The scripts never delete rollout files directly, write to the Codex SQLite database, or run `VACUUM`.

> [!WARNING]
> Canary and batch deletions are permanent. A deleted subagent history can no longer be inspected individually. The main conversation keeps only information already incorporated into its own history.

## Workflow

| Mode | Changes Codex state | Purpose |
| --- | --- | --- |
| `Discover` | No | List main threads with eligible closed leaf subagents. |
| `Audit` | No | Freeze exact target UUIDs in a small manifest. |
| `Canary` | Yes, one thread | Delete and verify the smallest eligible rollout. |
| `Apply` | Yes, frozen remainder | Delete the audited batch after separate approval. |

For destructive modes, every selected main rollout is opened with shared-read access and hashed. Verification permits append-only growth from an active conversation but rejects truncation or changes to its existing byte prefix.

## Installation

Clone the repository and copy the skill files into your personal Codex skills directory:

```powershell
git clone https://github.com/getoverroot/codex-clean-subagents.git

$source = Join-Path $PWD 'codex-clean-subagents'
$target = Join-Path $env:USERPROFILE '.codex\skills\codex-clean-subagents'

New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'SKILL.md') -Destination $target -Force
Copy-Item -LiteralPath (Join-Path $source 'agents') -Destination $target -Recurse -Force
Copy-Item -LiteralPath (Join-Path $source 'scripts') -Destination $target -Recurse -Force
```

Start a new Codex session if the skill is not discovered immediately, then invoke it with:

```text
$codex-clean-subagents
```

## Manual usage

The skill normally drives this workflow for you. The bundled PowerShell entry point can also be run directly.

Discover candidate root conversations:

```powershell
.\scripts\clean_subagents.ps1 -Mode Discover -Top 25
```

Audit exact roots without deleting anything:

```powershell
.\scripts\clean_subagents.ps1 -Mode Audit `
  -RootThreadId '<root-uuid-1>','<root-uuid-2>'
```

Delete and verify one canary from the emitted manifest:

```powershell
.\scripts\clean_subagents.ps1 -Mode Canary `
  -ManifestPath '<manifest.json>' `
  -ConfirmPermanentDeletion
```

After reviewing the canary result, delete the remaining frozen targets:

```powershell
.\scripts\clean_subagents.ps1 -Mode Apply `
  -ManifestPath '<manifest.json>' `
  -ConfirmPermanentDeletion
```

Newly eligible descendants are never added after the audit. If state, paths, eligibility, CLI behavior, database schema, or main-rollout hashes differ from expectations, the workflow stops.

## Requirements

- Windows 10 or 11
- PowerShell 7 or Windows PowerShell 5.1
- Python 3.9+ with the standard-library `sqlite3` module
- Codex CLI exposing `codex delete --force`

## Project status

**Compatibility: Experimental.** This is an independent community project, not an official OpenAI package. Codex's local SQLite schema and CLI behavior can change; always review the read-only audit before approving deletion.

## License

[MIT](LICENSE)
