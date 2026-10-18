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

# Runs a throwaway container under the hardening baseline from the README. HARDENED_TMPFS_SIZE
# resizes /tmp for tests that fill it; passing a second --tmpfs for /tmp would be a conflict.
hardened_run() {
  docker run \
    --rm \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --tmpfs "/tmp:rw,nodev,noexec,nosuid,size=${HARDENED_TMPFS_SIZE:-512m}" \
    "$@"
}

# Retries a command once a second for up to 30 seconds.
wait_for() {
  ATTEMPT=1
  while [ "${ATTEMPT}" -le 30 ]
  do
    "$@" && return 0

    sleep 1
    ATTEMPT=$((ATTEMPT + 1))
  done

  return 1
}
