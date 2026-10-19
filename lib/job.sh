# Helpers shared by the job scripts in /usr/local/bin. Source after log.sh.

# At most one run at a time: the lock is held for as long as this process, or any child that inherits
# file descriptor 9, is alive. /tmp is the only place the read-only image can write.
acquire_run_lock() {
  exec 9> /tmp/rclone-backup.lock
  flock -x -n 9 || fatal "another backup is already running"
}

# Creates a private working directory for the run's staged files, in STAGING_DIRECTORY. It is removed
# on every exit path, including a stop: the TERM trap turns the signal into a normal exit so the EXIT
# trap still runs, and the conventional 143 reaches the monitor wrapper as the run's status.
open_staging_directory() {
  STAGING_DIRECTORY="$(mktemp -d "${BACKUP_STAGING_PATH:-/tmp}/rclone-backup.XXXXXX")" \
    || fatal "failed to create a staging directory under '${BACKUP_STAGING_PATH:-/tmp}'"

  trap 'rm -rf "${STAGING_DIRECTORY}"' EXIT
  trap 'exit 143' TERM
}

# Copies one staged file to BACKUP_TARGET as OBJECT_NAME. The object name is appended directly to a
# target that ends in `/` or `:`, and joined with a slash otherwise, so `b2:bucket/app/` and
# `b2:bucket/app` both give `b2:bucket/app/<name>`. A target ending in `:` is a bare remote, where
# `sftp:name` addresses the remote's own root and `sftp:/name` the filesystem root, so the slash
# is never added or removed there.
#
# Where the target can report a hash, an object whose checksum matches is left alone, so an unchanged
# dump adds no version to the bucket. A target that reports none (a crypt remote, for one) would make
# rclone compare sizes and modification times instead and skip a changed file of the same size, so
# there the file is uploaded on every run.
upload_staged_file() {
  UPLOAD_SOURCE_PATH="$1"
  UPLOAD_OBJECT_NAME="$2"

  case "${BACKUP_TARGET}" in
    */ | *:) UPLOAD_DESTINATION="${BACKUP_TARGET}${UPLOAD_OBJECT_NAME}" ;;
    *) UPLOAD_DESTINATION="${BACKUP_TARGET}/${UPLOAD_OBJECT_NAME}" ;;
  esac

  TARGET_FEATURES="$(rclone backend features "${BACKUP_TARGET}")" \
    || fatal "failed to read the features of ${BACKUP_TARGET}"

  # grep reads all of its input, because under pipefail a `grep -q` that exits at the first match can
  # leave printf or tr with a broken pipe, which would turn a match into a failed pipeline.
  if printf '%s' "${TARGET_FEATURES}" | tr -d ' \t\n' | grep '"Hashes":\["' > /dev/null
  then
    info "uploading ${UPLOAD_DESTINATION}, skipping it if the target already holds the same checksum"
    rclone copyto --checksum "${UPLOAD_SOURCE_PATH}" "${UPLOAD_DESTINATION}" \
      || fatal "failed to upload ${UPLOAD_DESTINATION}"
  else
    info "uploading ${UPLOAD_DESTINATION}, which the target cannot compare by checksum, so every run uploads"
    rclone copyto --ignore-times "${UPLOAD_SOURCE_PATH}" "${UPLOAD_DESTINATION}" \
      || fatal "failed to upload ${UPLOAD_DESTINATION}"
  fi
}

# Logs each line that TOOL_NAME wrote to the file STDERR_PATH as a warning, and stops the run when any
# line mentions an error. A tool such as mysqldump can print `Error: ...` and still exit 0, so its
# exit status alone doesn't prove the dump is whole.
fail_on_error_lines() {
  ERROR_SCAN_PATH="$1"
  ERROR_SCAN_TOOL_NAME="$2"
  ERROR_LINE_FOUND=false

  while IFS= read -r ERROR_SCAN_LINE || [ -n "${ERROR_SCAN_LINE}" ]
  do
    warn "${ERROR_SCAN_LINE}"

    case "${ERROR_SCAN_LINE}" in
      *[Ee][Rr][Rr][Oo][Rr]*) ERROR_LINE_FOUND=true ;;
    esac
  done < "${ERROR_SCAN_PATH}"

  [ "${ERROR_LINE_FOUND}" = false ] || fatal "${ERROR_SCAN_TOOL_NAME} reported an error, so the dump can't be trusted"
}
