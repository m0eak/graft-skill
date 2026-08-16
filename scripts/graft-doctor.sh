#!/usr/bin/env sh
# graft-doctor.sh — deterministic, read-only pre-flight for a Graft repo.
#
# Purpose
#   Decide whether a repository is a good candidate for `graft build` and
#   classify its current graph state, WITHOUT writing anything to the target
#   repository. It is a pure filesystem analysis (POSIX sh + standard tools)
#   plus a read-only `graft --version` probe for runtime discovery.
#
# Statuses / exit codes
#   0  ready          a graft/ graph exists and has nodes -> queryable
#   1  partial        fallback: a graft/ graph exists but is empty (empty graph,
#                     possibly never built or the build failed), OR the repo is
#                     a mixed source/orchestration repo (supported files are a
#                     minority) even when NO graft/ graph exists -> build only
#                     after the user confirms; often a fallback (rg/limited
#                     reads) is more useful than build
#   2  unsupported    no graft-supported code extensions at all -> do NOT build;
#                     use rg/limited reads or index the real source directory
#   3  uninitialized  no graft/ graph, no mixed signal, but supported code
#                     exists -> init/build only after explicit user confirmation
#   4  error          bad usage, or the target path is not a directory
#   5  unavailable    the supported-extension set cannot be determined (graft
#                     and/or the @nanonets/graft npm package missing, or
#                     CODE_EXTENSIONS could not be extracted). The doctor does
#                     NOT silently fall back to a stale hard-coded list; it
#                     reports this state with install / manual-check guidance.
#
# Freshness
#   This doctor does NOT judge whether a graph is fresh or stale; it only
#   inspects graft/.graph/wiring.json on disk. Graph freshness must be
#   confirmed separately with `graft check <repo> --json` (via
#   scripts/graft-check.sh). The emitted top-level field is always
#   "freshness":"not_checked".
#
# Read-only guarantee
#   This script only reads the repository and the installed graft package. It
#   never creates, modifies, or deletes anything under the target path. It runs
#   `graft --version` (read-only) for runtime discovery when graft is
#   available. It does create a temporary scratch dir under ${TMPDIR:-/tmp}
#   which is removed on exit.
#
# Runtime / supported-set discovery
#   Delegates to scripts/graft-runtime.sh: resolves the graft binary, the CLI
#   version, the @nanonets/graft package dir, package.json version, and the
#   real CODE_EXTENSIONS list from dist/context/build.js. Nothing is
#   hard-coded. If discovery cannot produce a supported-extension set, the
#   doctor reports status "unavailable" (exit 5) instead of guessing.
#
# Usage
#   graft-doctor.sh <repo-path>
#   graft-doctor.sh --help
#
# Output
#   One JSON document on stdout; human errors go to stderr only.

set -eu

