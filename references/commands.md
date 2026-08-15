# Graft command reference

## Read-only defaults

| Goal | Command |
|---|---|
| Verify CLI/version | `graft --version` / `graft version` |
| Orient in a repo | `graft map <repo> --json` |
| Find relevant code | `graft ask "<question>" <repo> --source --json` |
| Inspect one file API | `graft skeleton <repo-relative-file> <repo> --json` |
| Find callers/callees | `graft callers <symbol> <repo> --direction in|out --depth <N|all> --json` |
| Regex/literal search | `graft grep "<pattern>" <repo> [--fixed] --json` |
| Check graph freshness | `graft check <repo> --json` |

All query commands normally refresh the graph if it is stale. This is an implicit local write to `graft/`; use `--no-refresh` when the user requests strictly read-only behavior or has not approved graph refresh.

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
