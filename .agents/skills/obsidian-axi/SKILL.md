---
name: obsidian-axi
description: >-
 AXI-compliant Obsidian vault operations — search notes, view content, explore backlinks,
 manage tasks, inspect tags, and read daily notes with token-efficient TOON output.
 Use when the agent needs to read, search, or explore an Obsidian knowledge base.
user-invocable: false
metadata:
  internal: true
---

# obsidian-axi

Token-efficient Obsidian CLI wrapper for AI agents. Provides structured, agent-ergonomic access to an Obsidian vault with TOON output (~40% token savings over JSON).

## Commands

| Command | Description |
|---------|-------------|
| `obsidian-axi` | Dashboard — vault info, open tasks, tags |
| `obsidian-axi search ` | Search vault content |
| `obsidian-axi note list [folder]` | List files in vault |
| `obsidian-axi note view ` | Read a note (truncated; use `--full` for complete) |
| `obsidian-axi note create --title ` | Create a new note |
| `obsidian-axi backlinks ` | Show incoming references |
| `obsidian-axi tags` | List tags with counts |
| `obsidian-axi tasks` | List open tasks |
| `obsidian-axi daily read` | Read today's daily note |
| `obsidian-axi daily append --content ` | Append to daily note |
| `obsidian-axi graph ` | Show outgoing links |
| `obsidian-axi vault` | Vault info (name, files, folders) |

## Examples

```
obsidian-axi search "machine learning"
obsidian-axi note view "Projects/My Project/index.md"
obsidian-axi backlinks "Meta/Open Items.md"
obsidian-axi tasks --done
```

## Installation

```sh
npm install -g obsidian-axi
```

Requires the [Obsidian CLI](https://obsidian.md) (`obsidian` command on PATH) with Obsidian app running.
