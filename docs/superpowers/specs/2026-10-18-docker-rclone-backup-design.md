# docker-rclone-backup — design

Status: draft for approval, 2026-10-18.

## Intent

One repository replaces five: `docker-rclone-sync`, `docker-mariadb-backup`, `docker-mysql-backup`
and `docker-postgres-backup`, plus a new SQLite backup that none of them covered. (The fifth,
`docker-backup`, and the unpublished `docker-restic-backup` are retired without a replacement here:
restic and multi-destination backups are the job of tidweard, the owner's separate Go project.)

The old repositories are a reference pool only. This is a new project with no obligation to their
image names, tags, settings or behaviour; every existing deployment will be reconfigured by hand as
it moves over, and the old repositories will then be deleted.

Why now:

- **Maintenance is multiplied.** The same ~90-line backup script, scheduler start-up, failure
  notifier, prune script and workflow exist in near-identical copies, and every fix has to be
  ported to each.
- **The weekly rebuilds have stopped.** GitHub disables a scheduled workflow after 60 days without
  repository activity, and these repositories go months without a commit. Three of the four
  published ones are disabled today.
- **Several images are stranded on end-of-life Alpine releases.** Alpine drops old database
  versions, so PostgreSQL 14 and MariaDB 10.11 are built on Alpine 3.20 (end of life since April
  2026) and PostgreSQL 15 on 3.22, where the weekly rebuild can no longer deliver fixes.

What the owner wants, in their words: **simple and reliable.**

## Goals

- **One repository, five images**, published to GHCR, maintained in one place.
- **Each image does one thing on a schedule**: produces one object (a database dump, a SQLite
  snapshot, or a mirrored folder) and puts it in a bucket with versioning enabled, using rclone.
  History lives in the bucket's versioning.
- **Minimal**: shell scripts only. No restic, no compiled program of its own.
- **Reliable**: failures and missed runs are always noticed; dumps are checked before they're
  uploaded; nothing is published untested.
- **Hardened**: non-root by default, read-only root filesystem, no capabilities.
- **Low maintenance**: Renovate keeps dependencies current; routine patches merge and publish
  themselves once tests pass; every other release is a single click.

## Non-goals

- **Restores in code.** The README documents one restore command per image instead.
- **Buckets without versioning.** The old database images' timestamped filenames and pruning
  (`BACKUP_FILENAME_TIMESTAMPED`, `BACKUP_MAX_VERSIONS`, `bin/prune`) are not carried over.
- **More than one thing per container.** One database, one SQLite file or one folder; more means
  more containers. No auto-discovery of databases.
- **Compatibility with the old images**: names, tags, settings or behaviour.
- **Anything restic-shaped**: snapshots, deduplication, several destinations, manifests.

## Anti-goals

- **Becoming a second tidweard.** When a feature needs real logic (manifests, restore planning,
  verification by test restore, capability checking), it belongs in tidweard, not here. Each
  image's job script should stay short enough to read in one sitting.
- **A silent failure.** A backup that didn't run, ran partially, or produced an unrestorable dump
  must never look the same as one that worked.

## Constraints

- **Shell scripts only**, linted by shellcheck in CI.
- **Built on `debian:trixie-slim`.** Alpine can't supply Oracle's MySQL client or PostgreSQL clients
  15 to 18 on one release (tidweard's image design and spike 5 settled this).
- **Platforms**: `linux/amd64` and `linux/arm64`.
- **Must run under the hardening baseline** (below) with no exceptions for the database images.
- **Dumps stay standard**: restorable with stock `pg_restore`, `mysql`/`mariadb` and `sqlite3` on any
  machine, without this image.
- **British English** in all prose, including the README and commit messages; the owner's
  `~/.claude/CLAUDE.md` conventions apply to the code (naming, comments, guard clauses, commit
  style). A project `CLAUDE.md` is created with the five project-memory rules copied in.

## Names

- **Repository**: `NialtoServices/docker-rclone-backup`.
- **Images**: `ghcr.io/nialtoservices/rclone-backup/<name>`, where `<name>` is `postgres`,
  `mariadb`, `mysql`, `sqlite` or `files`. Grouping under `rclone-backup/` keeps clear of the old
  images' names (`rclone-sync`, `postgres-backup`, `mariadb-backup`, `mysql-backup`, `backup`), so
  no existing deployment can pull a new image by accident.

## The images

| Image | Backs up | Tool | Object written to the target |
|---|---|---|---|
| `postgres` | One PostgreSQL database | `pg_dump` of the server's own major | `<database>.dump` (custom format) |
| `mariadb` | One MariaDB database | `mariadb-dump` (Debian's, 11.8) | `<database>.sql.zst` |
| `mysql` | One MySQL database | Oracle's `mysqldump` (9.7 LTS) | `<database>.sql.zst` |
| `sqlite` | One SQLite database file | `sqlite3` (Debian's) | `<file name>.zst` (e.g. `app.db.zst`) |
| `files` | One directory, or one rclone remote path | `rclone sync` | A mirror of the source under the target |

### Supported database versions (from tidweard's spikes 1 and 2)

| Family | Servers | Client |
|---|---|---|
| PostgreSQL | 15, 16, 17, 18 | 14 reaches end of life on 12 November 2026 and nothing the owner runs uses it, so it's left out from the start. Every major's client from PGDG, side by side under `/usr/lib/postgresql/<major>/bin`. Before each run the server's major is read (`SHOW server_version_num`) and the matching `pg_dump` used. A server with no matching client, including a newer one, is refused with a message naming its version. |
| MariaDB | 10.11, 11.4, 11.8 and later | Debian trixie's client (11.8). |
| MySQL | 8.0, 8.4, 9.x | Oracle's client from the newest LTS (9.7), copied from the official `mysql:9.7` image into `/opt/mysql/bin` and always called by absolute path. Bumped only to the next LTS. |

Neither MySQL family's client stands in for the other's, and `pg_restore` of one major can't
reliably restore another's dump (tidweard spikes 1 and 2), which is why the clients are chosen as
above.

**PostgreSQL has a yearly rhythm**, and it's the only family where versions age out of the build:
a new major arrives around September and the oldest reaches end of life in November, after which
PGDG moves its client to an archive repository and installing it would fail. So each November a
major release adds the new major's client and drops the end-of-life one; Renovate's Dependency
Dashboard prompts the first half and the README's maintenance section records the second. If it's
missed, the weekly rebuild fails safely: nothing is pushed, existing images keep working, and the
rebuild monitor and GitHub's failure email say so. MariaDB and MySQL each use one client, so their
end-of-life dates don't affect the build.

Known requirements the README states (from tidweard's `sources.md`):

- **PostgreSQL account**: `pg_read_all_data`, `BYPASSRLS`, and `SELECT` on each large object.
- **MySQL and MariaDB account**: `SELECT, SHOW VIEW, TRIGGER, EVENT` on the database, plus a routine
  privilege (`SHOW_ROUTINE` on MySQL 8.0.20+, `SHOW CREATE ROUTINE` on MariaDB 11.3+, `SELECT` on
  `mysql.proc` on MariaDB 10.11). **Without the routine privilege the dump silently omits routines**;
  the README says so prominently. (tidweard checks grants at run time; here it's documented only.)
- **MySQL accounts use `caching_sha2_password`**; the 9.7 client can't log in with
  `mysql_native_password`.
- **Avoid schema migrations during a MySQL or MariaDB backup**: `--single-transaction` doesn't
  isolate a dump from them.

### Dump flags (from tidweard's `sources.md`, unchanged)

- **MySQL**: `--single-transaction --quick --routines --events --triggers --no-tablespaces
  --skip-dump-date --default-character-set=utf8mb4 --set-gtid-purged=OFF --skip-masking-policies`.
- **MariaDB**: the same minus the two MySQL-only flags, plus `--dump-history` (without it, history
  in system-versioned tables is silently dropped).
- **PostgreSQL**: `--format=custom` and `--lock-wait-timeout`. Ownership and privileges stay in the
  dump; the restore decides.

`--skip-dump-date` makes an unchanged MySQL or MariaDB database produce identical bytes, and zstd's
output is deterministic, so an unchanged database adds no new version in the bucket. A PostgreSQL
custom-format archive records its creation time, so it always adds a version.

### SQLite (from tidweard's `sources.md` and spike 3)

- **Snapshot with `VACUUM INTO`** into the staging directory, opening the database read-write
  (`mode=rw`, so a missing file fails the run instead of creating an empty database) with a 30-second
  busy timeout. Never copy the file.
- **Check the snapshot** with `PRAGMA integrity_check`, refusing anything but `ok`.
- **The database's directory must be writable**: a cleanly stopped WAL database needs its `-wal` and
  `-shm` files created while the snapshot is open. The README says a SQLite volume can't be mounted
  read-only.
- **Refuse a database path that is, or lies under, a symlink**, so the file snapshotted is the one
  configured.
- The snapshot is compressed with zstd before upload. (My call: every version is stored in full in
  the bucket, and SQLite files compress well.)

### Files

What `docker-rclone-sync` does today: `rclone sync` of a source to the target, where the source is an
absolute path inside the container or an rclone remote path. Carried over from that repository:
refusing relative paths, the end-of-run transfer and deletion summary, and the README's warning that
an empty source empties the target (with `RCLONE_MAX_DELETE` as the guard).

## Shared behaviour (every image)

Carried over from `docker-rclone-sync` as it stands at commit `37d83c5`, where each piece is
implemented and tested:

- **Schedule**: a cron expression (five fields or an `@` macro) or `disabled`. Validated at start-up;
  an unparseable value stops the container with an error. Times follow `TZ` (`tzdata` installed).
- **One run at a time**: a second run while one is going is refused.
- **Heartbeat monitor**: optional `MONITOR_START_URL`, `MONITOR_SUCCESS_URL` and `MONITOR_FAILURE_URL`,
  requested at each run's start, success and failure. The failure request is a `POST` whose body is
  the run's last 100 kB of log, with option values in rclone connection strings redacted. Each
  request times out after 10 seconds and retries up to 5 times, including refused connections; a
  request that still fails is logged and never changes the run's result. The URL never appears in a
  process's arguments. Works with Healthchecks, Uptime Kuma push monitors and StatusCake push checks
  (the README's table from that repository carries over). A container started without
  `MONITOR_SUCCESS_URL` logs a warning at start-up.
- **Clean stop**: on `docker stop`, a running job's tool is signalled so it can clean up, the run is
  reported as failed, and the container exits with 143. The README recommends a 2-minute stop grace
  period so the report gets through.
- **Logging**: one line format, `<script> [<timestamp>] <LEVEL>: <message>`, from shared helpers.

New for this repository:

- **Stage, check, then upload.** A dump or snapshot is written to the staging directory, checked,
  and only then uploaded; never streamed into rclone, which would store a truncated dump as the
  newest version if the dump tool died part-way. The checks:
  - every image: the tool's exit status, including inside any pipeline into zstd;
  - MySQL and MariaDB: **any error line on stderr fails the run** (the 9.x `mysqldump` can print
    `mysqldump: Error: …` and still exit 0);
  - PostgreSQL: `pg_restore --list` reads the archive;
  - SQLite: `PRAGMA integrity_check` returns `ok`;
  - compressed files: `zstd --test`.
- **Uploads are compared by checksum** (`rclone copyto --checksum`), so an identical object isn't
  re-uploaded and adds no version. **A target that can't report a hash the staged file has** (a
  `crypt` remote, for one) **is always uploaded instead**: rclone would otherwise fall back to
  comparing sizes and skip a changed dump of the same size, which tidweard's spike 7 saw happen (my
  call). Such targets add a version every run.
- **Versioning on the target is documented, not checked.** Any rclone remote is accepted; the
  README states that history depends on the bucket's versioning and lifecycle rules, and warns that
  rules such as B2's "keep only the last version" make old versions vanish within a day (my call:
  a start-up check only exists for some backends).
- **The staging directory** defaults to `/tmp` (tmpfs under the hardening baseline) and is settable,
  so a large database's dumps can go on a volume. A staged file is deleted after each run.
- **The scheduler is supercronic**, not busybox crond: busybox crond won't run jobs as non-root (it
  starts and silently does nothing), and Debian's cron needs root and clears the environment.
  supercronic passes the environment through, logs to stdout, and waits for running jobs on SIGTERM
  without signalling them, which is why the clean-stop supervisor stays. The crontab is generated at
  start-up into `/tmp`.

## Configuration

One set of names shared by every image (my call):

| Setting | Images | Meaning |
|---|---|---|
| `BACKUP_SCHEDULE` | all | Cron schedule, or `disabled`. Default `0 0 * * *`. |
| `BACKUP_TARGET` | all | rclone remote path that receives the object (e.g. `b2:my-bucket/app`). |
| `BACKUP_STAGING_PATH` | database and SQLite images | Where dumps are staged. Default `/tmp`. |
| `TZ` | all | Time zone for the schedule and log timestamps. Default UTC. |
| `MONITOR_START_URL`, `MONITOR_SUCCESS_URL`, `MONITOR_FAILURE_URL` | all | As above. |
| `RCLONE_*` | all | Any rclone flag or remote definition, passed through to rclone (`RCLONE_CONFIG_<REMOTE>_<OPTION>` for remotes, `RCLONE_MAX_DELETE` and so on). |
| `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_NAME`, `DATABASE_TLS`, `DATABASE_TLS_CA_PATH` | `postgres`, `mariadb`, `mysql` | Connection. Port defaults to 5432 for PostgreSQL and 3306 otherwise. |
| `SQLITE_DATABASE` | `sqlite` | Absolute path to the database file. |
| `BACKUP_SOURCE` | `files` | Absolute path, or rclone remote path, to mirror. |

- **The three database images share one set of connection names** (my call), deliberately unlike
  the official database images' own variables (`POSTGRES_USER`, `MYSQL_PASSWORD`, `POSTGRES_DB`…).
  An env file shared with the database container then can't make the backup quietly connect as the
  application's or root's account instead of its dedicated backup role, and every database image
  reads the same way.
- **The password may instead be given as `DATABASE_PASSWORD_FILE`**, a path to a file holding it
  (Docker and Compose secrets), so it needn't sit in the container's environment (my call). It
  reaches the dump tools through their own environment variables (`PGPASSWORD`, `MYSQL_PWD`), never
  their arguments.
- **`DATABASE_TLS`** takes `disabled`, `required` or `verify` (with `DATABASE_TLS_CA_PATH` for a private CA), meaning
  the same for all three families. **Default `disabled`** (my call): these containers normally sit
  beside their database on a private Docker network, and MariaDB's 11.4+ client has no "preferred"
  mode, so a "preferred" default would need tidweard's server probe. Managed databases set
  `required` or `verify`.
- **rclone is configured through the environment or a read-only config file**; nothing needs to be
  written to it. The README notes `no_check_bucket = true` (or `RCLONE_S3_NO_CHECK_BUCKET=true`) for
  keys restricted to one bucket (tidweard spike 4).
- **Unknown or contradictory settings fail at start-up**, not at the first run. "Unknown" means a
  variable under this project's own prefixes (`BACKUP_`, `MONITOR_`, `DATABASE_`, `SQLITE_`) that
  the image doesn't read, such as a typo or another image's setting; anything else in the
  environment is ignored (my call).

## Hardening (from tidweard's `hardening.md`)

The baseline, in every README example:

```yaml
user: "1000:1000"          # files and sqlite: the owning application's uid:gid
read_only: true
cap_drop: [ALL]
security_opt: ["no-new-privileges:true"]
tmpfs:
  - /tmp:rw,nodev,noexec,nosuid,size=512m
```

- **The image's default user is non-root**: uid and gid `65532`, no shell login, no home directory.
- **Only `/tmp` (and the staging path, if moved) and the backed-up volumes are writable.**
  rclone's cache directory is set under `/tmp`.
- **Database images need no special access**: the tools connect over the network, so the default
  uid works.
- **`files` and `sqlite` run as the owning application's uid and gid** ("application mode"), which
  can read everything the application can and write a WAL database's `-shm`. The README shows how
  to find it (`docker exec <app> id`, or `stat` on the volume).
- **Root mode as a documented fallback** when sources have different owners, opening with its cost:
  `user: "0:0"` with `cap_add: [DAC_READ_SEARCH]` for `files`, or `[DAC_OVERRIDE, CHOWN]` for
  `sqlite` (never `DAC_OVERRIDE` without `CHOWN`, so SQLite's `-wal` and `-shm` keep the database's
  owner). Capabilities only take effect for root.

## Build and supply chain

- **One Dockerfile**: a shared base stage, plus one final stage per image (`--target <name>`).
- **Every build upgrades the installed packages** (`apt-get upgrade`), so a rebuild picks up Debian
  and PGDG fixes even when the pinned base digest hasn't moved.
- **The base**: `debian:trixie-slim`, `ca-certificates`, `tini`, `tzdata`, `curl`, `zstd`, the tools
  the scripts need (`flock`, `pgrep`/`pkill`), rclone, supercronic, and the shared scripts.
- **rclone is the official release zip** from downloads.rclone.org, pinned by version, never the
  `rclone/rclone` image (a separate build with no signature or provenance; tidweard's `image.md`).
  The build verifies the zip against the release's `SHA256SUMS` and that file's PGP signature
  against rclone's pinned signing key, so a version bump needs no checksum edits (my call; tidweard
  pins per-architecture checksums filled in by a workflow instead).
- **supercronic is its GitHub release binary**, pinned by version and verified against a pinned
  checksum or signature.
- **PostgreSQL clients from PGDG's apt repository**, Debian's MariaDB client and `sqlite3` from
  Debian, installed as packages (each image carries only its own client, so dropping Perl isn't worth
  tidweard's copying and `libpq5` pinning). **Oracle's client is copied** from `mysql:9.7`, pinned by
  digest, with the libraries it needs installed from Debian; the build runs each copied binary with
  `LD_BIND_NOW=1 … --version` so a missing symbol fails the build.
- **Each image ends `USER 65532:65532`** and `ENTRYPOINT ["/usr/bin/tini", "--"]`.
- **Labels and attestations**: OCI labels per image, an SBOM and `mode=max` provenance on every
  published image.
- **Licences**: Apache-2.0 for this project; the README names each bundled component's licence and
  where its source is. (Attaching GPL sources to releases, as tidweard plans, is out of scope for
  now.)

## CI, releases and updates

- **Every pull request and every push to `main`**: shellcheck, build all five images for both
  platforms on native runners (`ubuntu-24.04` and `ubuntu-24.04-arm`), and run the test suite
  against each.
- **The test suite** extends `docker-rclone-sync`'s `test/smoke`. It runs each image against real
  servers of every supported version (PostgreSQL 15 to 18, MariaDB 10.11, 11.4 and 11.8, MySQL 8.0,
  8.4 and 9.7), a SQLite database being written to while it's snapshotted, and a stand-in for a
  versioned bucket. It covers at least what the old repository's suite covered, plus: each dump
  restores with stock tools and matches the source; a failed dump never uploads; an unchanged MySQL,
  MariaDB or SQLite source adds no new version; the hardening baseline holds (each test runs with
  it).
- **Releases use release-drafter**: a draft GitHub release is kept up to date as pull requests
  merge, its version worked out from labels (`major`, `minor`, `patch`; Renovate labels its own pull
  requests by update type, and an unlabelled one counts as a patch). Release-please was rejected
  because it needs Conventional Commits prefixes, which the owner's commit style doesn't use.
- **Patches publish themselves; everything else waits for the owner** (the owner's decision):

  | Change | Release |
  |---|---|
  | A Renovate patch or digest update that changes the image (rclone x.y.**z**, a client package, the Debian or `mysql:9.7` digest, supercronic x.y.**z**) | Published automatically as a patch release once its tests pass |
  | An Actions pin or a test server's digest | Nothing published; it only changes CI |
  | A dependency's minor update (rclone x.**y** included) | A pull request the owner reviews and merges; the draft becomes a minor release, published with one click |
  | A new major: PostgreSQL 19, the next MySQL LTS, a new MariaDB series, the next Debian | Listed on Renovate's Dependency Dashboard for approval, which opens a pull request adding it to the build and tests; published by the owner |
  | The owner's own changes | Labelled at merge; published by the owner |

  **A patch publishes itself only when everything merged since the last release is a patch.** If
  an unpublished minor or major change is waiting in the draft, the patch joins the draft instead,
  so nothing unreleased ever ships under a patch number. An automatic release must trigger the same
  build, test and push as a manual one (a release created with a workflow's own `GITHUB_TOKEN`
  triggers no further workflows, so the builder chooses between calling the publish workflow
  directly and a GitHub App token).
- **Publishing a release** builds, tests and then pushes all five images by digest, never pushing
  an untested image. Tags per image: `1.2.3`, `1.2`, `1` and `latest`, the floating ones only when
  the release is the newest in that series (the release-resolution logic from `docker-rclone-sync`).
- **Weekly rebuild**: the newest release is rebuilt, tested and re-pushed every week to pick up
  Debian and PGDG updates, off the hour. A successful scheduled rebuild pings an optional
  `REBUILD_MONITOR_URL` repository secret, so a lapsed schedule raises an alert.
- **Renovate, not Dependabot**, tracking: the Debian base digest, the `mysql:9.7` digest, the rclone
  and supercronic versions (through `# renovate:` comments), GitHub Actions pins, and the test
  servers' image digests. Patch and digest updates automerge once CI passes (a required check
  through branch protection); minor updates wait for review; a new major (PostgreSQL 19, the next
  MySQL LTS, a new Debian) appears on Renovate's Dependency Dashboard for approval. Its regular
  merges are also what keep the scheduled workflow from being disabled for inactivity.
- **All Actions pinned to commit SHAs**, as in `docker-rclone-sync`.

## Documentation

- **One README** for the repository: what it is; the hardening baseline; shared settings and the
  monitor table; then a section per image with its settings, account requirements, a complete
  Compose example, and its restore command; the image and tag policy; maintenance (Renovate,
  releases, the weekly rebuild and its monitor); licences.
- **Restore commands**, one per image, for example `zstd -d < app.sql.zst | mysql app` and
  `pg_restore --dbname=app --no-owner app.dump` with the matching major's `pg_restore`.

## Rollout (owner's actions, outside the code)

1. Create `NialtoServices/docker-rclone-backup` on GitHub and push.
2. Install the Renovate GitHub app on it; enable branch protection with the CI check required.
3. Optionally add the `REBUILD_MONITOR_URL` secret.
4. Publish the first release.
5. Move each deployment to the new images, reconfiguring it, with a heartbeat monitor per container.
6. Delete the old repositories; delete their GHCR packages once nothing pulls them.

## Left to the builder

- Script layout, file names and helper structure, within the owner's conventions.
- Whether the scripts are POSIX `sh` (Debian's `dash`) or `bash`, provided no pipeline's exit status
  is lost (dash's support for `set -o pipefail` must be checked) and shellcheck's dialect matches.
- The versioned-bucket stand-in for tests, provided it can show that an unchanged object adds no
  version.
- How the clean-stop supervisor finds the running tool under supercronic.
- How the test suite is split and parallelised across the matrix, provided every supported server
  version is exercised before a release.
- The exact `--lock-wait-timeout` value, the default staging path's size guidance, and the README's
  wording.
- Build ordering and caching in the Dockerfile.
