---
name: graft-skill
description: Use the locally installed Graft CLI (@nanonets/graft) to map, query, and trace an existing codebase through its context graph. Trigger for requests to use Graft, inspect a graft/ graph, find relevant code, map a repository, trace callers/callees, search indexed code, check graph freshness, initialize Graft/MCP wiring, or install/upgrade the Graft CLI.
---

# Graft CLI

Use Graft as the codebase-orientation layer before broad text search or large file reads. Prefer the bundled wrapper so PATH differences across machines do not matter:

```sh
./scripts/graft.sh <subcommand> ...
```

## Installation

Graft is distributed as the official npm package and requires Node.js **>=20**:

```sh
npm install -g @nanonets/graft
```

First check whether it already exists:

```sh
./scripts/graft.sh --version
```

If missing, explain that the install changes global npm state and ask the user for explicit confirmation. Only then run:

```sh
./scripts/install-graft.sh
```

Do not hard-code a global npm bin path. The wrapper first resolves `graft` from `PATH`, then checks `npm prefix -g`.

## Default workflow: understand code without changing it

1. Require a repository root or locate one from the task context.
2. Run `graft check <repo> --json` to see whether a graph exists/is fresh.
3. If a usable graph exists, orient with `graft map <repo> --json`.
4. Use the narrowest query:
   - Concept/question → `graft ask "<question>" <repo> --source --json`
   - Symbol call impact → `graft callers <symbol> <repo> --direction in|out --depth <N> --json`
   - Pattern → `graft grep "<pattern>" <repo> --json`; add `--fixed` for literal input.
   - File API → `graft skeleton <repo-relative-file> <repo> --json`
5. Use returned exact file/line results to read only the relevant code.

Pass `--no-refresh` to query commands when strictly read-only behavior is required. Without it, Graft may structurally refresh stale files under `graft/` before answering.

## Graph setup and mutation boundaries

Never install, upgrade, build, initialize, deep-index, launch servers, or register MCP wiring without the user's current explicit confirmation.

For an uninitialized repository, first show a non-mutating preview:

```sh
./scripts/graft.sh init <repo> --dry-run --no-global
```

Then explain affected paths and offer the narrowest command. For an Agent-compatible repo integration, prefer:

```sh
./scripts/graft.sh init <repo> --agents agents --no-global
```

Use `graft build <repo>` only after approval. It creates/updates `graft/`. Use `--deep` only when the user has approved configured-provider usage and any potential API cost; it needs `GRAFT_PROVIDER`, `GRAFT_MODEL`, `GRAFT_API_KEY`, and possibly `GRAFT_BASE_URL`.

Treat `graft viz` and `graft mcp` as long-running services. Use `viz --no-open` by default; use `mcp` only when configuring an MCP client or when the user explicitly requests the server.

## Native MCP tools

`graft mcp <repo>` exposes these tools to MCP-capable clients:

- `graft_find_code`
- `graft_trace_calls`
- `graft_find_all`
- `graft_file_api`
- `graft_repo_map`
- `graft_check_freshness`

Prefer native MCP registration (via reviewed `graft init`) over manually keeping an stdio process alive. If native MCP registration is unavailable, use the wrapper CLI commands above.

## Output discipline

- State the repository and whether the graph was fresh, stale, or absent.
- Summarize query results with exact paths/symbols, not speculative conclusions.
- If no graph exists, offer a preview and wait for approval before creating one.
- Read [references/commands.md](references/commands.md) for the full command matrix and safety details.
