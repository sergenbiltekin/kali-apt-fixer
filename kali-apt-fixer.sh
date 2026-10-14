#!/usr/bin/env bash
# kali-apt-fixer - diagnose and fix common Kali Linux APT update problems,
# especially behind corporate proxies and firewalls.
# MIT licensed.
set -euo pipefail

readonly VERSION="1.0.0"
readonly PROG="kali-apt-fixer"
readonly DEFAULT_MIRRORS="https://mirrors.tuna.tsinghua.edu.cn/kali https://mirror.aarnet.edu.au/kali https://ftp.acc.umu.se/mirror/kali.org/kali https://mirrors.ocf.berkeley.edu/kali http://http.kali.org/kali"
readonly DEFAULT_COMPONENTS="main contrib non-free non-free-firmware"
readonly PGP_HEADER="-----BEGIN PGP SIGNED MESSAGE-----"

# Paths and tunables. The KAF_* overrides exist so the test-suite can run
# against a scratch directory; they are not meant for normal use.
APT_DIR="${KAF_APT_DIR:-/etc/apt}"
SOURCES_LIST="$APT_DIR/sources.list"
SOURCES_DIR="$APT_DIR/sources.list.d"
BACKUP_DIR="$APT_DIR/kali-apt-fixer-backup"
KEYRING="${KAF_KEYRING:-/usr/share/keyrings/kali-archive-keyring.gpg}"
LOG_FILE="${KAF_LOG_FILE:-/var/log/kali-apt-fixer.log}"
CONF_FILE="${KAF_CONF_FILE:-/etc/kali-apt-fixer.conf}"
SUITE="${KAF_SUITE:-kali-rolling}"
CONNECT_TIMEOUT="${KAF_CONNECT_TIMEOUT:-8}"
MAX_TIME="${KAF_MAX_TIME:-30}"

CMD=""
FORCED_MIRROR=""
DRY_RUN=0
ASSUME_YES=0
USE_COLOR=1
VERBOSE=0
WORKDIR=""
CHOSEN_MIRROR=""
KEYRING_DEB_MIRROR=""
KEYRING_DEB_NAME=""
URL_SCHEME="" URL_HOST="" URL_PORT=""
C_RED="" C_GREEN="" C_YELLOW="" C_BOLD="" C_RESET=""

declare -ga MIRROR_LIST=()
declare -ga FINDINGS=()
declare -ga ACTIONS=()
declare -ga PLAN=()
declare -ga STAGE_SRC=()
declare -ga STAGE_DST=()
declare -gA MIRROR_STATUS=()

# ---------------------------------------------------------------- output ---

setup_colors() {
  if [[ $USE_COLOR -eq 1 && -t 1 && -z ${NO_COLOR:-} ]]; then
    C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
    C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
  fi
}

log_file() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true
}

info()    { printf '%s\n' "$*"; log_file INFO "$*"; }
section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; log_file INFO "== $* =="; }
good()    { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log_file OK "$*"; }
warn()    { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; log_file WARN "$*"; }
bad()     { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*"; log_file FAIL "$*"; }
die()     { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log_file ERROR "$*"; exit 1; }

debug() {
  [[ $VERBOSE -eq 1 ]] || return 0
  printf '[debug] %s\n' "$*" >&2
  log_file DEBUG "$*"
}

usage() {
  cat <<EOF
$PROG $VERSION - diagnose and fix common Kali Linux APT update problems

Usage: sudo $PROG <command> [options]

Commands:
  diagnose       Read-only checks; explains what is wrong and what 'fix' would do
  fix            Back up sources, pick a working mirror, rewrite sources,
                 remove duplicates, repair the keyring, run apt-get update
  restore        Restore the original (first) backup of the APT sources
  upgrade        apt-get update, upgrade, dist-upgrade, autoremove, autoclean
  list-mirrors   Show the configured mirrors and whether each one works

Options:
  --mirror <url>   Use this mirror base URL (e.g. https://host/kali)
  --dry-run        Show what would change, change nothing
  --yes, -y        Do not ask for confirmation
  --no-color       Disable colored output
  --verbose, -v    Print extra detail
  --help, -h       Show this help
  --version        Show version

Mirrors: MIRRORS env var, or MIRRORS="url url ..." in $CONF_FILE.
EOF
}

# ------------------------------------------------------------- arguments ---

parse_args() {
  while (($#)); do
    case $1 in
      diagnose|fix|restore|upgrade|list-mirrors) CMD=$1 ;;
      --mirror)
        [[ $# -ge 2 ]] || die "--mirror needs a URL"
        FORCED_MIRROR=$2
        shift
        ;;
      --mirror=*) FORCED_MIRROR=${1#--mirror=} ;;
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --no-color) USE_COLOR=0 ;;
      --verbose|-v) VERBOSE=1 ;;
      --help|-h) usage; exit 0 ;;
      --version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
  done
  if [[ -z $CMD ]]; then
    usage >&2
    exit 2
  fi
}

require_root() {
  [[ $EUID -eq 0 || ${KAF_ALLOW_NONROOT:-0} -eq 1 ]] || die "must run as root (try: sudo $PROG $CMD)"
}

init_workdir() {
  WORKDIR=$(mktemp -d)
  trap cleanup EXIT
}

cleanup() {
  [[ -n $WORKDIR && -d $WORKDIR ]] && rm -rf "$WORKDIR"
  return 0
}

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  [[ -t 0 ]] || die "not interactive: re-run with --yes to apply changes"
  local answer
  read -r -p "$1 [y/N] " answer
  [[ $answer == y || $answer == Y || $answer == yes ]]
}

