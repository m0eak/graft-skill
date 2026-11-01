# Graft command reference

## Read-only defaults

| Goal | Command |
|---|---|
| Pre-flight repo suitability | `graft-doctor.sh <repo>` (see below) |
| Check graph usability/freshness | `graft-check.sh <repo>` (safe wrapper; see below) |
| Verify CLI/version | `graft --version` / `graft version` |
| Orient in a repo | `graft map <repo> --json` |
| Find relevant code | `graft ask "<question>" <repo> --source --json` |
| Inspect one file API | `graft skeleton <repo-relative-file> <repo> --json` |
| Find callers/callees | `graft callers <symbol> <repo> --direction in|out --depth <N|all> --json` |
| Regex/literal search | `graft grep "<pattern>" <repo> [--fixed] --json` |
| Diff blast radius | `graft blast <repo> --format json --no-refresh [--base <ref>] [--depth N\|all]` |
| Check graph freshness (raw) | `graft check <repo> --json` |
| Telemetry status (read-only) | `graft telemetry` / `graft telemetry debug` |
| Session savings mix | `graft stats <repo> --json` |
All query commands normally refresh the graph if it is stale. This is an implicit local write to `graft/`; use `--no-refresh` when the user requests strictly read-only behavior or has not approved graph refresh. `map`, `ask`, `grep`, `callers`, `blast`, and `skeleton` all accept `--no-refresh`.

**Do not pipe graft commands through `head`, `tail`, or `sed -n`.** Output is already token-capped and self-describing; clipping it drops hits and strips the `[graft] tokens saved ≈ N` line.

## Token savings reporting

In text mode a retrieval tool opens with `[graft] tokens saved ≈ N` when the call saved anything; sum those lines and report the turn total (e.g. `🌱 graft saved ~12,400 tokens this turn (3 calls)`). Verified on 0.28.1: the line appears in text output for a large target, and is **absent from `--json` output** by design. So a missing line in JSON is not evidence of zero savings — report "not provided", or re-run in text mode when the number matters.

## Providers

`--provider` (or `GRAFT_PROVIDER`) accepts `openai`, `anthropic`, `litellm`, `orcarouter`. The `openai` wire format covers any OpenAI-compatible endpoint via `GRAFT_BASE_URL` (OpenRouter, Fireworks, Groq, a LiteLLM proxy, a local server). Only `build --deep`, `blast --name`, and `skills` need a key; the whole structural path is `$0`.

## Telemetry

Newer releases (anything past 0.10.1) have anonymous telemetry **on by default**, flushing daily to `https://events.nanonets.com`. Surface it as information; treat disabling as the user's call.

| Command | Effect |
|---|---|
| `graft telemetry` | Status: state, endpoint, queued count |
| `graft telemetry debug` | Prints the exact batch a flush would POST; sends nothing itself, but the invocation still runs the startup hook (update check + 24h flush gate), so it can trigger a detached flush. Use `DO_NOT_TRACK=1 graft telemetry debug` to be sure |
| `graft telemetry disable` | Turns it off (equivalent to `DO_NOT_TRACK=1`) |

Verified payload fields: `app_version`, `os`, `arch`, `node_major`, `ci`, `agent_host`, `cli_name`, `command`, `surface`, `repo_id` (opaque UUID), `distinct_id` (per-install id), `timestamp`. No source code, paths, or repository names.

## Commands that require confirmation

| Command | Why |
|---|---|
| `npm install -g @nanonets/graft` / `graft upgrade` | Modifies global npm packages |
| `graft init` | Creates/updates graph and agent wiring; may write user-level agent config unless `--no-global` |
| `graft init --connect/--pair/--look-back` | Sends repo-derived data to Trail's hosted workspace (see below) |
| `graft build` / `graft build --deep` | Creates/updates `graft/`; `--deep` may use configured LLM credentials and incur provider cost |
| `graft blast --export-viz <dir>` | Writes a self-contained `index.html` to disk |
| `graft blast --name` | Uses one cached LLM call; needs `GRAFT_API_KEY` |
| `graft viz` | Starts a local server; use `--no-open` by default |
| `graft mcp` | Starts a long-running stdio server; prefer native MCP registration via `graft init` after review |
| `graft uninstall` | Removes instruction files, MCP/hook entries and repo wiring; default also touches `~/.codex`, `~/.gemini`. Run without `-y` first |
| `graft skills add/lesson/keep/update/forget/restore` | Mutates locally kept Trail skills |

### Cloud-facing flags (`init`)

| Flag | What leaves the machine |
|---|---|
| `--connect <code>` | Connects this machine to a Trail workspace and sends a repo summary — titles, counts, names (upstream states: never code) |
| `--pair <code>` | Pairs with Trail's onboarding page, which shows the run live, then uploads what it found |
| `--look-back` / `--plain` | Reviews past agent sessions on this machine |

