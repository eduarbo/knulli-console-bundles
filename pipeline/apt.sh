# shellcheck shell=bash
# Sourced inside the build containers: apt from one snapshot.debian.org date when
# DEBIAN_SNAPSHOT is set (same packages on every run), and apt failures reported as
# infrastructure failures (exit INFRA_EXIT), not as a unit's failure.
export DEBIAN_FRONTEND=noninteractive
apt_install() {
	if [ -n "${DEBIAN_SNAPSHOT:-}" ]; then
		rm -f /etc/apt/sources.list.d/debian.sources
		printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s bookworm main\ndeb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s bookworm-updates main\ndeb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/%s bookworm-security main\n' \
			"$DEBIAN_SNAPSHOT" "$DEBIAN_SNAPSHOT" "$DEBIAN_SNAPSHOT" > /etc/apt/sources.list
	fi
	local i
	for i in 1 2 3; do
		apt-get -o Acquire::Retries=3 update -qq > /tmp/apt.log 2>&1 &&
			apt-get -o Acquire::Retries=3 install -y -qq --no-install-recommends "$@" >> /tmp/apt.log 2>&1 && return 0
		sleep $((i * 10))
	done
	echo "apt failed (infrastructure):"; tail -5 /tmp/apt.log
	exit "${INFRA_EXIT:-90}"
}
