#!/usr/bin/env bash
set -euo pipefail

failures=0

check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS  %s\n' "$description"
  else
    printf 'FAIL  %s\n' "$description"
    failures=$((failures + 1))
  fi
}

not_mounted() {
  ! mountpoint -q "$1"
}

check "codexbox user exists" id codexbox
check "bubblewrap is installed" command -v bwrap
check "git is installed" command -v git
check "broker token exists" test -s /etc/codexbox/token
check "Windows C drive is not mounted" not_mounted /mnt/c
check "Windows interop is disabled" test ! -e /proc/sys/fs/binfmt_misc/WSLInterop
check "broker service is active" systemctl is-active --quiet codexbox-broker
check "bubblewrap can create a user namespace" \
  runuser -u codexbox -- bwrap --ro-bind / / --unshare-user -- /bin/true

if (( failures > 0 )); then
  printf '%d preflight check(s) failed\n' "$failures" >&2
  exit 1
fi

echo "CodexBox preflight passed."
