#!/usr/bin/env bats
# Detection logic of kali-apt-fixer with mocked curl/apt/dpkg.

load helpers

setup() { setup_env; }
teardown() { teardown_env; }

# --- problem 1: proxy block page / SNI filtering ---------------------------

@test "HTTP proxy 'Web Page Blocked' page is classified as PROXY_BLOCK" {
  MOCK_MODE=proxy_block
  run mirror_status "http://http.kali.org/kali"
  [ "$status" -eq 0 ]
  [ "$output" = "PROXY_BLOCK" ]
}

@test "HTTPS connection reset is classified as CONN_RESET" {
  MOCK_MODE=proxy_block
  run mirror_status "https://http.kali.org/kali"
  [ "$output" = "CONN_RESET" ]
}

# --- problem 2: WAF 403 on package download --------------------------------

@test "WAF 403 on a package download is classified as WAF_403" {
  MOCK_MODE=waf
  run package_status "https://kali.download/kali"
  [ "$output" = "WAF_403" ]
}

@test "mirror with valid InRelease but WAF-blocked packages is not usable" {
  MOCK_MODE=waf
  run mirror_usable "https://kali.download/kali"
  [ "$status" -ne 0 ]
}

# --- problem 3: dead mirror ------------------------------------------------

@test "Cloudflare 522 is classified as DEAD_MIRROR" {
  MOCK_MODE=dead
  run mirror_status "https://mirror.example.org/kali"
  [ "$output" = "DEAD_MIRROR" ]
}

@test "healthy mirror returns OK and is usable" {
  run mirror_status "https://mirror.example.org/kali"
  [ "$output" = "OK" ]
  run mirror_usable "https://mirror.example.org/kali"
  [ "$status" -eq 0 ]
}

@test "empty InRelease is not accepted" {
  : >"$TEST_ROOT/empty"
  run classify_fetch 0 200 "$TEST_ROOT/empty" /dev/null inrelease
  [ "$output" = "EMPTY" ]
}

# --- problems 4 + 5: source formats and duplicates -------------------------

@test "legacy one-line format is detected" {
  use_legacy_sources
  [ "$(source_format)" = "legacy" ]
}

@test "deb822 format is detected" {
  use_deb822_sources
  [ "$(source_format)" = "deb822" ]
}

@test "both formats are detected and flagged as duplicate" {
  use_legacy_sources
  use_deb822_sources
  [ "$(source_format)" = "both" ]
  [ -n "$(duplicate_keys)" ]
}

@test "single definition is not a duplicate" {
  use_deb822_sources
  [ -z "$(duplicate_keys)" ]
}

@test "commented-out Kali line does not count" {
  printf '# deb http://http.kali.org/kali kali-rolling main\n' >"$KAF_APT_DIR/sources.list"
  [ "$(source_format)" = "none" ]
}

@test "deb822 stanza with Enabled: no does not count" {
  { cat "$FIXTURES/kali.sources"; echo "Enabled: no"; } >"$KAF_APT_DIR/sources.list.d/kali.sources"
  [ "$(source_format)" = "none" ]
}

@test "fix stages: duplicate legacy line is disabled, deb822 gets new mirror" {
  use_legacy_sources
  use_deb822_sources
  stage_source_changes "https://mirror.aarnet.edu.au/kali"
  [ "${#STAGE_DST[@]}" -eq 2 ]
  for i in "${!STAGE_DST[@]}"; do
    case ${STAGE_DST[$i]} in
      */kali.sources) grep -q '^URIs: https://mirror.aarnet.edu.au/kali$' "${STAGE_SRC[$i]}" ;;
      */sources.list) grep -q '^# kali-apt-fixer disabled (duplicate): deb http' "${STAGE_SRC[$i]}" ;;
    esac
  done
}

@test "legacy rewrite merges same-suite lines and keeps all components" {
  printf '%s
'     'deb http://http.kali.org/kali kali-rolling main'     'deb http://http.kali.org/kali kali-rolling main contrib non-free' >"$KAF_APT_DIR/sources.list"
  run transform_legacy "$KAF_APT_DIR/sources.list" rewrite "https://mirror.aarnet.edu.au/kali"
  [ "$output" = "deb https://mirror.aarnet.edu.au/kali kali-rolling main contrib non-free" ]
}

