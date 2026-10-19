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
# other than BACKUP_TARGET and a leading dot would write a hidden object. It is also passed to the
# dump tool as an argument, where a leading hyphen would be read as an option.
require_object_name() {
  eval "SETTING_VALUE=\${${1}:-}"

  case "${SETTING_VALUE}" in
    */* | .* | -*) fatal "'${1}' must not contain '/' or start with '.' or '-', not '${SETTING_VALUE}'" ;;
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

# Exactly one of DATABASE_PASSWORD and DATABASE_PASSWORD_FILE must be set. A file is read here, so a
# missing or unreadable secret stops the container at start-up, and its contents replace
# DATABASE_PASSWORD. Command substitution drops the trailing newline that editors and `echo` leave, and
# a carriage return left by a file saved with Windows line endings is dropped too.
#
# The password ends up an ordinary shell variable even when the container's environment supplied it:
# rclone and every other child inherit exported variables, and only the dump tools may see the secret.
load_database_password() {
  if [ -n "${DATABASE_PASSWORD:-}" ] && [ -n "${DATABASE_PASSWORD_FILE:-}" ]
  then
    fatal "set one of 'DATABASE_PASSWORD' and 'DATABASE_PASSWORD_FILE', not both"
  fi

  if [ -n "${DATABASE_PASSWORD_FILE:-}" ]
  then
    [ -f "${DATABASE_PASSWORD_FILE}" ] && [ -r "${DATABASE_PASSWORD_FILE}" ] \
      || fatal "'DATABASE_PASSWORD_FILE' is not a readable file: '${DATABASE_PASSWORD_FILE}'"

    DATABASE_PASSWORD="$(cat "${DATABASE_PASSWORD_FILE}")" \
      || fatal "failed to read '${DATABASE_PASSWORD_FILE}'"
    DATABASE_PASSWORD="${DATABASE_PASSWORD%"$(printf '\r')"}"
    [ -n "${DATABASE_PASSWORD}" ] || fatal "'DATABASE_PASSWORD_FILE' is empty: '${DATABASE_PASSWORD_FILE}'"
  fi

  [ -n "${DATABASE_PASSWORD:-}" ] || fatal "set one of 'DATABASE_PASSWORD' and 'DATABASE_PASSWORD_FILE'"

  PASSWORD_TO_KEEP="${DATABASE_PASSWORD}"
  unset DATABASE_PASSWORD
  DATABASE_PASSWORD="${PASSWORD_TO_KEEP}"
  unset PASSWORD_TO_KEEP
}

# DATABASE_PORT is optional, so an empty value counts as unset. A set one must be a positive integer.
require_database_port() {
  case "${DATABASE_PORT:-}" in
    "") ;;
    *[!0-9]* | 0*) fatal "'DATABASE_PORT' must be a positive integer, not '${DATABASE_PORT}'" ;;
  esac
}

# DATABASE_TLS defaults to disabled. A CA file only means something when the server's certificate is
# verified, so naming one under another mode is a mistake worth stopping for, and naming one the
# container can't read would otherwise fail every run with the client's own message.
require_database_tls() {
  DATABASE_TLS="${DATABASE_TLS:-disabled}"

  case "${DATABASE_TLS}" in
    disabled | required | verify) ;;
    *) fatal "'DATABASE_TLS' must be 'disabled', 'required' or 'verify', not '${DATABASE_TLS}'" ;;
  esac

  if [ -n "${DATABASE_TLS_CA_PATH:-}" ] && [ "${DATABASE_TLS}" != "verify" ]
  then
    fatal "'DATABASE_TLS_CA_PATH' is only used when 'DATABASE_TLS' is 'verify', not '${DATABASE_TLS}'"
  fi

  if [ -n "${DATABASE_TLS_CA_PATH:-}" ]
  then
    [ -f "${DATABASE_TLS_CA_PATH}" ] && [ -r "${DATABASE_TLS_CA_PATH}" ] \
      || fatal "'DATABASE_TLS_CA_PATH' is not a readable file: '${DATABASE_TLS_CA_PATH}'"
  fi
}
