#!/bin/bash
# Off-device tests for connman_pmf v3: install.sh, rollback.sh and the boot service against a fake
# root with stubbed system commands. Needs an aarch64 Linux with libglib2.0-0, libdbus-1-3 and
# libxtables12 (the candidate's --version preflight really runs). See ../../VALIDATION.md.
#   STOCK_BIN=<Scarab /usr/sbin/connmand> V2_BIN=<v2 candidate cda54485...> bash tests/run.sh
set -u
UNIT=$(cd "$(dirname "$0")/.." && pwd)
: "${STOCK_BIN:?path to the stock Scarab connmand}" "${V2_BIN:?path to the v2 candidate}"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $*"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $*"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else no "$name"; fi; }
sha() { sha256sum "$1" | cut -d ' ' -f 1; }
CAND=a43f5ff1e9140fde0eab2db47ea3bea8d8d0962209256a19ea026e921d0f9928
STOCK=e83607dc10d2fa7638ca475bec973b36cb9b46b3a61ca0e0bc7f202dcf2375ef
V2=cda54485fe1de38838791b59589fa30d33b954c8e64b7800b28c14b6b3812697

setup() { # services
    T=$(mktemp -d); R=$T/root
    mkdir -p "$R/usr/sbin" "$R/etc/init.d" "$R/userdata/system/services" "$R/var/log" "$R/run" "$R/proc" "$T/bin"
    cp "$STOCK_BIN" "$R/usr/sbin/connmand"
    printf 'system.services=%s\nwifi.enabled=1\nwifi.ssid=example\n' "$1" >"$R/userdata/system/knulli.conf"
    touch "$R/run/route"
    # S08connman: "runs" whatever /usr/sbin/connmand is; fail flags simulate a broken daemon or no route.
    cat >"$R/etc/init.d/S08connman" <<EOF
#!/bin/bash
R=$R
rm -f \$R/proc/4242/exe \$R/run/pid
cp \$R/usr/sbin/connmand \$R/run/exe
s=\$(sha256sum \$R/run/exe | cut -d ' ' -f 1)
[ "\$s" = $CAND ] && [ -e \$R/run/fail-candidate ] && exit 0
mkdir -p \$R/proc/4242 && ln -s \$R/run/exe \$R/proc/4242/exe && echo 4242 >\$R/run/pid
if [ -e \$R/run/no-route-any ] || { [ "\$s" = $CAND ] && [ -e \$R/run/no-route-with-candidate ]; }; then rm -f \$R/run/route; else touch \$R/run/route; fi
EOF
    chmod +x "$R/etc/init.d/S08connman"
    "$R/etc/init.d/S08connman" reload
    cat >"$T/bin/pidof" <<EOF
#!/bin/sh
[ "\$1" = connmand ] && cat $R/run/pid 2>/dev/null
EOF
    cat >"$T/bin/ip" <<EOF
#!/bin/sh
[ -e $R/run/route ] && echo "default dev wlan0"
EOF
    cat >"$T/bin/curl" <<EOF
#!/bin/sh
for a; do last=\$a; done; echo "\$last" >>$R/notify.log
EOF
    printf '#!/bin/sh\nexit 0\n' >"$T/bin/udevadm"
    cat >"$T/bin/knulli-settings-get" <<EOF
#!/bin/sh
sed -n "s/^\$1=//p" $R/userdata/system/knulli.conf | tail -1
EOF
    cat >"$T/bin/knulli-settings-set" <<EOF
#!/bin/sh
grep -v "^\$1=" $R/userdata/system/knulli.conf >$R/kc.tmp; echo "\$1=\$2" >>$R/kc.tmp; mv $R/kc.tmp $R/userdata/system/knulli.conf
EOF
    chmod +x "$T/bin/"*
    export PATH="$T/bin:$PATH" KNULLI_TEST_ROOT=$R CONNMAN_PMF_ROUTE_WAIT=2
}
v2_state() { # what the console runs today
    mkdir -p "$R/userdata/system/patches/connman_pmf"
    cp "$STOCK_BIN" "$R/userdata/system/patches/connman_pmf/original-connmand"
    cp "$V2_BIN" "$R/userdata/system/patches/connman_pmf/connmand"
    # Stand-in for the v2 python manager: swap in the pinned build and restart.
    cat >"$R/userdata/system/services/connman_pmf" <<EOF
#!/bin/bash
[ "\$1" = start ] || exit 0
cp $R/userdata/system/patches/connman_pmf/connmand $R/usr/sbin/connmand && $R/etc/init.d/S08connman reload
echo v2 >$R/v2-started
EOF
    bash "$R/userdata/system/services/connman_pmf" start
}
svcs() { knulli-settings-get system.services; }
active() { sha "$R/proc/4242/exe" 2>/dev/null; }
teardown() { rm -rf "$T"; }
noticed() { for _ in $(seq 1 30); do grep -q "$1" "$R/notify.log" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

echo "# 1 fresh stock console"
setup "ssh"
bash "$UNIT/install.sh" >/dev/null
check "installed" grep -q '^state=installed' "$R/userdata/system/patches/connman_pmf/install-v3.result"
check "candidate running" [ "$(active)" = "$CAND" ]
check "stock kept for restore" [ "$(sha "$R/userdata/system/patches/connman_pmf/original-connmand")" = "$STOCK" ]
check "services" [ "$(svcs)" = "ssh connman_pmf" ]
echo "# 2 second run is a no-op"
bash "$UNIT/install.sh" >/dev/null
check "still installed" grep -q '^state=installed' "$R/userdata/system/patches/connman_pmf/install-v3.result"
check "services unchanged" [ "$(svcs)" = "ssh connman_pmf" ]
check "no v2 backup invented" [ ! -e "$R/userdata/system/patches/connman_pmf/v2-service.bak" ]
echo "# 3 next boot: stock binary again, service swaps it"
cp "$STOCK_BIN" "$R/usr/sbin/connmand"; "$R/etc/init.d/S08connman" reload
bash "$R/userdata/system/services/connman_pmf" start
check "candidate after boot" [ "$(active)" = "$CAND" ]
echo "# 4 rollback --stock keeps services added later"
knulli-settings-set system.services "$(svcs) ds_guard"
bash "$UNIT/rollback.sh" --stock >/dev/null
check "stock running" [ "$(active)" = "$STOCK" ]
check "only connman_pmf dropped" [ "$(svcs)" = "ssh ds_guard" ]
teardown

echo "# 5 upgrade from v2 (what the console runs now)"
setup "ssh connman_pmf brightness_persist connman_bluetooth btaudio"
v2_state; rm -f "$R/v2-started"
check "v2 running before" [ "$(active)" = "$V2" ]
bash "$UNIT/install.sh" >/dev/null
check "candidate running" [ "$(active)" = "$CAND" ]
check "services untouched (connman_bluetooth stays)" [ "$(svcs)" = "ssh connman_pmf brightness_persist connman_bluetooth btaudio" ]
check "v2 wrapper kept" grep -q 'echo v2' "$R/userdata/system/patches/connman_pmf/v2-service.bak"
check "v2 build left on the card" [ "$(sha "$R/userdata/system/patches/connman_pmf/connmand")" = "$V2" ]
echo "# 6 rollback to previous keeps services added later"
knulli-settings-set system.services "$(svcs) es_patched volume_persist"
bash "$UNIT/rollback.sh" >/dev/null
check "v2 running again" [ "$(active)" = "$V2" ]
check "v2 wrapper back" grep -q 'echo v2' "$R/userdata/system/services/connman_pmf"
check "services kept" [ "$(svcs)" = "ssh connman_pmf brightness_persist connman_bluetooth btaudio es_patched volume_persist" ]
teardown

echo "# 7 candidate crashes on start: service restores stock"
setup "ssh"; bash "$UNIT/install.sh" >/dev/null
cp "$STOCK_BIN" "$R/usr/sbin/connmand"; "$R/etc/init.d/S08connman" reload; touch "$R/run/fail-candidate"
bash "$R/userdata/system/services/connman_pmf" start; rc=$?
check "start reports failure" [ $rc -ne 0 ]
check "stock running" [ "$(active)" = "$STOCK" ]
check "notice sent" noticed 'stock ConnMan restored'
teardown

echo "# 8 install with a crashing candidate rolls back by itself (from v2)"
setup "ssh connman_pmf connman_bluetooth"; v2_state; touch "$R/run/fail-candidate"
bash "$UNIT/install.sh" >/dev/null; rc=$?
check "install fails" [ $rc -ne 0 ]
check "v2 running again" [ "$(active)" = "$V2" ]
check "services unchanged" [ "$(svcs)" = "ssh connman_pmf connman_bluetooth" ]
teardown

echo "# 9 candidate runs but the route never comes back: auto rollback"
setup "ssh"; touch "$R/run/no-route-with-candidate"
bash "$UNIT/install.sh" >/dev/null; rc=$?
check "install fails" [ $rc -ne 0 ]
check "reason recorded" grep -q 'no_default_route' "$R/userdata/system/patches/connman_pmf/install-v3.result"
check "stock running" [ "$(active)" = "$STOCK" ]
check "service dropped" [ "$(svcs)" = "ssh" ]
teardown

echo "# 10 firmware update: unknown stock binary is left alone"
setup "ssh"; bash "$UNIT/install.sh" >/dev/null
printf 'other firmware\n' >"$R/usr/sbin/connmand"; "$R/etc/init.d/S08connman" reload
before=$(active)
bash "$R/userdata/system/services/connman_pmf" start; rc=$?
check "start does not fail boot" [ $rc -eq 0 ]
check "binary untouched" [ "$(active)" = "$before" ]
check "notice sent" noticed 'different ConnMan'
check "install refuses" bash -c "! bash '$UNIT/install.sh' >/dev/null 2>&1"
teardown

echo "# 11 damaged candidate file: stock kept"
setup "ssh"; bash "$UNIT/install.sh" >/dev/null
cp "$STOCK_BIN" "$R/usr/sbin/connmand"; "$R/etc/init.d/S08connman" reload
echo x >>"$R/userdata/system/patches/connman_pmf/connmand-generic"
bash "$R/userdata/system/services/connman_pmf" start; rc=$?
check "start refuses" [ $rc -ne 0 ]
check "stock running" [ "$(active)" = "$STOCK" ]
teardown

boot() { cp "$STOCK_BIN" "$R/usr/sbin/connmand"; "$R/etc/init.d/S08connman" reload; rm -f "$R/notify.log"; bash "$R/userdata/system/services/connman_pmf" start; }
echo "# 12 boot: candidate crashes, v2 on the card -> v2 (not stock)"
setup "ssh connman_pmf connman_bluetooth"; v2_state; bash "$UNIT/install.sh" >/dev/null
touch "$R/run/fail-candidate"; boot; rc=$?
check "reports fallback" [ $rc -ne 0 ]
check "v2 running" [ "$(active)" = "$V2" ]
check "route up" [ -e "$R/run/route" ]
check "notice" noticed 'using the previous build'
rm -f "$R/run/fail-candidate"
echo "# 13 boot: candidate runs but gets no route, v2 connects -> v2"
touch "$R/run/no-route-with-candidate"; boot
check "v2 running" [ "$(active)" = "$V2" ]
check "notice" noticed 'previous build connected'
rm -f "$R/run/no-route-with-candidate"
echo "# 14 boot: nothing connects (out of range) -> generic build kept"
touch "$R/run/no-route-any"; boot; rc=$?
check "start ok" [ $rc -eq 0 ]
check "candidate running" [ "$(active)" = "$CAND" ]
echo "# 15 boot: Wi-Fi off -> no route wait, candidate kept"
knulli-settings-set wifi.enabled 0; s0=$(date +%s); boot; rc=$?
check "candidate running" [ "$(active)" = "$CAND" ]
check "did not wait for a route" [ $(( $(date +%s) - s0 )) -lt 2 ]
teardown
echo "# 16 boot: candidate crashes, no v2 -> stock"
setup "ssh"; bash "$UNIT/install.sh" >/dev/null; touch "$R/run/fail-candidate"; boot
check "stock running" [ "$(active)" = "$STOCK" ]
teardown

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
