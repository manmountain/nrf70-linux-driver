#!/usr/bin/env bash
set -euo pipefail

DRIVER_MODULE="nrf_wifi_fmac_sta"
DRIVER_KO="./nrf_wifi_fmac_sta.ko"
IFACE="nrf_wifi"
OVERLAY="dts/nrf70_rpi5_interposer.dtbo"

module_loaded() {
  lsmod | awk '{print $1}' | grep -qx "${DRIVER_MODULE}"
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

if ip link show "${IFACE}" >/dev/null 2>&1; then
  ip link set "${IFACE}" down || true
fi

if module_loaded; then
  rmmod "${DRIVER_MODULE}"
fi

if [[ -f "${OVERLAY}" ]]; then
  dtoverlay "${OVERLAY}" || true
fi

# Overlay apply can trigger module autoload via modalias; drop it so the
# explicitly built local module is what gets inserted below.
if module_loaded; then
  rmmod "${DRIVER_MODULE}"
fi

insmod "${DRIVER_KO}"

for _ in $(seq 1 20); do
  if ip link show "${IFACE}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

ip link show "${IFACE}" || true
iw dev "${IFACE}" info || true
