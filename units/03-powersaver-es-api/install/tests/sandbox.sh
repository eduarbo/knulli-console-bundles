# Sourced by the install tests: a fake device root for install.sh/rollback.sh.
# new_root <file>... where each file is "<device path>=<fixture>" copied in.
# Stubs: knulli-settings-get/set (-f FILE), mount --bind / umount (copy the
# source over the target and record it in proc/mounts), flock (macOS only),
# curl (recorded), sync.
new_root() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/unitroot.XXXXXX")
  STUB="$ROOT.stub"; mkdir -p "$STUB"
  mkdir -p "$ROOT/proc/device-tree" "$ROOT/usr/share/knulli" "$ROOT/userdata/system/services" "$ROOT/usr/bin" "$ROOT/etc" "$ROOT/var/run"
  printf 'Anbernic RG35XX-H\000' > "$ROOT/proc/device-tree/model"
  echo 'scarab 2026/05/11 00:09' > "$ROOT/usr/share/knulli/knulli.version"
  : > "$ROOT/proc/mounts"
  printf 'system.hostname=KNULLI\nsystem.services=connman_pmf brightness_persist romm_autosync\nwifi.enabled=1\n' > "$ROOT/userdata/system/knulli.conf"
  for spec in "$@"; do
    mkdir -p "$ROOT$(dirname "${spec%%=*}")"; cp "${spec#*=}" "$ROOT${spec%%=*}"; chmod 755 "$ROOT${spec%%=*}"
  done
  cat > "$STUB/knulli-settings-get" <<'S'
#!/bin/sh
[ "$1" = -f ] && { f=$2; shift 2; }
v=$(grep "^$1=" "$f" | tail -1) || exit 1
printf '%s\n' "${v#*=}"
S
  cat > "$STUB/knulli-settings-set" <<'S'
#!/bin/sh
[ "$1" = -f ] && { f=$2; shift 2; }
if grep -q "^$1=" "$f"; then
  awk -v k="$1" -v v="$2" 'index($0, k "=") == 1 { print k "=" v; next } { print }' "$f" > "$f.t" && mv "$f.t" "$f"
else
  printf '%s=%s\n' "$1" "$2" >> "$f"
fi
S
  cat > "$STUB/mount" <<S
#!/bin/sh
[ "\$1" = --bind ] || exit 1
grep -q " \${3#$ROOT} " "$ROOT/proc/mounts" || cp -p "\$3" "\$3.under"
cp "\$2" "\$3"; echo "none \${3#$ROOT} squashfs rw 0 0" >> "$ROOT/proc/mounts"
S
  cat > "$STUB/umount" <<S
#!/bin/sh
grep -q " \${1#$ROOT} " "$ROOT/proc/mounts" || exit 1
grep -v " \${1#$ROOT} " "$ROOT/proc/mounts" > "$ROOT/proc/mounts.t"; mv "$ROOT/proc/mounts.t" "$ROOT/proc/mounts"
grep -q " \${1#$ROOT} " "$ROOT/proc/mounts" || { cp -p "\$1.under" "\$1"; rm -f "\$1.under"; }
S
  # Real flock where it exists (Linux); macOS has none
  command -v flock >/dev/null 2>&1 || printf '#!/bin/sh\nexit 0\n' > "$STUB/flock"
  # ES /notify calls are recorded in $ROOT.calls
  printf '#!/bin/sh\necho "curl $*" >> %s.calls\nexit 0\n' "$ROOT" > "$STUB/curl"
  printf '#!/bin/sh\nexit 0\n' > "$STUB/sync"
  chmod +x "$STUB"/*
  export UNIT_ROOT="$ROOT" PATH="$STUB:$PATH"
}

drop_root() {
  rm -rf "$ROOT" "$ROOT.stub" "$ROOT.calls"
  unset UNIT_ROOT
}

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $*"; }
ko() { fail=$((fail+1)); echo "FAIL $*"; }
expect() {  # expect <name> <command...>
  name=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else ko "$name"; fi
}
sha_of() { sha256sum "$1" | cut -d ' ' -f 1; }
