## What does this change?

<!-- Short description and the problem it solves. Link the issue if there is one. -->

## How was it tested?

<!-- Commands run, mocked scenarios added, or real environments tried. -->

## Checklist

- [ ] `shellcheck kali-apt-fixer.sh` is clean
- [ ] `bats tests/` passes
- [ ] New detection logic or behaviour has a bats test (mocked `curl`/`apt-get`/`dpkg`)
- [ ] Signature checks are not weakened (no `trusted=yes`, no `--allow-unauthenticated`)
- [ ] No new network destinations other than the mirrors being tested
- [ ] No `eval`, unquoted variables or `curl | bash`
- [ ] `README.md` / `CHANGELOG.md` updated if behaviour or usage changed
