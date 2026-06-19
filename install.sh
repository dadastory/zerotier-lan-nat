#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="zerotier-lan-nat.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
DEFAULT_PATH="/etc/default/zerotier-lan-nat"
SYSCTL_PATH="/etc/sysctl.d/99-zerotier-lan-nat.conf"
ROUTES_FILE="${SCRIPT_DIR}/routes.conf"
LAN_IF="${LAN_IF:-eth0}"
LAN_NET="${LAN_NET:-192.168.1.0/24}"

if [[ ! -x "${SCRIPT_DIR}/zerotier-lan-nat.sh" ]]; then
  chmod +x "${SCRIPT_DIR}/zerotier-lan-nat.sh"
fi

mkdir -p "${SCRIPT_DIR}"
if [[ ! -f "${ROUTES_FILE}" ]]; then
  if [[ -f "${SCRIPT_DIR}/routes.conf.example" ]]; then
    cp "${SCRIPT_DIR}/routes.conf.example" "${ROUTES_FILE}"
  else
    cat > "${ROUTES_FILE}" <<'ROUTES'
# ZeroTier interface and subnet. One route per line.
# Example: ztxxxxxxxx 10.147.17.0/24
ROUTES
  fi
  echo "Created ${ROUTES_FILE}. Edit it before expecting routes to work."
fi

if [[ -f "${DEFAULT_PATH}" ]]; then
  cp -a "${DEFAULT_PATH}" "${DEFAULT_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
fi

cat > "${DEFAULT_PATH}" <<EOF_DEFAULT
# ZeroTier LAN NAT central config
APP_DIR=${SCRIPT_DIR}
ROUTES_FILE=${ROUTES_FILE}
LAN_IF=${LAN_IF}
LAN_NET=${LAN_NET}
EOF_DEFAULT

cat > "${SYSCTL_PATH}" <<'EOF_SYSCTL'
net.ipv4.ip_forward=1
EOF_SYSCTL
sysctl -w net.ipv4.ip_forward=1 >/dev/null

cat > "${SERVICE_PATH}" <<EOF_SERVICE
[Unit]
Description=ZeroTier to LAN NAT router
Wants=network-online.target
After=network-online.target docker.service ufw.service zerotier-one.service

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-${DEFAULT_PATH}
ExecStart=${SCRIPT_DIR}/zerotier-lan-nat.sh start
ExecStop=${SCRIPT_DIR}/zerotier-lan-nat.sh stop

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo "Installed and started ${SERVICE_NAME}."
echo "App dir: ${SCRIPT_DIR}"
echo "Routes file: ${ROUTES_FILE}"
systemctl --no-pager --full status "${SERVICE_NAME}" | sed -n '1,18p'