@test "legacy rewrite keeps other lines and drops trusted=yes" {
  printf '%s\n' '# my sources' \
    'deb [trusted=yes] http://http.kali.org/kali kali-rolling main contrib' \
    'deb http://example.com/other stable main' >"$KAF_APT_DIR/sources.list"
  run transform_legacy "$KAF_APT_DIR/sources.list" rewrite "https://mirror.aarnet.edu.au/kali"
  [[ $output == *"deb https://mirror.aarnet.edu.au/kali kali-rolling main contrib"* ]]
  [[ $output == *"deb http://example.com/other stable main"* ]]
  [[ $output != *"trusted=yes"* ]]
}

@test "insecure entries are reported" {
  printf 'deb [trusted=yes] http://http.kali.org/kali kali-rolling main\n' >"$KAF_APT_DIR/sources.list"
  [ -n "$(insecure_source_files)" ]
}

# --- problem 6: keyring ----------------------------------------------------

@test "empty keyring is detected" {
  : >"$KAF_KEYRING"
  [ "$(keyring_state)" = "empty" ]
}

@test "missing keyring is detected" {
  rm -f "$KAF_KEYRING"
  [ "$(keyring_state)" = "missing" ]
}

@test "non-empty keyring is ok" {
  [ "$(keyring_state)" = "ok" ]
}

@test "keyring .deb name is parsed from the listing, newest version wins" {
  run keyring_deb_name "https://mirror.example.org/kali"
  [ "$output" = "kali-archive-keyring_2025.1_all.deb" ]
}

@test "listing replaced by a proxy block page yields no keyring name" {
  MOCK_MODE=proxy_block
  run keyring_deb_name "http://http.kali.org/kali"
  [ "$status" -ne 0 ]
}

# --- end to end ------------------------------------------------------------

@test "fix skips a blocked mirror, picks the next, repairs keyring, no trusted=yes" {
  use_deb822_sources
  : >"$KAF_KEYRING"
  MOCK_MODE=reset
  MOCK_BAD_HOST="http.kali.org"
  MIRRORS="http://http.kali.org/kali https://mirror.aarnet.edu.au/kali"
  load_config
  run cmd_fix
  [ "$status" -eq 0 ]
  grep -q '^URIs: https://mirror.aarnet.edu.au/kali$' "$KAF_APT_DIR/sources.list.d/kali.sources"
  [ -s "$KAF_KEYRING" ]
  grep -q '^dpkg -i .*kali-archive-keyring_2025.1_all.deb' "$CALLS_LOG"
  grep -q '^apt-get update' "$CALLS_LOG"
  run grep -rqi 'trusted=yes\|allow-unauthenticated' "$KAF_APT_DIR" "$CALLS_LOG"
  [ "$status" -ne 0 ]
  [ -f "$KAF_APT_DIR/kali-apt-fixer-backup/original/files/sources.list.d/kali.sources" ]
}

@test "fix is idempotent: second run changes nothing" {
  use_legacy_sources
  use_deb822_sources
  MIRRORS="https://mirror.aarnet.edu.au/kali"
  load_config
  run cmd_fix
  [ "$status" -eq 0 ]
  before=$(cat "$KAF_APT_DIR/sources.list" "$KAF_APT_DIR/sources.list.d/kali.sources" | sha256sum)
  backups_before=$(ls "$KAF_APT_DIR/kali-apt-fixer-backup" | wc -l)
  : >"$CALLS_LOG"
  run cmd_fix
  [ "$status" -eq 0 ]
  [[ $output == *"nothing to change"* ]]
  after=$(cat "$KAF_APT_DIR/sources.list" "$KAF_APT_DIR/sources.list.d/kali.sources" | sha256sum)
  [ "$before" = "$after" ]
  [ "$backups_before" -eq "$(ls "$KAF_APT_DIR/kali-apt-fixer-backup" | wc -l)" ]
  run grep -q '^dpkg' "$CALLS_LOG"
  [ "$status" -ne 0 ]
}

