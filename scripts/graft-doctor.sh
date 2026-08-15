#!/usr/bin/env sh
# graft-doctor.sh — deterministic, read-only pre-flight for a Graft repo.
#
# Purpose
#   Decide whether a repository is a good candidate for `graft build` and
#   classify its current graph state, WITHOUT writing anything to the target
#   repository and WITHOUT invoking the graft CLI. It is a pure filesystem
#   analysis: deterministic, dependency-free (POSIX sh + standard tools).
#
# Statuses / exit codes
#   0  ready          a graft/ graph exists and has nodes -> queryable
#   1  partial        a graft/ graph exists but is empty/stale, or the repo is
#                     a mixed source/orchestration repo -> build only after the
#                     user confirms; often a fallback (rg/limited reads) is
#                     more useful than build
#   2  unsupported    no graft-supported code extensions at all -> do NOT build;
#                     use rg/limited reads or index the real source directory
#   3  uninitialized  no graft/ graph, but supported code exists -> init/build
#                     only after explicit user confirmation
#   4  error          bad usage, or the target path is not a directory
#
# Read-only guarantee
#   This script only reads the repository. It never creates, modifies, or
#   deletes anything under the target path, and it never runs graft. It does
#   create a temporary scratch dir under ${TMPDIR:-/tmp} which is removed on
#   exit.
#
# Supported extensions
#   Mirror of graft 0.10.1 `CODE_EXTENSIONS` (from dist/context/build.js).
#   `--extensions` on `graft build`/`graft check` only narrows this set; it does
#   NOT add new language support, so a repo that is pure config/yml/Makefile
#   cannot be made "supported" by passing flags.
#
# Usage
#   graft-doctor.sh <repo-path>
#   graft-doctor.sh --help
#
# Output
#   One JSON document on stdout; human errors go to stderr only.

set -eu

CODE_EXTENSIONS=".ts .tsx .js .jsx .mjs .cjs .py .go .rs .java .kt .scala .rb .php .c .h .cpp .hpp .cc .cs .swift .sql .sh .proto"

usage() {
  cat >&2 <<'EOF'
usage: graft-doctor.sh <repo-path>

Deterministic read-only pre-flight for Graft. Prints one JSON document to
stdout. Exit codes: 0=ready 1=partial 2=unsupported 3=uninitialized 4=error.
Never writes to <repo-path>; never runs the graft CLI.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage; exit 4 ;;
esac

repo="$1"

# JSON string body escaping: backslash and double quote, then collapse
# control chars (newline/tab/CR) to space so the document stays valid.
json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\t\r' ' '
}

# ---------------------------------------------------------------------------
# Error: not a directory
# ---------------------------------------------------------------------------
if [ ! -d "$repo" ]; then
  repo_esc=$(printf '%s' "$repo" | json_escape)
  printf '{"schema":1,"doctor":"graft-doctor.sh","graftVersion":"0.10.1","repo":"%s","status":"error","exit":4,"signal":"path is not a directory","recommendation":"Pass a path to a directory that exists. Nothing was modified.","graph":{"exists":false,"dir":null,"wiringPresent":false,"nodeCount":0,"edgeCount":0,"languages":[],"empty":false},"files":{"total":0,"supported":0,"supportedExtensions":{},"topUnsupportedExtensions":[],"mixed":false},"notes":["Target path is not a directory; nothing to diagnose."]}\n' "$repo_esc"
  exit 4
fi

# ---------------------------------------------------------------------------
# Read-only walk: aggregate file metrics with a single awk pass.
# Skips .git, node_modules, and the graft output dir itself (mirrors graft).
# ---------------------------------------------------------------------------
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/graft-doctor.XXXXXX" 2>/dev/null) || {
  tmpdir="${TMPDIR:-/tmp}/graft-doctor.$$"
  mkdir -p "$tmpdir"
}
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

