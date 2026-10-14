# Contributing

Thanks for helping make Kali APT updates less painful on restricted networks.

## Reporting problems

- Bugs and ideas: open an issue using one of the templates. Please redact internal
  host names, IP addresses and proxy details from any output you paste.
- Security problems: use the private report link in [SECURITY.md](SECURITY.md),
  not a public issue.

## Development setup

You need `bash`, `shellcheck` and [bats-core](https://github.com/bats-core/bats-core):

```bash
sudo apt-get install -y shellcheck bats
```

Run everything CI runs:

```bash
shellcheck kali-apt-fixer.sh
bash -n kali-apt-fixer.sh
bats tests/
```

Tests source the script and mock `curl`, `apt-get`, `dpkg`, DNS and TCP checks.
They use a scratch directory (`KAF_APT_DIR`, `KAF_KEYRING`, `KAF_LOG_FILE`,
`KAF_CONF_FILE`) and never touch the real network or `/etc/apt`.

## Adding a detection case

1. Add a fixture under `tests/fixtures/` that reproduces what the network returns
   (a block page, a WAF page, an error body, a directory listing).
2. Teach the mock in `tests/helpers.bash` to return it (a new `MOCK_MODE` or URL).
3. Write a bats test that fails first, then implement the classification in
   `classify_fetch` / `describe_status` in `kali-apt-fixer.sh`.
4. Mention the new case in the README table of handled problems.

## Code guidelines

- Bash with `set -euo pipefail`; small functions; comments only where the logic is
  not obvious.
- Quote every variable. No `eval`, no `curl | bash`.
- Do not weaken signature verification: never write `trusted=yes` /
  `Trusted: yes` and never pass `--allow-unauthenticated`.
- The only network destinations are the mirrors being tested.
- Anything that changes the system must be shown in the plan first (unless `--yes`),
  must respect `--dry-run`, and must be idempotent.
- Do not invent mirror URLs. Check that a mirror actually serves
  `dists/kali-rolling/InRelease` and a pool listing before adding it to the defaults.
- Be careful with `set -e`: a loop or function whose last command is a failing
  `cmd && other` exits the script.
- Keep awk portable: Kali's default `awk` is mawk, so avoid gawk-only features.

## Pull requests

- Keep changes focused; one logical change per PR.
- Fill in the PR template checklist.
- Update `README.md` and `CHANGELOG.md` (under "Unreleased") when behaviour changes.
- Use clear, imperative commit messages (`Fix duplicate detection for deb-src`).

By contributing you agree that your work is released under the [MIT License](LICENSE).
