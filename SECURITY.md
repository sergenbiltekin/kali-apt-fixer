# Security Policy

## Supported versions

Only the latest release receives security fixes.

| Version | Supported |
|---------|-----------|
| 1.0.x   | yes       |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report privately through GitHub:
[Security > Report a vulnerability](https://github.com/sergenbiltekin/kali-apt-fixer/security/advisories/new).

Include, if you can:

- what the problem is and why it matters
- the version or commit, and the Kali/Debian release you ran it on
- steps or a minimal example to reproduce it

You can expect an acknowledgement within a few days. Fixes are released as a new
patch version, and reporters are credited in the advisory unless they prefer otherwise.

## Scope

This tool runs as root and edits `/etc/apt`, so these are in scope:

- anything that lets untrusted input (mirror responses, config file contents,
  environment variables, file names) run commands or write outside the intended files
- any path that disables or weakens APT signature verification
- data being sent anywhere other than the mirrors being tested
- unsafe handling of backups, temporary files or the downloaded keyring package

Out of scope: problems that require an attacker who is already root, and the
documented trust limitation of the keyring bootstrap (see "Security notes" in the
README).

## Verifying releases

Release assets come with a `SHA256SUMS` file. See "Install" in the README.
