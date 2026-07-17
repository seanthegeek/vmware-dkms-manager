# AGENTS.md

Instructions for AI coding agents working on this project.

## What this project is

A single bash script, `vmware-dkms-manager.sh`, plus `README.md` documenting
it. It wraps VMware Workstation's `vmmon`/`vmnet` kernel modules as a real
DKMS package so they rebuild and get signed automatically on every kernel
update, across Debian, RHEL-family, openSUSE, Arch, Gentoo, and Void.

**Why this exists**: VMware's own `vmware-modconfig` builder never hooks
into DKMS, so with Secure Boot enabled, every kernel update leaves the
modules unsigned until someone manually re-signs them. This script fixes
that permanently by registering the modules with DKMS instead.

## Files

- `vmware-dkms-manager.sh` — the script. Single file, no external deps
  beyond what it installs itself (`dkms`, `mokutil`, `openssl`, and
  `shim-signed` where applicable).
- `README.md` — user-facing docs: usage, exit codes, signing-key selection
  order, distro support matrix, troubleshooting.

## Non-negotiable design invariants

These encode real bugs and false assumptions found and fixed during
development. Don't reintroduce them.

1. **VMware's modules are not natively DKMS-managed.** That's the entire
   reason this script exists — don't "simplify" by assuming otherwise.
2. **Never assert a signing key path — detect and reuse first.**
   `determine_mok_paths` checks `/etc/dkms/framework.conf` (and, on
   Gentoo, `/etc/portage/make.conf`'s `MODULES_SIGN_KEY`/`MODULES_SIGN_CERT`)
   for an existing config before falling back to DKMS's own native default
   (`/var/lib/dkms/mok.key`/`mok.pub`). Overwriting an existing distro's or
   user's signing config unconditionally is the bug this replaced.
3. **MOK comparisons use SHA1 fingerprint, never subject-string or
   `/proc/keys` matching.** `/proc/keys` truncates the key-type column
   (`asymmetri`), and subject-string formatting isn't guaranteed to match
   between `openssl` and `mokutil` output. `mok_is_enrolled` and
   `mok_import_pending` both compare by fingerprint — keep it that way.
4. **`sbctl`-only Secure Boot, immutable/atomic roots, and NixOS must fail
   closed, not silently proceed.** See `check_sbctl_conflict` (exit `3`)
   and `check_immutable_root` (exit `4`). These aren't edge cases to
   "handle" by attempting a fix — this script's whole model (writing to
   `/usr/src`, `/var/lib/dkms`, `/etc/dkms`) doesn't apply there.
5. **Never `chmod` a directory this script doesn't own outright.**
   `/var/lib/dkms` and `/var/lib/shim-signed/mok` are shared system
   directories; only `chmod` the key files themselves.
6. **Package names differ per distro family** — see the table in
   `README.md`. Don't add apt-only assumptions (e.g. `dpkg -s`) outside
   the `debian` branch of `ensure_packages`.

## Making changes

- Keep `README.md`'s exit-code table and distro-support table in sync with
  the script whenever either changes — they're the same information in
  two places and reviewers rely on both being accurate.
- Prefer detection over assumption for anything OS/distro-specific.
  If you're not certain a claim about a distro's package name, default
  file path, or DKMS integration is accurate, verify it (web search) rather
  than guessing — several early drafts of this script guessed wrong (e.g.
  assuming Ubuntu's shim-signed auto-sign behavior was generic DKMS
  behavior; it isn't).
- `status` must stay strictly read-only — it's the tool used to debug the
  other two commands, so it can never be the thing that changes state.

## Validating changes

```bash
# Script: syntax check (and shellcheck if available)
bash -n vmware-dkms-manager.sh
shellcheck vmware-dkms-manager.sh   # if installed

# README: lint, ignoring line-length (MD013)
npx --yes markdownlint-cli README.md --disable MD013
```

Both should be run before considering an edit complete. Neither requires
network access or a VMware install to run.

## Out of scope

Don't add support for Alpine (musl + no dependency-resolving package
manager makes VMware Workstation an unlikely target) or Slackware (no
dependency-resolving package manager to script against). Don't attempt to
make immutable/atomic distros or NixOS "work" — the refusal in
`check_immutable_root` is the correct behavior, not a placeholder for a
future implementation.