usage() {
  cat >&2 <<'EOF'
usage: graft-doctor.sh <repo-path>

Deterministic read-only pre-flight for Graft. Prints one JSON document to
stdout. Exit codes: 0=ready 1=partial 2=unsupported 3=uninitialized 4=error
5=unavailable (supported-set discovery failed). Never writes to <repo-path>;
only runs `graft --version` (read-only) for runtime discovery.
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
# Runtime / supported-set discovery (dynamic; never hard-coded)
# ---------------------------------------------------------------------------
SCRIPTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GRAFT_BIN=""
GRAFT_RUNTIME_VERSION=""
GRAFT_PKG_DIR=""
GRAFT_SUPPORTED_SET_VERSION=""
GRAFT_CODE_EXTENSIONS=""
GRAFT_SUPPORT_DISCOVERY=""
_runtime_out=$(sh "$SCRIPTS_DIR/graft-runtime.sh" --shell 2>/dev/null || true)
eval "$_runtime_out"

# supportedExtensions array (or null)
sup_set_json="null"
if [ -n "$GRAFT_CODE_EXTENSIONS" ]; then
  sup_set_json="["
  _sep=""
  for _e in $GRAFT_CODE_EXTENSIONS; do
    _ee=$(printf '%s' "$_e" | json_escape)
    sup_set_json="$sup_set_json$_sep\"$_ee\""
    _sep=","
  done
  sup_set_json="$sup_set_json]"
fi

# discoveryNotes array
discovery_notes=""
add_note() {
  _nn=$(printf '%s' "$1" | json_escape)
  [ "$discovery_notes" != "" ] && discovery_notes="$discovery_notes,"
  discovery_notes="$discovery_notes\"$_nn\""
}
case "$GRAFT_SUPPORT_DISCOVERY" in
  ok)
    add_note "Resolved runtime discovery from $GRAFT_PKG_DIR."
    if [ -n "$GRAFT_RUNTIME_VERSION" ]; then
      add_note "Installed CLI version: $GRAFT_RUNTIME_VERSION (graft --version)."
    else
      add_note "graft binary present but its version could not be read."
    fi
    add_note "Supported-set version read from package.json: $GRAFT_SUPPORTED_SET_VERSION."
    ;;
  not_installed)
    add_note "No graft binary on PATH and no @nanonets/graft package found via npm root -g / npm prefix -g."
    add_note "Install with 'npm install -g @nanonets/graft' (Node.js >=20) only after the user confirms, then re-run the doctor."
    ;;
  package_not_found)
    add_note "graft binary found at ${GRAFT_BIN:-?} but the @nanonets/graft package directory could not be located."
    add_note "Run 'npm root -g' and check for @nanonets/graft, or resolve the graft bin symlink to find dist/cli.js, then re-run."
    ;;
  extract_failed)
    add_note "Package found at ${GRAFT_PKG_DIR:-?} but CODE_EXTENSIONS could not be extracted from dist/context/build.js."
    add_note "Inspect that file manually for the CODE_EXTENSIONS array; do not rely on a stale hard-coded list."
    ;;
  *)
    add_note "Unrecognized supportDiscovery state: $GRAFT_SUPPORT_DISCOVERY."
    ;;
esac
[ "$discovery_notes" != "" ] && discovery_notes="[$discovery_notes]" || discovery_notes="[]"

# Runtime fields used by error / unavailable / normal output
_rt_ver=$(printf '%s' "$GRAFT_RUNTIME_VERSION" | json_escape)
_set_ver=$(printf '%s' "$GRAFT_SUPPORTED_SET_VERSION" | json_escape)
if [ -n "$GRAFT_RUNTIME_VERSION" ]; then
  _rt_ver_json="\"$_rt_ver\""
else
  _rt_ver_json="null"
fi
if [ -n "$GRAFT_SUPPORTED_SET_VERSION" ]; then
  _set_ver_json="\"$_set_ver\""
else
  _set_ver_json="null"
fi

# ---------------------------------------------------------------------------
# Error: not a directory
# ---------------------------------------------------------------------------
if [ ! -d "$repo" ]; then
  repo_esc=$(printf '%s' "$repo" | json_escape)
  printf '{"schema":1,"doctor":"graft-doctor.sh","runtimeVersion":%s,"supportedSetVersion":%s,"supportedExtensions":%s,"supportDiscovery":"%s","discoveryNotes":%s,"freshness":"not_checked","repo":"%s","status":"error","exit":4,"signal":"path is not a directory","recommendation":"Pass a path to a directory that exists. Nothing was modified.","graph":{"exists":false,"dir":null,"wiringPresent":false,"nodeCount":0,"edgeCount":0,"languages":[],"empty":false},"files":{"total":0,"supported":0,"supportedExtensions":{},"topUnsupportedExtensions":[],"mixed":false},"notes":["Target path is not a directory; nothing to diagnose."]}\n' \
    "$_rt_ver_json" "$_set_ver_json" "$sup_set_json" "$GRAFT_SUPPORT_DISCOVERY" "$discovery_notes" "$repo_esc"
  exit 4
fi