@test "original backup is never overwritten and restore brings it back" {
  use_legacy_sources
  cp "$KAF_APT_DIR/sources.list" "$TEST_ROOT/orig.list"
  MOCK_MODE=reset
  MOCK_BAD_HOST="http.kali.org"
  MIRRORS="https://mirror.aarnet.edu.au/kali"
  load_config
  run cmd_fix
  [ "$status" -eq 0 ]
  run cmp -s "$KAF_APT_DIR/sources.list" "$TEST_ROOT/orig.list"
  [ "$status" -ne 0 ]
  # a second change must not touch the first backup
  printf 'deb http://http.kali.org/kali kali-rolling main\n' >>"$KAF_APT_DIR/sources.list"
  run cmd_fix
  cmp -s "$KAF_APT_DIR/kali-apt-fixer-backup/original/files/sources.list" "$TEST_ROOT/orig.list"
  run cmd_restore
  [ "$status" -eq 0 ]
  cmp -s "$KAF_APT_DIR/sources.list" "$TEST_ROOT/orig.list"
}

@test "--dry-run changes nothing" {
  use_legacy_sources
  cp "$KAF_APT_DIR/sources.list" "$TEST_ROOT/orig.list"
  MIRRORS="https://mirror.aarnet.edu.au/kali"
  load_config
  DRY_RUN=1
  run cmd_fix
  [ "$status" -eq 0 ]
  cmp -s "$KAF_APT_DIR/sources.list" "$TEST_ROOT/orig.list"
  [ ! -d "$KAF_APT_DIR/kali-apt-fixer-backup" ]
  run grep -q '^apt-get' "$CALLS_LOG"
  [ "$status" -ne 0 ]
}

# --- problem 7: zsh hint ---------------------------------------------------

@test "zsh hint is needed when zsh packages changed" {
  run zsh_hint_needed "zsh=5.9-1" "zsh=5.9-2"
  [ "$status" -eq 0 ]
}

@test "zsh hint is not needed when zsh is unchanged or absent" {
  run zsh_hint_needed "zsh=5.9-1" "zsh=5.9-1"
  [ "$status" -ne 0 ]
  run zsh_hint_needed "" "zsh=5.9-1"
  [ "$status" -ne 0 ]
}

@test "upgrade prints the zsh hint after a zsh upgrade" {
  dpkg-query() { printf 'zsh=%s\n' "$(cat "$TEST_ROOT/zshver")"; }
  echo 5.9-1 >"$TEST_ROOT/zshver"
  apt-get() { echo 5.9-2 >"$TEST_ROOT/zshver"; }
  run cmd_upgrade
  [ "$status" -eq 0 ]
  [[ $output == *"zsh/complist"* ]]
}

# --- config and safety -----------------------------------------------------

@test "MIRRORS env var overrides the defaults" {
  MIRRORS="https://a.example/kali https://b.example/kali"
  load_config
  [ "${#MIRROR_LIST[@]}" -eq 2 ]
  [ "${MIRROR_LIST[1]}" = "https://b.example/kali" ]
}

@test "config file is parsed, not executed" {
  printf 'MIRRORS="https://c.example/kali"\ntouch %s/pwned\n' "$TEST_ROOT" >"$KAF_CONF_FILE"
  load_config
  [ "${MIRROR_LIST[0]}" = "https://c.example/kali" ]
  [ ! -e "$TEST_ROOT/pwned" ]
}

@test "mirror URLs with shell metacharacters are rejected" {
  MIRRORS='https://x.example/kali;rm'
  run load_config
  [ "$status" -ne 0 ]
}

@test "non-root users are refused" {
  [ "$EUID" -ne 0 ] || skip "running as root"
  KAF_ALLOW_NONROOT=0
  run require_root
  [ "$status" -ne 0 ]
  [[ $output == *"must run as root"* ]]
}
