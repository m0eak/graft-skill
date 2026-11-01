#!/usr/bin/env sh
# graft-check.sh — safe JSON wrapper around `graft check <repo> --json`.
#
# Purpose
#   Report whether a repo's Graft graph is usable and fresh by parsing the real
#   `graft check --json` output. It NEVER relies on the CLI exit code alone:
#   the CLI may exit 0 even when no context graph exists (context.missing=true),
#   which must be judged "needs_initialization", not "usable".
#
# Semantics (derived from parsed JSON only)
#   status              fresh | structural_only | stale | needs_initialization | indeterminate | error
#   usable              true when the structural graph is current and holds nodes
#                       (fresh, or structural_only when the --deep concept layer
#                       is absent — the normal result of a plain `graft build`)
#   freshness           fresh | stale | not_built | unknown
#   context             { ok, missing, drifted, contentDrift, removed, coverage, indexDrift }
#   graph               { ok, missing, drifted, nodes, added, removed, changed, stale, pending }
#   nodesSource         cli | wiring.json | unknown — where the node count came from
#
# Classification
#   context.ok && graph.ok                -> fresh / usable
#   graph.ok && nodes>0 && context.missing -> structural_only / usable
#   graph.missing, or nodes==0            -> needs_initialization
#   node count unknowable                  -> indeterminate (do not guess)
#   graph exists but drifted              -> stale
#
# Exit codes
#   0  fresh or structural_only
#   1  stale
#   2  needs_initialization
#   3  indeterminate (no node count available to distinguish empty from populated)
#   10 graft CLI not found
#   11 graft check output could not be parsed
#   12 target path is not a directory, or bad usage
#
# Read-only guarantee
#   `graft check` is pure I/O + hashing in the installed CLI (no LLM, no
#   writes). This wrapper only reads the repo and runs `graft check` and
#   `graft --version`; it never calls init/build/install/upgrade and never
#   writes to the target repository.
#
# Usage
#   graft-check.sh <repo-path>
#   graft-check.sh --help

set -eu

usage() {
  cat >&2 <<'EOF'
usage: graft-check.sh <repo-path>

Safe JSON wrapper around `graft check <repo> --json`. Prints one JSON document
to stdout. Exit codes: 0=fresh/structural_only 1=stale 2=needs_initialization
3=indeterminate 10=graft not found 11=unparseable output 12=bad path. Never
writes to the repo and never calls init/build/install/upgrade.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage; exit 12 ;;
esac
repo="$1"

if [ ! -d "$repo" ]; then
  repo_esc=$(printf '%s' "$repo" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"schema":1,"wrapper":"graft-check.sh","repo":"%s","status":"error","error":"bad_path","usable":false,"freshness":"unknown","context":null,"graph":null,"cli":{"found":null,"version":null,"exitCode":null},"signal":"target path is not a directory","recommendation":"Pass a path to an existing directory. Nothing was modified.","notes":["Target path is not a directory; nothing to check."]}\n' "$repo_esc"
  exit 12
fi

# ---------------------------------------------------------------------------
# Resolve the graft binary (PATH first, then npm prefix -g)
# ---------------------------------------------------------------------------
GRAFT_BIN=""
if command -v graft >/dev/null 2>&1; then
  GRAFT_BIN=$(command -v graft)
elif command -v npm >/dev/null 2>&1; then
  _prefix=$(npm prefix -g 2>/dev/null || true)
  if [ -n "$_prefix" ] && [ -x "$_prefix/bin/graft" ]; then
    GRAFT_BIN="$_prefix/bin/graft"
  fi
fi

if [ -z "$GRAFT_BIN" ]; then
  repo_esc=$(printf '%s' "$repo" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"schema":1,"wrapper":"graft-check.sh","repo":"%s","status":"error","error":"graft_not_found","usable":false,"freshness":"unknown","context":null,"graph":null,"cli":{"found":false,"version":null,"exitCode":null},"signal":"graft CLI not found","recommendation":"Install graft only after the user confirms: npm install -g @nanonets/graft (Node.js >=20), then re-run. Nothing was modified.","notes":["graft was not found on PATH or via npm prefix -g.","No check was performed."]}\n' "$repo_esc"
  exit 10
fi

# ---------------------------------------------------------------------------
# Run `graft check <repo> --json` (read-only) and capture real CLI exit code
# ---------------------------------------------------------------------------
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/graft-check.XXXXXX" 2>/dev/null) || {
  tmpdir="${TMPDIR:-/tmp}/graft-check.$$"
  mkdir -p "$tmpdir"
}
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

