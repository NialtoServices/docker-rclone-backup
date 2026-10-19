# docker-rclone-backup

## Project memory rules

This file carries what the codebase **cannot** tell you: constraints, rationale, gotchas, business
rules. It is not a description of the code. Derivable content here is worse than none, because the
file reads as ground truth and so misleads the moment it drifts.

- **The codebase wins.** Where this file and the code disagree, the code is right and the line is
  stale. Verify against the source before acting on anything that reads like a fact about the
  current implementation, and fix or delete the line once you find the drift.
- **Before adding anything, ask whether a session could work it out** with `ls`, `cat`, `grep`, or
  the package manifest. If it could, don't add it: no directory layouts, dependency lists,
  component rosters, frontmatter or type enumerations, function signatures, or standard commands.
- **Do add** what the code can't explain: why something is the way it is, what breaks if it
  changes, prohibitions, copy and business rules, and non-obvious build or environment steps.
- **Prefer a pointer to a copy.** Name the file that holds the detail rather than restating it, so
  there is one source of truth and nothing to keep in sync.
- **Record constraints, not progress.** This file is not a changelog.

## Constraints

- **Features that need real logic belong in tidweard, not here.** Manifests, restore planning,
  verification by test restore and capability checking are tidweard's job. This project stays a
  thin layer of shell around the database clients and rclone.
- **Everything written at run time lives under `/tmp`.** The images run with a read-only root
  filesystem and `/tmp` as a `noexec` tmpfs, so the crontab, the lock, staging and rclone's cache
  all go there, unless the owner moves staging with `BACKUP_STAGING_PATH`.
- **Patches publish themselves only when every change since the last release is a patch.** If an
  unpublished minor or major change is waiting, a patch joins that release instead of shipping
  under a patch number. See the CI section of the design spec in `docs/superpowers/specs/`.
- **`renovate.json` keeps `ci` pull requests free of the `patch` label.** The update-type rules set
  `labels` and the later CI rule replaces it; changing either to `addLabels` would give an Actions
  or test-server patch `patch,ci`, which the auto-release decision publishes and Release Drafter
  leaves out of the notes. Test-server lines get their own branch prefix so that the Dockerfile's
  update of the same image (`mysql:9.7`) is a separate pull request that keeps `patch`.
- **`config:recommended` ignores `test/`**, so `renovate.json` removes `:ignoreModulesAndTests`;
  without that `test/servers` is never read and Renovate reports nothing wrong.
