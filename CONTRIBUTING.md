# Contributing

Bug reports and pull requests are welcome.

- **Bugs / ideas:** open an issue and redact internal host names and IPs from any output.
- **Security problems:** report privately, see [SECURITY.md](SECURITY.md).

## Development

```bash
sudo apt-get install -y shellcheck bats
shellcheck kali-apt-fixer.sh
bats tests/
```

Tests mock `curl`, `apt-get`, `dpkg`, DNS and TCP checks and use a scratch directory;
they never touch the real network or `/etc/apt`. A new detection case needs a fixture in
`tests/fixtures/`, a mock in `tests/helpers.bash` and a bats test.

## Guidelines

- Quote every variable; no `eval`, no `curl | bash`.
- Never weaken signature verification (`trusted=yes`, `--allow-unauthenticated`).
- Only contact the mirrors being tested; do not invent mirror URLs.
- Changes must respect `--dry-run`, be shown before applied, and stay idempotent.
- Update `README.md` / `CHANGELOG.md` when behaviour changes.

By contributing you agree that your work is released under the [MIT License](LICENSE).
