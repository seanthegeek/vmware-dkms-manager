# CLAUDE.md

@AGENTS.md

## Claude Code

- Use plan mode before editing anything in `determine_mok_paths`,
  `create_mok_if_missing`, `ensure_dkms_signing_config`, `mok_is_enrolled`,
  or `mok_import_pending` — this is the signing-key selection logic
  covered by invariant #2 and #3 in AGENTS.md, and mistakes here are easy
  to make and hard to notice (they fail silently as "not enrolled" rather
  than with an error).
- This project has no test suite and no CI. "Validated" means the checks
  in AGENTS.md's Validating changes section pass, plus a manual read-through
  confirming the change doesn't touch a file/directory it doesn't own
  (invariant #5).
- When asked to add distro support, check whether the distro already loads
  under an existing family via `ID_LIKE` (see the table in `README.md`)
  before adding a new `DISTRO_FAMILY` case — most derivatives already do.
