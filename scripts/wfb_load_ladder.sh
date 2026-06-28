#!/usr/bin/env bash
# wfb_load_ladder.sh
# Incrementally increases video bitrate and fps, running each load step for
# STEP_DURATION_SEC seconds with the proven working wfb_tx parameters.
# Stops and reports when the first drops are detected.
#
# Usage:
#   sudo WFB_DIR=/home/goran/Source/wfb-ng IFACE=nrf_wifi \
#     ./scripts/wfb_load_ladder.sh
#
# Tunable env vars (all have defaults):
#   WFB_DIR          - path to wfb-ng checkout (default: /home/goran/Source/wfb-ng)
#   WFB_KEY          - key file name inside WFB_DIR (default: drone.key)
#   IFACE            - monitor interface (default: nrf_wifi)
#   UDP_PORT         - wfb_tx UDP port (default: 5602)
#   STEP_DURATION_SEC- seconds per load step (default: 60)
#   STOP_ON_FIRST_DROP - 1=stop at first drop, 0=run all steps (default: 1)
#   OUTPUT_DIR       - where to write per-step logs (default: ./artifacts/load-ladder/<ts>)

set -euo pipefail

WFB_DIR="${WFB_DIR:-/home/goran/Source/wfb-ng}"
WFB_KEY="${WFB_KEY:-drone.key}"
IFACE="${IFACE:-nrf_wifi}"
UDP_PORT="${UDP_PORT:-5602}"
STEP_DURATION_SEC="${STEP_DURATION_SEC:-60}"
STOP_ON_FIRST_DROP="${STOP_ON_FIRST_DROP:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-./artifacts/load-ladder/$(date +%Y%m%d-%H%M%S)}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

if [[ ! -x "${WFB_DIR}/wfb_tx" ]]; then
  echo "wfb_tx not found at ${WFB_DIR}/wfb_tx"
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

SUMMARY="${OUTPUT_DIR}/summary.txt"
echo "step,width,height,fps,bitrate_kbps,duration_sec,total_injected,total_dropped,drop_pct,result" \
  | tee "${SUMMARY}"

# ─── Load steps ──────────────────────────────────────────────────────────────
# Format: "WIDTHxHEIGHT FPS BITRATE_KBPS"
# Steps go from low (safe) to high (expected ceiling).
STEPS=(
  "320x180  16   200"
  "320x180  16   400"
  "320x180  24   600"
  "320x180  30   800"
  "640x360  16   800"
  "640x360  24  1200"
  "640x360  30  1800"
  "1280x720 16  2000"
  "1280x720 24  3000"
  "1280x720 30  4000"
  "1280x720 30  5000"
  "1280x720 30  6000"
  "1280x720 60  6000"
  "1280x720 30  7000"
  "1280x720 60  7000"
  "1280x720 30  8000"
  "1280x720 60  8000"
)

