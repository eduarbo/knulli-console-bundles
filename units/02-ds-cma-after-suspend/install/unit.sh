# Shared helpers for the install.sh / rollback.sh of a Knulli device unit.
# Sourced, POSIX sh (dash on Knulli). UNIT_ROOT prefixes every absolute path
# for the off-device tests; it is unset on the device.
R="${UNIT_ROOT:-}"
CONF="$R/userdata/system/knulli.conf"
SERVICES_DIR="$R/userdata/system/services"
PATCHES_DIR="$R/userdata/system/patches"
BACKUP_DIR="$PATCHES_DIR/backups/"
# Shared with the knulli-settings-set binary
SETTINGS_LOCK="$R/var/run/knulli-settings-set.lock"
DEVICE_MODEL='Anbernic RG35XX-H'
FIRMWARE='scarab 2026/05/11 00:09'

fail() {
  echo "${UNIT_NAME:-unit}: FAILED: $*"
  exit 1
}

say() {
  echo "${UNIT_NAME:-unit}: $*"
}

sha() {
  sha256sum "$1" 2>/dev/null | cut -d ' ' -f 1
}

check_device() {
  [ "$(tr -d '\000' < "$R/proc/device-tree/model" 2>/dev/null)" = "$DEVICE_MODEL" ] || fail "not an $DEVICE_MODEL"
  [ "$(cat "$R/usr/share/knulli/knulli.version" 2>/dev/null)" = "$FIRMWARE" ] || fail "firmware is not $FIRMWARE"
  [ -f "$CONF" ] && [ ! -L "$CONF" ] || fail "missing $CONF"
}

# install_file <source> <destination> <mode> <sha256>: atomic, idempotent
install_file() {
  [ "$(sha "$1")" = "$4" ] || fail "source changed: $1"
  if [ -f "$2" ] && [ ! -L "$2" ] && [ "$(sha "$2")" = "$4" ]; then
    chmod "$3" "$2"
    return 0
  fi
  [ ! -e "$2" ] || [ -f "$2" ] || fail "not a regular file: $2"
  if [ -f "$2" ]; then
    # Backups go elsewhere: every executable in scripts/ runs as a game hook
    backup="$BACKUP_DIR$(echo "${2#$R}" | tr / _).$(date +%Y%m%d%H%M%S)"
    mkdir -p "$BACKUP_DIR" && cp -p "$2" "$backup" && chmod a-x "$backup" || fail "backup of $2"
  fi
  cp "$1" "$2.tmp" && chmod "$3" "$2.tmp" && mv -f "$2.tmp" "$2" || fail "copy to $2"
  [ "$(sha "$2")" = "$4" ] || fail "readback of $2"
}

conf_get() {
  knulli-settings-get -f "$CONF" "$1" 2>/dev/null || true
}

conf_has() {
  grep -q "^$1=" "$CONF" 2>/dev/null
}

conf_set() {
  knulli-settings-set -f "$CONF" "$1" "$2" || fail "setting $1"
  [ "$(conf_get "$1")" = "$2" ] || fail "readback of $1"
}

# knulli-settings-set has no delete; edit under its own lock file
conf_remove() {
  conf_has "$1" || return 0
  (
    flock -w 10 8 || exit 1
    awk -v key="$1" 'index($0, key "=") != 1' "$CONF" > "$CONF.tmp" || exit 1
    chmod --reference="$CONF" "$CONF.tmp" 2>/dev/null
    mv -f "$CONF.tmp" "$CONF"
  ) 8> "$SETTINGS_LOCK" || fail "removing $1"
  ! conf_has "$1" || fail "readback of removing $1"
}

# One copy of knulli.conf from before the first install of this unit
backup_conf() {
  [ -e "$CONF.bak-$UNIT_NAME" ] || cp -p "$CONF" "$CONF.bak-$UNIT_NAME" || fail "backup of knulli.conf"
}

# remember_setting <state file> <key>: first value seen, or absent
remember_setting() {
  grep -q "^$2	" "$1" 2>/dev/null && return 0
  if conf_has "$2"; then
    printf '%s\tpresent\t%s\n' "$2" "$(conf_get "$2")" >> "$1"
  else
    printf '%s\tabsent\t\n' "$2" >> "$1"
  fi
}

# set_default <state file> <key> <value>: only when the key is not set
set_default() {
  remember_setting "$1" "$2"
  conf_has "$2" || conf_set "$2" "$3"
}

# restore_setting <state file> <key> <installed value>: undo set_default
# unless the owner changed the value since
restore_setting() {
  line=$(grep "^$2	" "$1" 2>/dev/null) || return 0
  [ "$(conf_get "$2")" = "$3" ] || return 0
  case "$line" in
    *"	absent	"*) conf_remove "$2" ;;
    *) conf_set "$2" "${line##*	}" ;;
  esac
}

services_add() {
  current=$(conf_get system.services)
  case " $current " in *" $1 "*) return 0 ;; esac
  conf_set system.services "$(echo $current $1)"
}

services_remove() {
  current=$(conf_get system.services)
  case " $current " in *" $1 "*) ;; *) return 0 ;; esac
  rest=""
  for s in $current; do [ "$s" = "$1" ] || rest="$rest $s"; done
  conf_set system.services "$(echo $rest)"
}

# Bound files: a bind mount shows up in /proc/mounts at the target path
is_mounted() {
  grep -q " ${1#$R} " "$R/proc/mounts" 2>/dev/null
}
