# Patches

Applied to the library sources by `build.sh`, in name order, after Homebrew's
formulae for the same versions (Homebrew/homebrew-core at ce4e1815, 2026-10-22):

- `openldap/01-libtool-no-flat-namespace.diff` — Homebrew's
  `Patches/libtool/configure-big_sur.diff`: the libtool bundled with OpenLDAP
  links with `-flat_namespace` on a macOS it doesn't recognise.
- `libssh2/*` — the security fixes Homebrew backports onto libssh2 1.11.1
  (`Patches/libssh2/` and the upstream commits named in the formula), in the
  formula's order; several only apply after the ones before them.

When bumping a version in `build.sh`, check the formula for patches it has
added or dropped: `brew cat <formula>`.