find "$repo" -type f \
  -not -path '*/node_modules/*' \
  -not -path '*/.git/*' \
  -not -path '*/graft/*' \
  -print 2>/dev/null \
  | awk -v extstr="$CODE_EXTENSIONS" '
      BEGIN {
        n = split(extstr, e, " ");
        total = 0;
        supported = 0;
      }
      {
        total++;
        f = $0;
        lf = tolower(f);
        m = split(f, p, "/"); base = p[m];
        # extension = suffix after the LAST dot, but only when that dot is not
        # at position 1 (so ".mcp.json" -> "json", ".gitignore" -> "")
        lastdot = 0;
        for (j = length(base); j >= 1; j--) {
          if (substr(base, j, 1) == ".") { lastdot = j; break; }
        }
        if (lastdot > 1) {
          ext = substr(base, lastdot + 1);
        } else {
          ext = "";
        }
        is_sup = 0;
        for (i = 1; i <= n; i++) {
          le = length(e[i]);
          if (length(lf) >= le && substr(lf, length(lf) - le + 1) == e[i]) {
            is_sup = 1;
            supext[e[i]]++;
            break;
          }
        }
        if (is_sup) supported++;
        else if (ext != "") allext[ext]++;
        else noext++;
      }
      END {
        printf "total=%d\n", total;
        printf "supported=%d\n", supported;
        for (x in supext) printf "supext %s %d\n", x, supext[x];
        for (x in allext) printf "allext %s %d\n", x, allext[x];
        if (noext) printf "noext %d\n", noext;
      }
    ' > "$tmpdir/metrics" 2>/dev/null

total=0
supported=0
while IFS= read -r line; do
  case "$line" in
    total=*) total=${line#total=} ;;
    supported=*) supported=${line#supported=} ;;
  esac
done < "$tmpdir/metrics"

# Supported-extension counts -> {"ext": n, ...}
sup_json=""
while IFS= read -r line; do
  case "$line" in
    supext\ *)
      set -- $line
      [ "${2:-}" != "" ] || continue
      esc=$(printf '%s' "$2" | json_escape)
      [ "$sup_json" != "" ] && sup_json="$sup_json,"
      sup_json="$sup_json\"$esc\":$3"
      ;;
  esac
done < "$tmpdir/metrics"
[ "$sup_json" != "" ] && sup_json="{$sup_json}" || sup_json="{}"

# Top unsupported extensions (sorted desc, top 8) -> [{ext,count}, ...]
unsup_json=""
{
  awk '/^allext /{print $3, $2}' "$tmpdir/metrics" | sort -rn | head -8
} > "$tmpdir/unsup_top"
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  set -- $entry
  esc=$(printf '%s' "$2" | json_escape)
  [ "$unsup_json" != "" ] && unsup_json="$unsup_json,"
  unsup_json="$unsup_json{\"ext\":\"$esc\",\"count\":$1}"
done < "$tmpdir/unsup_top"
[ "$unsup_json" != "" ] && unsup_json="[$unsup_json]" || unsup_json="[]"

# ---------------------------------------------------------------------------
# Graph state (read-only inspection of graft/.graph/wiring.json)
# ---------------------------------------------------------------------------
graph_exists=false
wiring_present=false
node_count=0
edge_count=0
languages="[]"
if [ -d "$repo/graft" ]; then
  graph_exists=true
fi
wiring="$repo/graft/.graph/wiring.json"
if [ -f "$wiring" ]; then
  wiring_present=true
  node_count=$(sed -n 's/.*"nodeCount"[^0-9]*\([0-9][0-9]*\).*/\1/p' "$wiring" | head -1)
  edge_count=$(sed -n 's/.*"edgeCount"[^0-9]*\([0-9][0-9]*\).*/\1/p' "$wiring" | head -1)
  lang_raw=$(sed -n 's/.*"languages"[[:space:]]*:\([^]]*\]\).*/\1/p' "$wiring" | head -1 | tr -d ' ')
  [ -n "$node_count" ] || node_count=0
  [ -n "$edge_count" ] || edge_count=0
  [ -n "$lang_raw" ] && languages="$lang_raw"
fi
graph_empty=false
[ "$graph_exists" = true ] && [ "$node_count" -eq 0 ] && graph_empty=true

# graft dir as JSON string (or null)
graph_dir_json="null"
if [ "$graph_exists" = true ]; then
  graph_dir_json=$(printf '%s/graft' "$repo" | json_escape)
  graph_dir_json="\"$graph_dir_json\""
