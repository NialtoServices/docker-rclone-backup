# docker-rclone-backup

Hardened, shell-only images that back up a PostgreSQL, MariaDB or MySQL database, a SQLite database or a directory of files to any rclone remote on a cron schedule. Each image runs as a non-root user on a read-only root filesystem, and reports to a heartbeat monitor if you give it one.

## Settings every image shares

| Variable | Description |
|---|---|
| `BACKUP_SCHEDULE` | When to run: a five-field cron schedule (`0 3 * * *`), a macro such as `@daily` or `@hourly`, or `disabled` to keep the container running with nothing scheduled. Defaults to `0 0 * * *`. Seven-field schedules with seconds are accepted too, and `@reboot` is not |
| `BACKUP_TARGET` | The rclone remote and path that receives the backup (`b2:my-bucket/app`), or an absolute path inside the container |
| `TZ` | The time zone the schedule and the log timestamps follow, for example `Europe/London`. Defaults to UTC |
| `MONITOR_START_URL`, `MONITOR_SUCCESS_URL`, `MONITOR_FAILURE_URL` | Heartbeat monitor URLs, all optional; see [Monitoring](#monitoring) |

Any rclone flag can be set through the environment by upper-casing its name, replacing hyphens with underscores and adding the `RCLONE_` prefix: `--max-delete 100` becomes `RCLONE_MAX_DELETE=100`. A remote needs no config file: `RCLONE_CONFIG_B2_TYPE`, `RCLONE_CONFIG_B2_ACCOUNT` and `RCLONE_CONFIG_B2_KEY` define one called `b2`. To use a config file instead, mount it and point `RCLONE_CONFIG` at it.

- **The container checks its settings when it starts.** A bad schedule, a missing or malformed required setting, or any variable beginning `BACKUP_`, `MONITOR_`, `DATABASE_` or `SQLITE_` that the image doesn't read (a typo, or a setting that belongs to another image) stops the container with a message naming it, rather than failing at the first run. Variables with any other name are ignored.
- **One run at a time.** A run that starts while another is still going is refused and logged. A scheduled run that would overlap is skipped the same way.

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

## Files

The `files` image mirrors one directory, or one rclone remote path, to the target with `rclone sync`. The target ends up as a copy of the source, so keep history by pointing the target at a bucket with versioning enabled.

> **`rclone sync` is destructive.** Files deleted at the source are also deleted at the target on the next run. All recoverability of deleted or overwritten files lives at the target, in the bucket's versioning, and not in this container.
>
> An empty source is mirrored like any other: if the source is empty when a run starts (for example, because a volume failed to mount), everything at the target is deleted and the run still succeeds. To make a run like that fail instead, cap the number of deletions per run with `RCLONE_MAX_DELETE`. The run stops once the cap is reached and exits with an error.

| Variable | Description |
|---|---|
| `BACKUP_SOURCE` | Where to copy from: an rclone remote and path (`b2:my-source-bucket`), or an absolute path inside the container (a mounted volume at `/source`) |
| `BACKUP_TARGET` | Where to copy to, in the same forms |

A relative path is refused, because it would resolve inside the container's own filesystem.

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
```

### Root mode

When the source holds files with different owners, no single uid can read them all. Run as root and add back the one capability that reads without write access:

```yaml
    user: "0:0"
    cap_add: [DAC_READ_SEARCH]
```

Capabilities only take effect for root, and root inside a container is a larger target than an unprivileged uid, so prefer the owner's uid where one will do.

## SQLite

The `sqlite` image takes a consistent snapshot of one SQLite database with `VACUUM INTO` while the application keeps running, checks it with `PRAGMA integrity_check`, compresses it with zstd and uploads it to the target as `<file name>.zst` (`app.db.zst` for `/data/app.db`). The database file is never copied directly, which would capture a torn state of a database that is being written. A snapshot that fails its check is not uploaded, and the run fails.

| Variable | Description |
|---|---|
| `SQLITE_DATABASE` | The absolute path of the database file inside the container. It must be the file's real path: a path that is, or lies under, a symlink is refused, so the file backed up is always the one configured |
| `BACKUP_TARGET` | Where to upload the snapshot: an rclone remote and path (`b2:my-bucket/app`), or an absolute path inside the container |
| `BACKUP_STAGING_PATH` | Where the snapshot is written before it is uploaded. Defaults to `/tmp`, which is held in memory under the settings below, so a database larger than the `/tmp` tmpfs needs a volume here. The staged file is deleted after every run |

- **Versioning is the history.** Each upload replaces the object at the target, so keep older snapshots by pointing the target at a bucket with versioning enabled, and set lifecycle rules there. Rules such as B2's "keep only the last version" make old versions vanish within a day.
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
```

### Root mode

When the application's uid can't be matched, run as root and add back exactly two capabilities. `DAC_OVERRIDE` lets root open a database it doesn't own, and `CHOWN` lets SQLite give the `-wal` and `-shm` files it creates the database's owner:

```yaml
    user: "0:0"
    cap_add: [DAC_OVERRIDE, CHOWN]
```

**Never add `DAC_OVERRIDE` without `CHOWN`.** Without `CHOWN`, those files are created owned by root, and an application running as another uid can then no longer open its own database's WAL, which breaks the application until the files are removed. Capabilities only take effect for root, and root inside a container is a larger target than an unprivileged uid, so prefer the application's uid where one will do.

### Restoring

Download the object from the target, then decompress it and check it. The result is an ordinary SQLite database file, and neither step needs this image:

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
| `DATABASE_NAME` | The database to dump. It becomes the object's name, so it must not contain `/` or start with `.` |
| `DATABASE_TLS` | `disabled` (the default), `required` or `verify`. `required` encrypts the connection without checking the server's certificate; `verify` also checks that the certificate is trusted and names the host. Set `required` or `verify` for a managed database or any server across an untrusted network |
| `DATABASE_TLS_CA_PATH` | With `verify`, the path of the certificate authority file to trust, for a private CA; it must be a readable file. Without it the operating system's CA certificates are used. Refused with any other `DATABASE_TLS` value |
| `BACKUP_TARGET` | Where to upload the dump: an rclone remote and path (`b2:my-bucket/app`), or an absolute path inside the container |
| `BACKUP_STAGING_PATH` | Where the dump is written before it is uploaded. Defaults to `/tmp`, which is held in memory under the settings below, so a dump larger than the `/tmp` tmpfs fails the run, uploads nothing and leaves nothing behind; a volume here avoids that. The staged file is deleted after every run |

Passwords with any characters work, and the password reaches `pg_dump` through its environment, never its arguments. Neither it nor any other connection detail is passed on to rclone.

- **Versioning is the history.** Each upload replaces the object at the target, so keep older dumps by pointing the target at a bucket with versioning enabled, and set lifecycle rules there. Rules such as B2's "keep only the last version" make old versions vanish within a day.
- **Every run adds a version.** A custom-format archive records when it was created, so two dumps of an unchanged database differ and the checksum comparison never finds a match.
- **A migration can stop a run.** `pg_dump` waits up to a minute for the locks it needs, so a migration holding an exclusive lock for longer than that fails the run, which the monitor reports, instead of the dump waiting until the next schedule.
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
```

### Restoring

Download the object from the target, create an empty database and restore into it with the `pg_restore` of the **server's own major**. A newer `pg_restore` can't restore into an older server: PostgreSQL 18's, for one, sends a setting that servers 14 to 16 don't know. The `postgres` image of your server's version has the right one:

```sh
createdb --username postgres restored
pg_restore --username postgres --dbname restored --exit-on-error app.dump
```

Add `--no-owner` if the roles that owned the objects don't exist on the server you restore to, and `--no-acl` to skip the grants. A trusted extension in the dump is created as the restoring role, so restore with a role that may create it.

## Licence

This project is licensed under the Apache-2.0 License - see the LICENSE file for details.