# ─── Helpers ─────────────────────────────────────────────────────────────────
cleanup() {
  kill "${wfb_pid}" "${gst_pid}" 2>/dev/null || true
  wait "${wfb_pid}" "${gst_pid}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

parse_pkt_line() {
  # PKT line: fec_timeouts:incoming:incoming_bytes:injected:injected_bytes:dropped:truncated
  local line="$1"
  INJECTED=$(echo "${line}" | awk -F'\t' '{split($3,a,":"); print a[4]}')
  DROPPED=$(echo "${line}" | awk  -F'\t' '{split($3,a,":"); print a[6]}')
}

# ─── Main loop ───────────────────────────────────────────────────────────────
first_drop_step=""

for i in "${!STEPS[@]}"; do
  step_num=$((i + 1))
  read -r res fps bitrate <<< "${STEPS[$i]}"
  width="${res%x*}"
  height="${res#*x}"

  step_name="step${step_num}_${width}x${height}_${fps}fps_${bitrate}kbps"
  step_dir="${OUTPUT_DIR}/${step_name}"
  mkdir -p "${step_dir}"

  echo ""
  echo "━━━ Step ${step_num}/${#STEPS[@]}: ${width}x${height} @ ${fps}fps  ${bitrate}kbps  (${STEP_DURATION_SEC}s) ━━━"

  # Start wfb_tx (proven-working params)
  (
    cd "${WFB_DIR}"
    ./wfb_tx -p 0 -u "${UDP_PORT}" -K "${WFB_KEY}" "${IFACE}" \
      -F 3000 -J 4 -E 5000 -R 8388608 -l 1000 -Q \
      > "${step_dir}/wfb_tx.log" 2>&1
  ) &
  wfb_pid=$!

  sleep 1  # let wfb_tx settle

  # Start GStreamer video source
  gst-launch-1.0 -q \
    videotestsrc is-live=true pattern=ball ! \
    "video/x-raw,width=${width},height=${height},framerate=${fps}/1" ! \
    videoconvert ! \
    openh264enc "bitrate=$((bitrate * 1000))" complexity=low gop-size=32 ! \
    h264parse ! mpegtsmux alignment=7 ! \
    udpsink host=127.0.0.1 port="${UDP_PORT}" buffer-size=1048576 sync=false async=false \
    > "${step_dir}/gst.log" 2>&1 &
  gst_pid=$!

  # Run for STEP_DURATION_SEC, sampling wfb_tx log during the run
  step_end=$(( $(date +%s) + STEP_DURATION_SEC ))

  total_injected=0
  total_dropped=0

  while [[ $(date +%s) -lt "${step_end}" ]]; do
    sleep 2
    # read last PKT line from wfb_tx log
    last_pkt=$(grep $'\tPKT\t' "${step_dir}/wfb_tx.log" 2>/dev/null | tail -n 1 || true)
    if [[ -n "${last_pkt}" ]]; then
      parse_pkt_line "${last_pkt}"
      total_injected=$(( total_injected + ${INJECTED:-0} ))
      total_dropped=$(( total_dropped + ${DROPPED:-0} ))
    fi
  done

  # Stop gst and wfb_tx
  kill "${gst_pid}" 2>/dev/null || true
  wait "${gst_pid}" 2>/dev/null || true
  kill "${wfb_pid}" 2>/dev/null || true
  wait "${wfb_pid}" 2>/dev/null || true

  # Final tally from wfb_tx log
  final_injected=$(awk -F'\t' '/\tPKT\t/{split($3,a,":"); s+=a[4]} END{print s+0}' \
    "${step_dir}/wfb_tx.log")
  final_dropped=$(awk -F'\t' '/\tPKT\t/{split($3,a,":"); s+=a[6]} END{print s+0}' \
    "${step_dir}/wfb_tx.log")

  if [[ "${final_injected}" -gt 0 ]]; then
    drop_pct=$(awk -v d="${final_dropped}" -v inj="${final_injected}" \
      'BEGIN{printf "%.1f", (100*d)/(d+inj)}')
  else
    drop_pct="100.0"
  fi

  if [[ "${final_dropped}" -gt 0 ]]; then
    result="DROPS"
    [[ -z "${first_drop_step}" ]] && first_drop_step="${step_name}"
  else
    result="OK"
  fi

  printf "%d,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "${step_num}" "${width}" "${height}" "${fps}" "${bitrate}" \
    "${STEP_DURATION_SEC}" "${final_injected}" "${final_dropped}" \
    "${drop_pct}" "${result}" | tee -a "${SUMMARY}"

  printf "  Result: %s  injected=%s  dropped=%s  drop_pct=%s%%\n" \
    "${result}" "${final_injected}" "${final_dropped}" "${drop_pct}"

  if [[ "${result}" == "DROPS" && "${STOP_ON_FIRST_DROP}" -eq 1 ]]; then
    echo ""
    echo "━━━ First drops at: ${step_name} — stopping ladder ━━━"
    break
  fi
done

echo ""
echo "Ladder complete. Results: ${SUMMARY}"
if [[ -n "${first_drop_step}" ]]; then
  echo "First drop step: ${first_drop_step}"
  step_before=$((${first_drop_step%%_*//step} - 1))
  echo "Safe ceiling: step before that (check ${SUMMARY} for details)"
fi