# ---------------------------------------------------------------------------
# Error: supported-set discovery failed -> report, do NOT guess
# ---------------------------------------------------------------------------
if [ "$GRAFT_SUPPORT_DISCOVERY" != "ok" ]; then
  repo_esc=$(printf '%s' "$repo" | json_escape)
  case "$GRAFT_SUPPORT_DISCOVERY" in
    not_installed)
      _sig="cannot determine supported extensions: graft CLI and @nanonets/graft package are not installed"
      _rec="Install graft only after the user confirms (npm install -g @nanonets/graft, Node.js >=20), then re-run the doctor. Nothing was modified."
      ;;
    package_not_found)
      _sig="cannot determine supported extensions: @nanonets/graft package could not be located"
      _rec="Locate the @nanonets/graft package (npm root -g, or the graft bin symlink target) and re-run the doctor, or verify the supported set manually against dist/context/build.js. Nothing was modified."
      ;;
    extract_failed)
      _sig="cannot determine supported extensions: CODE_EXTENSIONS extraction failed"
      _rec="Inspect ${GRAFT_PKG_DIR:-the package}/dist/context/build.js manually for the CODE_EXTENSIONS array; do not rely on a stale hard-coded list. Nothing was modified."
      ;;
    *)
      _sig="cannot determine supported extensions (discovery state: $GRAFT_SUPPORT_DISCOVERY)"
      _rec="Resolve runtime discovery and re-run the doctor. Nothing was modified."
      ;;
  esac
  _sig_esc=$(printf '%s' "$_sig" | json_escape)
  _rec_esc=$(printf '%s' "$_rec" | json_escape)
  printf '{"schema":1,"doctor":"graft-doctor.sh","runtimeVersion":%s,"supportedSetVersion":%s,"supportedExtensions":%s,"supportDiscovery":"%s","discoveryNotes":%s,"freshness":"not_checked","repo":"%s","status":"unavailable","exit":5,"signal":"%s","recommendation":"%s","graph":{"exists":false,"dir":null,"wiringPresent":false,"nodeCount":0,"edgeCount":0,"languages":[],"empty":false},"files":{"total":0,"supported":0,"supportedExtensions":{},"topUnsupportedExtensions":[],"mixed":false},"notes":["Supported-extension set could not be determined; classification skipped."]}\n' \
    "$_rt_ver_json" "$_set_ver_json" "$sup_set_json" "$GRAFT_SUPPORT_DISCOVERY" "$discovery_notes" "$repo_esc" "$_sig_esc" "$_rec_esc"
  exit 5
fi

CODE_EXTENSIONS="$GRAFT_CODE_EXTENSIONS"

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
#   partial covers two fallback shapes:
#     A) a graft/ graph exists but is empty (nodeCount == 0):
#        - if the repo is ALSO mixed (supported files a strict minority)
#          -> mixed fallback wording
#        - otherwise -> EMPTY GRAPH wording (possibly never built, or the build
#          failed); this is NOT a mixed repo and must not be called one
#     B) NO graft/ graph, but the repo is a mixed source/orchestration repo
#        (supported files are a strict minority) -> building would only index
#        the small supported subset, so init/build must not be proposed as a
#        first step.
#   uninitialized is only the clean case: no graph + supported code exists and
#   no mixed signal.
# ---------------------------------------------------------------------------
status=uninitialized
exit_code=3
signal="no graft graph present; supported code exists and is not a minority"
recommendation="Supported code exists but no graph yet. Initialize/build only after the user explicitly confirms; start with the non-mutating preview: graft init <repo> --dry-run --no-global."
notes="[\"No graft/ graph present.\",\"Repo is not flagged mixed; supported code is not a minority.\",\"Initialize only after explicit user confirmation.\",\"Run 'graft init <repo> --dry-run --no-global' for a preview first.\"]"

if [ "$graph_exists" = true ] && [ "$node_count" -gt 0 ]; then
  status=ready
  exit_code=0
  signal="graft graph exists with $node_count nodes"
  recommendation="Graph is ready. Orient with: graft map <repo> --json --no-refresh. Query with --no-refresh in strict read-only mode; without it, queries may refresh graft/ locally. The doctor does not judge freshness; confirm it with 'graft check <repo> --json' if needed."
  notes="[\"Graph is queryable.\",\"Strict read-only: append --no-refresh to ask/grep/callers/skeleton/map.\",\"Doctor does not judge freshness; use 'graft check <repo> --json' for that.\"]"
elif [ "$supported" -eq 0 ]; then
  status=unsupported
  exit_code=2
  signal="no graft-supported code extensions found"
  recommendation="Graft indexes only the code extensions in CODE_EXTENSIONS (supported-set version: $GRAFT_SUPPORTED_SET_VERSION); a config/orchestration-only repo cannot be made supported with --extensions. Do NOT use 'graft build' here -- it would produce an empty graph. Use rg/limited reads instead, and if the real source code lives in another directory, run the doctor against that directory and index it."
  notes="[\"No supported code files (of $total total).\",\"CODE_EXTENSIONS: $CODE_EXTENSIONS\",\"--extensions only narrows the walk; it does not add config/yml/Makefile support.\",\"Do NOT build as a workaround.\"]"