fi

# Mixed source/orchestration heuristic: supported files are a strict minority.
mixed=false
if [ "$total" -gt 0 ] && [ "$supported" -gt 0 ] && [ $((supported * 2)) -lt "$total" ]; then
  mixed=true
fi

# ---------------------------------------------------------------------------
# Classification (precedence: error > ready > unsupported > partial > uninit)
# ---------------------------------------------------------------------------
status=uninitialized
exit_code=3
signal="no graft graph present"
recommendation="Supported code exists but no graph yet. Initialize/build only after the user explicitly confirms; start with the non-mutating preview: graft init <repo> --dry-run --no-global."
notes="[\"No graft/ graph present.\",\"Initialize only after explicit user confirmation.\",\"Run 'graft init <repo> --dry-run --no-global' for a preview first.\"]"

if [ "$graph_exists" = true ] && [ "$node_count" -gt 0 ]; then
  status=ready
  exit_code=0
  signal="graft graph exists with $node_count nodes"
  recommendation="Graph is ready. Orient with: graft map <repo> --json --no-refresh. Query with --no-refresh in strict read-only mode; without it, queries may refresh graft/ locally."
  notes="[\"Graph is queryable.\",\"Strict read-only: append --no-refresh to ask/grep/callers/skeleton/map.\"]"
elif [ "$supported" -eq 0 ]; then
  status=unsupported
  exit_code=2
  signal="no graft-supported code extensions found"
  recommendation="Graft 0.10.1 indexes only the code extensions baked into CODE_EXTENSIONS; a config/orchestration-only repo cannot be made supported with --extensions. Do NOT use 'graft build' here -- it would produce an empty graph. Use rg/limited reads instead, and if the real source code lives in another directory, run the doctor against that directory and index it."
  notes="[\"No supported code files (of $total total).\",\"graft 0.10.1 CODE_EXTENSIONS: $CODE_EXTENSIONS\",\"--extensions only narrows the walk; it does not add config/yml/Makefile support.\",\"Do NOT build as a workaround.\"]"
elif [ "$graph_exists" = true ]; then
  status=partial
  exit_code=1
  signal="graft graph exists but has 0 nodes"
  recommendation="The graft/ graph exists but is empty (0 nodes). Rebuilding requires explicit user confirmation and only makes the few supported code files queryable. This repo looks like a mixed source/orchestration repo: prefer rg/limited reads scoped to code/config dirs (config/, sh/, Makefile, default-settings-*, .github/). If the real OpenWrt source lives in another directory, index that directory instead of the Builder orchestration repo."
  notes="[\"graft/ exists but wiring.json has 0 nodes.\",\"Mixed source/orchestration repo: only $supported of $total files are graft-supported.\",\"Prefer rg/limited reads over build for config/yml/Makefile content.\",\"If real source is elsewhere, doctor+index that source directory.\"]"
fi

# ---------------------------------------------------------------------------
# Emit one machine-parseable JSON document
# ---------------------------------------------------------------------------
repo_esc=$(printf '%s' "$repo" | json_escape)
signal_esc=$(printf '%s' "$signal" | json_escape)
rec_esc=$(printf '%s' "$recommendation" | json_escape)

printf '{"schema":1,"doctor":"graft-doctor.sh","graftVersion":"0.10.1","repo":"%s","status":"%s","exit":%s,"signal":"%s","recommendation":"%s","graph":{"exists":%s,"dir":%s,"wiringPresent":%s,"nodeCount":%s,"edgeCount":%s,"languages":%s,"empty":%s},"files":{"total":%s,"supported":%s,"supportedExtensions":%s,"topUnsupportedExtensions":%s,"mixed":%s},"notes":%s}\n' \
  "$repo_esc" "$status" "$exit_code" "$signal_esc" "$rec_esc" \
  "$graph_exists" "$graph_dir_json" "$wiring_present" "$node_count" "$edge_count" "$languages" "$graph_empty" \
  "$total" "$supported" "$sup_json" "$unsup_json" "$mixed" "$notes"

exit "$exit_code"