# ---------------------------------------------------------------- config ---

valid_mirror_url() {
  [[ $1 =~ ^https?://[A-Za-z0-9._~:/%@+-]+$ ]]
}

# Reads MIRRORS="..." from the config file without executing it.
conf_mirrors() {
  [[ -r $CONF_FILE ]] || return 0
  local line val
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*MIRRORS=(.*)$ ]]; then
      val=${BASH_REMATCH[1]}
      val=${val//\"/}
      val=${val//\'/}
      printf '%s\n' "$val"
    fi
  done <"$CONF_FILE"
}

load_config() {
  local raw=${MIRRORS:-} m
  local -a parsed=()
  [[ -n $raw ]] || raw=$(conf_mirrors | tail -n1)
  [[ -n $raw ]] || raw=$DEFAULT_MIRRORS
  IFS=' ,' read -r -a parsed <<<"$raw"
  MIRROR_LIST=()
  for m in "${parsed[@]}"; do
    m=${m%/}
    valid_mirror_url "$m" || die "invalid mirror URL in configuration: $m"
    MIRROR_LIST+=("$m")
  done
  [[ ${#MIRROR_LIST[@]} -gt 0 ]] || die "no mirrors configured"
  if [[ -n $FORCED_MIRROR ]]; then
    FORCED_MIRROR=${FORCED_MIRROR%/}
    valid_mirror_url "$FORCED_MIRROR" || die "invalid --mirror URL: $FORCED_MIRROR"
  fi
}

parse_url() {
  if [[ $1 =~ ^(https?)://([^/:]+)(:([0-9]+))?(/.*)?$ ]]; then
    URL_SCHEME=${BASH_REMATCH[1]}
    URL_HOST=${BASH_REMATCH[2]}
    URL_PORT=${BASH_REMATCH[4]:-}
    [[ -n $URL_PORT ]] || { [[ $URL_SCHEME == https ]] && URL_PORT=443 || URL_PORT=80; }
  else
    die "cannot parse URL: $1"
  fi
}

# --------------------------------------------------------------- network ---

# Prints the HTTP status ("000" if none); curl's exit code is the return value.
http_fetch() {
  local url=$1 body=$2 err=$3 code rc=0
  shift 3
  code=$(curl -sS -L --proto '=http,https' --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" "$@" -o "$body" -w '%{http_code}' "$url" 2>"$err") || rc=$?
  debug "GET $url -> curl rc=$rc http=${code:-000}"
  printf '%s' "${code:-000}"
  return "$rc"
}

dns_check() { getent hosts "$1" >/dev/null 2>&1; }

tcp_check() {
  # shellcheck disable=SC2016 # $1/$2 belong to the inner bash
  timeout "$CONNECT_TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2>/dev/null
}

# Prints OK, CONN_RESET or TLS_CERT for a TLS handshake against host:port.
tls_status() {
  local rc=0
  curl -sS -I -o /dev/null --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    "https://$1:$2/" 2>/dev/null || rc=$?
  case $rc in
    35|56) echo CONN_RESET ;;
    51|58|59|60|77|83) echo TLS_CERT ;;
    *) echo OK ;;
  esac
}

is_waf_page()   { grep -qiE 'High Security Alert|cloudflare|cf-ray|Attention Required' "$1"; }
is_block_page() { grep -qiE 'Web Page Blocked|has been blocked|blocked by|access denied|url filter|category' "$1"; }

# classify_fetch <curl_rc> <http_code> <body> <stderr_file> <inrelease|listing|deb>
classify_fetch() {
  local rc=$1 code=$2 body=$3 kind=$5
  case $rc in
    0) ;;
    6) echo DNS_FAIL; return 0 ;;
    7) echo TCP_FAIL; return 0 ;;
    28) echo TIMEOUT; return 0 ;;
    35|56) echo CONN_RESET; return 0 ;;
    51|58|59|60|77|83) echo TLS_CERT; return 0 ;;
    *) echo "CURL_$rc"; return 0 ;;
  esac
  case $code in
    52[0-9]|5[0-9][0-9]) echo DEAD_MIRROR ;;
    401|403|407|451)
      if is_waf_page "$body"; then echo WAF_403
      elif is_block_page "$body"; then echo PROXY_BLOCK
      else echo "HTTP_$code"; fi
      ;;
    404) echo NOT_FOUND ;;
    200|206) classify_content "$body" "$kind" ;;
    *) echo "HTTP_$code" ;;
  esac
}

