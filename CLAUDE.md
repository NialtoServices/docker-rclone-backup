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
- **One database, SQLite file or folder per container, and no history of its own.** The bucket's
  versioning is the history, so timestamped object names, pruning and discovering several databases
  stay out; more sources mean more containers.
- **Every object restores with stock tools, without these images.** `pg_restore`, `mysql` or
  `mariadb`, `sqlite3`, `zstd` and rclone on any machine are enough; nothing may wrap, encrypt or
  reformat a dump in a way only this project can undo.
- **A failure must never look like a success.** A run that didn't happen, stopped part-way or
  produced a dump that can't be read back fails the run and reaches the monitor.
- **The `DATABASE_*` names deliberately differ from the official database images' variables**
  (`POSTGRES_USER`, `MYSQL_PASSWORD`, `MARIADB_DATABASE`…). An env file shared with the database
  container then can't make the backup connect as the application's or root's account, so never
  read those names or fall back to them.
- **Everything written at run time lives under `/tmp`.** The images run with a read-only root
  filesystem and `/tmp` as a `noexec` tmpfs, so the crontab, the lock, staging and rclone's cache
  all go there, unless the owner moves staging with `BACKUP_STAGING_PATH`.
- **Patches publish themselves only when every change since the last release is a patch.** If an
  unpublished minor or major change is waiting, a patch joins that release instead of shipping
  under a patch number. `.github/scripts/auto-release-decision` holds the rule.
- **`renovate.json` keeps `ci` pull requests free of the `patch` label.** The update-type rules set
  `labels` and the later CI rule replaces it; changing either to `addLabels` would give an Actions
  or test-server patch `patch,ci`, which the auto-release decision publishes and Release Drafter
  leaves out of the notes. Test-server lines get their own branch prefix so that the Dockerfile's
  update of the same image (`mysql:9.7`) is a separate pull request that keeps `patch`.
- **`config:recommended` ignores `test/`**, so `renovate.json` removes `:ignoreModulesAndTests`;
  without that `test/servers` is never read and Renovate reports nothing wrong.

## Maintenance

- **Label every pull request of your own `major`, `minor` or `patch` before merging it**, or `ci`
  when it only changes CI. Release Drafter counts an unlabelled one as a patch, and anything not by
  Renovate holds back the automatic release, so the draft then waits to be published by hand.
- **supercronic bumps can't automerge.** Its releases publish only SHA-1s, in the release notes, so
  the per-architecture `SUPERCRONIC_SHA256_*` ARGs are computed by hand on Renovate's branch:
  download both binaries, check each `sha1sum` against the notes, and commit each `sha256sum`.
  Renovate changes only the version, so until then the stale checksum fails the build. Renovate
  leaves a branch alone once someone else has pushed to it.
- **PostgreSQL's supported majors change every year, in two releases.** When a new major arrives
  (around September), add its `postgresql-client-N` to the Dockerfile, its server to `test/servers`
  and to the version settings at the top of `test/postgres`, and release it as a minor. When the
  oldest reaches end of life in November, PGDG moves its client to an archive and every build,
  the weekly rebuild included, fails until it is dropped: remove its client and its supported
  entry, and release that as a major. Each time, also update the hard-coded range in the
  "isn't supported" message in `jobs/postgres`, the two `grep`s for that message in `test/postgres`,
  and the README's version lists. A dropped major's line stays in `test/servers`, because the
  refusal test runs against the newest unsupported major: point `UNSUPPORTED_VERSION` in
  `test/postgres` at it, and the line it named before can go.
- **The next Debian release is a manual change Renovate won't propose.** The base image's tag is
  the codename `trixie`, so Renovate only moves its digest. The `trixie-pgdg` suite in the
  `postgres` stage moves with it, the `mysql` stage's library package names are trixie's
  (`libssl3t64`), and Debian's MariaDB client series, which the README names, changes with it.
  Check that PGDG and Debian carry every client package for the new release before switching.
- **The rclone and PGDG signing keys are pinned by file and fingerprint** (`keys/` and the
  `*_SIGNER_FINGERPRINT` ARGs). A key rotation fails the build until the new key is committed and
  its fingerprint checked against the one its publisher announces.
- **Renovate offers every newer `mysql` tag, innovation releases included.** The client moves only
  to the next LTS, so approve or merge nothing else for the Dockerfile's `mysql` stage.
- **A test server's major on the Dependency Dashboard is a prompt, not a change to approve.** Each
  `test/servers` line is one supported series, so the pull request would replace that series
  instead of adding the new one; add the new series' line and tests by hand.
- **A release whose Publish run never built has no images.** Publish runs one at a time and GitHub
  keeps only one run pending, so a third run cancels the waiting one and two releases published
  close together can leave the earlier without images (a cancelled Publish run in the Actions tab).
  Auto release's dispatch step failing after it publishes does the same. Re-run it with
  `gh workflow run publish.yml --ref <tag>`; the weekly rebuild only ever builds the newest release.
- **GitHub disables the weekly rebuild after 60 days without repository activity.** Renovate's
  automerged updates keep the repository active, and a failed scheduled run emails whoever last
  changed the schedule, so the optional `REBUILD_MONITOR_URL` heartbeat isn't set. If Renovate stops
  merging, the schedule can lapse unnoticed: re-enable it with `gh workflow enable publish.yml`, or
  set the secret to a weekly check's success URL to be alerted.
- **Branch protection requires the one check named `CI passed`** (the `ci-ok` job in `ci.yml`).
  Renaming it leaves every pull request, Renovate's included, waiting on a check that never reports.
- **A new image's GHCR package starts private.** A package that a workflow creates with
  `GITHUB_TOKEN` can't be pulled by anyone until it is made public in its package settings.
