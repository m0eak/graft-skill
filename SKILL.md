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

## Pre-flight: run the doctor before any build/init

Before deciding to build or initialize a repository, run the bundled read-only pre-flight check. It never writes to the target repo; it only runs `graft --version` (read-only) for runtime discovery:

```sh
./scripts/graft-doctor.sh <repo>
```

It prints one JSON document on stdout and exits with a code that maps to a state:

| Exit | Status | Meaning / next step |
|---|---|---|
| 0 | `ready` | Graph exists with nodes — orient with `graft map --json --no-refresh` |
| 1 | `partial` | Fallback: a `graft/` graph exists but is empty (empty graph, possibly never built or the build failed), OR the repo is a mixed source/orchestration repo (supported files are a minority) even when no `graft/` graph exists — build only after user confirmation; often a fallback (rg/limited reads) is more useful. The signal distinguishes an empty graph from a mixed repo |
| 2 | `unsupported` | No graft-supported code extensions at all — do **NOT** build; use rg/limited reads, or index the real source directory |
| 3 | `uninitialized` | No graph and no mixed signal, but supported code exists — init/build only after explicit user confirmation (`graft init --dry-run --no-global` preview first) |
| 4 | `error` | Target path is not a directory, or bad usage |
| 5 | `unavailable` | The supported-extension set could not be determined (graft and/or the `@nanonets/graft` npm package missing, or `CODE_EXTENSIONS` could not be extracted). The doctor does **not** silently fall back to a stale hard-coded list; it reports this state with install / manual-check guidance |

The doctor reports graph node/edge counts, per-extension file stats, and a `mixed` flag when config/orchestration files dominate. Machine-parseable JSON makes it safe to gate automation on the result.

**The doctor never judges graph freshness** — it only inspects `graft/.graph/wiring.json` on disk and always emits `"freshness":"not_checked"`. Confirm freshness separately with the bundled `./scripts/graft-check.sh <repo>` wrapper.

### Runtime / supported-set discovery (dynamic, never hard-coded)

`graft-doctor.sh` delegates to `scripts/graft-runtime.sh`, which resolves the installed runtime without hard-coding versions or extension lists. `graft-runtime.sh --json` reports all of the following; the doctor surfaces `runtimeVersion`, `supportedSetVersion`, `supportedExtensions`, `supportDiscovery`, and `discoveryNotes` in its JSON:

- `runtimeVersion` — from `graft --version` (read-only probe) when the CLI is on PATH or under `npm prefix -g`.
- `packageDir` — the `@nanonets/graft` package, located via `npm root -g`, then the graft bin symlink target, then `npm prefix -g`.
- `supportedSetVersion` — the package.json version (the source version of the supported-extension set).
- `supportedExtensions` — the real `CODE_EXTENSIONS` list extracted from `dist/context/build.js` of the installed package (heuristic: only `.<ext>` tokens inside the `CODE_EXTENSIONS = [ ... ]` literal are kept, so comments/other strings are not mistaken for extensions).
- `supportDiscovery` — `ok` | `not_installed` | `package_not_found` | `extract_failed`; anything other than `ok` makes the doctor report `unavailable` (exit 5) instead of guessing.

Supported languages are therefore whatever the **installed** package actually indexes. **`--extensions` on `graft build`/`check` only narrows which of these files are walked; it does NOT add new language support.** A pure `.config`/YAML/`Makefile` orchestration repo cannot be made indexable by passing flags.

## Default workflow: understand code without changing it

0. Pre-flight: `./scripts/graft-doctor.sh <repo>`. If the status is `unsupported` or `partial`, follow the fallback strategy below instead of proposing a build. If it is `unavailable` (exit 5), the supported set could not be determined — do not guess; follow the doctor's guidance (install graft or check the package manually).
1. Require a repository root or locate one from the task context.
2. Check graph usability/freshness with the safe wrapper: `./scripts/graft-check.sh <repo>`. It wraps `graft check <repo> --json`, parses `context.ok` / `context.missing` / `graph.ok`, and reports `usable` / `freshness` / `graph` semantics without trusting the CLI exit code alone (the CLI can exit 0 while `context.missing=true`, which must be treated as "needs initialization", not "usable").
3. If a usable graph exists, orient with `graft map <repo> --json`.
4. Use the narrowest query:
   - Concept/question → `graft ask "<question>" <repo> --source --json`
   - Symbol call impact → `graft callers <symbol> <repo> --direction in|out --depth <N> --json`
   - Pattern → `graft grep "<pattern>" <repo> --json`; add `--fixed` for literal input.
   - File API → `graft skeleton <repo-relative-file> <repo> --json`
5. Use returned exact file/line results to read only the relevant code.

Pass `--no-refresh` to query commands when strictly read-only behavior is required. Without it, Graft may structurally refresh stale files under `graft/` before answering.

## Supported languages (dynamic, from the installed package)

The supported-extension set is **discovered dynamically** by `graft-runtime.sh` from the installed `@nanonets/graft` package (`dist/context/build.js`), never hard-coded. The doctor's `supportedExtensions` field lists the actual set, and `supportedSetVersion` is the package version that ships it (the source version of the set, **not** a runtime Graft version; use `graft --version` for the installed CLI version). On the machine this skill was validated against, the set is:

```
.ts .tsx .js .jsx .mjs .cjs .py .go .rs .java .kt .scala
.rb .php .c .h .cpp .hpp .cc .cs .swift .sql .sh .proto
```

Anything else (OpenWrt `.config`, YAML/JSON data, `Makefile`, `.md`, `.pkl`, binary files, etc.) is not parsed into the graph. `--extensions` only filters this list; it cannot add support for other languages or file types.

## Fallback for unsupported / partial repos (OpenWrt builders etc.)

When the doctor reports `unsupported` or `partial` for a repo dominated by build-orchestration files (OpenWrt `.config`, YAML workflows, `Makefile`, init scripts), do **not** use `graft build` to "solve" it — the resulting graph would be empty or near-empty. A `partial` result is a fallback even when no `graft/` graph exists yet (mixed repo): do not propose `init`/`build` as a first step:

- Prefer `rg` and limited reads, scoped to the meaningful code/config directories: `config/`, `sh/`, `Makefile`, `default-settings-*`, `.github/`.
- If the real OpenWrt source code lives in a separate directory, run the doctor against and index **that** source directory, not the Builder orchestration repo.
- See [references/commands.md](references/commands.md) for the detailed fallback matrix and the reason `build` cannot help.

## Graph setup and mutation boundaries

Never install, upgrade, build, initialize, deep-index, launch servers, or register MCP wiring without the user's current explicit confirmation. Run the doctor first; if it reports `unsupported`, do not propose `init`/`build` at all.

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

- State the repository, the doctor status (`ready`/`partial`/`unsupported`/`uninitialized`/`unavailable`), and the graft-check result (`fresh`/`stale`/`needs_initialization`/`error`). The doctor does **not** judge freshness — report its `"freshness":"not_checked"` and confirm actual freshness with `./scripts/graft-check.sh <repo>` (it reports `usable`/`freshness`/`graph` from the parsed `graft check --json` output).
- Summarize query results with exact paths/symbols, not speculative conclusions.
- If no graph exists, offer a preview and wait for approval before creating one.
- Read [references/commands.md](references/commands.md) for the full command matrix, doctor exit codes, the check-wrapper semantics, and the OpenWrt fallback strategy.
