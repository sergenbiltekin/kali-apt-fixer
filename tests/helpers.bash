# Shared setup and mocks for the kali-apt-fixer bats tests.
# shellcheck shell=bash disable=SC2034,SC2317

FIXTURES="$BATS_TEST_DIRNAME/fixtures"

# Builds a scratch /etc/apt + keyring tree and sources the script (the
# script only runs main() when executed, not when sourced).
setup_env() {
  TEST_ROOT=$(mktemp -d)
  export KAF_APT_DIR="$TEST_ROOT/etc/apt"
  export KAF_KEYRING="$TEST_ROOT/usr/share/keyrings/kali-archive-keyring.gpg"
  export KAF_LOG_FILE="$TEST_ROOT/kali-apt-fixer.log"
  export KAF_CONF_FILE="$TEST_ROOT/none.conf"
  export KAF_ALLOW_NONROOT=1
  export CALLS_LOG="$TEST_ROOT/calls.log"
  mkdir -p "$KAF_APT_DIR/sources.list.d" "$(dirname "$KAF_KEYRING")"
  : >"$CALLS_LOG"
  unset MIRRORS
  # shellcheck source=../kali-apt-fixer.sh
  source "$BATS_TEST_DIRNAME/../kali-apt-fixer.sh"
  WORKDIR=$(mktemp -d "$TEST_ROOT/work.XXXXXX")
  ASSUME_YES=1
  USE_COLOR=0
  MOCK_MODE=ok
  MOCK_BAD_HOST=""
  load_config
  printf 'KEYRING-DATA' >"$KAF_KEYRING"
}

teardown_env() {
  rm -rf "$TEST_ROOT"
}

use_legacy_sources() {
  cp "$FIXTURES/sources.list.kali" "$KAF_APT_DIR/sources.list"
}

use_deb822_sources() {
  cp "$FIXTURES/kali.sources" "$KAF_APT_DIR/sources.list.d/kali.sources"
}

# ---- mocks ----------------------------------------------------------------
# MOCK_MODE: ok | proxy_block | waf | dead | reset
# MOCK_BAD_HOST: only URLs containing this string misbehave (empty = all).

mock_mode_for() {
  if [[ -n $MOCK_BAD_HOST && $1 != *"$MOCK_BAD_HOST"* ]]; then
    echo ok
  else
    echo "$MOCK_MODE"
  fi
}

# Writes <body fixture or text> to $out and prints the status code.
mock_reply() { # out code fixture
  if [[ -n $3 ]]; then cat "$FIXTURES/$3" >"$1"; else : >"$1"; fi
  printf '%s' "$2"
}

curl() {
  local out="" url=""
  while (($#)); do
    case $1 in
      -o) out=$2; shift ;;
      -w|--connect-timeout|--max-time|--proto|-r) shift ;;
      -*) ;;
      *) url=$1 ;;
    esac
    shift
  done
  printf 'curl %s\n' "$url" >>"$CALLS_LOG"
  local mode
  mode=$(mock_mode_for "$url")
  case $mode in
    reset)
      echo "curl: (35) Recv failure: Connection reset by peer" >&2
      return 35
      ;;
    proxy_block)
      if [[ $url == http://* ]]; then mock_reply "$out" 200 proxy-block.html; return 0; fi
      echo "curl: (35) OpenSSL SSL_connect: Connection reset by peer" >&2
      return 35
      ;;
    dead) mock_reply "$out" 522 cf-522.html; return 0 ;;
    waf)
      case $url in
        */InRelease) mock_reply "$out" 200 InRelease.ok ;;
        */kali-archive-keyring/) mock_reply "$out" 200 pool-listing.html ;;
        *) mock_reply "$out" 403 waf-403.html ;;
      esac
      return 0
      ;;
  esac
  case $url in
    */InRelease) mock_reply "$out" 200 InRelease.ok ;;
    */kali-archive-keyring/) mock_reply "$out" 200 pool-listing.html ;;
    *.deb) printf '!<arch>\ndebian-binary' >"$out"; printf 206 ;;
    *) : >"$out"; printf 404 ;;
  esac
}

dns_check() { return 0; }
tcp_check() { return 0; }
tls_status() { echo OK; }

dpkg() {
  printf 'dpkg %s\n' "$*" >>"$CALLS_LOG"
  if [[ $1 == -i ]]; then printf 'KEYRING-DATA' >"$KAF_KEYRING"; fi
}
dpkg-deb() { echo kali-archive-keyring; }
dpkg-query() { printf 'zsh=%s\nzsh-common=%s\n' "${ZSH_VER:-5.9-1}" "${ZSH_VER:-5.9-1}"; }
apt-get() { printf 'apt-get %s\n' "$*" >>"$CALLS_LOG"; }