classify_content() {
  local body=$1 kind=$2
  [[ -s $body ]] || { echo EMPTY; return 0; }
  case $kind in
    inrelease)
      if [[ $(head -n1 "$body" | tr -d '\r') == "$PGP_HEADER" ]]; then echo OK
      elif is_block_page "$body"; then echo PROXY_BLOCK
      else echo NOT_PGP; fi
      ;;
    listing)
      if grep -q 'kali-archive-keyring_' "$body"; then echo OK
      elif is_block_page "$body"; then echo PROXY_BLOCK
      else echo BAD_CONTENT; fi
      ;;
    deb)
      if [[ $(head -c 7 "$body") == '!<arch>' ]]; then echo OK
      elif is_block_page "$body"; then echo PROXY_BLOCK
      else echo BAD_CONTENT; fi
      ;;
  esac
}

describe_status() {
  case $1 in
    OK) echo "valid" ;;
    CONN_RESET) echo "connection reset by peer (typical SNI-based TLS filtering)" ;;
    TLS_CERT) echo "TLS certificate rejected (TLS-inspecting proxy re-signing traffic?)" ;;
    PROXY_BLOCK) echo "proxy/firewall block page returned instead of repository data" ;;
    WAF_403) echo "403 from a WAF/CDN (e.g. Cloudflare 'High Security Alert')" ;;
    DEAD_MIRROR) echo "mirror is down or broken (HTTP 5xx / Cloudflare 52x)" ;;
    DNS_FAIL) echo "host name does not resolve" ;;
    TCP_FAIL) echo "TCP connection refused or unreachable" ;;
    TIMEOUT) echo "connection timed out" ;;
    EMPTY) echo "empty response" ;;
    NOT_PGP) echo "response is not a PGP-signed InRelease" ;;
    BAD_CONTENT) echo "unexpected content" ;;
    NOT_FOUND) echo "404 not found (wrong mirror path?)" ;;
    UNKNOWN) echo "could not be checked" ;;
    HTTP_*) echo "unexpected HTTP status ${1#HTTP_}" ;;
    CURL_*) echo "curl error ${1#CURL_}" ;;
    *) echo "$1" ;;
  esac
}

# fetch_status <url> <kind> [extra curl args]: prints a status word.
fetch_status() {
  local url=$1 kind=$2 body err code rc=0
  shift 2
  body=$(mktemp "$WORKDIR/body.XXXXXX")
  err=$(mktemp "$WORKDIR/err.XXXXXX")
  code=$(http_fetch "$url" "$body" "$err" "$@") || rc=$?
  classify_fetch "$rc" "$code" "$body" "$err" "$kind"
}

mirror_status() {
  fetch_status "${1%/}/dists/$SUITE/InRelease" inrelease
}

keyring_pool_url() { printf '%s/pool/main/k/kali-archive-keyring/' "${1%/}"; }

# Prints the newest kali-archive-keyring_*_all.deb listed by the mirror.
keyring_deb_name() {
  local body err code rc=0 st
  body=$(mktemp "$WORKDIR/body.XXXXXX")
  err=$(mktemp "$WORKDIR/err.XXXXXX")
  code=$(http_fetch "$(keyring_pool_url "$1")" "$body" "$err") || rc=$?
  st=$(classify_fetch "$rc" "$code" "$body" "$err" listing)
  [[ $st == OK ]] || return 1
  grep -oE 'kali-archive-keyring_[0-9][A-Za-z0-9.+~_-]*_all\.deb' "$body" | sort -uV | tail -n1
}

# Checks that real package downloads work (the WAF 403 case): range-GET the
# keyring .deb. UNKNOWN when the mirror offers no directory listing.
package_status() {
  local name
  name=$(keyring_deb_name "$1") || name=""
  if [[ -z $name ]]; then echo UNKNOWN; return 0; fi
  fetch_status "$(keyring_pool_url "$1")$name" deb -r 0-1023
}

mirror_usable() {
  local m=$1 st pst
  st=$(mirror_status "$m")
  MIRROR_STATUS[$m]=$st
  if [[ $st != OK ]]; then
    bad "$m: InRelease $(describe_status "$st")"
    return 1
  fi
  pst=$(package_status "$m")
  case $pst in
    OK|UNKNOWN) good "$m: valid InRelease, package downloads work" ;;
    *) bad "$m: InRelease ok but package downloads fail: $(describe_status "$pst")"; return 1 ;;
  esac
}

