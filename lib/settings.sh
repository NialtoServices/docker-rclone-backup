# Setting validation shared by the job scripts and bin/start. Source after log.sh: every helper reports
# through fatal, so a bad setting stops the script with one line naming it.

# Stops at the first named setting that is empty or unset.
require_settings() {
  for SETTING_NAME in "$@"
  do
    eval "SETTING_VALUE=\${${SETTING_NAME}:-}"
    [ -n "${SETTING_VALUE}" ] || fatal "'${SETTING_NAME}' is not set"
  done
}

# A relative path resolves against the working directory, which differs between scheduled and manual
# runs, and always lands inside the container's own filesystem.
require_location() {
  eval "SETTING_VALUE=\${${1}:-}"

  case "${SETTING_VALUE%%/*}" in
    *:* | "") ;;
    *) fatal "'${1}' must be an rclone remote (remote:path) or an absolute path, not '${SETTING_VALUE}'" ;;
  esac
}

# The name becomes the last segment of the uploaded object's path, so a slash would write somewhere
# other than BACKUP_TARGET and a leading dot would write a hidden object.
require_object_name() {
  eval "SETTING_VALUE=\${${1}:-}"

  case "${SETTING_VALUE}" in
    */* | .*) fatal "'${1}' must not contain '/' or start with '.', not '${SETTING_VALUE}'" ;;
  esac
}

# Stops when the environment holds a setting under this project's prefixes that neither the caller nor
# the shared list names, so a typo fails at start-up instead of being silently ignored. Variables with
# any other prefix, such as RCLONE_ and TZ, are never examined.
refuse_unknown_settings() {
  KNOWN_SETTINGS=" $* BACKUP_SCHEDULE BACKUP_TARGET MONITOR_START_URL MONITOR_SUCCESS_URL MONITOR_FAILURE_URL "
  UNKNOWN_SETTINGS=""

  # env -0 separates entries with NUL, so a newline inside a value can't pass for a variable name.
  for SETTING_NAME in $(env -0 | tr '\0\n' '\n ' | sed -n 's/^\(\(BACKUP\|MONITOR\|DATABASE\|SQLITE\)_[A-Za-z0-9_]*\)=.*/\1/p' | sort)
  do
    case "${KNOWN_SETTINGS}" in
      *" ${SETTING_NAME} "*) continue ;;
    esac

    UNKNOWN_SETTINGS="${UNKNOWN_SETTINGS:+${UNKNOWN_SETTINGS}, }${SETTING_NAME}"
  done

  [ -z "${UNKNOWN_SETTINGS}" ] || fatal "unknown settings: ${UNKNOWN_SETTINGS}"
}
