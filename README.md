# docker-rclone-backup

Hardened, shell-only images that back up a PostgreSQL, MariaDB or MySQL database, a SQLite database or a directory of files to any rclone remote on a cron schedule. Each image runs as a non-root user on a read-only root filesystem, and reports to a heartbeat monitor if you give it one.

## Settings every image shares

| Variable | Description |
|---|---|
| `BACKUP_SCHEDULE` | When to run: a five-field cron schedule (`0 3 * * *`), a macro such as `@daily` or `@hourly`, or `disabled` to keep the container running with nothing scheduled. Defaults to `0 0 * * *`. Seven-field schedules with seconds are accepted too, and `@reboot` is not |
| `BACKUP_TARGET` | The rclone remote and path that receives the backup (`b2:my-bucket/app`), or an absolute path inside the container |
| `TZ` | The time zone the schedule and the log timestamps follow, for example `Europe/London`. Defaults to UTC |

Any rclone flag can be set through the environment by upper-casing its name, replacing hyphens with underscores and adding the `RCLONE_` prefix: `--max-delete 100` becomes `RCLONE_MAX_DELETE=100`. A remote needs no config file: `RCLONE_CONFIG_B2_TYPE`, `RCLONE_CONFIG_B2_ACCOUNT` and `RCLONE_CONFIG_B2_KEY` define one called `b2`. To use a config file instead, mount it and point `RCLONE_CONFIG` at it.

- **The container checks its settings when it starts.** A bad schedule, a missing or malformed required setting, or any variable beginning `BACKUP_`, `MONITOR_`, `DATABASE_` or `SQLITE_` that the image doesn't read (a typo, or a setting that belongs to another image) stops the container with a message naming it, rather than failing at the first run. Variables with any other name are ignored.
- **One run at a time.** A run that starts while another is still going is refused and logged. A scheduled run that would overlap is skipped the same way.
- **Stopping the container stops the run.** `docker stop` signals the running backup so that it can clean up, and the container then exits with 143. Set `stop_grace_period` to `2m` so a large run has time to finish stopping.

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

## Licence

This project is licensed under the Apache-2.0 License - see the LICENSE file for details.