# --------------------------------------------------------------- sources ---

# One path per line: sources.list plus every *.list / *.sources.
list_source_files() {
  local f
  if [[ -f $SOURCES_LIST ]]; then printf '%s\n' "$SOURCES_LIST"; fi
  for f in "$SOURCES_DIR"/*.list "$SOURCES_DIR"/*.sources; do
    if [[ -f $f ]]; then printf '%s\n' "$f"; fi
  done
  return 0
}

# Prints "<type> <suite> <uri>" for each active Kali entry in a file.
kali_entries() {
  case $1 in
    *.sources)
      awk '
        BEGIN { RS = ""; FS = "\n" }
        {
          types = ""; suites = ""; uris = ""; off = 0
          for (k = 1; k <= NF; k++) {
            if ($k ~ /^Types:/)  { types = $k;  sub(/^Types:[ \t]*/, "", types) }
            if ($k ~ /^Suites:/) { suites = $k; sub(/^Suites:[ \t]*/, "", suites) }
            if ($k ~ /^URIs:/)   { uris = $k;   sub(/^URIs:[ \t]*/, "", uris) }
            if ($k ~ /^Enabled:[ \t]*(no|false)/) off = 1
          }
          if (off || suites !~ /kali-/) next
          nt = split(types, T, /[ \t]+/); ns = split(suites, S, /[ \t]+/); split(uris, U, /[ \t]+/)
          for (a = 1; a <= nt; a++)
            for (b = 1; b <= ns; b++)
              if (S[b] ~ /^kali-/) print T[a], S[b], U[1]
        }' "$1"
      ;;
    *)
      awk '
        /^[[:space:]]*deb(-src)?[[:space:]]/ {
          i = 2
          if ($i ~ /^\[/) { while ($i !~ /\]$/ && i < NF) i++; i++ }
          if ($(i + 1) ~ /^kali-/) print $1, $(i + 1), $i
        }' "$1"
      ;;
  esac
}

has_active_kali() {
  local entries
  [[ -f $1 ]] || return 1
  entries=$(kali_entries "$1")
  [[ -n $entries ]]
}

# deb822 / legacy / both / none, based on files with active Kali entries.
source_format() {
  local f legacy=0 deb822=0
  while IFS= read -r f; do
    has_active_kali "$f" || continue
    case $f in *.sources) deb822=1 ;; *) legacy=1 ;; esac
  done < <(list_source_files)
  if [[ $legacy -eq 1 && $deb822 -eq 1 ]]; then echo both
  elif [[ $deb822 -eq 1 ]]; then echo deb822
  elif [[ $legacy -eq 1 ]]; then echo legacy
  else echo none; fi
}

