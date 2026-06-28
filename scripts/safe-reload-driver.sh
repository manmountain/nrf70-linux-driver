#!/usr/bin/env bash
set -euo pipefail

DRIVER_MODULE="nrf_wifi_fmac_sta"
DRIVER_KO="./nrf_wifi_fmac_sta.ko"
IFACE="nrf_wifi"
OVERLAY="dts/nrf70_rpi5_interposer.dtbo"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

if ip link show "${IFACE}" >/dev/null 2>&1; then
  ip link set "${IFACE}" down || true
fi

if lsmod | grep -q "^${DRIVER_MODULE}"; then
  rmmod "${DRIVER_MODULE}"
fi

if [[ -f "${OVERLAY}" ]]; then
  dtoverlay "${OVERLAY}" || true
fi

insmod "${DRIVER_KO}"

ip link show "${IFACE}" || true
iw dev "${IFACE}" info || true
