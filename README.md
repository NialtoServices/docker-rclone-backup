# docker-rclone-backup

Hardened, shell-only images that back up a PostgreSQL, MariaDB or MySQL database, a SQLite database or a directory of files to any rclone remote on a cron schedule. Each image runs as a non-root user on a read-only root filesystem, and reports to a heartbeat monitor if you give it one.

| Image | Backs up |
|---|---|
| `ghcr.io/nialtoservices/rclone-backup/postgres` | A PostgreSQL database |
| `ghcr.io/nialtoservices/rclone-backup/mariadb` | A MariaDB database |
| `ghcr.io/nialtoservices/rclone-backup/mysql` | A MySQL database |
| `ghcr.io/nialtoservices/rclone-backup/sqlite` | A SQLite database |
| `ghcr.io/nialtoservices/rclone-backup/files` | A directory of files |

Every run writes its backup to the target under a fixed name, replacing the object from the run before (`app.dump`, `app.sql.zst` or `app.db.zst` for a database), except `files`, which mirrors the source. The images keep no history of their own.

> **Point the target at a bucket with versioning enabled.** The bucket's versions are the backup history, and without them a run that replaces an object destroys the previous backup, and a `files` run that mirrors a deletion destroys the file. The images can't check this: any rclone remote is accepted, and only some backends can report whether versioning is on.
>
> **Check the bucket's lifecycle rules as well.** Rules such as Backblaze B2's "keep only the last version" make old versions vanish within a day, which leaves you with a single copy that the next bad run overwrites.

## The hardening baseline

Every example in this README runs under the same settings, and so does every test. Start from them and loosen one only for a reason:

```yaml
services:
  backup:
    image: ghcr.io/nialtoservices/rclone-backup/<image>
    user: "1000:1000"
    stop_grace_period: 2m
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    tmpfs:
      - /tmp:rw,nodev,noexec,nosuid,size=512m
```