set +e
"$GRAFT_BIN" check "$repo" --json > "$tmpdir/check.out" 2> "$tmpdir/check.err"
CLI_EXIT=$?
set -e

CLI_VERSION=""
set +e
_v=$("$GRAFT_BIN" --version 2>/dev/null | head -n 1)
set -e
_v=$(printf '%s' "$_v" | tr -d '[:space:]')
case "$_v" in
  ''|*[!0-9A-Za-z.+-]*) ;;
  *) CLI_VERSION="$_v" ;;
esac
# ---------------------------------------------------------------------------
# Parse `graft check --json` output with a char-level JSON tokenizer so both
# pretty-printed and single-line output parse identically. Emits
# `section.field=value` lines; array fields are counted accurately (top-level
# items only, so contentDrift objects count as one item each).
# ---------------------------------------------------------------------------
awk '
function set_scalar() {
  # Only emit scalars that are direct fields of the section object (odepth 2);
  # also emit `sec=null` when a whole top-level section is JSON null
  # (e.g. "graph": null when no graft/ graph exists at all).
  if (odepth == 2 && current_key != "" && sec != "") {
    print sec "." current_key "=" scalar_val
  } else if (odepth == 1 && scalar_val == "null" && (sec == "context" || sec == "graph")) {
    print sec "=null"
  }
  current_key = ""
}
function finish_string() {
  # key: prev is "{" / "," in an object / start; value: prev is ":" ;
  # array element: prev is "[" / "," in an array
  if (prev == ":") {
    scalar_val = tok
    set_scalar()
  } else if (prev == "[") {
    arr_seen = 1
  } else if (prev == ",") {
    if (length(stack) > 0 && substr(stack, length(stack)) == "[") {
      arr_seen = 1
    } else if (odepth == 1 && (tok == "context" || tok == "graph")) {
      sec = tok
    } else if (odepth == 2) {
      current_key = tok
    }
  } else if (prev == "{") {
    if (odepth == 1 && (tok == "context" || tok == "graph")) {
      sec = tok
    } else if (odepth == 2) {
      current_key = tok
    }
  } else {
    if (odepth == 1 && (tok == "context" || tok == "graph")) {
      sec = tok
    } else if (odepth == 2) {
      current_key = tok
    }
  }
  tok = ""
}
BEGIN {
  RS = "\0"
  stack = ""; current_key = ""; sec = ""; prev = ""
  in_str = 0; esc = 0; odepth = 0
  arrkey = ""; arr_seen = 0; arrcnt = 0; scalar_val = ""; tok = ""
}
{
  s = $0; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (in_str) {
      if (esc) { esc = 0; tok = tok c; continue }
      if (c == "\\") { esc = 1; continue }
      if (c == "\"") { in_str = 0; finish_string(); continue }
      tok = tok c
      continue
    }
    if (c == "\"") { in_str = 1; tok = ""; continue }
    if (c == " " || c == "\t" || c == "\n" || c == "\r") continue
    if (c == "{") {
      if (length(stack) > 0 && substr(stack, length(stack)) == "[") arr_seen = 1
      stack = stack "{"
      odepth++
      prev = c
      continue
    }
    if (c == "}") {
      if (length(stack) > 0) stack = substr(stack, 1, length(stack) - 1)
      if (odepth > 0) odepth--
      prev = c
      continue
    }
    if (c == "[") {
      stack = stack "["
      arrkey = current_key
      arr_seen = 0
      arrcnt = 0
      prev = c
      continue
    }
    if (c == "]") {
      if (length(stack) > 0) stack = substr(stack, 1, length(stack) - 1)
      if (sec != "" && arrkey != "") {
        if (arr_seen) print sec "." arrkey "=" (arrcnt + 1)
        else print sec "." arrkey "=0"
      }
      arrkey = ""
      prev = c
      continue
    }
    if (c == ",") {
      if (length(stack) > 0 && substr(stack, length(stack)) == "[") arrcnt++
      prev = c
      continue
    }
    if (c == ":") { prev = c; continue }
    scalar_val = ""
    while (i <= n && (substr(s, i, 1) ~ /[0-9a-zA-Z.\-]/)) {
      scalar_val = scalar_val substr(s, i, 1)
      i++
    }
    i--
    if (prev == ":") set_scalar()
    prev = "v"
  }
}
' "$tmpdir/check.out" > "$tmpdir/fields"

