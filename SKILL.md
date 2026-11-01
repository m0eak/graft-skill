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

## Telemetry and outbound network

Current graft releases (newer than 0.10.1) ship **anonymous telemetry that is on by default** and flushes daily to `https://events.nanonets.com`. This is a deliberate, disclosed design choice by the upstream project, not a misconfiguration — surface it to the user as information, and let them decide.

Two different questions, two different commands:

```sh
graft telemetry                  # the SAVED preference: on/off, endpoint, queued count
DO_NOT_TRACK=1 graft telemetry debug   # no outbound at all: queued count + exact payload
```

`graft telemetry` reports what the user's machine is actually configured to do, but that invocation runs the startup hook and may trigger the daily flush. `DO_NOT_TRACK=1 graft telemetry debug` makes no outbound attempt and still shows the queue and the batch — but note its status line then reads **"off: DO_NOT_TRACK is set in this environment"**, which reflects the override on this one call, **not** the saved preference. Do not report that as "the user has telemetry disabled".

`debug` prints the batch and sends nothing **itself**, but that is not the whole story. The CLI runs a startup hook (`preAction`) for every subcommand except `version`, `upgrade`, `_update-check` and `mcp` — `telemetry` is not exempt. So a `graft telemetry debug` invocation still evaluates the background update check and the flush gate (24h since the last `flushedAt`), and if that gate is open the invocation can trigger a detached send.

If the point of the command is "show me this without anything leaving the machine", run it as:

```sh
DO_NOT_TRACK=1 graft telemetry debug
```

`DO_NOT_TRACK` (or `graft telemetry disable`) is the actual off switch; `debug` alone is not.

What the payload actually contains (verified on the wire body, not the docs): `app_version`, `os`, `arch`, `node_major`, `ci`, `agent_host`, `cli_name`, `command`, `surface`, `repo_id` (an opaque random UUID), `distinct_id` (per-install id), `timestamp`. It does **not** contain source code, file paths, file names, or repository names.

To turn it off, only if the user asks for it:

```sh
graft telemetry disable   # or export DO_NOT_TRACK=1
```

Treat disabling as a user preference, not a required hardening step. If the user is indifferent, leave the default alone and mention the tradeoff in one line rather than pushing the change.

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
2. Check graph usability/freshness with the safe wrapper: `./scripts/graft-check.sh <repo>`. It wraps `graft check <repo> --json`, parses `context.ok` / `context.missing` / `graph.ok` / `graph.nodes`, and reports `usable` / `freshness` / `deepLayer` without trusting the CLI exit code alone. It reports `structural_only` (usable) when the structural graph is current but the LLM concept layer is absent — the normal state after a plain `graft build` — and reserves `needs_initialization` for a genuinely absent or empty graph.
3. If a usable graph exists, orient with `graft map <repo> --json`.
4. Use the narrowest query:
   - Concept/question → `graft ask "<question>" <repo> --source --json`
   - Symbol call impact → `graft callers <symbol> <repo> --direction in|out --depth <N> --json`
   - Diff blast radius → `graft blast <repo> --format json` (see below)
   - Pattern → `graft grep "<pattern>" <repo> --json`; add `--fixed` for literal input.
   - File API → `graft skeleton <repo-relative-file> <repo> --json`
5. Use returned exact file/line results to read only the relevant code.

### Never pipe graft output through a filter

Do **not** pipe graft commands through `head`, `tail`, or `sed -n`. Graft's output is already token-capped and states what it dropped; clipping it silently discards hits you asked for and strips the `[graft] tokens saved ≈ N` line that carries the savings figure. Run the command and read its own bounds instead.

### Report what graft saved

In its human-readable (text) output, a retrieval tool opens with a `[graft] tokens saved ≈ N` line when the call actually saved anything. When a turn used graft tools in text mode, close the reply with a one-line tally across those calls, e.g. `🌱 graft saved ~12,400 tokens this turn (3 calls)`. Some lines also state a dollar value at the session's actual input rate — include it alongside the token total when present, and never price it yourself when absent.

Two cases where a missing line does **not** mean "saved nothing":

- **`--json` output never carries the savings line.** JSON is the machine-readable surface, so its absence there is expected. Do not report "saved 0" from a JSON call — say the figure was not provided, or re-run in text mode if the user wants the number.
- **Genuinely tiny targets** (where the pointers cost as much as the source) save nothing and print no line; those can be skipped.

### Blast radius of a diff