These sit outside the local `$0` path. Use only when the user asks, and say what leaves the machine first.

## Pre-flight doctor (`scripts/graft-doctor.sh`)

Deterministic, read-only (POSIX sh + standard tools, plus a read-only `graft --version` probe for runtime discovery). It never writes to the target repo. Prints one JSON document on stdout:

```
usage: graft-doctor.sh <repo-path>
```

Exit codes map to states:

| Exit | Status | Meaning | Guidance |
|---|---|---|---|
| 0 | `ready` | graph exists with nodes | queryable; orient with `graft map --json --no-refresh` |
| 1 | `partial` | fallback: a `graft/` graph exists but is empty (empty graph — possibly never built, or the build failed), OR the repo is a mixed source/orchestration repo (supported files a minority) even without a `graft/` graph. The signal distinguishes an empty graph from a mixed repo | build only after user confirmation; often fallback (rg/limited reads) is better |
| 2 | `unsupported` | no graft-supported code extensions | do **NOT** build; use rg/limited reads or index the real source dir |
| 3 | `uninitialized` | no graph and no mixed signal, but supported code exists | `graft init --dry-run --no-global` preview first; init/build only after confirmation |
| 4 | `error` | path is not a directory, or bad usage | fix the path/arguments |
| 5 | `unavailable` | supported-extension set could not be determined (graft and/or `@nanonets/graft` package missing, or `CODE_EXTENSIONS` extraction failed). The doctor does NOT silently fall back to a stale hard-coded list | install graft (after user confirmation) or inspect the package manually; see `supportDiscovery` + `discoveryNotes` |

Key JSON fields: `runtimeVersion`, `supportedSetVersion`, `supportedExtensions`, `supportDiscovery`, `discoveryNotes`, `freshness` (always `"not_checked"`), `status`, `exit`, `signal`, `recommendation`, `graph.{exists,nodeCount,edgeCount,languages,empty}`, `files.{total,supported,supportedExtensions,topUnsupportedExtensions,mixed}`.

**Freshness is not judged by the doctor.** It only inspects `graft/.graph/wiring.json` on disk; run `graft-check.sh <repo>` to confirm whether the graph is actually usable/fresh.

### Doctor detection rules (deterministic)

- **Empty graph (source-majority)**: `graft/` exists, `graft/.graph/wiring.json` has `nodeCount: 0`, and supported files are NOT a minority → `partial` with an "empty graph, possibly never built or the build failed" signal (NOT a mixed repo).
- **Empty graph (mixed)**: same empty graph but supported files ARE a strict minority → `partial` with the mixed source/orchestration signal.
- **No supported extensions**: zero files match the supported set → `unsupported` (takes precedence over partial/uninitialized).
- **Mixed without a graph**: `mixed: true` and no `graft/` graph → `partial` (fallback; do not propose init/build as a first step).
- **Uninitialized (clean)**: no `graft/` graph, `mixed: false`, and supported files exist → `uninitialized`.
- **Missing directory**: target path does not exist or is not a directory → `error`.
- **Discovery failure**: `supportDiscovery` is `not_installed` / `package_not_found` / `extract_failed` → `unavailable` (classification is skipped; no guessing).

### Supported extensions (dynamic, from the installed package)

The supported-extension set is discovered by `scripts/graft-runtime.sh` from the installed `@nanonets/graft` package — never hard-coded. `runtimeVersion` comes from `graft --version`; `supportedSetVersion` is the package.json version; `supportedExtensions` is extracted from `dist/context/build.js` (`CODE_EXTENSIONS`). The set changes between releases (0.10.1 shipped 24; 0.28.1 ships 25, adding `.gleam`), which is why it is read at runtime. The set this skill was last validated against (`0.28.1`):

```
.ts .tsx .js .jsx .mjs .cjs .py .go .rs .java .kt .scala
.rb .php .c .h .cpp .hpp .cc .cs .swift .gleam .sql .sh .proto
```

`--extensions` on `graft build`/`check` only **narrows** this walk set. It does **not** add support for OpenWrt `.config`, YAML/JSON data, `Makefile`, or any other language/file type. Do not present `--extensions` as a way to index unsupported content.

## Check wrapper (`scripts/graft-check.sh`)

Safe JSON wrapper around `graft check <repo> --json`. It reports the real CLI exit code but **never classifies from it alone**. Measured on 0.28.1: the CLI exits **0** both for an empty graph (`nodes=0`) and for a healthy structural-only graph, and exits **1** when no graph exists at all — the same code it uses for a stale graph. So a 0 does not prove the graph is usable, and a 1 does not say which failure it is. The wrapper parses `context.ok`, `context.missing`, `graph.ok`, `graph.nodes` and the drift arrays, and falls back to reading `nodeCount` from `graft/.graph/wiring.json` when the CLI does not report a node count.

