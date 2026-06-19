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
PURGE=0

if [[ "${1:-}" == "--purge" ]]; then
  PURGE=1
fi

if systemctl list-unit-files "${SERVICE_NAME}" >/dev/null 2>&1; then
  systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
fi

# Belt and suspenders: remove managed iptables rules even if systemd was absent.
if [[ -x "${SCRIPT_DIR}/zerotier-lan-nat.sh" ]]; then
  "${SCRIPT_DIR}/zerotier-lan-nat.sh" stop >/dev/null 2>&1 || true
fi

rm -f "${SERVICE_PATH}"
rm -f "${DEFAULT_PATH}"
rm -f "${SYSCTL_PATH}"
systemctl daemon-reload
systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true

if [[ "${PURGE}" -eq 1 ]]; then
  cd /
  rm -rf "${SCRIPT_DIR}"
  echo "Uninstalled ${SERVICE_NAME} and removed ${SCRIPT_DIR}."
else
  echo "Uninstalled ${SERVICE_NAME}."
  echo "Kept config/tool directory: ${SCRIPT_DIR}"
  echo "Use './uninstall.sh --purge' only if you also want to remove this directory."
fi
