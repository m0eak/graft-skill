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
| Check graph freshness (raw) | `graft check <repo> --json` |

All query commands normally refresh the graph if it is stale. This is an implicit local write to `graft/`; use `--no-refresh` when the user requests strictly read-only behavior or has not approved graph refresh. `map`, `ask`, `grep`, `callers`, and `skeleton` all accept `--no-refresh`.

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

The supported-extension set is discovered by `scripts/graft-runtime.sh` from the installed `@nanonets/graft` package — never hard-coded. `runtimeVersion` comes from `graft --version`; `supportedSetVersion` is the package.json version; `supportedExtensions` is extracted from `dist/context/build.js` (`CODE_EXTENSIONS`). The set this skill was validated against (`0.10.1`):

```
.ts .tsx .js .jsx .mjs .cjs .py .go .rs .java .kt .scala
.rb .php .c .h .cpp .hpp .cc .cs .swift .sql .sh .proto
```

`--extensions` on `graft build`/`check` only **narrows** this walk set. It does **not** add support for OpenWrt `.config`, YAML/JSON data, `Makefile`, or any other language/file type. Do not present `--extensions` as a way to index unsupported content.

## Check wrapper (`scripts/graft-check.sh`)

Safe JSON wrapper around `graft check <repo> --json`. It reports the real CLI exit code but **never classifies from it alone**: the CLI can exit 0 while `context.missing=true`, which must be judged `needs_initialization`, not usable. It parses `context.ok`, `context.missing`, `graph.ok` and the drift arrays.

```
usage: graft-check.sh <repo-path>
```

| Exit | Status | Usable | Meaning |
|---|---|---|---|
| 0 | `fresh` | true | `context.ok && graph.ok` — graph is fresh and queryable |
| 1 | `stale` | false | context/graph exists but drifted (`context.ok=false` or `graph.ok=false`) |
| 2 | `needs_initialization` | false | `context.missing=true` (even if the CLI exited 0); also covers `graph: null` when nothing is built |
| 10 | `error` (`graft_not_found`) | false | graft CLI not found on PATH or via `npm prefix -g` |
| 11 | `error` (`unparseable_json`) | false | the CLI produced no parseable check JSON |
| 12 | `error` (`bad_path`) | false | target is not a directory, or bad usage |

Key JSON fields: `status`, `usable`, `freshness` (`fresh`/`stale`/`not_built`), `context.{ok,missing,drifted,contentDrift,removed,coverage,indexDrift}`, `graph.{ok,missing,drifted,added,removed,changed,stale,pending}`, `cli.{found,version,exitCode}`, `signal`, `recommendation`, `notes`.

The wrapper runs `graft check` (pure I/O + hashing in the installed CLI, no writes) and `graft --version`; it never calls init/build/install/upgrade and never writes to the target repository.

## Commands that require confirmation

| Command | Why |
|---|---|
| `npm install -g @nanonets/graft` / `graft upgrade` | Modifies global npm packages |
| `graft init` | Creates/updates graph and agent wiring; may write user-level agent config unless `--no-global` |
| `graft build` / `graft build --deep` | Creates/updates `graft/`; `--deep` may use configured LLM credentials and incur provider cost |
| `graft viz` | Starts a local server; use `--no-open` by default |
| `graft mcp` | Starts a long-running stdio server; prefer native MCP registration via `graft init` after review |

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