```
usage: graft-check.sh <repo-path>
```

| Exit | Status | Usable | Meaning |
|---|---|---|---|
| 0 | `fresh` | true | `context.ok && graph.ok` — both layers fresh and queryable |
| 0 | `structural_only` | true | `graph.ok && nodes>0 && context.missing` — the normal result of a plain `graft build` (no `--deep`). ask/grep/callers/skeleton/map all answer from this graph; only the prose concept layer is absent |
| 1 | `stale` | false | graph exists but drifted (`graph.ok=false` with nodes present) |
| 2 | `needs_initialization` | false | no graph at all (`graph.missing=true`), or a graph indexing `nodes=0` |
| 3 | `indeterminate` | false | the CLI reports no node count **and** `graft/.graph/wiring.json` is unreadable, so an empty graph cannot be told from a populated one. Do not assert "not initialized" and do not infer "usable" — inspect the `graft/` tree |
| 10 | `error` (`graft_not_found`) | false | graft CLI not found on PATH or via `npm prefix -g` |
| 11 | `error` (`unparseable_json`) | false | the CLI produced no parseable check JSON |
| 12 | `error` (`bad_path`) | false | target is not a directory, or bad usage |

**Why `context.missing` alone is not "uninitialized":** `graft build` without `--deep` produces a structural wiring graph and leaves the markdown concept layer absent, so `context.missing=true` while `graph.ok=true` and `nodes>0`. Verified on 0.28.1: that repo answers `graft ask` normally. Classify on the structural graph first, then report the deep layer separately via `deepLayer`.

**Node-count source:** `graph.nodes` exists from 0.28.x on. When a CLI does not report it, the wrapper reads `nodeCount` from `graft/.graph/wiring.json` and records where the number came from in `nodesSource` (`cli` / `wiring.json` / `unknown`). Only when both are unavailable does it return `indeterminate` — it never substitutes a guess.

Key JSON fields: `status`, `usable`, `freshness` (`fresh`/`stale`/`not_built`/`unknown`), `deepLayer` (`present`/`missing`), `nodesSource` (`cli`/`wiring.json`/`unknown`), `context.{ok,missing,drifted,contentDrift,removed,coverage,indexDrift}`, `graph.{ok,missing,drifted,nodes,added,removed,changed,stale,pending}`, `cli.{found,version,exitCode}`, `signal`, `recommendation`, `notes`.

The wrapper runs `graft check` (pure I/O + hashing in the installed CLI, no writes) and `graft --version`; it never calls init/build/install/upgrade and never writes to the target repository.

## Safer mutation preflight

Before `init`, run:

```sh
graft init <repo> --dry-run --no-global
```

Report the prospective changes, then request explicit confirmation. For scripted setup, use the narrowest scope, for example:

```sh
graft init <repo> --agents agents --no-global
```

Use `--no-build` only when the user explicitly wants wiring without an initial graph.

## Fallback strategy: OpenWrt / build-orchestration repos

These repos (e.g. an OpenWrt Builder) are dominated by files Graft does not index: OpenWrt `.config`, YAML CI workflows, `Makefile`, JSON/PKL metadata, init scripts. The doctor usually reports `unsupported` (no supported code files) or `partial` — whether the graph is empty, or there is no graph at all but the repo is mixed (supported files a minority).

**Do not use `graft build` to work around missing language support.** Building only indexes the small supported subset (e.g. `.sh`, `.cjs` hooks); it will never make `.config`/YAML/`Makefile` queryable. The result is an empty or near-empty graph and wasted user-facing churn.

Instead:

1. **Use `rg` and limited reads**, scoped to the meaningful code/config directories:
   - `config/` — the `.config` snippets (search by key, e.g. `CONFIG_PACKAGE_`)
   - `sh/` and other `*.sh` — build/device scripts
   - `Makefile` — package definitions (e.g. under `default-settings-*`)
   - `default-settings-*` — default settings / init snippets
   - `.github/` — CI workflow orchestration (YAML)
2. **Index the real source directory instead.** If the actual OpenWrt source (e.g. `immortalwrt`, `openwrt`) lives in a separate directory, run the doctor against **that** directory and, after confirmation, build/query there. Do not build the Builder orchestration repo to answer questions about source code.

Example read-only fallback commands:

```sh
# Search OpenWrt config keys across the Builder repo
rg 'CONFIG_PACKAGE_' config/ -n

# Inspect a device script
rg -n 'mt5000|ipq' sh/ -i

# Inspect CI workflow
rg -n 'device|profile|target' .github/ -i
```
