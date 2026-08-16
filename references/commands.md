# Graft command reference

## Read-only defaults

| Goal | Command |
|---|---|
| Pre-flight repo suitability | `graft-doctor.sh <repo>` (see below) |
| Verify CLI/version | `graft --version` / `graft version` |
| Orient in a repo | `graft map <repo> --json` |
| Find relevant code | `graft ask "<question>" <repo> --source --json` |
| Inspect one file API | `graft skeleton <repo-relative-file> <repo> --json` |
| Find callers/callees | `graft callers <symbol> <repo> --direction in|out --depth <N|all> --json` |
| Regex/literal search | `graft grep "<pattern>" <repo> [--fixed] --json` |
| Check graph freshness | `graft check <repo> --json` |

All query commands normally refresh the graph if it is stale. This is an implicit local write to `graft/`; use `--no-refresh` when the user requests strictly read-only behavior or has not approved graph refresh. `map`, `ask`, `grep`, `callers`, and `skeleton` all accept `--no-refresh`.

## Pre-flight doctor (`scripts/graft-doctor.sh`)

Deterministic, dependency-free (POSIX sh + standard tools), read-only. It never writes to the target repo and never runs graft. Prints one JSON document on stdout:

```
usage: graft-doctor.sh <repo-path>
```

Exit codes map to states:

| Exit | Status | Meaning | Guidance |
|---|---|---|---|
| 0 | `ready` | graph exists with nodes | queryable; orient with `graft map --json --no-refresh` |
| 1 | `partial` | fallback: graph exists but is empty, or the repo is a mixed source/orchestration repo (supported files a minority) even without a `graft/` graph | build only after user confirmation; often fallback (rg/limited reads) is better |
| 2 | `unsupported` | no graft-supported code extensions | do **NOT** build; use rg/limited reads or index the real source dir |
| 3 | `uninitialized` | no graph and no mixed signal, but supported code exists | `graft init --dry-run --no-global` preview first; init/build only after confirmation |
| 4 | `error` | path is not a directory, or bad usage | fix the path/arguments |

Key JSON fields: `supportedSetVersion`, `freshness` (always `"not_checked"`), `status`, `exit`, `signal`, `recommendation`, `graph.{exists,nodeCount,edgeCount,languages,empty}`, `files.{total,supported,supportedExtensions,topUnsupportedExtensions,mixed}`.

**Freshness is not judged by the doctor.** It only inspects `graft/.graph/wiring.json` on disk; run `graft check <repo> --json` to confirm whether the graph is actually fresh.

### Doctor detection rules (deterministic)

- **Empty graph**: `graft/` exists but `graft/.graph/wiring.json` has `nodeCount: 0` → `partial`.
- **No supported extensions**: zero files match the supported set below → `unsupported` (takes precedence over partial/uninitialized).
- **Mixed source/config**: supported files are a strict minority of total files → `mixed: true`.
- **Mixed without a graph**: `mixed: true` and no `graft/` graph → `partial` (fallback; do not propose init/build as a first step).
- **Uninitialized (clean)**: no `graft/` graph, `mixed: false`, and supported files exist → `uninitialized`.
- **Missing directory**: target path does not exist or is not a directory → `error`.

### Supported extensions (supported-set source: graft 0.10.1)

`supportedSetVersion` in the doctor output is the source version of this extension set (`"0.10.1"`), **not** a runtime Graft version detected by the doctor; use `graft --version` / `graft version` for the installed CLI.

```
.ts .tsx .js .jsx .mjs .cjs .py .go .rs .java .kt .scala .rb .php
.c .h .cpp .hpp .cc .cs .swift .sql .sh .proto
```

`--extensions` on `graft build`/`check` only **narrows** this walk set. It does **not** add support for OpenWrt `.config`, YAML/JSON data, `Makefile`, or any other language/file type. Do not present `--extensions` as a way to index unsupported content.

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