elif [ "$graph_exists" = true ]; then
  status=partial
  exit_code=1
  if [ "$mixed" = true ]; then
    signal="graft graph exists but has 0 nodes (empty graph) in a mixed source/orchestration repo"
    recommendation="The graft/ graph exists but is empty (0 nodes) and the repo is mixed: only $supported of $total files are graft-supported, so a rebuild only makes that small subset queryable and needs explicit user confirmation. Prefer rg/limited reads scoped to code/config dirs (config/, sh/, Makefile, default-settings-*, .github/). If the real OpenWrt source lives in another directory, index that directory instead of the Builder orchestration repo. The doctor does not judge freshness; confirm it with 'graft check <repo> --json'."
    notes="[\"graft/ exists but wiring.json has 0 nodes.\",\"Mixed source/orchestration repo: only $supported of $total files are graft-supported.\",\"Prefer rg/limited reads over build for config/yml/Makefile content.\",\"If real source is elsewhere, doctor+index that source directory.\",\"Doctor does not judge freshness; use 'graft check <repo> --json'.\"]"
  else
    signal="graft graph exists but has 0 nodes (empty graph; possibly never built or the build failed)"
    recommendation="The graft/ graph exists but is empty (0 nodes). This is likely an empty graph that was never built or whose build failed -- NOT a mixed repo (supported code files are not a minority: $supported of $total files). Rebuilding after explicit user confirmation may produce a useful graph; run 'graft init <repo> --dry-run --no-global' for a preview first, then confirm before building. The doctor does not judge freshness; confirm it with 'graft check <repo> --json'."
    notes="[\"graft/ exists but wiring.json has 0 nodes.\",\"Repo is not flagged mixed; supported code files are not a minority.\",\"Empty graph: possibly never built or the build failed.\",\"Rebuild only after explicit user confirmation (preview with graft init --dry-run --no-global first).\",\"Doctor does not judge freshness; use 'graft check <repo> --json'.\"]"
  fi
elif [ "$mixed" = true ]; then
  status=partial
  exit_code=1
  signal="no graft graph; mixed source/orchestration repo"
  recommendation="No graft/ graph yet, but this is a mixed source/orchestration repo: only $supported of $total files are graft-supported, so a build would produce a near-empty graph and needs explicit user confirmation. Prefer rg/limited reads scoped to code/config dirs; if the real source lives in another directory, doctor+index that directory instead. The doctor does not judge freshness; confirm it with 'graft check <repo> --json'."
  notes="[\"No graft/ graph present.\",\"Repo flagged mixed: supported files ($supported) are a minority of $total total.\",\"Prefer rg/limited reads over build for config/yml/Makefile content.\",\"If real source is elsewhere, doctor+index that source directory.\",\"Init/build only after explicit user confirmation.\",\"Doctor does not judge freshness; use 'graft check <repo> --json'.\"]"
fi

# ---------------------------------------------------------------------------
# Emit one machine-parseable JSON document
# ---------------------------------------------------------------------------
repo_esc=$(printf '%s' "$repo" | json_escape)
signal_esc=$(printf '%s' "$signal" | json_escape)
rec_esc=$(printf '%s' "$recommendation" | json_escape)

printf '{"schema":1,"doctor":"graft-doctor.sh","runtimeVersion":%s,"supportedSetVersion":%s,"supportedExtensions":%s,"supportDiscovery":"%s","discoveryNotes":%s,"freshness":"not_checked","repo":"%s","status":"%s","exit":%s,"signal":"%s","recommendation":"%s","graph":{"exists":%s,"dir":%s,"wiringPresent":%s,"nodeCount":%s,"edgeCount":%s,"languages":%s,"empty":%s},"files":{"total":%s,"supported":%s,"supportedExtensions":%s,"topUnsupportedExtensions":%s,"mixed":%s},"notes":%s}\n' \
  "$_rt_ver_json" "$_set_ver_json" "$sup_set_json" "$GRAFT_SUPPORT_DISCOVERY" "$discovery_notes" \
  "$repo_esc" "$status" "$exit_code" "$signal_esc" "$rec_esc" \
  "$graph_exists" "$graph_dir_json" "$wiring_present" "$node_count" "$edge_count" "$languages" "$graph_empty" \
  "$total" "$supported" "$sup_json" "$unsup_json" "$mixed" "$notes"

exit "$exit_code"
