#!/usr/bin/env bash
set -euo pipefail

# Sweep wfb_tx pacing parameters and measure when drops begin.
# Requires:
# - wfb-ng checkout
# - monitor interface configured and up
# - debugfs mounted at /sys/kernel/debug

WFB_DIR="${WFB_DIR:-/home/goran/Source/wfb-ng}"
WFB_KEY="${WFB_KEY:-drone.key}"
IFACE="${IFACE:-nrf_wifi}"
UDP_PORT="${UDP_PORT:-5602}"
DURATION_SEC="${DURATION_SEC:-12}"
PAYLOAD_SIZE="${PAYLOAD_SIZE:-1024}"
UDP_INTERVAL_MS_LIST="${UDP_INTERVAL_MS_LIST:-20 10 5 2 1}"
F_LIST="${F_LIST:-3000 5000 7000}"
J_LIST="${J_LIST:-2 4 8}"
E_VALUE="${E_VALUE:-2000}"
OUTPUT_DIR="${OUTPUT_DIR:-./artifacts/wfb-sweep/$(date +%Y%m%d-%H%M%S)}"
STATS_FILE="/sys/kernel/debug/nrf/wifi/stats"

if ! command -v timeout >/dev/null 2>&1; then
  echo "timeout command not found"
  exit 1
fi

if [[ ! -x "${WFB_DIR}/wfb_tx" ]]; then
  echo "wfb_tx not found at ${WFB_DIR}/wfb_tx"
  exit 1
fi

if [[ ! -f "${WFB_DIR}/${WFB_KEY}" ]]; then
  echo "key not found at ${WFB_DIR}/${WFB_KEY}"
  exit 1
fi

if ! ip link show "${IFACE}" >/dev/null 2>&1; then
  echo "interface ${IFACE} not found"
  exit 1
fi

