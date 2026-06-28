#!/usr/bin/env bash
set -euo pipefail

# Phase 2/3 monitor RX validation helper.
# - Switches nrf_wifi into monitor mode
# - Verifies radiotap link-layer exposure
# - Runs a short wfb_rx smoke test

IFACE="${IFACE:-nrf_wifi}"
CHAN="${CHAN:-149}"
BW="${BW:-HT20}"
WFB_DIR="${WFB_DIR:-/home/goran/Source/wfb-ng}"
KEY="${KEY:-gs.key}"
RADIO_PORT="${RADIO_PORT:-0}"
UDP_PORT="${UDP_PORT:-5600}"
LOG_INTERVAL="${LOG_INTERVAL:-1000}"
RX_TIMEOUT="${RX_TIMEOUT:-8}"

DMESG_BASELINE="$(sudo dmesg | wc -l)"
WFB_LOG="$(mktemp)"
trap 'rm -f "${WFB_LOG}"' EXIT

echo "[1/4] Configure ${IFACE} monitor mode"
sudo ip link set "${IFACE}" down
sudo iw dev "${IFACE}" set monitor otherbss
sudo iw reg set BO
sudo ip link set "${IFACE}" up
sudo iw dev "${IFACE}" set channel "${CHAN}" "${BW}"
sudo iw dev "${IFACE}" info

echo "[2/4] Check link-layer types"
DLT_OUT="$(sudo tcpdump -i "${IFACE}" -L 2>&1 || true)"
echo "${DLT_OUT}"
if ! grep -q "IEEE802_11_RADIO" <<<"${DLT_OUT}"; then
  echo "ERROR: radiotap link type is missing on ${IFACE}" >&2
  exit 1
fi

echo "[3/4] Short wfb_rx smoke test (${RX_TIMEOUT}s)"
pushd "${WFB_DIR}" >/dev/null
set +e
sudo timeout "${RX_TIMEOUT}" ./wfb_rx \
  -p "${RADIO_PORT}" \
  -u "${UDP_PORT}" \
  -K "${KEY}" \
  "${IFACE}" \
  -l "${LOG_INTERVAL}" | tee "${WFB_LOG}"
RC=$?
set -e
popd >/dev/null

if [[ "${RC}" -ne 0 && "${RC}" -ne 124 ]]; then
  echo "ERROR: wfb_rx failed with rc=${RC}" >&2
  exit "${RC}"
fi

PKT_LINES="$(grep -Ec '[[:space:]]PKT[[:space:]]' "${WFB_LOG}" || true)"
NONZERO_PKT_LINES="$(awk '/[[:space:]]PKT[[:space:]]/ { split($NF, a, ":"); for (i in a) if (a[i] != 0) { nz++; break } } END { print nz + 0 }' "${WFB_LOG}")"

echo "wfb_rx summary: pkt_lines=${PKT_LINES}, nonzero_pkt_lines=${NONZERO_PKT_LINES}"
if [[ "${PKT_LINES}" -eq 0 ]]; then
  echo "WARNING: no PKT counters were emitted during smoke test" >&2
elif [[ "${NONZERO_PKT_LINES}" -eq 0 ]]; then
  echo "WARNING: PKT counters stayed zero (no decodable RF traffic observed yet)" >&2
fi

echo "[4/4] Recent monitor/RX diagnostics"
NEW_DMESG="$(sudo dmesg | tail -n +"$((DMESG_BASELINE + 1))" || true)"
if [[ -z "${NEW_DMESG}" ]]; then
  sudo dmesg | tail -n 80
else
  echo "${NEW_DMESG}"
fi

ERROR_RE='RPU is unresponsive|Set mode failed|Interrupt callback failed|Event queue processing failed|nrf_wifi_fmac_chg_vif_state failed|unknown encapsulation|\<BUG:\>|\<Oops:\>'
if grep -Eiq "${ERROR_RE}" <<<"${NEW_DMESG}"; then
  echo "ERROR: critical monitor/RX kernel errors detected in this run" >&2
  exit 2
fi

echo "PASS: monitor mode + radiotap + wfb_rx startup path look healthy"