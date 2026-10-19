# Helpers for the test scripts. Source this file; it expects the caller to run with `set -eu`.

# Runs a test and prints one TAP-style line, stopping the whole run on the first failure.
check() {
  CHECK_DESCRIPTION="$1"
  shift

  if "$@"
  then
    echo "ok - ${CHECK_DESCRIPTION}"
  else
    echo "not ok - ${CHECK_DESCRIPTION}" >&2
    exit 1
  fi
}

# Runs a throwaway container under the settings in the README's "The hardening baseline" section.
# HARDENED_TMPFS_SIZE resizes /tmp for tests that fill it; passing a second --tmpfs for /tmp would
# be a conflict.
hardened_run() {
  docker run \
    --rm \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --tmpfs "/tmp:rw,nodev,noexec,nosuid,size=${HARDENED_TMPFS_SIZE:-512m}" \
    "$@"
}

# Retries a command once a second for up to the given number of seconds.
wait_for_up_to() {
  WAIT_SECONDS="$1"
  shift

  ATTEMPT=1
  while [ "${ATTEMPT}" -le "${WAIT_SECONDS}" ]
  do
    "$@" && return 0

    sleep 1
    ATTEMPT=$((ATTEMPT + 1))
  done

  return 1
}

# Retries a command once a second for up to 30 seconds.
wait_for() {
  wait_for_up_to 30 "$@"
}

# Retries a command for up to 75 seconds, which covers the wait for a schedule's next minute.
wait_for_next_minute() {
  wait_for_up_to 75 "$@"
}

# Creates WORK_DIR, a temporary directory that any uid can write to, and LOG_FILE inside it, and
# removes the directory on exit. The containers run as 1000 or 65532 while the host user is whoever
# runs the tests (1001 on a Linux runner), so every directory a container writes into must be
# world-writable, and what the containers leave behind must be removed from inside one.
make_work_dir() {
  WORK_IMAGE="$1"
  WORK_DIR="$(mktemp -d)"
  LOG_FILE="${WORK_DIR}/output.log"

  chmod 0777 "${WORK_DIR}"
  trap remove_work_dir EXIT
}

# Deletes what lies at least MINIMUM_DEPTH levels below WORK_DIR, as root, since the containers'
# uids own it. Reports failure on stderr.
delete_in_work_dir() {
  docker run --rm --network none --user 0:0 --entrypoint find -v "${WORK_DIR}:/work" "${WORK_IMAGE}" \
    /work -mindepth "$1" -delete
}

# Empties every directory directly under WORK_DIR but keeps the directories and LOG_FILE.
empty_work_subdirectories() {
  delete_in_work_dir 2
}

# Removes WORK_DIR, and says so when that fails. Exits with the status the script was already exiting
# with (or the one passed in), or 1 when the removal failed.
remove_work_dir() {
  EXIT_STATUS="${1:-$?}"

  stop_fake_monitor

  if ! delete_in_work_dir 1
  then
    echo "warning: could not empty ${WORK_DIR}" >&2
    EXIT_STATUS=1
  fi

  if ! rm -rf "${WORK_DIR}"
  then
    echo "warning: could not remove ${WORK_DIR}" >&2
    EXIT_STATUS=1
  fi

  exit "${EXIT_STATUS}"
}

# The fake monitor's container name. Backup containers on its network reach it at this name, on
# port 8080.
FAKE_MONITOR_NAME="fake-monitor-$$"

# Starts a fake heartbeat monitor on the user-defined network NETWORK, replacing any earlier one. It
# answers every request with 200 and appends it, headers and body, to /tmp/requests. It is a separate
# container because the images carry no nc. nc serves one connection at a time, and the monitor
# wrapper retries a refused connection, which covers the moment between two listens. TEST_DIR names
# the directory holding test/servers.
start_fake_monitor() {
  stop_fake_monitor

  docker run --detach --name "${FAKE_MONITOR_NAME}" --network "$1" \
    "$(grep '^alpine:' "${TEST_DIR}/servers")" sh -c '
    : > /tmp/requests

    while true
    do
      printf "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" | nc -l -p 8080 >> /tmp/requests
    done
  ' > /dev/null
}

stop_fake_monitor() {
  docker rm --force "${FAKE_MONITOR_NAME}" > /dev/null 2>&1 || true
}

monitor_requests() {
  docker exec "${FAKE_MONITOR_NAME}" cat /tmp/requests
}

monitor_has_request() {
  monitor_requests | grep -q -- "$1"
}

# Writes an executable script at PATH that appends its own environment, which is the environment
# rclone would inherit, to /tmp/rclone-environment and then runs the real rclone. Mounting it at
# /usr/local/sbin/rclone puts it ahead of the real binary on the image's PATH, so the job's every
# rclone call goes through it.
write_rclone_environment_recorder() {
  cat > "$1" <<'RECORDER'
#!/bin/sh
env >> /tmp/rclone-environment
exec /usr/local/bin/rclone "$@"
RECORDER

  chmod 0755 "$1"
}

# Wraps a check function so the output saved in LOG_FILE is shown when it fails.
with_log() {
  "$@" && return 0

  cat "${LOG_FILE}" >&2
  return 1
}