- **`user`** is needed by `files` and `sqlite`, which run as the uid and gid of the application whose data they read (see [Running as the folder's owner](#running-as-the-folders-owner) and [Running as the application's user](#running-as-the-applications-user)). The database images reach everything over the network, so they need no `user` at all.
- **The image's own user is not root.** It is uid and gid `65532`, with no login shell and no home directory, so `user` is only ever needed to match a volume's owner.
- **`read_only`, `cap_drop` and `no-new-privileges`** leave the container with no writable root filesystem, no capabilities and no way to gain any. Nothing in the images needs them back, except in the two root modes ([files](#root-mode) and [SQLite](#root-mode-1)).
- **Everything the container writes at run time lives under `/tmp`**: the crontab, the lock that stops runs overlapping, rclone's cache and the staged dump or snapshot. That is why a `noexec` tmpfs is enough. The one exception is staging, which `BACKUP_STAGING_PATH` can move to a volume.
- **Size the tmpfs for the staged file.** `size=512m` is a ceiling and not a reservation, but data held in a tmpfs is held in memory. A dump or snapshot larger than the space fails the run, uploads nothing and leaves no staged file behind (only the lock file, which is harmless, stays in `/tmp`); either raise the size or move staging to a volume.
- **`stop_grace_period: 2m`** gives a stopped run time to report its failure; see [Stopping the container](#stopping-the-container).

The images also work without any of this, but there is no reason to run them that way.

## Images and tags

Every image is published for `linux/amd64` and `linux/arm64`. Each release is tagged with its full version (`1.2.3`), its minor series (`1.2`), its major series (`1`) and `latest`. `latest` always points at the newest release overall, while `1.2` and `1` point at the newest release in their own minor or major series. A new release moves each floating tag that it is the newest for.

The newest release is rebuilt every week to pick up updated Debian packages and database client packages (PostgreSQL's from its own package repository, MariaDB's and SQLite's from Debian), and its tags are moved to the new build. The MySQL client is copied from a pinned `mysql` image instead, so it changes only when that pin does. Pin a major version to receive these rebuilds without breaking changes. Older releases are not rebuilt, so a major series stops receiving updates once the next one is released.

## Configuring rclone

`BACKUP_TARGET` (and `BACKUP_SOURCE` for `files`) names an rclone remote and a path, such as `b2:my-bucket/app`, or an absolute path inside the container. Any rclone flag can be set through the environment by upper-casing its name, replacing hyphens with underscores and adding the `RCLONE_` prefix: `--max-delete 100` becomes `RCLONE_MAX_DELETE=100`.

Define the remote itself in one of two ways, and prefer either to a connection string with inline credentials such as `:b2,account=…,key=…:my-bucket`. The images log the target as given, so inline credentials end up in the container's log. They are redacted from the log sent to your monitor, but not from the container's own output.

- **Environment variables**, as `RCLONE_CONFIG_<REMOTE>_<OPTION>`: `RCLONE_CONFIG_B2_TYPE=b2`, `RCLONE_CONFIG_B2_ACCOUNT=…` and `RCLONE_CONFIG_B2_KEY=…` define a remote called `b2`. This needs no file, and it is what the examples below use. Keep the values in an `env_file` rather than in the Compose file.
- **A config file**, mounted read-only, with `RCLONE_CONFIG` pointing at it:

  ```yaml
  volumes:
    - ./rclone.conf:/config/rclone.conf:ro
  environment:
    RCLONE_CONFIG: /config/rclone.conf
  ```

`RCLONE_CONFIG` is `/dev/null` in the image, so the environment-only setup runs without rclone noting a missing config file in a container that has no home directory. Setting `RCLONE_CONFIG` replaces that. Nothing is written to the config file, with one exception: **a remote that refreshes OAuth tokens** (Google Drive, OneDrive, Dropbox and similar) writes each new token back to it. Such a remote needs `RCLONE_CONFIG` to point at a writable file, on a volume, and so can't use a read-only mount. A remote that authenticates with a static key, as B2, S3 and SFTP do, never needs this.

A key restricted to a single bucket can't create buckets, and rclone's check that the bucket exists can fail with a permissions error. For an S3 remote, set `RCLONE_S3_NO_CHECK_BUCKET=true` to skip it; the bucket must then already exist. Google Cloud Storage has `RCLONE_GCS_NO_CHECK_BUCKET` and Azure Blob `RCLONE_AZUREBLOB_NO_CHECK_CONTAINER`. The B2 backend has no such option, so the B2 examples here set nothing.

## Settings every image shares

| Variable | Description |
|---|---|
| `BACKUP_SCHEDULE` | When to run: a five-field cron schedule (`0 3 * * *`), a macro such as `@daily` or `@hourly`, or `disabled` to keep the container running with nothing scheduled. Defaults to `0 0 * * *`. `@reboot` and `@every` are not accepted, and neither are schedules with a seconds or year field |
| `BACKUP_TARGET` | The rclone remote and path that receives the backup (`b2:my-bucket/app`), or an absolute path inside the container |
| `BACKUP_STAGING_PATH` | The `sqlite` and database images only: where the dump or snapshot is written before it is uploaded. Defaults to `/tmp`; see each image for how to size it |
| `TZ` | The time zone the schedule and the log timestamps follow, for example `Europe/London`. Defaults to UTC |
| `MONITOR_START_URL`, `MONITOR_SUCCESS_URL`, `MONITOR_FAILURE_URL` | Heartbeat monitor URLs, all optional; see [Monitoring](#monitoring) |
| `RCLONE_*` | Passed through to rclone: any flag, or a remote's definition; see [Configuring rclone](#configuring-rclone) |

Each image adds its own settings, listed in its section. `BACKUP_TARGET`, like `BACKUP_SOURCE` in `files`, is an rclone remote or an absolute path in every image. A relative path is refused, because it would resolve inside the container's own filesystem.

- **The container checks its settings when it starts.** A bad schedule, a missing or malformed required setting, or any variable beginning `BACKUP_`, `MONITOR_`, `DATABASE_` or `SQLITE_` that the image doesn't read (a typo, or a setting that belongs to another image) stops the container with a message naming it, rather than failing at the first run. Variables with any other name are ignored.
- **One run at a time.** A scheduled run that comes due while the previous one is still going is skipped: the scheduler logs `not starting: job is still running` and starts nothing, so the monitor hears nothing from that tick. A run started by hand while another is going is refused with an error, and reported to the monitor as a failure if it was started through `/usr/local/bin/monitor`, as scheduled runs are.

## Monitoring

Each scheduled run can report to a heartbeat monitor (sometimes called a dead man's switch). Because the monitor expects to hear from every run, it alerts you when a backup fails and also when one doesn't happen at all: the container is down, the schedule never fires, or a run hangs.

Set whichever URLs your monitor provides:

- `MONITOR_START_URL` is requested when a run starts.
- `MONITOR_SUCCESS_URL` is requested when a run succeeds.
- `MONITOR_FAILURE_URL` is requested when a run fails. It's sent as a `POST` whose body is the last 100 kB of the run's log. The log includes file paths, remote names and object names; option values in rclone connection strings are replaced with `REDACTED`.

Each request times out after 10 seconds and is retried up to 5 times, including when the connection is refused. A request that still fails is logged as a warning and doesn't change the result of the run. The URLs are secrets, so they never appear in a process's arguments. Set the monitor's schedule or period to match `BACKUP_SCHEDULE`, with a grace time longer than your slowest run. A container started without `MONITOR_SUCCESS_URL` logs a warning, because a run that fails or never happens then raises no alert.

| Monitor | `MONITOR_START_URL` | `MONITOR_SUCCESS_URL` | `MONITOR_FAILURE_URL` |
|---|---|---|---|
| [Healthchecks](https://healthchecks.io) | `https://hc-ping.com/<uuid>/start` | `https://hc-ping.com/<uuid>` | `https://hc-ping.com/<uuid>/fail` |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma) push monitor | *(unset)* | `https://<kuma-host>/api/push/<token>?status=up&msg=OK` | `https://<kuma-host>/api/push/<token>?status=down&msg=Backup%20failed` |
| [StatusCake](https://www.statuscake.com) push check | *(unset)* | `https://push.statuscake.com/?PK=<key>&TestID=<id>&time=0` | *(unset)* |

- Uptime Kuma and StatusCake have no "started" signal. Leave `MONITOR_START_URL` unset for them: a start ping would count as a successful heartbeat and delay the alert for a run that hangs.
- StatusCake push checks have no failure signal either. StatusCake alerts when the success ping is overdue.
- Healthchecks keeps the failure log in the check's event history. Uptime Kuma and StatusCake ignore the request body, so the details are in the container's log.

## Stopping the container

Stopping the container interrupts a running backup: the dump tool or rclone cleans up its partial files, the run is reported to the monitor as failed, and the container exits with 143. If the monitor can't be reached, reporting can take up to about 90 seconds, while Docker kills a container 10 seconds after asking it to stop. To give the report time to get through, set a longer grace period, such as `stop_grace_period: 2m` in Compose or `docker stop -t 120`.

## Fetching a backup from the target

Every restore starts by downloading the object, which needs nothing from these images. With rclone on your own machine and the remote defined as above:

```sh
export RCLONE_CONFIG_B2_TYPE=b2 RCLONE_CONFIG_B2_ACCOUNT=<application key id> RCLONE_CONFIG_B2_KEY=<application key>
rclone copyto b2:my-bucket/app/app.dump app.dump
```

`app.dump` is what the `postgres` image writes for a database called `app`. The `mariadb` and `mysql` images write `app.sql.zst`, `sqlite` writes `<file name>.zst` (`app.db.zst`), and `files` mirrors the source, so use `rclone copy` there as in [Restoring](#restoring) under Files.

That fetches the current object. To fetch the one that an earlier run replaced, ask the bucket for its versions: `--b2-version-at "2026-10-01"` gives the object as it stood then, `--s3-version-at` does the same on S3, and `--b2-versions` or `--s3-versions` lists every version with a timestamp in its name. Each image's section below says what to do with the object once you have it.

## Files

The `files` image mirrors one directory, or one rclone remote path, to the target with `rclone sync`. The target ends up as a copy of the source, so keep history by pointing the target at a bucket with versioning enabled.

> **`rclone sync` is destructive.** Files deleted at the source are also deleted at the target on the next run. All recoverability of deleted or overwritten files lives at the target, in the bucket's versioning, and not in this container.
>
> An empty source is mirrored like any other: if the source is empty when a run starts (for example, because a volume failed to mount), everything at the target is deleted and the run still succeeds. To make a run like that fail instead, cap the number of deletions per run with `RCLONE_MAX_DELETE`. The run stops once the cap is reached and exits with an error.

| Variable | Description |
|---|---|
| `BACKUP_SOURCE` | Where to copy from: an rclone remote and path (`b2:my-source-bucket`), or an absolute path inside the container (a mounted volume at `/source`) |
| `BACKUP_TARGET` | Where to copy to, in the same forms |

### Running as the folder's owner

The image runs as the folder owner's uid and gid, so it can read exactly what the application can read and nothing more. Find them with `docker exec <app> id`, or `stat` on the volume, and set `user` to match. Mount the source read-only.

```yaml
services:
  backup:
    image: ghcr.io/nialtoservices/rclone-backup/files
    user: "1000:1000"
    stop_grace_period: 2m
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    tmpfs:
      - /tmp:rw,nodev,noexec,nosuid,size=512m
    volumes:
      - app-data:/source:ro
    environment:
      BACKUP_SOURCE: /source
      BACKUP_TARGET: b2:my-bucket/app-data
      BACKUP_SCHEDULE: "0 3 * * *"
      RCLONE_MAX_DELETE: "100"
      RCLONE_CONFIG_B2_TYPE: b2
      RCLONE_CONFIG_B2_ACCOUNT: <application key id>
      RCLONE_CONFIG_B2_KEY: <application key>

volumes:
  app-data:
```

Add the service to the application's own Compose file, so that `app-data` is the volume the application already declares.

### Root mode

When the source holds files with different owners, no single uid can read them all. Run as root and add back the one capability that reads without write access:

```yaml
    user: "0:0"
    cap_add: [DAC_READ_SEARCH]
```

Capabilities only take effect for root, and root inside a container is a larger target than an unprivileged uid, so prefer the owner's uid where one will do.

### Restoring

The target is a plain copy of the source, so restoring is copying it back. Copy into an empty directory, check it, and only then replace the original; `--b2-version-at` and `--s3-version-at` bring back files that a later run deleted or overwrote, as in [Fetching a backup from the target](#fetching-a-backup-from-the-target):

```sh
rclone copy b2:my-bucket/app-data ./restored
```

## SQLite

The `sqlite` image takes a consistent snapshot of one SQLite database with `VACUUM INTO` while the application keeps running, checks it with `PRAGMA integrity_check`, compresses it with zstd and uploads it to the target as `<file name>.zst` (`app.db.zst` for `/data/app.db`). The database file is never copied directly, which would capture a torn state of a database that is being written. A snapshot that fails its check is not uploaded, and the run fails.

| Variable | Description |
|---|---|
| `SQLITE_DATABASE` | The absolute path of the database file inside the container. It must be the file's real path: a path that is, or lies under, a symlink is refused, so the file backed up is always the one configured |
| `BACKUP_TARGET` | Where to upload the snapshot: an rclone remote and path (`b2:my-bucket/app`), or an absolute path inside the container |
| `BACKUP_STAGING_PATH` | Where the snapshot is written before it is uploaded. Defaults to `/tmp`, which is held in memory under the baseline's settings. See the sizing note below. The staged files are deleted after every run |

- **Versioning is the history.** Each upload replaces the object at the target, so keep older snapshots by pointing the target at a bucket with versioning enabled, and set lifecycle rules there. Rules such as B2's "keep only the last version" make old versions vanish within a day.
- **Size the staging space for about twice the database.** The snapshot is a full copy of the database, and it is compressed into a second file before the first is removed, so the two briefly exist together. Make the `/tmp` tmpfs, or the volume at `BACKUP_STAGING_PATH`, large enough for both. A run that runs out of space fails, uploads nothing and leaves no staged file behind.
- **An unchanged database adds no version.** The upload is compared by checksum, so a snapshot identical to the object already at the target is skipped. A target that can't report a checksum, such as a `crypt` remote, is uploaded on every run instead, and adds a version each time.
- **A missing database fails the run.** The file is opened for writing only if it already exists, so a wrong path or an unmounted volume never produces an empty database.

### Running as the application's user

Run the container as the uid and gid that own the database, so it can read what the application can read and create the files SQLite needs. Find them with `docker exec <app> id`, or `stat` on the volume.

**Mount the database's directory read-write.** A database in WAL mode keeps its recent writes in `app.db-wal`, and readers coordinate through `app.db-shm`. When the application has stopped cleanly, neither file exists, and SQLite has to create them while the snapshot is open, which needs a writable directory. A volume mounted `:ro` fails the run. The snapshot itself never modifies the database.

```yaml
services:
  backup:
    image: ghcr.io/nialtoservices/rclone-backup/sqlite
    user: "1000:1000"
    stop_grace_period: 2m
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    tmpfs:
      - /tmp:rw,nodev,noexec,nosuid,size=512m
    volumes:
      - app-data:/data
    environment:
      SQLITE_DATABASE: /data/app.db
      BACKUP_TARGET: b2:my-bucket/app
      BACKUP_SCHEDULE: "0 3 * * *"
      RCLONE_CONFIG_B2_TYPE: b2
      RCLONE_CONFIG_B2_ACCOUNT: <application key id>
      RCLONE_CONFIG_B2_KEY: <application key>

volumes:
  app-data:
```

Add the service to the application's own Compose file, so that `app-data` is the volume the application already declares.

### Root mode

When the application's uid can't be matched, run as root and add back exactly two capabilities. `DAC_OVERRIDE` lets root open a database it doesn't own, and `CHOWN` lets SQLite give the `-wal` and `-shm` files it creates the database's owner:

```yaml
    user: "0:0"
    cap_add: [DAC_OVERRIDE, CHOWN]
```

**Never add `DAC_OVERRIDE` without `CHOWN`.** Without `CHOWN`, those files are created owned by root, and an application running as another uid can then no longer open its own database's WAL, which breaks the application until the files are removed. Capabilities only take effect for root, and root inside a container is a larger target than an unprivileged uid, so prefer the application's uid where one will do.

### Restoring

[Download the object](#fetching-a-backup-from-the-target), then decompress it and check it. The result is an ordinary SQLite database file, and neither step needs this image:

```sh
zstd -d app.db.zst
sqlite3 app.db 'PRAGMA integrity_check'
```

Stop the application, replace its database file with the restored one (removing any `-wal` and `-shm` files beside the old one), and start it again.

## PostgreSQL

The `postgres` image dumps one PostgreSQL database with `pg_dump --format=custom` and uploads it to the target as `<database>.dump` (`app.dump` for a database called `app`). Servers 15, 16, 17 and 18 are supported. Before each run the image asks the server for its version and uses the `pg_dump` of that same major, so the dump is always taken by a matching client. A server of any other version, including one newer than the image, is refused with a message naming its version. The archive is checked with `pg_restore --list` before it is uploaded, and a dump that fails the check is not uploaded.

| Variable | Description |
|---|---|
| `DATABASE_HOST` | The server's host name or address |
| `DATABASE_PORT` | The server's port, a positive integer. Defaults to `5432` |
| `DATABASE_USER` | The role to connect as; see [the backup role](#the-backup-role) |
| `DATABASE_PASSWORD` | The role's password. Set this or `DATABASE_PASSWORD_FILE`, not both |
| `DATABASE_PASSWORD_FILE` | The path of a file holding the password, such as a Docker or Compose secret, so it needn't sit in the container's environment. A trailing newline, or a carriage return before it, is ignored |
| `DATABASE_NAME` | The database to dump. It becomes the object's name, so it must not contain `/` or start with `.` or `-` |
| `DATABASE_TLS` | `disabled` (the default), `required` or `verify`. `required` encrypts the connection without checking the server's certificate; `verify` also checks that the certificate is trusted and names the host. Set `required` or `verify` for a managed database or any server across an untrusted network |
| `DATABASE_TLS_CA_PATH` | With `verify`, the path of the certificate authority file to trust, for a private CA; it must be a readable file. Without it the operating system's CA certificates are used. Refused with any other `DATABASE_TLS` value |
| `BACKUP_TARGET` | Where to upload the dump: an rclone remote and path (`b2:my-bucket/app`), or an absolute path inside the container |
| `BACKUP_STAGING_PATH` | Where the dump is written before it is uploaded. Defaults to `/tmp`, which is held in memory under the [baseline](#the-hardening-baseline), so a dump larger than the `/tmp` tmpfs fails the run, uploads nothing and leaves no staged file behind; a volume here avoids that. The staged file is deleted after every run |

Passwords with any characters work, and the password reaches `pg_dump` through its environment, never its arguments. Neither it nor any other connection detail is passed on to rclone.

- **Versioning is the history.** Each upload replaces the object at the target, so keep older dumps by pointing the target at a bucket with versioning enabled, and set lifecycle rules there. Rules such as B2's "keep only the last version" make old versions vanish within a day.
- **Every run adds a version.** A custom-format archive records when it was created, so two dumps of an unchanged database differ and the checksum comparison never finds a match.
- **A migration can stop a run.** `pg_dump` waits up to a minute for the locks it needs, so a migration holding an exclusive lock for longer than that fails the run, which the monitor reports, instead of the dump waiting until the next schedule.
- **An unreachable server fails the run.** The connection attempt times out after 10 seconds, so a wrong host or a database that is down is reported straight away and not at the next schedule.
- **The dump keeps ownership and privileges.** The restore decides what to do with them, as below.

### The backup role

Give the image a role of its own, not the application's or a superuser. It needs `pg_read_all_data` to read every table and sequence, `BYPASSRLS` so row-level security can't hide rows from the dump, and `SELECT` on each large object, which `pg_read_all_data` doesn't cover:

```sql
CREATE ROLE backup LOGIN BYPASSRLS PASSWORD '<password>';
GRANT pg_read_all_data TO backup;
GRANT SELECT ON LARGE OBJECT <oid> TO backup;
```

Repeat the last grant for every large object (`SELECT oid FROM pg_largeobject_metadata`), and again for each one created later. A database that holds no large objects needs only the first two statements. Without the grant on a large object, the dump fails instead of leaving it out.

### Running it

The image needs no volume and no particular uid, because everything it uses is reached over the network. Run it beside the database on a private network:

```yaml
services:
  backup:
    image: ghcr.io/nialtoservices/rclone-backup/postgres
    stop_grace_period: 2m
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    tmpfs:
      - /tmp:rw,nodev,noexec,nosuid,size=512m
    secrets:
      - backup_password
    environment:
      DATABASE_HOST: database
      DATABASE_USER: backup
      DATABASE_PASSWORD_FILE: /run/secrets/backup_password
      DATABASE_NAME: app
      BACKUP_TARGET: b2:my-bucket/app
      BACKUP_SCHEDULE: "0 3 * * *"
      RCLONE_CONFIG_B2_TYPE: b2
      RCLONE_CONFIG_B2_ACCOUNT: <application key id>
      RCLONE_CONFIG_B2_KEY: <application key>

secrets:
  backup_password:
    file: ./backup_password.txt
```

Put the backup role's password in `backup_password.txt`, keep it out of version control, and make sure the image's user (`65532`) can read it, because Compose gives a file secret the file's own permissions. `DATABASE_HOST: database` is the database's service name, so add the service to the database's Compose file, or attach it to the database's network.

### Restoring

[Download the object](#fetching-a-backup-from-the-target), create an empty database and restore into it with the `pg_restore` of the **server's own major**. A newer `pg_restore` can't restore into an older server: PostgreSQL 18's, for one, sends a setting that servers 14 to 16 don't know. The `postgres` image of your server's version has the right one:

```sh
createdb --username postgres restored
pg_restore --username postgres --dbname restored --exit-on-error app.dump
```

Add `--no-owner` if the roles that owned the objects don't exist on the server you restore to, and `--no-acl` to skip the grants. A trusted extension in the dump is created as the restoring role, so restore with a role that may create it.

## MariaDB

The `mariadb` image dumps one MariaDB database with `mariadb-dump`, compresses it with zstd and uploads it to the target as `<database>.sql.zst` (`app.sql.zst` for a database called `app`). Servers 10.11, 11.4, 11.8 and later are supported, all by the one client the image carries, MariaDB 11.8's. The compressed dump is checked with `zstd --test` before it is uploaded, and a dump that fails the check, or whose client printed an error, is not uploaded.

| Variable | Description |
|---|---|
| `DATABASE_HOST` | The server's host name or address |
| `DATABASE_PORT` | The server's port, a positive integer. Defaults to `3306` |
| `DATABASE_USER` | The account to connect as; see [the backup account](#the-backup-account) |
| `DATABASE_PASSWORD` | The account's password. Set this or `DATABASE_PASSWORD_FILE`, not both |
| `DATABASE_PASSWORD_FILE` | The path of a file holding the password, such as a Docker or Compose secret, so it needn't sit in the container's environment. A trailing newline, or a carriage return before it, is ignored |
| `DATABASE_NAME` | The database to dump. It becomes the object's name, so it must not contain `/` or start with `.` or `-` |
| `DATABASE_TLS` | `disabled` (the default), `required` or `verify`. `required` encrypts the connection without checking the server's certificate, and the run fails if the connection turns out not to be encrypted; `verify` also checks the certificate. Set `required` or `verify` for a managed database or any server across an untrusted network |
| `DATABASE_TLS_CA_PATH` | With `verify`, the path of the certificate authority file to trust, for a private CA; it must be a readable file. Without it the operating system's CA certificates are used. Refused with any other `DATABASE_TLS` value |
| `BACKUP_TARGET` | Where to upload the dump: an rclone remote and path (`b2:my-bucket/app`), or an absolute path inside the container |
| `BACKUP_STAGING_PATH` | Where the dump is written before it is uploaded. Defaults to `/tmp`, which is held in memory under the [baseline](#the-hardening-baseline), so a dump larger than the `/tmp` tmpfs fails the run, uploads nothing and leaves no staged file behind; a volume here avoids that. The staged file is deleted after every run |

Passwords with any characters work, and the password reaches `mariadb-dump` through its environment, never its arguments. Neither it nor any other connection detail is passed on to rclone. The official `mariadb` image's own variables (`MARIADB_ROOT_PASSWORD`, `MARIADB_DATABASE` and the rest) are ignored, so an env file shared with the database container can't change which account or database is backed up.

- **Versioning is the history.** Each upload replaces the object at the target, so keep older dumps by pointing the target at a bucket with versioning enabled, and set lifecycle rules there. Rules such as B2's "keep only the last version" make old versions vanish within a day.
- **An unchanged database adds no version.** The dump leaves out its own timestamp and zstd's output is deterministic, so a dump identical to the object already at the target is skipped by the checksum comparison. A target that can't report a checksum, such as a `crypt` remote, is uploaded on every run instead, and adds a version each time.
- **History in system-versioned tables is kept.** The dump uses `--dump-history`, and restoring it brings back every row version, not only the current ones.
- **Avoid schema migrations during a backup.** `--single-transaction` gives the dump a consistent view of the data, but it doesn't isolate the dump from a migration that changes tables while it runs, and the dump can come out inconsistent. A migration can also stall the dump altogether: `mariadb-dump` has no bound on how long it waits for a lock, so a migration holding one makes the run wait until the migration finishes, however long that takes. While it waits, each later scheduled run is skipped, with a `not starting` line in the log, and nothing is reported to the monitor, which alerts you once the success ping is overdue. Set the monitor's grace time to fit, because a stalled dump and a run that never happened look the same to it. Schedule the backup away from migrations.
- **A sequence restores with its next value moved on.** MariaDB restores a sequence with its next value at the end of its cache, so the numbers it hands out after a restore skip ahead.
- **An unreachable server fails the run.** The image connects once before dumping, with a 10-second timeout, because `mariadb-dump` has no timeout of its own and would otherwise wait on the operating system for minutes.
- **`required` is checked, not assumed.** The MariaDB 11.8 client falls back to an unencrypted connection when the server has no TLS and certificate checking is switched off, which is how `required` has to be asked for. The image therefore asks the server whether the connection is encrypted and fails the run if it isn't. MariaDB 11.4 and later servers generate their own certificate, so `required` works against them with no setup; a 10.11 server needs TLS configured first.
- **`verify` without a CA file accepts a server's own certificate.** The 11.8 client can prove a self-signed certificate genuine through the account's password, so `verify` works against 11.4 and later servers that generate their own certificate. Give `DATABASE_TLS_CA_PATH` to trust only a particular authority.

### The backup account

Give the image an account of its own, not the application's or root. It needs `SELECT`, `SHOW VIEW`, `TRIGGER` and `EVENT` on the database, plus a privilege that lets it read stored routines, and which one depends on the server's version:

```sql
CREATE USER 'backup'@'%' IDENTIFIED BY '<password>';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON app.* TO 'backup'@'%';

-- MariaDB 11.3 and later:
GRANT SHOW CREATE ROUTINE ON app.* TO 'backup'@'%';

-- MariaDB 10.11:
GRANT SELECT ON mysql.proc TO 'backup'@'%';
```

**Without the routine privilege the dump silently leaves out every stored procedure and function, and the run still succeeds.** Neither the client nor the image reports it, and the backup looks complete until a restore finds the routines missing. Check by listing the routines in the dump: `zstd -dc app.sql.zst | grep -E '^CREATE .*(PROCEDURE|FUNCTION)'`.

### Running it

The image needs no volume and no particular uid, because everything it uses is reached over the network. Run it beside the database on a private network:

```yaml
services:
  backup:
    image: ghcr.io/nialtoservices/rclone-backup/mariadb
    stop_grace_period: 2m
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    tmpfs:
      - /tmp:rw,nodev,noexec,nosuid,size=512m
    secrets:
      - backup_password
    environment:
      DATABASE_HOST: database
      DATABASE_USER: backup
      DATABASE_PASSWORD_FILE: /run/secrets/backup_password
      DATABASE_NAME: app
      BACKUP_TARGET: b2:my-bucket/app
      BACKUP_SCHEDULE: "0 3 * * *"
      RCLONE_CONFIG_B2_TYPE: b2
      RCLONE_CONFIG_B2_ACCOUNT: <application key id>
      RCLONE_CONFIG_B2_KEY: <application key>

secrets:
  backup_password:
    file: ./backup_password.txt
```

Put the backup account's password in `backup_password.txt`, keep it out of version control, and make sure the image's user (`65532`) can read it, because Compose gives a file secret the file's own permissions. `DATABASE_HOST: database` is the database's service name, so add the service to the database's Compose file, or attach it to the database's network.

### Restoring

[Download the object](#fetching-a-backup-from-the-target), create an empty database and restore into it with the `mariadb` client of your server's own version, as an account that may create the dump's objects (its routines and triggers keep their original definers, so `root` is the safe choice). The dump restores to any server from 10.11 on:

```sh
mariadb --user root --execute 'CREATE DATABASE restored'
zstd -dc app.sql.zst | mariadb --user root restored
```

## MySQL

The `mysql` image dumps one MySQL database with Oracle's `mysqldump`, compresses it with zstd and uploads it to the target as `<database>.sql.zst` (`app.sql.zst` for a database called `app`). Servers 8.0, 8.4 and 9.x are supported, all by the one client the image carries, MySQL 9.7's. The compressed dump is checked with `zstd --test` before it is uploaded, and a dump that fails the check, or whose client printed an error, is not uploaded.

| Variable | Description |
|---|---|
| `DATABASE_HOST` | The server's host name or address |
| `DATABASE_PORT` | The server's port, a positive integer. Defaults to `3306` |
| `DATABASE_USER` | The account to connect as; see [the backup account](#the-backup-account-1) |
| `DATABASE_PASSWORD` | The account's password. Set this or `DATABASE_PASSWORD_FILE`, not both |
| `DATABASE_PASSWORD_FILE` | The path of a file holding the password, such as a Docker or Compose secret, so it needn't sit in the container's environment. A trailing newline, or a carriage return before it, is ignored |
| `DATABASE_NAME` | The database to dump. It becomes the object's name, so it must not contain `/` or start with `.` or `-` |
| `DATABASE_TLS` | `disabled` (the default), `required` or `verify`. `required` encrypts the connection without checking the server's certificate, and fails the run against a server that offers no TLS; `verify` also checks the certificate and that it names the server's host. Set `required` or `verify` for a managed database or any server across an untrusted network; `disabled` is only for a network you trust, as the notes below explain |
| `DATABASE_TLS_CA_PATH` | With `verify`, the path of the certificate authority file to trust, for a private CA; it must be a readable file. Without it the image's CA bundle (Debian's, `/etc/ssl/certs/ca-certificates.crt`) is used. Refused with any other `DATABASE_TLS` value |
| `BACKUP_TARGET` | Where to upload the dump: an rclone remote and path (`b2:my-bucket/app`), or an absolute path inside the container |
| `BACKUP_STAGING_PATH` | Where the dump is written before it is uploaded. Defaults to `/tmp`, which is held in memory under the [baseline](#the-hardening-baseline), so a dump larger than the `/tmp` tmpfs fails the run, uploads nothing and leaves no staged file behind; a volume here avoids that. The staged file is deleted after every run |

Passwords with any characters work, and the password reaches `mysqldump` through its environment, never its arguments. Neither it nor any other connection detail is passed on to rclone. The official `mysql` image's own variables (`MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE` and the rest) are ignored, so an env file shared with the database container can't change which account or database is backed up.

- **The account must use `caching_sha2_password`.** That is the default on every supported server, but the 9.7 client has no `mysql_native_password` plugin, so an account created with it fails the run with `Authentication plugin 'mysql_native_password' cannot be loaded`, and nothing is uploaded. Recreate such an account, or give the backup its own, with the default plugin.
- **Versioning is the history.** Each upload replaces the object at the target, so keep older dumps by pointing the target at a bucket with versioning enabled, and set lifecycle rules there. Rules such as B2's "keep only the last version" make old versions vanish within a day.
- **An unchanged database adds no version.** The dump leaves out its own timestamp and zstd's output is deterministic, so a dump identical to the object already at the target is skipped by the checksum comparison. A target that can't report a checksum, such as a `crypt` remote, is uploaded on every run instead, and adds a version each time.
- **Avoid schema migrations during a backup.** `--single-transaction` gives the dump a consistent view of the data, but it doesn't isolate the dump from a migration that changes tables while it runs, and the dump can come out inconsistent. A migration can also stall the dump altogether: `mysqldump` has no bound on how long it waits for a lock, so a migration holding one makes the run wait until the migration finishes, however long that takes. While it waits, each later scheduled run is skipped, with a `not starting` line in the log, and nothing is reported to the monitor, which alerts you once the success ping is overdue. Set the monitor's grace time to fit, because a stalled dump and a run that never happened look the same to it. Schedule the backup away from migrations.
- **The dump carries no replication state or masking policies.** It is taken with `--set-gtid-purged=OFF`, so it restores into a server with other transactions, and with `--skip-masking-policies`, because the 9.x client otherwise prints an error for them on a community server. Any line the client prints with `error` in it fails the run even when the client exits 0.
- **An unreachable server fails the run.** The image connects once before dumping, with a 10-second timeout, because `mysqldump` has no timeout of its own and would otherwise wait on the operating system for minutes.
- **`DATABASE_TLS=disabled` fetches the server's key without verifying it.** `caching_sha2_password` logs in over an unencrypted connection by encrypting the password with the server's RSA public key, so with `disabled` the image adds `--get-server-public-key` and the client takes the key from whichever server answers. Nothing proves that the key belongs to your server. On a network you control that is fine, but on an untrusted network an active attacker who can intercept the connection can substitute their own key and so learn the password. Even without an attacker, the data itself travels unencrypted. Use `required` or `verify` there.

### The backup account

Give the image an account of its own, not the application's or root. It needs `SELECT`, `SHOW VIEW`, `TRIGGER` and `EVENT` on the database, plus `SHOW_ROUTINE`, which lets it read stored routines. `SHOW_ROUTINE` is a global privilege, available from MySQL 8.0.20:

```sql
CREATE USER 'backup'@'%' IDENTIFIED BY '<password>';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON app.* TO 'backup'@'%';
GRANT SHOW_ROUTINE ON *.* TO 'backup'@'%';
```

**Without `SHOW_ROUTINE` the dump silently leaves out every stored procedure and function, and the run still succeeds.** Neither the client nor the image reports it, and the backup looks complete until a restore finds the routines missing. Check by listing the routines in the dump: `zstd -dc app.sql.zst | grep -E '^CREATE .*(PROCEDURE|FUNCTION)'`.

### Running it

The image needs no volume and no particular uid, because everything it uses is reached over the network. Run it beside the database on a private network:

```yaml
services:
  backup:
    image: ghcr.io/nialtoservices/rclone-backup/mysql
    stop_grace_period: 2m
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    tmpfs:
      - /tmp:rw,nodev,noexec,nosuid,size=512m
    secrets:
      - backup_password
    environment:
      DATABASE_HOST: database
      DATABASE_USER: backup
      DATABASE_PASSWORD_FILE: /run/secrets/backup_password
      DATABASE_NAME: app
      BACKUP_TARGET: b2:my-bucket/app
      BACKUP_SCHEDULE: "0 3 * * *"
      RCLONE_CONFIG_B2_TYPE: b2
      RCLONE_CONFIG_B2_ACCOUNT: <application key id>
      RCLONE_CONFIG_B2_KEY: <application key>

secrets:
  backup_password:
    file: ./backup_password.txt
```

Put the backup account's password in `backup_password.txt`, keep it out of version control, and make sure the image's user (`65532`) can read it, because Compose gives a file secret the file's own permissions. `DATABASE_HOST: database` is the database's service name, so add the service to the database's Compose file, or attach it to the database's network.

### Restoring

[Download the object](#fetching-a-backup-from-the-target), create an empty database and restore into it with the `mysql` client of your server's own version, as an account that may create the dump's objects (its routines and triggers keep their original definers, so `root` is the safe choice). The dump restores to any server from 8.0 on:

```sh
mysql --user root --execute 'CREATE DATABASE restored'
zstd -dc app.sql.zst | mysql --user root restored
```

## Maintenance

### Releases

Release Drafter keeps a draft GitHub release up to date as pull requests merge into `main`. It works out the next version from each pull request's label: `major`, `minor` or `patch`, with an unlabelled pull request counting as a patch. Label your own pull requests before you merge them. A pull request labelled `ci` changes only the build and tests, so it is left out of the draft. Publishing the draft by hand builds, tests and pushes all five images.

Routine patches publish themselves. When CI passes on `main`, the Auto release workflow lists everything merged since the newest published release, and publishes the draft only if every change is a Renovate pull request labelled `patch` or `ci`, with at least one `patch`. A change by anyone else, a direct push to `main`, or a `minor` or `major` Renovate update makes it wait, so nothing unreleased ever ships under a patch number; publish the draft yourself when you are ready. The workflow never publishes the first release, because there is nothing to compare against.

A release published with a workflow's own token starts no other workflows, so Auto release starts the Publish workflow itself. If that step fails, the release exists but its images do not; start the build with `gh workflow run publish.yml --ref v1.2.3`, or leave it for the weekly rebuild.

### Renovate

Renovate tracks the Debian and `mysql:9.7` digests, the rclone and supercronic versions (through the `# renovate:` comments in the Dockerfile), the GitHub Actions pins, the two images pinned inside `build.yml`, and the digests in `test/servers`. It labels each pull request by update type, and `ci` instead for anything that only changes CI.

- **Patch and digest updates** merge themselves once CI passes, except supercronic.
- **Minor updates** wait for you to review and merge them.
- **Major updates** wait on the Dependency Dashboard until you approve them. A new PostgreSQL, MariaDB or MySQL series needs its own line in `test/servers` and its own tests, so an approved major for a test server is a prompt to add that line by hand, not a change to merge.

#### supercronic

supercronic publishes no checksum file or signature, so each architecture's SHA-256 in the Dockerfile is edited by hand. Renovate changes only `SUPERCRONIC_VERSION`, so its pull request fails the build at the checksum until you update both checksums, which is the intended stop. On the Renovate branch:

1. Download `supercronic-linux-amd64` and `supercronic-linux-arm64` for the new version.
2. Check each `sha1sum` against the SHA-1 in the release notes.
3. Put each `sha256sum` in `SUPERCRONIC_SHA256_AMD64` and `SUPERCRONIC_SHA256_ARM64`, and push.

Renovate leaves a branch alone once you have pushed to it. Merge the pull request when CI passes; it publishes as a patch release like any other Renovate patch.

#### Every November

PostgreSQL's oldest major reaches end of life each November, and PGDG then moves its client to an archive repository, so installing it fails. Until that is dealt with, the weekly rebuild fails without pushing anything, and the images already published keep working. When the new major arrives, and again when the oldest ends:

1. In the Dockerfile, add the new major's `postgresql-client-N` package and drop the end-of-life one.
2. Update the version settings at the top of `test/postgres` and the matching lines in `test/servers`, where the newest unsupported major stays as the server the refusal test uses, and the supported versions in this README.
3. Merge it as a minor release and publish the draft.

MariaDB and MySQL each use a single client, so their end-of-life dates do not affect the build.

### The weekly rebuild

GitHub disables the weekly rebuild after 60 days without repository activity. To be alerted when that happens, or when a rebuild fails, set the `REBUILD_MONITOR_URL` repository secret to a heartbeat monitor's success URL with a weekly period. Re-enable a disabled schedule with `gh workflow enable publish.yml`.

### Setting up the repository

1. Create the repository on GitHub and push.
2. Create the labels `major`, `minor`, `patch` and `ci`.
3. Install the Renovate GitHub app on the repository.
4. Protect `main` with branch protection, and require the one check named `CI passed` (the `ci-ok` job in `ci.yml`), so that Renovate merges nothing that has not passed CI. It fails unless the lint and every image build and test succeeded, and it fails when they are skipped or cancelled, so you never need to list the individual jobs, whose names change with the images and platforms. Also enable "Allow auto-merge" in the repository settings: Renovate then asks GitHub to merge each automerge pull request as soon as the checks pass. Without it, Renovate skips that request and merges the pull request itself on a later run, so the setting is a speed-up and not a requirement.
5. Optionally add the `REBUILD_MONITOR_URL` secret.
6. Publish the first release yourself, from the draft Release Drafter creates on the first push to `main`.

### Tests

Before anything is published, CI lints the scripts with shellcheck and the workflows with actionlint, then builds every image and runs its tests on each platform. The suites need only Docker. Each takes the image to test, and the database suites pull the server images listed in `test/servers`:

```sh
docker build --target files --tag rclone-backup/files:test .
test/files rclone-backup/files:test
test/shared rclone-backup/files:test
test/base rclone-backup/files:test
```

`test/shared` (scheduling, monitoring and stopping) and `test/base` (what every image carries) run against the `files` image, which is the shared base plus one script. Each of the other images has a suite of its own, `test/sqlite`, `test/postgres`, `test/mariadb` and `test/mysql`, taking the same argument. The workflow scripts' tests take none:

```sh
test/github-scripts
```

## Licences

This project is licensed under the Apache License 2.0; see the [LICENSE](LICENSE) file. Each image also contains software under other licences. This repository does not redistribute their source: it is available from the projects below, and each image's own copy of every Debian package's licence is in `/usr/share/doc/<package>/copyright`.

| Component | In | Licence | Source |
|---|---|---|---|
| [rclone](https://rclone.org) | every image | MIT | [github.com/rclone/rclone](https://github.com/rclone/rclone) |
| [supercronic](https://github.com/aptible/supercronic) | every image | MIT | [github.com/aptible/supercronic](https://github.com/aptible/supercronic) |
| [tini](https://github.com/krallin/tini) (Debian's package) | every image | MIT | [github.com/krallin/tini](https://github.com/krallin/tini) |
| Debian packages (`curl`, `procps`, `zstd`, `tzdata`, `ca-certificates` and the rest of the base system) | every image | Each package's own, mostly GPL, LGPL, BSD and MIT | [sources.debian.org](https://sources.debian.org), or `apt-get source <package>` on Debian 13 |
| `sqlite3` (Debian's package) | `sqlite` | Public domain | [sqlite.org](https://sqlite.org/src) |
| PostgreSQL client programs (PostgreSQL's own package repository) | `postgres` | PostgreSQL Licence | [git.postgresql.org](https://git.postgresql.org/gitweb/?p=postgresql.git) |
| MariaDB client (Debian's `mariadb-client` package) | `mariadb` | GPL-2.0 | [github.com/MariaDB/server](https://github.com/MariaDB/server) |
| MySQL client (`mysql` and `mysqldump`, copied from the official `mysql` image) | `mysql` | GPL-2.0, with Oracle's Universal FOSS Exception | [github.com/mysql/mysql-server](https://github.com/mysql/mysql-server) |

The [Dockerfile](Dockerfile) pins rclone, supercronic and the MySQL client's source image. Everything else is the version that Debian 13 (trixie) or PostgreSQL's package repository held when the image was built.