`graft blast` reports what depends on the lines a change touched — the diff-scoped counterpart to `callers --depth N`. It is `$0` and makes no LLM call, but like every query command **it refreshes a stale graph before answering**, so it can write under `graft/`. Add `--no-refresh` for strict read-only use.

```sh
graft blast <repo> --format json --no-refresh                     # working tree vs HEAD
graft blast <repo> --base origin/main --format json --no-refresh  # vs a branch's merge base
```

- `--depth N` (default 2) or `--depth all` controls how far incoming edges are walked.
- `--format text|markdown|mermaid|json`; `markdown` produces a PR comment with a Mermaid diagram.
- `--name` adds LLM-named affected areas and needs `GRAFT_API_KEY`; without it, areas are named after their hub symbol.
- `--export-viz <dir>` writes a self-contained `index.html` — a **filesystem write**, so treat it as a mutation requiring confirmation.
- By default git history is used to suggest reviewers; `--no-owners` disables that, `--pr-author <who>` excludes a given author.

Pass `--no-refresh` to query commands when strictly read-only behavior is required. Without it, Graft may structurally refresh stale files under `graft/` before answering.

## Supported languages (dynamic, from the installed package)

The supported-extension set is **discovered dynamically** by `graft-runtime.sh` from the installed `@nanonets/graft` package (`dist/context/build.js`), never hard-coded. The doctor's `supportedExtensions` field lists the actual set, and `supportedSetVersion` is the package version that ships it (the source version of the set, **not** a runtime Graft version; use `graft --version` for the installed CLI version). The set has already changed across releases — 0.10.1 shipped 24 extensions and 0.28.1 ships 25 (adding `.gleam`) — which is exactly why it must be read from the installed package rather than pinned here. On the machine this skill was validated against (`0.28.1`):

```
.ts .tsx .js .jsx .mjs .cjs .py .go .rs .java .kt .scala
.rb .php .c .h .cpp .hpp .cc .cs .swift .gleam .sql .sh .proto
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

`graft uninstall` is the inverse of `init`: it removes graft's instruction files, MCP/hook entries, and repo wiring, and with default settings also touches out-of-repo config (`~/.codex`, `~/.gemini`). Run it without `-y` first to print what it would remove, report that list, and get explicit confirmation before adding `-y`. `--keep-cache` limits it to wiring and leaves `graft/` plus its `.gitignore` entries intact.

### Consent boundaries for the newer cloud-facing flags

Current `init` also exposes flags that send repository-derived data off the machine. Never use these without the user asking for them specifically, and state what leaves the machine before doing so:

| Flag | What leaves the machine |
|---|---|
| `--connect <code>` | Connects this machine to a Trail workspace and sends a summary of the repo — titles, counts and names (upstream states: never code) |
| `--pair <code>` | Pairs with Trail's onboarding page, which shows the run live for review, then uploads what it found |
| `--look-back` / `--plain` | Reviews past agent sessions on this machine to surface what isn't kept yet |

`--connect`, `--pair`, and `graft skills` are tied to Trail's hosted workspace. They are outside the local `$0` analysis path; treat them as opt-in integrations rather than default workflow steps.

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

- State the repository, the doctor status (`ready`/`partial`/`unsupported`/`uninitialized`/`unavailable`), and the graft-check result (`fresh`/`structural_only`/`stale`/`needs_initialization`/`indeterminate`/`error`). The doctor does **not** judge freshness — report its `"freshness":"not_checked"` and confirm actual freshness with `./scripts/graft-check.sh <repo>` (it reports `usable`/`freshness`/`deepLayer`/`staleLayer`/`nodesSource` from the parsed `graft check --json` output).
- `deepLayer: missing` means "no `--deep` concept layer", which is only reassuring when `status` is `structural_only`. If `status` is `needs_initialization` or `indeterminate`, the structural graph itself is absent, empty, or unknown — never describe those as "structural graph only".
- On `stale`, read `staleLayer` before proposing a fix: `graph` needs a plain `graft build` (local, `$0`); `context` or `both` need `graft build --deep`, which spends provider tokens — a plain build will not repair the concept layer, so recommending it sends the user in a circle.
- Summarize query results with exact paths/symbols, not speculative conclusions.
- If no graph exists, offer a preview and wait for approval before creating one.
- Read [references/commands.md](references/commands.md) for the full command matrix, doctor exit codes, the check-wrapper semantics, and the OpenWrt fallback strategy.