# The file that keeps the Kali definition; all others get disabled.
primary_source_file() {
  local default="$SOURCES_DIR/kali.sources" f
  if has_active_kali "$default"; then printf '%s\n' "$default"; return 0; fi
  for f in "$SOURCES_DIR"/*.sources "$SOURCES_LIST" "$SOURCES_DIR"/*.list; do
    if has_active_kali "$f"; then printf '%s\n' "$f"; return 0; fi
  done
  printf '%s\n' "$default"
}

# Repeated "<type> <suite>" pairs across all files: apt's
# "Target ... is configured multiple times".
duplicate_keys() {
  local f
  while IFS= read -r f; do
    if has_active_kali "$f"; then kali_entries "$f" | cut -d' ' -f1,2; fi
  done < <(list_source_files) | sort | uniq -d
}

current_mirror() {
  local primary entries uri=""
  primary=$(primary_source_file)
  if has_active_kali "$primary"; then
    entries=$(kali_entries "$primary")
    read -r _ _ uri _ <<<"$entries"
  fi
  printf '%s\n' "${uri%/}"
}

insecure_source_files() {
  local f
  while IFS= read -r f; do
    has_active_kali "$f" || continue
    if grep -qiE 'trusted=(yes|true)|^Trusted:[[:space:]]*(yes|true)|allow-insecure' "$f"; then
      printf '%s\n' "$f"
    fi
  done < <(list_source_files)
}

# transform_legacy <file> <rewrite|disable> <mirror>
# rewrite: point every Kali line at <mirror>; lines with the same type, options
# and suite are merged into one (components are unioned, never dropped).
transform_legacy() {
  awk -v mode="$2" -v mirror="$3" '
    /^[[:space:]]*deb(-src)?[[:space:]]/ {
      i = 2
      if ($i ~ /^\[/) { while ($i !~ /\]$/ && i < NF) i++; i++ }
      if ($(i + 1) !~ /^kali-/) { out[n++] = $0; next }
      if (mode == "disable") { out[n++] = "# kali-apt-fixer disabled (duplicate): " $0; next }
      opts = ""
      for (j = 2; j < i; j++) opts = opts (opts == "" ? "" : " ") $j
      gsub(/(trusted|allow-insecure)=(yes|true)/, "", opts)
      gsub(/[[:space:]]+/, " ", opts)
      sub(/\[ /, "[", opts); sub(/ \]/, "]", opts)
      if (opts == "[]") opts = ""
      suite = $(i + 1)
      key = $1 "|" opts "|" suite
      if (!(key in head)) {
        head[key] = $1 " " (opts == "" ? "" : opts " ") mirror " " suite
        comps[key] = ""
        out[n++] = "" key
      }
      for (j = i + 2; j <= NF; j++)
        if (index(" " comps[key] " ", " " $j " ") == 0) comps[key] = comps[key] " " $j
      next
    }
    { out[n++] = $0 }
    END {
      for (k = 0; k < n; k++) {
        if (substr(out[k], 1, 1) == "") { key = substr(out[k], 2); print head[key] comps[key] }
        else print out[k]
      }
    }' "$1"
}

# transform_deb822 <file> <rewrite|disable> <mirror> <keyring>
transform_deb822() {
  awk -v mode="$2" -v mirror="$3" -v keyring="$4" '
    BEGIN { RS = ""; FS = "\n"; n = 0 }
    {
      kali = 0; off = 0; types = ""; suites = ""; signed = 0
      for (k = 1; k <= NF; k++) {
        if ($k ~ /^Suites:.*kali-/) { kali = 1; suites = $k }
        if ($k ~ /^Types:/) types = $k
        if ($k ~ /^Enabled:[ \t]*(no|false)/) off = 1
        if ($k ~ /^Signed-By:/) signed = 1
      }
      if (!kali || off) { out[n++] = $0; next }
      if (mode == "disable") { out[n++] = $0 "\nEnabled: no"; next }
      key = types "|" suites
      if (key in seen) next
      seen[key] = 1
      rec = ""
      for (k = 1; k <= NF; k++) {
        if ($k ~ /^(Trusted|Allow-Insecure):/) continue
        line = ($k ~ /^URIs:/) ? "URIs: " mirror : $k
        rec = rec (rec == "" ? "" : "\n") line
      }
      if (!signed) rec = rec "\nSigned-By: " keyring
      out[n++] = rec
    }
    END { for (k = 0; k < n; k++) printf "%s%s", out[k], (k < n - 1 ? "\n\n" : "\n") }' "$1"
}

new_deb822_stanza() {
  printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: %s\n' \
    "$1" "$SUITE" "$DEFAULT_COMPONENTS" "$KEYRING"
}

# Scratch path for the next staged file (not a pipe: the arrays must be set
# in the current shell).
stage_tmp() { printf '%s/stage.%d' "$WORKDIR" "${#STAGE_DST[@]}"; }

# Records <src> as the new contents of <dest> only if they differ from disk.
stage_file() {
  local dest=$1 src=$2
  if [[ -f $dest ]] && cmp -s "$src" "$dest"; then return 0; fi
  STAGE_SRC+=("$src")
  STAGE_DST+=("$dest")
}

stage_source_changes() {
  local mirror=$1 primary f tmp
  STAGE_SRC=() STAGE_DST=()
  primary=$(primary_source_file)
  tmp=$(stage_tmp)
  if [[ ! -f $primary ]]; then
    new_deb822_stanza "$mirror" >"$tmp"
  elif [[ $primary == *.sources ]]; then
    transform_deb822 "$primary" rewrite "$mirror" "$KEYRING" >"$tmp"
  else
    transform_legacy "$primary" rewrite "$mirror" >"$tmp"
  fi
  stage_file "$primary" "$tmp"
  while IFS= read -r f; do
    [[ $f == "$primary" ]] && continue
    has_active_kali "$f" || continue
    tmp=$(stage_tmp)
    if [[ $f == *.sources ]]; then
      transform_deb822 "$f" disable "$mirror" "$KEYRING" >"$tmp"
    else
      transform_legacy "$f" disable "$mirror" >"$tmp"
    fi
    stage_file "$f" "$tmp"
  done < <(list_source_files)
}

# --------------------------------------------------------------- keyring ---

keyring_state() {
  if [[ ! -e $KEYRING ]]; then echo missing
  elif [[ ! -s $KEYRING ]]; then echo empty
  else echo ok; fi
}

# Sets KEYRING_DEB_MIRROR/NAME from the first mirror that lists the package.
find_keyring_deb() {
  local m name
  for m in "$@"; do
    if name=$(keyring_deb_name "$m") && [[ -n $name ]]; then
      KEYRING_DEB_MIRROR=$m
      KEYRING_DEB_NAME=$name
      return 0
    fi
  done
  return 1
}

install_keyring() {
  local url deb err code rc=0 st pkg
  url="$(keyring_pool_url "$KEYRING_DEB_MIRROR")$KEYRING_DEB_NAME"
  deb="$WORKDIR/$KEYRING_DEB_NAME"
  err="$WORKDIR/keyring.err"
  info "Downloading $url"
  code=$(http_fetch "$url" "$deb" "$err") || rc=$?
  st=$(classify_fetch "$rc" "$code" "$deb" "$err" deb)
  [[ $st == OK ]] || die "keyring download failed: $(describe_status "$st")"
  pkg=$(dpkg-deb -f "$deb" Package 2>/dev/null || true)
  [[ $pkg == kali-archive-keyring ]] || die "downloaded file is not the kali-archive-keyring package"
  info "sha256: $(sha256sum "$deb" | cut -d' ' -f1)"
  dpkg -i "$deb"
  [[ -s $KEYRING ]] || die "$KEYRING is still empty after installing the package"
}

# ---------------------------------------------------------------- backup ---

snapshot_to() {
  local dest=$1 f rel
  mkdir -p "$dest/files"
  : >"$dest/MANIFEST"
  while IFS= read -r f; do
    rel=${f#"$APT_DIR"/}
    install -D -m 0644 "$f" "$dest/files/$rel"
    printf '%s\n' "$rel" >>"$dest/MANIFEST"
  done < <(list_source_files)
}

# The first snapshot ("original") is never overwritten.
backup_sources() {
  local ts
  mkdir -p "$BACKUP_DIR"
  if [[ ! -d $BACKUP_DIR/original ]]; then
    rm -rf "$BACKUP_DIR/original.tmp"
    snapshot_to "$BACKUP_DIR/original.tmp"
    mv "$BACKUP_DIR/original.tmp" "$BACKUP_DIR/original"
    info "Original sources saved to $BACKUP_DIR/original"
  fi
  ts=$(date +%Y%m%d-%H%M%S)
  snapshot_to "$BACKUP_DIR/$ts"
  info "Snapshot saved to $BACKUP_DIR/$ts"
}

# ------------------------------------------------------------------- fix ---

select_mirror() {
  local cur m
  CHOSEN_MIRROR=""
  if [[ -n $FORCED_MIRROR ]]; then
    mirror_usable "$FORCED_MIRROR" || die "the mirror given with --mirror is not usable"
    CHOSEN_MIRROR=$FORCED_MIRROR
    return 0
  fi
  cur=$(current_mirror)
  if [[ -n $cur ]] && mirror_usable "$cur"; then
    CHOSEN_MIRROR=$cur
    return 0
  fi
  for m in "${MIRROR_LIST[@]}"; do
    [[ $m == "$cur" ]] && continue
    if mirror_usable "$m"; then CHOSEN_MIRROR=$m; return 0; fi
  done
  die "no usable mirror found. Run '$PROG diagnose' for details, or pass --mirror <url>"
}

show_staged_diffs() {
  local i
  for i in "${!STAGE_DST[@]}"; do
    info ""
    if [[ -f ${STAGE_DST[$i]} ]]; then
      diff -u "${STAGE_DST[$i]}" "${STAGE_SRC[$i]}" || true
    else
      info "--- new file ${STAGE_DST[$i]}"
      cat "${STAGE_SRC[$i]}"
    fi
  done
}

run_apt_update() {
  info "Running apt-get update"
  apt-get update || die "apt-get update failed - see output above"
  log_file INFO "apt-get update succeeded"
}

cmd_fix() {
  local kstate i
  init_workdir
  section "Selecting mirror"
  select_mirror
  PLAN=()
  stage_source_changes "$CHOSEN_MIRROR"
  for i in "${!STAGE_DST[@]}"; do PLAN+=("write ${STAGE_DST[$i]}"); done
  kstate=$(keyring_state)
  if [[ $kstate != ok ]]; then
    find_keyring_deb "$CHOSEN_MIRROR" "${MIRROR_LIST[@]}" \
      || die "keyring is $kstate and no mirror lists kali-archive-keyring"
    PLAN+=("install $KEYRING_DEB_NAME from $KEYRING_DEB_MIRROR with dpkg -i (keyring is $kstate)")
  fi

  section "Plan"
  if [[ ${#PLAN[@]} -eq 0 ]]; then
    good "Sources and keyring are already fine (mirror: $CHOSEN_MIRROR); nothing to change"
  else
    info "Mirror: $CHOSEN_MIRROR"
    local p
    for p in "${PLAN[@]}"; do info "  - $p"; done
    show_staged_diffs
    info "  - backup current sources to $BACKUP_DIR first"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    info ""
    info "Dry run: nothing was changed."
    return 0
  fi
  if [[ ${#PLAN[@]} -gt 0 ]]; then
    confirm "Apply these changes?" || die "aborted, nothing changed"
    backup_sources
    [[ $kstate == ok ]] || install_keyring
    for i in "${!STAGE_DST[@]}"; do
      install -D -m 0644 "${STAGE_SRC[$i]}" "${STAGE_DST[$i]}"
      good "wrote ${STAGE_DST[$i]}"
    done
  fi
  run_apt_update
  good "Done."
}

# --------------------------------------------------------------- restore ---

cmd_restore() {
  local orig="$BACKUP_DIR/original" rel f changed=0
  [[ -f $orig/MANIFEST ]] || die "no original backup found in $BACKUP_DIR"
  PLAN=()
  while IFS= read -r rel; do
    cmp -s "$orig/files/$rel" "$APT_DIR/$rel" 2>/dev/null || PLAN+=("restore $APT_DIR/$rel")
  done <"$orig/MANIFEST"
  f="$SOURCES_DIR/kali.sources"
  if [[ -f $f ]] && ! grep -qxF "sources.list.d/kali.sources" "$orig/MANIFEST"; then
    PLAN+=("remove $f (did not exist originally)")
  fi
  if [[ ${#PLAN[@]} -eq 0 ]]; then
    good "Sources already match the original backup; nothing to restore"
    return 0
  fi
  section "Plan"
  local p
  for p in "${PLAN[@]}"; do info "  - $p"; done
  [[ $DRY_RUN -eq 1 ]] && { info "Dry run: nothing was changed."; return 0; }
  confirm "Restore the original sources?" || die "aborted, nothing changed"
  snapshot_to "$BACKUP_DIR/pre-restore-$(date +%Y%m%d-%H%M%S)"
  while IFS= read -r rel; do
    install -D -m 0644 "$orig/files/$rel" "$APT_DIR/$rel"
    changed=1
  done <"$orig/MANIFEST"
  if [[ -f $f ]] && ! grep -qxF "sources.list.d/kali.sources" "$orig/MANIFEST"; then
    rm -f "$f"
  fi
  [[ $changed -eq 1 ]] && good "Original sources restored. Run 'apt-get update' to refresh."
  return 0
}

# --------------------------------------------------------------- upgrade ---

zsh_snapshot() {
  # shellcheck disable=SC2016 # dpkg-query expands ${...} itself
  { dpkg-query -W -f='${Package}=${Version}\n' zsh zsh-common 2>/dev/null || true; } | sort
}

# True when zsh was installed before and its packages changed during upgrade.
zsh_hint_needed() {
  [[ -n $1 && $1 != "$2" ]]
}

print_zsh_hint() {
  warn "zsh was upgraded. Already-open zsh sessions may now print errors such as"
  warn "  'failed to load module zsh/complist'."
  warn "Open a new terminal / SSH session (or run 'exec zsh') to fix that."
}

run_apt() {
  local -a args=("$@")
  [[ $ASSUME_YES -eq 1 ]] && args=(-y "${args[@]}")
  if [[ $DRY_RUN -eq 1 ]]; then
    info "would run: apt-get ${args[*]}"
    return 0
  fi
  info "Running: apt-get ${args[*]}"
  apt-get "${args[@]}" || die "apt-get ${args[*]} failed (if it is a mirror problem, try '$PROG fix')"
}

cmd_upgrade() {
  local before after
  before=$(zsh_snapshot)
  run_apt update
  run_apt upgrade
  run_apt dist-upgrade
  run_apt autoremove
  run_apt autoclean
  [[ $DRY_RUN -eq 1 ]] && return 0
  after=$(zsh_snapshot)
  if zsh_hint_needed "$before" "$after"; then print_zsh_hint; fi
  good "Upgrade finished."
}

# -------------------------------------------------------------- diagnose ---

diagnose_sources() {
  local f fmt dups cur bad_files
  section "APT sources"
  fmt=$(source_format)
  info "Active Kali entries: format=$fmt"
  while IFS= read -r f; do
    if has_active_kali "$f"; then info "  $f"; fi
  done < <(list_source_files)
  if [[ $fmt == none ]]; then
    FINDINGS+=("No active Kali entry found under $APT_DIR")
    ACTIONS+=("create $SOURCES_DIR/kali.sources")
  fi
  dups=$(duplicate_keys)
  if [[ -n $dups ]]; then
    bad "Duplicate definitions (apt: 'Target ... is configured multiple times'):"
    printf '       %s\n' "$dups"
    FINDINGS+=("Kali repository is defined more than once")
    ACTIONS+=("keep $(primary_source_file) and disable the duplicate definitions")
  elif [[ $fmt != none ]]; then
    good "No duplicate definitions"
  fi
  bad_files=$(insecure_source_files)
  if [[ -n $bad_files ]]; then
    bad "Signature checks are bypassed (trusted=yes / allow-insecure) in:"
    printf '       %s\n' "$bad_files"
    FINDINGS+=("Repository signature verification is bypassed")
    ACTIONS+=("remove trusted=yes / allow-insecure from the Kali entries")
  fi
  cur=$(current_mirror)
  [[ -z $cur ]] || info "Configured mirror: $cur"
}

diagnose_keyring() {
  local st
  section "Keyring"
  st=$(keyring_state)
  case $st in
    ok) good "$KEYRING present ($(wc -c <"$KEYRING") bytes)" ;;
    empty)
      bad "$KEYRING is empty (0 bytes) -> 'Missing key ... needed to verify signature'"
      FINDINGS+=("Keyring file is empty")
      ;;
    missing)
      bad "$KEYRING is missing"
      FINDINGS+=("Keyring file is missing")
      ;;
  esac
}

probe_mirror() {
  local url=$1 dns tcp tls="n/a" st pst
  parse_url "$url"
  info ""
  info "$url"
  dns_check "$URL_HOST" && dns=ok || dns=FAIL
  tcp_check "$URL_HOST" "$URL_PORT" && tcp=ok || tcp=FAIL
  if [[ $URL_SCHEME == https && $tcp == ok ]]; then tls=$(tls_status "$URL_HOST" "$URL_PORT"); fi
  info "  DNS: $dns   TCP/$URL_PORT: $tcp   TLS handshake: $tls"
  st=$(mirror_status "$url")
  MIRROR_STATUS[$url]=$st
  if [[ $st == OK ]]; then
    good "  InRelease: $(describe_status "$st")"
    pst=$(package_status "$url")
    case $pst in
      OK) good "  package download: works" ;;
      UNKNOWN) info "  package download: not checked (no directory listing)" ;;
      *) bad "  package download: $(describe_status "$pst")"; MIRROR_STATUS[$url]=$pst ;;
    esac
  else
    bad "  InRelease: $(describe_status "$st")"
  fi
}

diagnose_network() {
  local cur m url alt
  local -A seen=()
  local -a probes=()
  section "Mirrors"
  cur=$(current_mirror)
  for m in "$cur" "$FORCED_MIRROR" "${MIRROR_LIST[@]}"; do
    [[ -n $m && -z ${seen[$m]:-} ]] || continue
    seen[$m]=1
    probes+=("$m")
    # http.kali.org is the one most often filtered: show both schemes.
    alt="https://${m#http://}"
    if [[ $m == http://http.kali.org/* && -z ${seen[$alt]:-} ]]; then
      seen[$alt]=1
      probes+=("$alt")
    fi
  done
  for url in "${probes[@]}"; do probe_mirror "$url"; done

  local working=""
  for m in "$FORCED_MIRROR" "${MIRROR_LIST[@]}"; do
    if [[ -n $m && ${MIRROR_STATUS[$m]:-} == OK ]]; then working=$m; break; fi
  done
  if [[ -n $cur && ${MIRROR_STATUS[$cur]:-OK} != OK ]]; then
    FINDINGS+=("Configured mirror $cur does not work: $(describe_status "${MIRROR_STATUS[$cur]}")")
    if [[ -n $working ]]; then ACTIONS+=("switch the sources to $working"); fi
  fi
  if [[ -z $working ]]; then
    FINDINGS+=("None of the configured mirrors is reachable and valid")
    ACTIONS+=("nothing 'fix' can do alone: ask for a mirror to be allowed, or use --mirror <url>")
  elif [[ $(keyring_state) != ok ]]; then
    ACTIONS+=("download the newest kali-archive-keyring .deb from $working and install it with dpkg -i")
  fi
}

print_summary() {
  local f
  section "Summary"
  if [[ ${#FINDINGS[@]} -eq 0 ]]; then
    good "No problems detected."
    return 0
  fi
  info "Problems:"
  for f in "${FINDINGS[@]}"; do info "  - $f"; done
  info ""
  info "'$PROG fix' would:"
  for f in "${ACTIONS[@]}"; do info "  - $f"; done
  return 1
}

cmd_diagnose() {
  init_workdir
  diagnose_sources
  diagnose_keyring
  diagnose_network
  print_summary
}

# ------------------------------------------------------------ list-mirrors ---

cmd_list_mirrors() {
  local m n=1
  init_workdir
  for m in "${MIRROR_LIST[@]}"; do
    printf '%d. %s ... ' "$n" "$m"
    describe_status "$(mirror_status "$m")"
    n=$((n + 1))
  done
}

main() {
  parse_args "$@"
  setup_colors
  load_config
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  [[ $CMD == list-mirrors ]] || require_root
  log_file INFO "$PROG $VERSION: $CMD"
  case $CMD in
    diagnose) cmd_diagnose ;;
    fix) cmd_fix ;;
    restore) cmd_restore ;;
    upgrade) cmd_upgrade ;;
    list-mirrors) cmd_list_mirrors ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
