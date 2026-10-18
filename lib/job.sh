# Helpers shared by the job scripts in /usr/local/bin. Source after log.sh.

# At most one run at a time: the lock is held for as long as this process, or any child that inherits
# file descriptor 9, is alive. /tmp is the only place the read-only image can write.
acquire_run_lock() {
  exec 9> /tmp/rclone-backup.lock
  flock -x -n 9 || fatal "another backup is already running"
}
