#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "bootstrap.sh must run as root" >&2
  exit 1
fi

if [[ "$#" -ne 1 ]]; then
  echo "usage: bootstrap.sh <codexbox-source-root>" >&2
  exit 1
fi

source_root="$(readlink -f "$1")"
if [[ ! -f "${source_root}/broker/codexbox/server.py" ]]; then
  echo "broker sources were not found under ${source_root}" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  bubblewrap \
  build-essential \
  ca-certificates \
  cmake \
  gdb \
  git \
  ninja-build \
  openssl \
  python3
rm -rf /var/lib/apt/lists/*

if ! id codexbox >/dev/null 2>&1; then
  useradd --create-home --shell /usr/sbin/nologin --user-group codexbox
fi

install -d -o root -g root -m 0755 /opt/codexbox
install -d -o root -g root -m 0755 /workspace
rm -rf /opt/codexbox/codexbox
cp -a "${source_root}/broker/codexbox" /opt/codexbox/codexbox
install -m 0755 "${source_root}/guest/preflight.sh" /opt/codexbox/preflight.sh
find /opt/codexbox -type d -exec chmod 0755 {} +
find /opt/codexbox -type f -exec chmod 0644 {} +
chmod 0755 /opt/codexbox/preflight.sh
python3 -m compileall -q /opt/codexbox/codexbox

install -d -o root -g codexbox -m 0750 /etc/codexbox
install -d -o codexbox -g codexbox -m 0700 \
  /srv/codexbox \
  /srv/codexbox/persistent \
  /srv/codexbox/isolated \
  /srv/codexbox/metadata

if [[ ! -s /etc/codexbox/token ]]; then
  openssl rand -hex 32 > /etc/codexbox/token
fi
chown root:codexbox /etc/codexbox/token
chmod 0640 /etc/codexbox/token

cat > /etc/codexbox/config.env <<'EOF'
PYTHONPATH=/opt/codexbox
CODEXBOX_ROOT=/srv/codexbox
CODEXBOX_TOKEN_FILE=/etc/codexbox/token
CODEXBOX_HOST=127.0.0.1
CODEXBOX_PORT=18081
CODEXBOX_ALLOW_NETWORK=0
CODEXBOX_MAX_UPLOAD_BYTES=268435456
CODEXBOX_MAX_EXTRACT_BYTES=1073741824
CODEXBOX_MAX_OUTPUT_BYTES=8388608
CODEXBOX_MAX_FILES=100000
CODEXBOX_COMMAND_TIMEOUT=600
CODEXBOX_BWRAP=bwrap
EOF
chown root:codexbox /etc/codexbox/config.env
chmod 0640 /etc/codexbox/config.env

if [[ -f /etc/wsl.conf && ! -f /etc/wsl.conf.codexbox-backup ]]; then
  cp /etc/wsl.conf /etc/wsl.conf.codexbox-backup
fi
cat > /etc/wsl.conf <<'EOF'
[boot]
systemd=true

[automount]
enabled=false
mountFsTab=false

[interop]
enabled=false
appendWindowsPath=false

[user]
default=codexbox
EOF
chmod 0644 /etc/wsl.conf

install -m 0644 "${source_root}/guest/codexbox-broker.service" \
  /etc/systemd/system/codexbox-broker.service
systemctl enable codexbox-broker.service
if [[ "$(ps -p 1 -o comm=)" == "systemd" ]]; then
  systemctl daemon-reload
  systemctl restart codexbox-broker.service
fi

echo "CodexBox bootstrap completed. Restart the WSL distribution to apply wsl.conf."