if [[ "${OUTPUT_DIR}" != /* ]]; then
  OUTPUT_DIR="${PWD}/${OUTPUT_DIR}"
fi

mkdir -p "${OUTPUT_DIR}"
SUMMARY_CSV="${OUTPUT_DIR}/summary.csv"
STATS_AVAILABLE=1

if [[ ! -r "${STATS_FILE}" ]] || ! head -n1 "${STATS_FILE}" >/dev/null 2>&1; then
  echo "warning: unable to read ${STATS_FILE}; raw_tx_* columns may be blank" >&2
  STATS_AVAILABLE=0
fi

echo "case_id,f,j,e,udp_interval_ms,duration_sec,payload_size,tx_ant_dropped,pkt_dropped,raw_tx_dequeued,raw_tx_prep_fail,raw_tx_sent_ok,raw_tx_sent_fail" > "${SUMMARY_CSV}"

read_stat() {
  local key="$1"
  local val=""

  if [[ "${STATS_AVAILABLE}" -eq 1 ]]; then
    val="$(awk -F'= ' -v k="$key" '$1==k {print $2}' "${STATS_FILE}" 2>/dev/null | tail -n1 || true)"

    if [[ ! "${val}" =~ ^[0-9]+$ ]]; then
      val=""
    fi

    echo "${val}"
  else
    echo ""
  fi
}

extract_wfb_dropped() {
  local log_file="$1"
  local kind="$2"

  if [[ ! -f "${log_file}" ]]; then
    echo ""
    return
  fi

  if [[ "$kind" == "TX_ANT" ]]; then
    awk '
      /TX_ANT/{v=$0}
      /packets dropped/{p=$0}
      END{
        if (v ~ /dropped:[0-9]+/) {
          match(v,/dropped:[0-9]+/);
          print substr(v,RSTART+8,RLENGTH-8);
        } else if (p ~ /^[0-9]+ packets dropped$/) {
          split(p,a," ");
          print a[1];
        } else {
          print "";
        }
      }
    ' "${log_file}"
  else
    awk '
      /PKT/{v=$0}
      /packets dropped/{p=$0}
      END{
        if (v ~ /dropped:[0-9]+/) {
          match(v,/dropped:[0-9]+/);
          print substr(v,RSTART+8,RLENGTH-8);
        } else if (p ~ /^[0-9]+ packets dropped$/) {
          split(p,a," ");
          print a[1];
        } else {
          print "";
        }
      }
    ' "${log_file}"
  fi
}

run_udp_load() {
  local interval_ms="$1"
  local duration="$2"
  python3 - "$UDP_PORT" "$duration" "$PAYLOAD_SIZE" "$interval_ms" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
duration = float(sys.argv[2])
payload_size = int(sys.argv[3])
interval_ms = float(sys.argv[4])

payload = b'A' * payload_size
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
end = time.time() + duration
sleep_s = max(interval_ms / 1000.0, 0.0)

sent = 0
while time.time() < end:
    s.sendto(payload, ('127.0.0.1', port))
    sent += 1
    if sleep_s > 0:
        time.sleep(sleep_s)

print(sent)
PY
}

case_id=0
for f in ${F_LIST}; do
  for j in ${J_LIST}; do
    for udp_ms in ${UDP_INTERVAL_MS_LIST}; do
      case_id=$((case_id + 1))
      case_name="case_${case_id}_F${f}_J${j}_U${udp_ms}ms"
      case_dir="${OUTPUT_DIR}/${case_name}"
      mkdir -p "${case_dir}"

      d0="$(read_stat "raw_tx_dequeued_pkts")"
      p0="$(read_stat "raw_tx_prep_fail_pkts")"
      o0="$(read_stat "raw_tx_sent_ok_pkts")"
      f0="$(read_stat "raw_tx_sent_fail_pkts")"

      (
        cd "${WFB_DIR}"
        timeout "${DURATION_SEC}s" ./wfb_tx -p 0 -u "${UDP_PORT}" -K "${WFB_KEY}" "${IFACE}" -F "${f}" -J "${j}" -E "${E_VALUE}" > "${case_dir}/wfb_tx.log" 2>&1 || true
      ) &
      wfb_pid=$!

      sleep 1
      run_udp_load "${udp_ms}" "${DURATION_SEC}" > "${case_dir}/udp_sent.txt"
      wait "${wfb_pid}" || true

      d1="$(read_stat "raw_tx_dequeued_pkts")"
      p1="$(read_stat "raw_tx_prep_fail_pkts")"
      o1="$(read_stat "raw_tx_sent_ok_pkts")"
      f1="$(read_stat "raw_tx_sent_fail_pkts")"

      tx_ant_dropped="$(extract_wfb_dropped "${case_dir}/wfb_tx.log" "TX_ANT")"
      pkt_dropped="$(extract_wfb_dropped "${case_dir}/wfb_tx.log" "PKT")"

      raw_dequeued=""
      raw_prep_fail=""
      raw_sent_ok=""
      raw_sent_fail=""

      if [[ -n "${d0}" && -n "${d1}" ]]; then raw_dequeued=$((d1 - d0)); fi
      if [[ -n "${p0}" && -n "${p1}" ]]; then raw_prep_fail=$((p1 - p0)); fi
      if [[ -n "${o0}" && -n "${o1}" ]]; then raw_sent_ok=$((o1 - o0)); fi
      if [[ -n "${f0}" && -n "${f1}" ]]; then raw_sent_fail=$((f1 - f0)); fi

      echo "${case_id},${f},${j},${E_VALUE},${udp_ms},${DURATION_SEC},${PAYLOAD_SIZE},${tx_ant_dropped},${pkt_dropped},${raw_dequeued},${raw_prep_fail},${raw_sent_ok},${raw_sent_fail}" >> "${SUMMARY_CSV}"
      printf 'done %-28s TX_ANT_dropped=%s PKT_dropped=%s raw_ok=%s raw_fail=%s\n' "${case_name}" "${tx_ant_dropped:-na}" "${pkt_dropped:-na}" "${raw_sent_ok:-na}" "${raw_sent_fail:-na}"
    done
  done
done

echo "Sweep completed: ${SUMMARY_CSV}"
