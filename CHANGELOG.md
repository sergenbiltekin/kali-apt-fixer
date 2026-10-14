# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-14

### Added
- `diagnose`, `fix`, `restore`, `upgrade` and `list-mirrors` subcommands.
- Detection of proxy block pages, SNI-based TLS resets, TLS-inspection
  certificate errors, Cloudflare/WAF 403 on package downloads, dead mirrors
  (HTTP 5xx / Cloudflare 52x) and DNS/TCP failures.
- Support for legacy `sources.list` and deb822 `*.sources`, including
  duplicate ("configured multiple times") detection and cleanup.
- Keyring repair: the newest `kali-archive-keyring` .deb is discovered from the
  mirror's pool listing and installed with `dpkg -i`.
- Timestamped backups; the first original backup is never overwritten.
- Hint for already-open zsh sessions after an upgrade
  (`failed to load module zsh/complist`).
- Configurable mirror list via `MIRRORS` or `/etc/kali-apt-fixer.conf`.
- bats test-suite with mocked `curl`/`apt-get`/`dpkg`, shellcheck + bats CI.
