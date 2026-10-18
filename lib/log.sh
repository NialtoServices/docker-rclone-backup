# Log helpers shared by the scripts in /usr/local/bin. Each line names the script that sourced this
# file, so interleaved output from the scheduler and its jobs stays attributable.

info() {
  echo "$(basename "$0") [$(date +'%Y-%m-%d %H:%M:%S %Z')]  INFO: $*" >&2
}

warn() {
  echo "$(basename "$0") [$(date +'%Y-%m-%d %H:%M:%S %Z')]  WARN: $*" >&2
}

fatal() {
  echo "$(basename "$0") [$(date +'%Y-%m-%d %H:%M:%S %Z')] FATAL: $*" >&2
  exit 1
}