# Unparseable guard: require the three structural booleans to be present.
if ! grep -q '^context\.ok=' "$tmpdir/fields" \
   || ! grep -q '^context\.missing=' "$tmpdir/fields" \
   || { ! grep -q '^graph\.ok=' "$tmpdir/fields" && ! grep -q '^graph=null' "$tmpdir/fields"; }; then
  repo_esc=$(printf '%s' "$repo" | sed 's/\\/\\\\/g; s/"/\\"/g')
  cli_ver_json="null"
  if [ -n "$CLI_VERSION" ]; then
    cli_ver_json=$(printf '"%s"' "$(printf '%s' "$CLI_VERSION" | sed 's/\\/\\\\/g; s/"/\\"/g')")
  fi
  printf '{"schema":1,"wrapper":"graft-check.sh","repo":"%s","status":"error","error":"unparseable_json","usable":false,"freshness":"unknown","context":null,"graph":null,"cli":{"found":true,"version":%s,"exitCode":%s},"signal":"graft check output could not be parsed","recommendation":"The CLI produced no parseable check JSON. Verify the graft installation and the repo path, then re-run. Nothing was modified.","notes":["Required fields context.ok / context.missing / graph.ok were not found in the output.","Do not trust the CLI exit code alone."]}\n' \
    "$repo_esc" "$cli_ver_json" "$CLI_EXIT"
  exit 11
fi

# Load parsed fields (defaults keep scripts safe under `set -u`)
context_ok="false"; context_missing="false"; context_drifted="false"
graph_ok="false"; graph_missing="false"; graph_drifted="false"
context_contentDrift=0; context_removed=0; context_coverage=0; context_indexDrift=0
graph_added=0; graph_removed=0; graph_changed=0; graph_stale=0; graph_pending=0
graph_nodes=""

while IFS= read -r line; do
  [ -n "$line" ] || continue
  key=${line%%=*}
  val=${line#*=}
  case "$key" in
    context.ok) context_ok="$val" ;;
    context.missing) context_missing="$val" ;;
    context) if [ "$val" = null ]; then context_ok=false; context_missing=true; fi ;;
    context.contentDrift) context_contentDrift="$val" ;;
    context.removed) context_removed="$val" ;;
    context.coverage) context_coverage="$val" ;;
    context.indexDrift) context_indexDrift="$val" ;;
    graph.ok) graph_ok="$val" ;;
    graph.missing) graph_missing="$val" ;;
    graph.nodes) graph_nodes="$val" ;;
    graph) if [ "$val" = null ]; then graph_ok=false; graph_missing=true; fi ;;
    graph.added) graph_added="$val" ;;
    graph.removed) graph_removed="$val" ;;
    graph.changed) graph_changed="$val" ;;
    graph.stale) graph_stale="$val" ;;
    graph.pending) graph_pending="$val" ;;
  esac
done < "$tmpdir/fields"

# A node count is only trusted when it is a complete non-negative integer. The
# CLI's JSON may surface `null`, `-1` or `1.5`; reading any of those as a
# populated graph would report an unusable graph as usable.
case "$graph_nodes" in
  ''|*[!0-9]*) graph_nodes="" ;;
esac

# drifted = at least one drift array non-empty
if [ "$context_contentDrift" -gt 0 ] || [ "$context_removed" -gt 0 ] \
   || [ "$context_coverage" -gt 0 ] || [ "$context_indexDrift" -gt 0 ]; then
  context_drifted="true"
fi
if [ "$graph_added" -gt 0 ] || [ "$graph_removed" -gt 0 ] \
   || [ "$graph_changed" -gt 0 ] || [ "$graph_stale" -gt 0 ]; then
  graph_drifted="true"
fi

