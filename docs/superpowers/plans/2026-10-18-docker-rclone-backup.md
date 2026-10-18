# docker-rclone-backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one repository that publishes five hardened, shell-only backup images (`postgres`, `mariadb`, `mysql`, `sqlite`, `files`) which each put one object into a versioned bucket with rclone on a schedule.

**Architecture:** One Dockerfile with a shared `base` stage (Debian trixie-slim, rclone, supercronic, tini, the shared scripts) and one final stage per image that adds its client and copies its own job script to `/usr/local/bin/backup`. A shared `start` validates settings and the schedule, then supervises supercronic; a shared `monitor` wrapper reports each run to a heartbeat monitor. GitHub Actions builds, tests and publishes all five; Renovate and release-drafter keep it current.

**Tech Stack:** POSIX `sh` (Debian's `dash`, which supports `set -o pipefail`), rclone, supercronic, tini, PGDG PostgreSQL clients 15–18, Debian's MariaDB 11.8 client and `sqlite3`, Oracle's `mysqldump` 9.7, zstd, Docker Buildx, GitHub Actions, Renovate, release-drafter.

**Spec:** `docs/superpowers/specs/2026-10-18-docker-rclone-backup-design.md` — read it alongside this plan; it carries the reasoning, and this plan carries the decisions.

**Working style (the owner's, overriding test-first):** each task writes its code and its tests together, then runs them, then commits. Commit messages are a plain imperative subject (no `feat:`-style prefix, ~50 characters, no full stop), with a body only when the why isn't obvious, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Follow `~/.claude/CLAUDE.md` for naming (descriptive, no contractions), guard clauses (blank line after a guard run), and comments (why, not what; blank line before an inline comment).

**Reference implementation:** `../docker-rclone-sync` at commit `37d83c5`. Its `bin/monitor`, `bin/start` (supervisor), `lib/log.sh`, `test/smoke` and `.github/workflows/docker-containers.yaml` (release resolution) are the starting point for the matching pieces here; port them rather than rewriting from scratch, adapting as each task says.

## Global Constraints

- Base image: `debian:trixie-slim`, pinned by digest. Platforms: `linux/amd64`, `linux/arm64`.
- Images: `ghcr.io/nialtoservices/rclone-backup/<name>` for `postgres`, `mariadb`, `mysql`, `sqlite`, `files`.
- Default user `65532:65532`, no login shell, no home directory. Every image ends `USER 65532:65532` and `ENTRYPOINT ["/usr/bin/tini", "--"]`, `CMD ["/usr/local/bin/start"]`.
- Must work under the hardening baseline: `read_only`, `cap_drop: [ALL]`, `no-new-privileges`, `/tmp` as `noexec` tmpfs. So everything written at run time (crontab, lock, staging, rclone cache) lives under `/tmp` unless the owner moves staging with `BACKUP_STAGING_PATH`.
- Scripts are POSIX `sh` with `set -eu` (plus `-o pipefail` wherever a pipeline's status matters). `.shellcheckrc` sets `shell=dash`.
- PostgreSQL servers 15, 16, 17, 18; MariaDB 10.11, 11.4, 11.8+; MySQL 8.0, 8.4, 9.x.
- Shared settings: `BACKUP_SCHEDULE` (default `0 0 * * *`, or `disabled`), `BACKUP_TARGET`, `BACKUP_STAGING_PATH` (default `/tmp`, database and SQLite images), `TZ`, `MONITOR_START_URL`, `MONITOR_SUCCESS_URL`, `MONITOR_FAILURE_URL`, `RCLONE_*` passed through.
- Database settings: `DATABASE_HOST`, `DATABASE_PORT` (5432 / 3306), `DATABASE_USER`, `DATABASE_PASSWORD` or `DATABASE_PASSWORD_FILE`, `DATABASE_NAME`, `DATABASE_TLS` (`disabled` default, `required`, `verify`), `DATABASE_TLS_CA_PATH`. SQLite: `SQLITE_DATABASE`. Files: `BACKUP_SOURCE`.
- Unknown settings: any variable starting `BACKUP_`, `MONITOR_`, `DATABASE_` or `SQLITE_` that the image doesn't read stops the container at start-up.
- Objects: `<DATABASE_NAME>.dump` (postgres), `<DATABASE_NAME>.sql.zst` (mariadb, mysql), `<basename of SQLITE_DATABASE>.zst` (sqlite).
- rclone: official zip from downloads.rclone.org, `SHA256SUMS` verified by PGP against the committed key with fingerprint `FBF737ECE9F8AB18604BD2AC93935E02FF3B54FA`. Never the `rclone/rclone` image.
- supercronic: GitHub release binary, pinned version, per-architecture SHA-256 in the Dockerfile (its releases publish no checksum file or signature, so a supercronic bump is a hand-checked pull request, not an automerge).
- Every build runs `apt-get upgrade`.
- British English in prose, README and commit messages.

## Review Focus

1. **Passwords with shell-hostile characters** (`p@ss w'rd"$;\`) must work for all three database images and never appear in a process's arguments. Pinned in Tasks 6–8.
2. **`DATABASE_NAME` containing `/` or starting with `.`** would write the object somewhere other than `BACKUP_TARGET`; it must be refused by `backup --check`. Pinned in Task 3 (settings helper) and exercised in Task 6.
3. **`BACKUP_TARGET` with a trailing slash** (`b2:bucket/app/`) must still produce `b2:bucket/app/<object>`, not `…app//<object>`. Pinned in Task 5.
4. **A dump larger than the staging space** must fail the run, upload nothing and leave no staged file behind. Pinned in Task 6.
5. **An unreachable database host** must fail within about a minute and report, never hang until the next schedule. Pinned in Tasks 6–8 (connect timeouts: `PGCONNECT_TIMEOUT=10`, `--connect-timeout=10`).

---

## File Structure

```
.editorconfig                 LF, final newline; 2-space for scripts and YAML
.shellcheckrc                 shell=dash; disable=SC1091 (scripts source in-image paths)
CLAUDE.md                     project rules (the owner's five project-memory rules) and non-derivable constraints
LICENSE                       Apache-2.0
README.md                     the only user documentation
Dockerfile                    base stage + one target per image
keys/rclone.asc               rclone's release signing key (from rclone's docs/content/KEYS)
lib/log.sh                    info, warn, fatal                       -> /usr/local/lib/rclone-backup/
lib/settings.sh               setting validation helpers               -> /usr/local/lib/rclone-backup/
lib/job.sh                    run lock, staging directory, upload       -> /usr/local/lib/rclone-backup/
bin/start                     entry point: validate, write crontab, supervise supercronic
bin/monitor                   heartbeat wrapper around one run
jobs/files                    -> /usr/local/bin/backup in the files image
jobs/sqlite                   -> /usr/local/bin/backup in the sqlite image
jobs/postgres                 -> /usr/local/bin/backup in the postgres image
jobs/mariadb                  -> /usr/local/bin/backup in the mariadb image
jobs/mysql                    -> /usr/local/bin/backup in the mysql image
test/lib.sh                   check(), hardened docker run, fake monitor, wait_for
test/servers                  database server images used by tests, one per line, digest-pinned
test/shared                   start/monitor/stop behaviour, run against the files image
test/files, test/sqlite, test/postgres, test/mariadb, test/mysql   one suite per image
.github/scripts/resolve-release           which release a publish run builds (stdin: tags)
.github/scripts/auto-release-decision     publish or wait (stdin: merged changes)
test/github-scripts           tests for the two scripts above
.github/workflows/build.yml   reusable: lint, build, test, optionally push by digest
.github/workflows/ci.yml      pull requests and pushes to main
.github/workflows/publish.yml releases, dispatch, weekly rebuild; merges manifests and tags
.github/workflows/release-drafter.yml, .github/release-drafter.yml
.github/workflows/auto-release.yml
renovate.json
```

---

### Task 1: Repository scaffolding and the base image

**Files:**
- Create: `.editorconfig`, `.shellcheckrc`, `CLAUDE.md`, `LICENSE` (copy `../docker-rclone-sync/LICENSE`), `README.md` (title, one-paragraph intro, `## Licence`), `keys/rclone.asc`, `lib/log.sh` (port from `../docker-rclone-sync/lib/log.sh`, install path `/usr/local/lib/rclone-backup/log.sh`), `Dockerfile` (the download stages and `base` only), `test/lib.sh`, `test/base`

**Interfaces:**
- Produces: image stage `base`; `/usr/local/lib/rclone-backup/log.sh` with `info MESSAGE`, `warn MESSAGE`, `fatal MESSAGE` (exits 1); `test/lib.sh` with `check DESCRIPTION COMMAND...`, `hardened_run [docker run options] IMAGE [command...]` (adds `--rm --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp:rw,nodev,noexec,nosuid,size=512m`), `wait_for COMMAND...` (30 one-second attempts).

- [ ] **Step 1: Write the scaffolding files.** `.shellcheckrc`: `shell=dash` and `disable=SC1091` with a comment saying the scripts source paths that exist only in the image. `CLAUDE.md`: copy the five rules from the "Project Memory Files (`CLAUDE.md`)" section of `~/.claude/CLAUDE.md` near the top, then only non-derivable constraints: the anti-goal (features needing real logic belong in tidweard), "everything written at run time lives under `/tmp`" (read-only root filesystem), and "patches publish themselves only when every change since the last release is a patch" (spec, CI section). `keys/rclone.asc`: rclone's current signing key from `https://github.com/rclone/rclone/blob/master/docs/content/KEYS`, confirmed to have fingerprint `FBF737ECE9F8AB18604BD2AC93935E02FF3B54FA` with `gpg --show-keys`.

- [ ] **Step 2: Write the `base` stage.** In order: `FROM debian:trixie-slim@sha256:<current digest>`; a `rclone` download stage that installs `curl gpg unzip`, downloads `rclone-v${RCLONE_VERSION}-linux-${TARGETARCH}.zip` and `SHA256SUMS` from `https://downloads.rclone.org/v${RCLONE_VERSION}/`, verifies `SHA256SUMS` with `gpg --verify` against `keys/rclone.asc` (fail unless the signing key's fingerprint is the pinned one), checks the zip's line with `sha256sum -c`, and unzips the binary; a `supercronic` download stage that fetches `supercronic-linux-${TARGETARCH}` for `ARG SUPERCRONIC_VERSION=0.2.50` and checks it against `ARG SUPERCRONIC_SHA256_AMD64` / `_ARM64` (compute both with `sha256sum` and confirm against the SHA-1s in the release notes); the `base` stage itself: `apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends ca-certificates curl procps tini tzdata zstd`, clean apt lists, create user and group `65532` named `rclone-backup` (`--no-create-home --shell /usr/sbin/nologin`), copy rclone to `/usr/local/bin/rclone` and supercronic to `/usr/local/bin/supercronic`, copy `lib/` to `/usr/local/lib/rclone-backup/`, `ENV RCLONE_CACHE_DIR=/tmp/rclone-cache`, `USER 65532:65532`, `ENTRYPOINT ["/usr/bin/tini", "--"]`. Each version `ARG` carries a `# renovate:` comment (`datasource=github-releases depName=rclone/rclone` and `depName=aptible/supercronic`), and `RCLONE_VERSION=1.75.2`.

- [ ] **Step 3: Write `test/lib.sh` and `test/base`.** `test/base IMAGE` checks, each with `check`, using `hardened_run`: "rclone is the official release" (`rclone version` first line is `rclone v1.75.2` with no `-DEV` suffix); "supercronic runs" (`supercronic -version`); "it runs as 65532" (`id -u` prints `65532`); "zone data is present" (`/usr/share/zoneinfo/Europe/London` exists); "procps is present" (`pgrep` and `pkill` resolve).

- [ ] **Step 4: Build and run.**
Run: `docker build --target base -t rclone-backup/base:test . && test/base rclone-backup/base:test && shellcheck lib/* test/*`
Expected: every line `ok - …`, shellcheck silent. Then break the pinned fingerprint in a scratch copy of the Dockerfile and confirm the build fails at the verification step.

- [ ] **Step 5: Commit** — `Add the shared base image with verified rclone`

---

### Task 2: The `files` image

**Files:**
- Create: `jobs/files`, `test/files`
- Modify: `Dockerfile` (add `target files`), `README.md` (files section)

**Interfaces:**
- Consumes: `log.sh` (Task 1). Until Task 3 lands, `jobs/files` validates its own settings inline; Task 3 moves that into `lib/settings.sh`.
- Produces: `/usr/local/bin/backup` in the `files` image, which also accepts `--check` (validate settings, print nothing on success, exit 0) — every job script supports `--check` from Task 3 on.

- [ ] **Step 1: Write `jobs/files`.** Port `../docker-rclone-sync/bin/sync`'s behaviour without its root check or lock (the lock arrives in Task 3): require `BACKUP_SOURCE` and `BACKUP_TARGET`; each must be `remote:path` or an absolute path (the `${LOCATION%%/*}` case from the reference); log `syncing <source> to <target>`; `rclone sync --stats-log-level NOTICE "${BACKUP_SOURCE}" "${BACKUP_TARGET}"`; log completion. `files` stage: `FROM base AS files`, copy `jobs/files` to `/usr/local/bin/backup`, labels (description "Scheduled rclone mirror of a folder or remote into a versioned bucket"), `CMD ["/usr/local/bin/start"]` (added once `start` exists in Task 3; for now omit `CMD`).

- [ ] **Step 2: Write `test/files IMAGE`.** Run as `--user 1000:1000` with a host temp directory mounted at `/source` and another at `/target`: "a sync mirrors the source and deletes what the source lacks"; "a relative target is refused" (exit non-zero, message names the value); "RCLONE_MAX_DELETE caps deletions" (`RCLONE_MAX_DELETE=0` with an extra file at the target: exit non-zero and the file still there); "the run logs a deletion summary" (output contains `Deleted:`).

- [ ] **Step 3: Write the README's files section**: what it does, the empty-source warning and `RCLONE_MAX_DELETE` (port the reference README's wording), running as the folder owner's uid, and root mode with `cap_add: [DAC_READ_SEARCH]` as the fallback.

- [ ] **Step 4: Run** `docker build --target files -t rclone-backup/files:test . && test/files rclone-backup/files:test && shellcheck jobs/files test/files` — expected all `ok`.

- [ ] **Step 5: Commit** — `Add the files image`

---

### Task 3: Settings validation, the run lock and the scheduler

**Files:**
- Create: `lib/settings.sh`, `lib/job.sh` (lock part only), `bin/start`, `test/shared`
- Modify: `Dockerfile` (copy `bin/start` into `base`; `CMD ["/usr/local/bin/start"]` on `files`), `jobs/files` (use the helpers, take the lock, support `--check`), `README.md` (shared settings, schedule)

**Interfaces:**
- Produces in `lib/settings.sh`:
  - `require_settings NAME...` — `fatal "'NAME' is not set"` for the first empty one.
  - `require_location NAME` — the named variable must be `remote:path` or an absolute path.
  - `require_object_name NAME` — the named variable must not contain `/` or start with `.`.
  - `refuse_unknown_settings KNOWN_NAME...` — collects every environment variable whose name starts `BACKUP_`, `MONITOR_`, `DATABASE_` or `SQLITE_` and isn't in the list or in the shared list (`BACKUP_SCHEDULE BACKUP_TARGET MONITOR_START_URL MONITOR_SUCCESS_URL MONITOR_FAILURE_URL`); `fatal "unknown settings: A, B"` naming all of them.
- Produces in `lib/job.sh`: `acquire_run_lock` — opens `/tmp/rclone-backup.lock` on fd 9 and `flock -x -n 9`, else `fatal "another backup is already running"`.
- Produces: every job script's contract — `backup --check` validates settings only (exit 0 silently, or `fatal`); `backup` validates, takes the lock and runs.
- Produces `bin/start`: validates `BACKUP_SCHEDULE`, runs `/usr/local/bin/backup --check`, writes `/tmp/crontab` as `<schedule> /usr/local/bin/monitor /usr/local/bin/backup` (Task 4 supplies `monitor`; until then the crontab runs `/usr/local/bin/backup` directly), warns when `MONITOR_SUCCESS_URL` is unset, then supervises `supercronic -passthrough-logs /tmp/crontab`.

- [ ] **Step 1: Write `lib/settings.sh` and wire `jobs/files` to it** (`refuse_unknown_settings BACKUP_SOURCE`, `require_settings BACKUP_SOURCE BACKUP_TARGET`, `require_location` for both, `--check` exits after validation, then `acquire_run_lock`).

- [ ] **Step 2: Write `bin/start`.** Schedule validation, in order: `disabled` means no crontab job; otherwise refuse any character outside `0-9 A-Z a-z * / , ? @ - space tab` and any newline (a `#` would comment out the command, which `supercronic -test` accepts), then write the crontab and refuse it unless `supercronic -test /tmp/crontab` succeeds. Fatal message: `"BACKUP_SCHEDULE must be a cron schedule (e.g. '0 0 * * *'), a macro such as '@daily', or 'disabled', not '<value>'"`. Then `backup --check` (its own `fatal` stops start). Warning text: `"MONITOR_SUCCESS_URL is not set, so a run that fails or never happens raises no alert"`. Supervision: start supercronic in the background (with `disabled`, keep the container alive the same way — an empty crontab, verified to keep supercronic running, or a `sleep` child); on TERM or INT, `stop_gracefully`: signal supercronic with TERM, then send TERM to the process group of every running `/usr/local/bin/monitor` (found with `pgrep -f`, group from `ps -o pgid=`), wait for those processes to exit, and `exit 143`. Port the reference's comments about why (crond/supercronic start jobs in their own process group and don't signal them).

- [ ] **Step 3: Write `test/shared IMAGE`** (the files image; every container hardened, `--user 1000:1000`): "a valid schedule is accepted" (`0 3 * * *`, `@daily`, `*/15 * * * *`: the container is still running after 2 s); "an invalid schedule stops the container with exit 1" (`"0 3 * * *"` with literal quotes, `0 3 * *`, `0 3 * * * # nightly`, `@reboot`, a value containing a newline — each: `timeout 10 docker run …` exits 1 and the output contains `BACKUP_SCHEDULE must be`); "a disabled schedule keeps running with nothing scheduled"; "an unknown setting stops the container" (`BACKUP_SOURSE=/x` → exit 1, output names `BACKUP_SOURSE`); "a missing required setting stops the container at start-up, not at the first run"; "start warns without a success URL"; "a second run is refused while one is running" (two `backup` runs in one container with `RCLONE_BWLIMIT=1M` and a 20 MB source).

- [ ] **Step 4: Run** `docker build --target files -t rclone-backup/files:test . && test/files rclone-backup/files:test && test/shared rclone-backup/files:test && shellcheck bin/* lib/* jobs/* test/*` — expected all `ok`.

- [ ] **Step 5: Commit** — `Validate settings and supervise supercronic at start`

---

### Task 4: The monitor wrapper, scheduled runs and clean stops

**Files:**
- Create: `bin/monitor` (port `../docker-rclone-sync/bin/monitor`)
- Modify: `bin/start` (crontab runs `/usr/local/bin/monitor /usr/local/bin/backup`), `Dockerfile` (copy `bin/monitor` into `base`), `test/lib.sh` (fake monitor), `test/shared`, `README.md` (monitoring and stopping sections, ported from the reference README)

**Interfaces:**
- Produces `monitor COMMAND [ARGUMENT...]`: exactly the reference's behaviour (start/success/failure pings, `--fail --silent --show-error --max-time 10 --retry 5 --retry-connrefused`, URL via `--config -`, failure `POST` body = last 100000 bytes of the log with `,key=value` redaction, exit status preserved), plus: it traps TERM with a handler that doesn't exit, so a stop signal sent to its process group interrupts the job but the wrapper still reports.
- Produces in `test/lib.sh`: `start_fake_monitor NETWORK` — runs a digest-pinned `alpine` container (image listed in `test/servers`) named `fake-monitor-$$` on a user-defined network, answering every request with 200 and appending it to `/tmp/requests` (the reference's `nc` loop); `monitor_requests` prints them (`docker exec … cat /tmp/requests`); cleanup on exit. The production images carry no `nc`.

- [ ] **Step 1: Port `bin/monitor` and wire it into the crontab.**

- [ ] **Step 2: Extend `test/shared`** with the reference's monitor and stop tests, adapted: "the monitor hears the start and success of a passing run"; "a failing run keeps its exit status and sends a redacted log" (no `TOPSECRET` in the requests; `secret_access_key=REDACTED` present); "a scheduled run reports its failure" (schedule `* * * * * * *` — supercronic's per-second form, since it has no `@reboot` — with `RCLONE_MAX_DELETE=0` and an extra target file: a `POST /fail` arrives and the file survives); "docker stop lets a scheduled sync clean up and report its failure" (per-second schedule, `RCLONE_BWLIMIT=1M`, 20 MB source: after a `.partial` file appears, `docker stop --time 30` → exit code 143, a `POST /fail`, no `.partial` left); "a monitor URL never appears in process arguments".

- [ ] **Step 3: Run** the Task 3 command again plus the new checks — expected all `ok`. Then revert the TERM trap in a scratch build and confirm the stop test fails.

- [ ] **Step 4: Commit** — `Report every run to a heartbeat monitor`

---

### Task 5: Staging and upload helpers, and the `sqlite` image

**Files:**
- Modify: `lib/job.sh` (staging and upload), `Dockerfile` (`target sqlite`: `apt-get install sqlite3`), `README.md` (sqlite section: run as the application's uid, the directory can't be mounted read-only, root mode with `cap_add: [DAC_OVERRIDE, CHOWN]` and why never one without the other, and the restore command)
- Create: `jobs/sqlite`, `test/sqlite`

**Interfaces:**
- Produces in `lib/job.sh`:
  - `open_staging_directory` — `mktemp -d "${BACKUP_STAGING_PATH:-/tmp}/rclone-backup.XXXXXX"` into `STAGING_DIRECTORY`; an EXIT trap removes it; a TERM trap runs `exit 143` so the EXIT trap still fires on a stop.
  - `upload_staged_file STAGED_PATH OBJECT_NAME` — `rclone copyto [--checksum] STAGED_PATH "${BACKUP_TARGET%/}/${OBJECT_NAME}"`, passing `--checksum` only when `rclone backend features "${BACKUP_TARGET}"` reports a non-empty `Hashes` list; logs which it did.
- Consumes: `acquire_run_lock`, settings helpers (Task 3).

- [ ] **Step 1: Write the helpers and `jobs/sqlite`.** Settings: `SQLITE_DATABASE` (absolute path), `BACKUP_TARGET`, `BACKUP_STAGING_PATH`. Refuse a path that is, or lies under, a symlink: `realpath "${SQLITE_DATABASE}"` must equal the configured path. Snapshot: `sqlite3 "file:${SQLITE_DATABASE}?mode=rw" ".timeout 30000" "VACUUM INTO '<staged>'"`. Check: `PRAGMA integrity_check` on the snapshot must print exactly `ok`. Compress: `zstd -q --rm` then `zstd -q --test`. Upload as `<basename>.zst`. The spec requires an unchanged database to add no version; if `VACUUM INTO` output proves not to be byte-stable for an unchanged database, stop and report rather than working around it.

- [ ] **Step 2: Write `test/sqlite IMAGE`** (hardened, `--user 1000:1000`, database volume and target directory from the host): "a snapshot of a WAL database being written restores and passes the integrity check" (a writer container inserting every 20 ms as uid 1000 during the backup; restore = `zstd -d` then `sqlite3 … 'PRAGMA integrity_check'` and a row count > 0); "a cleanly stopped WAL database with no `-shm` is backed up" (directory writable); "a missing database fails, uploads nothing and creates no file"; "a symlinked database path is refused"; "an unchanged database is not uploaded again" (the target object's modification time and inode are unchanged after a second run); "a crypt target is uploaded every run" (a `crypt` remote over a local path via `RCLONE_CONFIG_SECRET_*`, password from `rclone obscure`: the second run of an unchanged database still transfers); "a trailing slash on BACKUP_TARGET is ignored" (object lands at `<target>/app.db.zst`, nothing at `<target>//`).

- [ ] **Step 3: Run** `docker build --target sqlite -t rclone-backup/sqlite:test . && test/sqlite rclone-backup/sqlite:test && shellcheck lib/* jobs/* test/*` — expected all `ok`.

- [ ] **Step 4: Commit** — `Add the sqlite image`

---

### Task 6: The `postgres` image

**Files:**
- Create: `jobs/postgres`, `test/postgres`
- Modify: `Dockerfile` (`target postgres`), `test/servers` (`postgres:15`, `:16`, `:17`, `:18`, and `postgres:14` for the refusal test, each `@sha256:` pinned), `lib/settings.sh` (add `load_database_password` and `require_database_tls`), `README.md` (postgres section: settings, account grants, restore command)

**Interfaces:**
- Produces in `lib/settings.sh`: `load_database_password` — exactly one of `DATABASE_PASSWORD` and `DATABASE_PASSWORD_FILE` must be set; a file must be readable; the value ends up in `DATABASE_PASSWORD` (not exported). `require_database_tls` — `DATABASE_TLS` defaults to `disabled`, must be `disabled`, `required` or `verify`; `DATABASE_TLS_CA_PATH` is refused unless `DATABASE_TLS=verify`.
- Consumes: Task 3 and Task 5 helpers.

- [ ] **Step 1: Write the `postgres` stage**: from `base`, add PGDG's apt source and key (`https://www.postgresql.org/media/keys/ACCC4CF8.asc` into `/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc`, `deb [signed-by=…] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main`; `ca-certificates` is already installed, which PGDG's HTTPS needs) and install `postgresql-client-15` to `-18`; run every `/usr/lib/postgresql/*/bin/{pg_dump,pg_restore,psql}` with `LD_BIND_NOW=1 … --version` in the build.

- [ ] **Step 2: Write `jobs/postgres`.** Settings: the `DATABASE_*` set (`refuse_unknown_settings` with all of them plus `BACKUP_STAGING_PATH`), `require_object_name DATABASE_NAME`. Environment for the tools only: `PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE`, `PGCONNECT_TIMEOUT=10`, `PGSSLMODE` (`disable`/`require`/`verify-full`), `PGSSLROOTCERT` for `verify`. Major: `/usr/lib/postgresql/18/bin/psql -XAtc 'SHOW server_version_num'`, divided by 10000; refuse a major without `/usr/lib/postgresql/<major>/bin/pg_dump` with `"PostgreSQL <major> isn't supported; this image has clients for 15 to 18"`. Dump with that major's `pg_dump --format=custom --lock-wait-timeout=<value> --file=<staged>` (the spec leaves the value to you: pick one long enough for a busy table, short enough that a stuck migration fails the run, and say why in a comment); check with the same major's `pg_restore --list <staged> > /dev/null`; upload `<DATABASE_NAME>.dump`.

- [ ] **Step 3: Write `test/postgres IMAGE`**, for each server in `test/servers` (15 to 18), on a user-defined network: seed a table with rows, a sequence, an enum and a large object; back up as a backup role with `pg_read_all_data`, `BYPASSRLS` and `SELECT` on the large object; restore with the server's own `pg_restore` into a new database; the row count, sequence value and large object match. Plus, once: "PostgreSQL 14 is refused naming its version, and nothing is uploaded"; "a password with `p@ss w'rd\"$;` works, and appears in no process arguments"; "DATABASE_PASSWORD_FILE works"; "setting both password forms stops the container"; "a database name containing `/`, or starting with `.`, is refused at start"; "an unreachable host fails within 60 s and uploads nothing"; "DATABASE_TLS=required against a server without TLS fails clearly and uploads nothing" (the official image has TLS off); "a dump larger than the staging space fails, uploads nothing and leaves no staged file" (`--tmpfs /tmp:…,size=1m` with a 5 MB table).

- [ ] **Step 4: Run** `docker build --target postgres -t rclone-backup/postgres:test . && test/postgres rclone-backup/postgres:test` — expected all `ok` for every server.

- [ ] **Step 5: Commit** — `Add the postgres image`

---

### Task 7: The `mariadb` image

**Files:**
- Create: `jobs/mariadb`, `test/mariadb`
- Modify: `Dockerfile` (`target mariadb`: `apt-get install mariadb-client`, then remove the `/usr/bin/mysql` and `/usr/bin/mysqldump` links), `test/servers` (`mariadb:10.11`, `:11.4`, `:11.8`, digest-pinned), `README.md` (mariadb section: grants incl. the silent-routines warning, schema-migration caution, restore command)

**Interfaces:**
- Consumes: Task 3, 5 and 6 helpers.
- Produces in `lib/job.sh`: `fail_on_error_lines STDERR_PATH TOOL_NAME` — logs every captured stderr line as a warning, and `fatal`s if any contains `error` (case-insensitive). Task 8 reuses it.

- [ ] **Step 1: Write `jobs/mariadb`.** `MYSQL_PWD` carries the password. TLS: `disabled` → `--skip-ssl`; `required` → `--ssl --skip-ssl-verify-server-cert`; `verify` → `--ssl --ssl-verify-server-cert` (+ `--ssl-ca`). Flags, verbatim from the spec: `--single-transaction --quick --routines --events --triggers --no-tablespaces --skip-dump-date --default-character-set=utf8mb4 --dump-history`, plus `--connect-timeout=10`. Pipeline under `pipefail`: `mariadb-dump … "${DATABASE_NAME}" 2> <stderr file> | zstd -q -o <staged>`; then `fail_on_error_lines`; `zstd -q --test`; upload `<DATABASE_NAME>.sql.zst`.

- [ ] **Step 2: Write `test/mariadb IMAGE`**, for each server: seed a table, a stored procedure, a trigger and a system-versioned table with history; grant the spec's minimal account plus the version's routine privilege; back up; restore with the server's own `mariadb` client into a new database; table checksums match, the procedure exists, the versioned table's history row count matches. Plus once: "an unchanged database is not uploaded again"; "a failing dump uploads nothing" (wrong database name); "DATABASE_TLS=required works against 11.8" (11.4 and later generate a certificate; confirm this holds for the pinned image) and "fails clearly against a 10.11 server without TLS"; the shell-hostile password, password file and unreachable host checks from Task 6.

- [ ] **Step 3: Run** `docker build --target mariadb -t rclone-backup/mariadb:test . && test/mariadb rclone-backup/mariadb:test` — expected all `ok`.

- [ ] **Step 4: Commit** — `Add the mariadb image`

---

### Task 8: The `mysql` image

**Files:**
- Create: `jobs/mysql`, `test/mysql`
- Modify: `Dockerfile` (`FROM mysql:9.7@sha256:<digest> AS mysql`; `target mysql`: install `libssl3t64 zlib1g libstdc++6`, copy `/usr/bin/mysqldump` to `/opt/mysql/bin/mysqldump`, run it with `LD_BIND_NOW=1 … --version`), `test/servers` (`mysql:8.0`, `:8.4`, `:9.7`), `README.md` (mysql section: `caching_sha2_password`, grants, silent-routines warning, restore command)

**Interfaces:**
- Consumes: Task 3, 5, 6 and 7 helpers (`fail_on_error_lines`).

- [ ] **Step 1: Write `jobs/mysql`.** Always `/opt/mysql/bin/mysqldump` by absolute path. TLS: `--ssl-mode=DISABLED`, `REQUIRED`, `VERIFY_IDENTITY` (+ `--ssl-ca`). Flags verbatim: `--single-transaction --quick --routines --events --triggers --no-tablespaces --skip-dump-date --default-character-set=utf8mb4 --set-gtid-purged=OFF --skip-masking-policies`, plus `--connect-timeout=10`. Same pipeline, checks and upload as Task 7, object `<DATABASE_NAME>.sql.zst`.

- [ ] **Step 2: Write `test/mysql IMAGE`**, for each server: as Task 7's round trip (without the versioned table), with a `caching_sha2_password` account holding `SHOW_ROUTINE`. Plus once: "a `mysql_native_password` account fails with a clear error and uploads nothing" (on 8.0 or 8.4, where it can still be created); "an unchanged database is not uploaded again"; "DATABASE_TLS=required works" (MySQL servers generate a certificate); the shell-hostile password and unreachable host checks.

- [ ] **Step 3: Run** `docker build --target mysql -t rclone-backup/mysql:test . && test/mysql rclone-backup/mysql:test` — expected all `ok`, on both an amd64 and an arm64 machine (the copied binary is per architecture).

- [ ] **Step 4: Commit** — `Add the mysql image`

---

### Task 9: CI — lint, build and test on every change

**Files:**
- Create: `.github/workflows/build.yml` (reusable, `workflow_call`), `.github/workflows/ci.yml`

**Interfaces:**
- Produces `build.yml` inputs: `ref` (string, what to check out), `push` (boolean). With `push: true` it uploads one digest artifact per image and platform, named `digest-<image>-<platform slug>`. Outputs nothing else.

- [ ] **Step 1: Write `build.yml`.** Jobs: `lint` (shellcheck via the pinned `koalaman/shellcheck:v0.11.0@sha256:…` image over `bin/* lib/* jobs/* test/* .github/scripts/*`, as in the reference; plus `actionlint`); `build` with matrix `image` × `platform` (`linux/amd64` on `ubuntu-24.04`, `linux/arm64` on `ubuntu-24.04-arm`, native, no QEMU): check out `ref`, Buildx with the GitHub Actions cache, build `--target <image> --load` as `rclone-backup/<image>:test`, run `test/<image>` (and `test/shared` and `test/base` in the `files` job), then — only when `push` — build again from the same cache with `labels`, `sbom: true`, `provenance: mode=max` and `push-by-digest=true` to `ghcr.io/nialtoservices/rclone-backup/<image>`, and upload the digest. Comment the constraint that the pushed build must share every input with the tested one. All actions pinned by SHA with a version comment (current SHAs as in the reference's workflow).

- [ ] **Step 2: Write `ci.yml`**: on `pull_request` and `push` to `main`, `permissions: contents: read`, calls `build.yml` with `push: false`. Name the workflow `CI` (Task 11's `workflow_run` refers to it).

- [ ] **Step 3: Verify** with `actionlint`, then push to a scratch branch of the GitHub repository once the owner has created it (Rollout step 1) and confirm all ten build jobs pass. If the repository doesn't exist yet, record that the first CI run is still owed and continue.

- [ ] **Step 4: Commit** — `Lint, build and test every image in CI`

---

### Task 10: Publishing and the weekly rebuild

**Files:**
- Create: `.github/scripts/resolve-release`, `.github/workflows/publish.yml`, `test/github-scripts` (resolve-release part)
- Modify: `README.md` (images and tags section, weekly rebuild)

**Interfaces:**
- Produces `resolve-release`: reads release tags on stdin (one per line, any order, non-`vX.Y.Z` lines ignored), takes `REF_TYPE` and `REF_NAME` from the environment, prints `release=…`, `newest=…`, `newest-in-major=…`, `newest-in-minor=…` lines. Logic exactly the reference workflow's `resolve` step, moved into a file so it can be tested.

- [ ] **Step 1: Write `resolve-release` and its tests.** `test/github-scripts` runs the seven tag histories used when the reference was verified (schedule with newest v1.1.0; push v1.0.2 after v1.1.0; push v2.0.0; dispatch v1.1.0 after v2.0.0; v10 sorting; v1.9.0 after v1.10.0; no releases → error) and asserts each output line.

- [ ] **Step 2: Write `publish.yml`**: triggers `release: published`, `workflow_dispatch`, `schedule: '23 3 * * 1'`; `concurrency` as in the reference; `resolve` job (feeds `gh api repos/$GITHUB_REPOSITORY/tags --paginate --jq '.[].name'` into `resolve-release`); `build` calls `build.yml` with `ref` = the resolved release and `push: true` (`permissions: packages: write`); `merge` job with matrix `image`, downloading `digest-<image>-*`, creating the manifest list with `docker buildx imagetools create`, tags from `metadata-action` exactly as the reference (`{{version}}` always; `{{major}}.{{minor}}`, `{{major}}`, `latest` gated on the resolved flags; `flavor: latest=false`); final step pinging the `REBUILD_MONITOR_URL` secret on scheduled runs, as in the reference.

- [ ] **Step 3: Verify** with `actionlint` and `test/github-scripts`.

- [ ] **Step 4: Commit** — `Publish releases and rebuild the newest weekly`

---

### Task 11: Release drafting, automatic patch releases and Renovate

**Files:**
- Create: `.github/release-drafter.yml`, `.github/workflows/release-drafter.yml`, `.github/scripts/auto-release-decision`, `.github/workflows/auto-release.yml`, `renovate.json`
- Modify: `test/github-scripts` (decision tests), `README.md` (maintenance: releases, Renovate, the November PostgreSQL release, supercronic bumps, rollout steps for the owner), `CLAUDE.md` if anything non-derivable came up

**Interfaces:**
- Produces `auto-release-decision`: reads one line per change merged since the last release, `<author> <comma-separated labels>` (a direct push to `main` appears as `direct -`), prints `publish` or `wait`. `publish` only when every line's author is `renovate[bot]`, every label set is a subset of `{patch, ci}`, and at least one line has `patch`.

- [ ] **Step 1: Write the decision script and its tests**: all-patch Renovate → `publish`; patch plus `ci` → `publish`; only `ci` → `wait`; a `minor` among them → `wait`; any non-Renovate author → `wait`; a direct push → `wait`; no lines → `wait`.

- [ ] **Step 2: Write release-drafter's config and workflow**: tag and name `v$RESOLVED_VERSION`; `version-resolver` with `major`, `minor` and `patch` labels and `default: patch`; `exclude-labels: [ci]`; runs on `push` to `main` with `contents: write`.

- [ ] **Step 3: Write `auto-release.yml`**: on `workflow_run` of `CI`, `completed`, for `main`, when the conclusion is `success`; lists commits since the newest published release, finds each commit's pull request and labels with `gh api repos/{repo}/commits/{sha}/pulls`, feeds `auto-release-decision`; on `publish`, publishes the current draft (`gh release edit <draft> --draft=false`) and then runs `gh workflow run publish.yml --ref <tag>` (a release published with `GITHUB_TOKEN` triggers no `release` event; `workflow_dispatch` is the documented exception). Permissions: `contents: write`, `actions: write`, `pull-requests: read`.

- [ ] **Step 4: Write `renovate.json`**: extends `config:recommended`; dependency dashboard on; labels: `patch` for `patch`, `digest`, `pin` and `pinDigest`, `minor` for `minor`, `major` for `major`, and `ci` for GitHub Actions and for `test/servers`; `automerge: true` for patch, digest, pin and pinDigest except `aptible/supercronic` (its checksums are edited by hand); `dependencyDashboardApproval: true` for majors; custom regex managers for the `# renovate:` comments in the Dockerfile and for the image lines in `test/servers`. Validate with `npx --yes --package renovate -- renovate-config-validator renovate.json`.

- [ ] **Step 5: Run** `test/github-scripts && actionlint && shellcheck .github/scripts/*` — expected all `ok`.

- [ ] **Step 6: Commit** — `Draft releases and publish routine patches automatically`

---

### Task 12: Finish the README and verify end to end

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Complete the README** to the spec's Documentation section: intro and the versioned-bucket requirement (with the lifecycle-rule warning); the hardening baseline as the first example; configuring rclone through `RCLONE_CONFIG_<REMOTE>_<OPTION>` or a read-only config file, preferring that to inline credentials, and `RCLONE_S3_NO_CHECK_BUCKET=true` for keys limited to one bucket; shared settings and the monitor table (Healthchecks, Uptime Kuma, StatusCake); each image's section with a complete Compose example; restore commands; images and tags; maintenance; licences (each bundled component and where its source is). British English; no em dashes are needed but the README may use them (it is technical documentation).

- [ ] **Step 2: Verify everything locally**: build all five targets, run `test/base`, `test/shared`, and every image suite, `test/github-scripts`, shellcheck and actionlint. Expected: all `ok`. Confirm the tree is clean.

- [ ] **Step 3: Commit** — `Document every image, its settings and restores`

---

## Rollout (the owner's actions after the plan is done)

1. Create `NialtoServices/docker-rclone-backup` on GitHub and push; confirm CI passes on both platforms.
2. Install the Renovate app; protect `main` with the CI checks required (Renovate's automerge depends on it).
3. Optionally add the `REBUILD_MONITOR_URL` secret.
4. Publish the first release from the draft.
5. Move each deployment over with a heartbeat monitor per container; then delete the old repositories, and their GHCR packages once nothing pulls them.
