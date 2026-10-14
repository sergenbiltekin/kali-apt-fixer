# kali-apt-fixer

A single Bash tool that **diagnoses and fixes common Kali Linux APT update problems**,
especially on corporate or otherwise restricted networks.

It was written for situations where `apt update` fails because a proxy, firewall or CDN
sits between you and `http.kali.org` / `kali.download`, and where the usual advice
("just change the mirror") is not enough because the keyring is broken, the sources are
defined twice, or the "working" mirror still blocks package downloads.

- One file, no dependencies beyond what a stock Kali install already has
- Read-only `diagnose`, explicit plan + confirmation before `fix` changes anything
- Never disables signature checking (no `[trusted=yes]`, no `--allow-unauthenticated`)
- Idempotent, with backups; `restore` returns to your original configuration

## Problems it handles

| # | Symptom | How it is detected |
|---|---------|--------------------|
| 1a | `https://http.kali.org` fails with *Connection reset by peer* during the TLS handshake (SNI-based filtering) | curl exit code 35/56 on the HTTPS probe, reported as `CONN_RESET` |
| 1b | `http://http.kali.org` returns a *Web Page Blocked* page (category: hacking) | HTTP 200 whose body is not a PGP-signed `InRelease` and matches known block-page wording, reported as `PROXY_BLOCK` |
| 2 | Cloudflare/WAF answers **403 "High Security Alert"** for package downloads on `kali.download` after the `http.kali.org` 302 | A real range request for a package (`kali-archive-keyring_*.deb`) is made; 403 + WAF wording is `WAF_403`. A mirror whose `InRelease` works but whose packages are blocked is rejected |
| 3 | Dead mirrors: Cloudflare 522, unresolvable hosts | HTTP 5xx / 52x → `DEAD_MIRROR`; DNS and TCP checks → `DNS_FAIL` / `TCP_FAIL` |
| 4 | `Target ... is configured multiple times` | The same `<type> <suite>` is defined more than once across `sources.list`, `*.list` and `*.sources` |
| 5 | Two source formats | Legacy one-line (`/etc/apt/sources.list`, `*.list`) and deb822 (`/etc/apt/sources.list.d/*.sources`) are both parsed and rewritten in place |
| 6 | `Missing key ... needed to verify signature` caused by an empty `/usr/share/keyrings/kali-archive-keyring.gpg` | File size is 0 (or the file is missing). Fix downloads the newest `kali-archive-keyring_*_all.deb` (name parsed from the mirror's pool listing, never hard-coded) and installs it with `dpkg -i` |
| 6b | Keyring bypass | `trusted=yes` / `allow-insecure` are reported by `diagnose` and removed on rewrite. The tool itself never uses them |
| 7 | `failed to load module zsh/complist` in an already-open zsh after a big upgrade | `upgrade` compares the `zsh`/`zsh-common` versions before and after and prints a hint to open a new shell/SSH session |

## Install

```bash
# from a clone (recommended: you can read it before running it)
git clone https://github.com/sergenbiltekin/kali-apt-fixer.git
cd kali-apt-fixer
sudo install -m 0755 kali-apt-fixer.sh /usr/local/bin/kali-apt-fixer
```

or just download the single file:

```bash
curl -fsSLO https://raw.githubusercontent.com/sergenbiltekin/kali-apt-fixer/main/kali-apt-fixer.sh
less kali-apt-fixer.sh          # read it first
sudo install -m 0755 kali-apt-fixer.sh /usr/local/bin/kali-apt-fixer
```

> The script never pipes anything into a shell and neither should you.

## Usage

```
sudo kali-apt-fixer <command> [options]

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
```

Typical session:

```bash
sudo kali-apt-fixer diagnose            # what is wrong?
sudo kali-apt-fixer fix --dry-run       # what would change?
sudo kali-apt-fixer fix                 # do it (asks first)
sudo kali-apt-fixer upgrade --yes       # full upgrade, then the zsh hint
sudo kali-apt-fixer restore             # put the original sources back
```

Other examples:

```bash
sudo kali-apt-fixer fix --mirror https://mirror.example.org/kali
sudo MIRRORS="https://a.example/kali https://b.example/kali" kali-apt-fixer fix
kali-apt-fixer list-mirrors             # no root needed, only talks to the mirrors
```

If your network needs an HTTP proxy, export it and keep it through sudo:
`sudo -E kali-apt-fixer fix` (curl and apt both honour `http_proxy`/`https_proxy`).

### Exit codes

`diagnose` exits `1` when it found problems (handy in scripts); every command exits `1`
on errors and `0` on success.

## Example output

> Illustrative output; exact wording and hosts depend on your network.

```
$ sudo kali-apt-fixer diagnose --no-color

== APT sources ==
Active Kali entries: format=both
  /etc/apt/sources.list
  /etc/apt/sources.list.d/kali.sources
[FAIL] Duplicate definitions (apt: 'Target ... is configured multiple times'):
       deb kali-rolling
Configured mirror: http://http.kali.org/kali

== Keyring ==
[FAIL] /usr/share/keyrings/kali-archive-keyring.gpg is empty (0 bytes) -> 'Missing key ... needed to verify signature'

== Mirrors ==

http://http.kali.org/kali
  DNS: ok   TCP/80: ok   TLS handshake: n/a
[FAIL]   InRelease: proxy/firewall block page returned instead of repository data

https://http.kali.org/kali
  DNS: ok   TCP/443: ok   TLS handshake: CONN_RESET
[FAIL]   InRelease: connection reset by peer (typical SNI-based TLS filtering)

https://mirror.aarnet.edu.au/kali
  DNS: ok   TCP/443: ok   TLS handshake: OK
[ OK ]   InRelease: valid
[ OK ]   package download: works

== Summary ==
Problems:
  - Kali repository is defined more than once
  - Keyring file is empty
  - Configured mirror http://http.kali.org/kali does not work: proxy/firewall block page returned instead of repository data
'kali-apt-fixer fix' would:
  - keep /etc/apt/sources.list.d/kali.sources and disable the duplicate definitions
  - switch the sources to https://mirror.aarnet.edu.au/kali
  - download the newest kali-archive-keyring .deb from https://mirror.aarnet.edu.au/kali and install it with dpkg -i
```

```
$ sudo kali-apt-fixer fix
== Selecting mirror ==
[FAIL] http://http.kali.org/kali: InRelease proxy/firewall block page returned instead of repository data
[ OK ] https://mirrors.tuna.tsinghua.edu.cn/kali: valid InRelease, package downloads work

== Plan ==
Mirror: https://mirrors.tuna.tsinghua.edu.cn/kali
  - write /etc/apt/sources.list.d/kali.sources
  - write /etc/apt/sources.list
  - install kali-archive-keyring_2025.3_all.deb from https://mirrors.tuna.tsinghua.edu.cn/kali with dpkg -i (keyring is empty)
  ... unified diffs ...
  - backup current sources to /etc/apt/kali-apt-fixer-backup first
Apply these changes? [y/N] y
```

## How `fix` works

1. **Pick a mirror.** If `--mirror` is given, only that one is tried. Otherwise the mirror
   that is already configured is kept if it works; if not, the list is tried in order and
   the first one that passes both checks wins:
   - `dists/kali-rolling/InRelease` is non-empty and starts with
     `-----BEGIN PGP SIGNED MESSAGE-----` (so a block page returned with HTTP 200 does not pass)
   - a package download works (this is what catches the WAF 403 case)
2. **Stage changes** in a temporary directory and show them as a diff / plan.
   Nothing is written before you confirm (or pass `--yes`).
3. **Back up** `sources.list`, `sources.list.d/*.list` and `*.sources` to
   `/etc/apt/kali-apt-fixer-backup/`. `original/` is written once and never replaced;
   every run that changes something also adds a timestamped snapshot.
4. **Rewrite** the Kali entry in the detected format. One file keeps the definition
   (`kali.sources` if present); other Kali entries are disabled, not deleted
   (legacy lines are commented out with a marker, deb822 stanzas get `Enabled: no`).
   Non-Kali entries are untouched.
5. **Repair the keyring** if it is empty or missing, then `apt-get update`.

Running `fix` a second time finds nothing to change and creates no new backup.

## Configuration

Mirrors, first match wins:

1. `MIRRORS` environment variable (space- or comma-separated base URLs)
2. `MIRRORS="url url ..."` in `/etc/kali-apt-fixer.conf` (parsed as text, **not** sourced)
3. Built-in list:

```
https://mirrors.tuna.tsinghua.edu.cn/kali
https://mirror.aarnet.edu.au/kali
https://ftp.acc.umu.se/mirror/kali.org/kali
https://mirrors.ocf.berkeley.edu/kali
http://http.kali.org/kali
```

These are base URLs of the form `<scheme>://<host>/<path>` such that
`<base>/dists/kali-rolling/InRelease` exists. Every mirror is validated at run time and
unusable ones are skipped; if a path changes upstream, adjust the list.

Logging goes to `/var/log/kali-apt-fixer.log`.

## Tests

```bash
sudo apt-get install -y bats shellcheck
shellcheck kali-apt-fixer.sh
bats tests/
```

The bats suite sources the script and mocks `curl`, `apt-get`, `dpkg`, DNS and TCP checks
with fixtures for a proxy block page, a WAF 403, a dead mirror, an empty keyring,
duplicate definitions and both source formats. No test touches the real network or `/etc/apt`.

## Limitations

- Only the `kali-rolling` suite is handled (`KAF_SUITE` exists for experiments).
- A proxy that requires **authentication**, or one that re-signs TLS with a corporate CA,
  is reported (`TLS_CERT`) but not fixed: install the CA certificate or configure
  `Acquire::http::Proxy` yourself. The tool never uses `curl -k`.
- If *every* mirror is blocked, `fix` stops with an error and changes nothing. You need an
  allowed mirror (internal mirror, `--mirror <url>`) or a firewall exception.
- Mirror validation is a point-in-time check; a mirror can be fine for `InRelease` and
  still throttle or block later downloads.
- The package probe needs a directory listing at
  `<mirror>/pool/main/k/kali-archive-keyring/`. Mirrors without one are accepted with the
  package check marked "not checked", and cannot be used to download the keyring.
- Only APT source files under `/etc/apt` are managed. `Acquire::*` proxy settings,
  `apt.conf.d` overrides and pinning are out of scope.
- Written for Debian/Kali tooling (`apt-get`, `dpkg`, GNU coreutils, awk).

## Security notes

- **Network:** the only hosts contacted are the mirrors being tested (plus the redirect
  targets a mirror itself sends curl to). Nothing is reported or uploaded anywhere.
- **Signatures stay on.** The script never writes `[trusted=yes]`, `Trusted: yes` or
  `--allow-unauthenticated`; it strips them if it finds them in Kali entries.
- **Keyring bootstrap caveat:** the keyring package is the root of trust, so it cannot be
  verified by APT before it is installed. The tool checks that the download is a real
  `.deb` of the package `kali-archive-keyring`, prints its SHA-256 and then installs it,
  but trust in the mirror (and TLS, where used) is what protects that one step. If your
  threat model needs more, fetch the package from a source you trust and compare it
  manually against the key fingerprints published at kali.org, then use `dpkg -i`.
- **No code execution from config:** `/etc/kali-apt-fixer.conf` is parsed line by line,
  never sourced; mirror URLs are restricted to a safe character set. The script uses no
  `eval` and no `curl | bash`.
- Runs as root because it edits `/etc/apt` and installs a package; read it first.

## License

MIT, see [LICENSE](LICENSE).