# ---------------------------------------------------------------------------
# Node-count fallback for CLIs that do not report graph.nodes (pre-0.28).
# The wiring file is read directly instead of guessing: without a count the
# wrapper could not tell an empty graph from a populated one, and reporting
# "uninitialized" on that uncertainty would send the user to rebuild a graph
# that already works.
# ---------------------------------------------------------------------------
nodes_source="cli"
if [ -z "$graph_nodes" ]; then
  nodes_source="unknown"
  # When the CLI says the graph is absent, a leftover wiring file is
  # contradictory evidence — reporting its node count alongside "no graph"
  # would be self-refuting, so the fallback only applies to a present graph.
  if [ "$graph_missing" != true ] && [ -f "$repo/graft/.graph/wiring.json" ]; then
    # Anchor the match to the value that directly follows "nodeCount": so a
    # sibling field (edgeCount, pending) can never be mistaken for the count.
    # Capture the whole numeric token, dots included, then reject anything that
    # is not pure digits — otherwise `1.5` would be truncated to `1`.
    _wn=$(grep -o '"nodeCount"[[:space:]]*:[[:space:]]*[0-9][0-9.]*' "$repo/graft/.graph/wiring.json" 2>/dev/null \
          | head -n 1 | sed 's/^.*:[[:space:]]*//' || true)
    case "$_wn" in
      ''|*[!0-9]*) : ;;
      *) graph_nodes="$_wn"; nodes_source="wiring.json" ;;
    esac
  fi
fi
# ---------------------------------------------------------------------------
# Classification from parsed fields only (never the bare CLI exit code)
#
# Precedence is deliberate: establish that a graph exists and holds nodes
# BEFORE any "fresh" verdict. Otherwise a graph reporting ok/ok with an unknown
# or zero node count would be advertised as usable.
#
#   1. no graph at all                        -> needs_initialization
#   2. graph holds 0 nodes                    -> needs_initialization
#   3. node count unknowable                  -> indeterminate (never infer usable)
#   4. graph.ok && context.ok                 -> fresh
#   5. graph.ok && context.missing            -> structural_only (usable)
#   6. otherwise (graph exists but stale)     -> stale
#
# Branch 5 requires context.missing=true. A deep layer that EXISTS but has
# drifted also reports graph.ok=true with context.ok=false; treating that as
# structural_only would advertise a stale graph as fresh and usable.
#
# A plain `graft build` builds the structural wiring graph only; the markdown
# concept layer needs `--deep`. Such a repo reports context.missing=true while
# graph.ok=true and nodes>0 — and ask/grep/callers/skeleton/map all answer from
# that graph, so it is usable rather than uninitialized.
# ---------------------------------------------------------------------------
deep_layer="present"
if [ "$context_missing" = true ]; then
  deep_layer="missing"
fi

if [ "$graph_missing" = true ]; then
  status="needs_initialization"
  exit_code=2
  usable=false
  freshness="not_built"
  signal="no graph present (graph.missing=true); the CLI exited $CLI_EXIT"
  recommendation="No graph exists in this repo. Do NOT treat the repo as queryable based on the CLI exit code alone. Run the doctor, then init/build only after explicit user confirmation; start with 'graft init <repo> --dry-run --no-global' for a preview. Nothing was modified."
  notes="[\"No graph present; the repo needs initialization before queries.\",\"CLI exit code $CLI_EXIT is NOT sufficient to call this repo usable.\",\"Run graft-doctor.sh first, then init/build only after explicit user confirmation.\"]"
elif [ -n "$graph_nodes" ] && [ "$graph_nodes" = "0" ]; then
  status="needs_initialization"
  exit_code=2
  usable=false
  freshness="not_built"
  signal="graph exists but indexes 0 nodes (nodes=0, source: $nodes_source)"
  recommendation="The graph is present but empty, so there is nothing to query. Check that the repo contains files in a supported language (run graft-doctor.sh); if it does, rebuild only after explicit user confirmation. Do not treat an empty graph as usable."
  notes="[\"nodes=0: the graph holds no symbols.\",\"Run graft-doctor.sh to confirm the repo has supported source files.\",\"Rebuild only after explicit user confirmation.\"]"
elif [ -z "$graph_nodes" ]; then
  status="indeterminate"
  exit_code=3
  usable=false
  freshness="unknown"
  signal="no node count is available (the CLI reported no graph.nodes and graft/.graph/wiring.json yielded no usable nodeCount), so an empty graph cannot be distinguished from a populated one"
  recommendation="Do not report this repo as needing initialization on this evidence alone, and do not call it usable either. Inspect graft/.graph/wiring.json (or the graft/ tree) directly, or confirm with the doctor, before proposing any build. Nothing was modified."
  notes="[\"graph.nodes is absent from this CLI's check output (pre-0.28 format).\",\"No valid nodeCount could be read from graft/.graph/wiring.json either.\",\"Verdict is genuinely unknown; do not assert 'not initialized' and do not infer 'usable'.\",\"Inspect the graft/ tree directly before proposing a rebuild.\"]"
elif [ "$graph_ok" = true ] && [ "$context_ok" = true ]; then
  status="fresh"
  exit_code=0
  usable=true
  freshness="fresh"
  signal="graph is fresh and usable (graph.ok && context.ok, nodes=$graph_nodes)"
  recommendation="Graph is fresh and queryable. Orient with: graft map <repo> --json --no-refresh. Append --no-refresh for strict read-only queries."
  notes="[\"graph.ok=true and context.ok=true.\",\"Queries can run now; use --no-refresh in strict read-only mode.\"]"
elif [ "$graph_ok" = true ] && [ "$context_missing" = true ]; then
  status="structural_only"
  exit_code=0
  usable=true
  freshness="fresh"
  signal="structural graph is fresh and queryable (nodes=$graph_nodes); the LLM concept layer is absent (context.missing=true)"
  recommendation="The structural wiring graph is current, so ask/grep/callers/skeleton/map all work. This is the normal state after a plain 'graft build' — the markdown concept layer only exists after 'graft build --deep', which costs provider tokens. Do NOT report this repo as needing initialization. Use --no-refresh for strict read-only queries."
  notes="[\"context.missing=true with nodes=$graph_nodes is the expected result of a structural-only build.\",\"Queries are usable; only the prose concept layer is missing.\",\"Run 'graft build --deep' only if the user wants that layer and accepts provider cost.\"]"
else
  status="stale"
  exit_code=1
  usable=false
  freshness="stale"
  signal="graph has drifted (graph.ok=$graph_ok, context.ok=$context_ok, nodes=$graph_nodes)"
  recommendation="The graph has drifted from the code. Rebuild only after explicit user confirmation ('graft build <repo>', or 'graft init <repo> --no-build' to adjust wiring), then re-run this check. Nothing was modified."
  notes="[\"graph.ok=$graph_ok, context.ok=$context_ok (CLI exit $CLI_EXIT).\",\"Graph exists but is not fresh; queries would use stale data.\",\"Rebuild only after explicit user confirmation.\"]"
fi

# graph.nodes as JSON (null when the CLI did not report it)
case "$graph_nodes" in
  ''|*[!0-9]*) graph_nodes_json="null" ;;
  *) graph_nodes_json="$graph_nodes" ;;
esac

# ---------------------------------------------------------------------------
# Emit one machine-parseable JSON document
# ---------------------------------------------------------------------------
repo_esc=$(printf '%s' "$repo" | sed 's/\\/\\\\/g; s/"/\\"/g')
sig_esc=$(printf '%s' "$signal" | sed 's/\\/\\\\/g; s/"/\\"/g')
rec_esc=$(printf '%s' "$recommendation" | sed 's/\\/\\\\/g; s/"/\\"/g')
cli_ver_json="null"
if [ -n "$CLI_VERSION" ]; then
  cli_ver_json=$(printf '"%s"' "$(printf '%s' "$CLI_VERSION" | sed 's/\\/\\\\/g; s/"/\\"/g')")
fi

printf '{"schema":1,"wrapper":"graft-check.sh","repo":"%s","status":"%s","usable":%s,"freshness":"%s","deepLayer":"%s","nodesSource":"%s","context":{"ok":%s,"missing":%s,"drifted":%s,"contentDrift":%s,"removed":%s,"coverage":%s,"indexDrift":%s},"graph":{"ok":%s,"missing":%s,"drifted":%s,"nodes":%s,"added":%s,"removed":%s,"changed":%s,"stale":%s,"pending":%s},"cli":{"found":true,"version":%s,"exitCode":%s},"signal":"%s","recommendation":"%s","notes":%s}\n' \
  "$repo_esc" "$status" "$usable" "$freshness" "$deep_layer" "$nodes_source" \
  "$context_ok" "$context_missing" "$context_drifted" \
  "$context_contentDrift" "$context_removed" "$context_coverage" "$context_indexDrift" \
  "$graph_ok" "$graph_missing" "$graph_drifted" "$graph_nodes_json" \
  "$graph_added" "$graph_removed" "$graph_changed" "$graph_stale" "$graph_pending" \
  "$cli_ver_json" "$CLI_EXIT" "$sig_esc" "$rec_esc" "$notes"

exit "$exit_code"
