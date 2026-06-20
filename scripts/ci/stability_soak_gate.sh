#!/usr/bin/env bash
set -euo pipefail

# Repeatable stability gate for nRF70 on RPi5/Ubuntu.
# Reproduces the guarded soak used during long-run crash validation.

usage() {
  cat <<'EOF'
Usage:
  scripts/ci/stability_soak_gate.sh [options]

Options:
  --iface <name>            Wi-Fi interface (default: nrf_wifi)
  --wpa-conf <path>         WPA supplicant config (default: ~/nrf_wifi_wpa_supplicant.conf)
  --trials <n>              Number of downloads (default: 50)
  --checkpoint-every <n>    Marker checkpoint interval (default: 5)
  --ifstats-every <n>       Interface snapshot interval (default: 10)
  --ping-interval <sec>     Ping interval (default: 0.4)
  --ping-size <bytes>       Ping payload size (default: 1200)
  --curl-timeout <sec>      Per-trial timeout (default: 110)
  --artifact-root <path>    Artifact root folder (default: ./artifacts/soak-gate)
  --help                    Show this message

Exit codes:
  0: PASS (all downloads succeeded and no kernel fault markers matched)
  1: FAIL (any download failed, marker matched, or script error)
EOF
}

IFACE="nrf_wifi"
WPA_CONF="${HOME}/nrf_wifi_wpa_supplicant.conf"
TRIALS=50
CHECKPOINT_EVERY=5
IFSTATS_EVERY=10
PING_INTERVAL="0.4"
PING_SIZE=1200
CURL_TIMEOUT=110
ARTIFACT_ROOT="./artifacts/soak-gate"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iface)
      IFACE="$2"
      shift 2
      ;;
    --wpa-conf)
      WPA_CONF="$2"
      shift 2
      ;;
    --trials)
      TRIALS="$2"
      shift 2
      ;;
    --checkpoint-every)
      CHECKPOINT_EVERY="$2"
      shift 2
      ;;
    --ifstats-every)
      IFSTATS_EVERY="$2"
      shift 2
      ;;
    --ping-interval)
      PING_INTERVAL="$2"
      shift 2
      ;;
    --ping-size)
      PING_SIZE="$2"
      shift 2
      ;;
    --curl-timeout)
      CURL_TIMEOUT="$2"
      shift 2
      ;;
    --artifact-root)
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

for cmd in sudo curl ping journalctl ip iw timeout date wc sed grep; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

if [[ ! -f "$WPA_CONF" ]]; then
  echo "WPA config not found: $WPA_CONF" >&2
  exit 1
fi

MARKERS_REGEX='list_del corruption|__list_del_entry_valid_or_report|Unable to handle kernel NULL pointer dereference|RPU is unresponsive|UMAC buff config not yet done|No callback registered for event 289|nrf_wifi_fmac_start_xmit failed|BUG:|Oops|fortify|UBSAN'
TEST_IP="141.95.207.211"
TEST_URL="https://proof.ovh.net/files/10Mb.dat"
TEST_HOST="proof.ovh.net:443:${TEST_IP}"
PING_TARGET="1.1.1.1"

stamp="$(date '+%Y%m%d-%H%M%S')"
ARTIFACT_DIR="${ARTIFACT_ROOT}/${stamp}"
mkdir -p "$ARTIFACT_DIR/checkpoints" "$ARTIFACT_DIR/trials"

summary_file="$ARTIFACT_DIR/summary.txt"
markers_file="$ARTIFACT_DIR/final_kernel_markers.log"
ifstats_file="$ARTIFACT_DIR/final_ifstats.txt"
iw_file="$ARTIFACT_DIR/final_iw.txt"
ping_log="$ARTIFACT_DIR/ping.log"

log() {
  printf '%s\n' "$*" | tee -a "$summary_file"
}

cleanup() {
  if [[ -n "${PING_PID:-}" ]]; then
    kill "$PING_PID" >/dev/null 2>&1 || true
    wait "$PING_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

TS="$(date '+%Y-%m-%d %H:%M:%S')"
log "MARK:${TS}"
log "ARTIFACT_DIR:${ARTIFACT_DIR}"

# Prepare interface and reconnect before soak.
sudo ip link set "$IFACE" up
sudo killall wpa_supplicant >/dev/null 2>&1 || true
sudo wpa_supplicant -Dnl80211 -i "$IFACE" -c "$WPA_CONF" -B >/dev/null 2>&1
sleep 5
sudo dhclient -4 -1 "$IFACE" >/dev/null 2>&1 || true

ping -I "$IFACE" -s "$PING_SIZE" -i "$PING_INTERVAL" "$PING_TARGET" >"$ping_log" 2>&1 &
PING_PID=$!

ok=0
fail=0

for i in $(seq 1 "$TRIALS"); do
  trial_bin="$ARTIFACT_DIR/trials/soak-${i}.bin"
  trial_log="$ARTIFACT_DIR/trials/soak-${i}.curl.log"

  rm -f "$trial_bin"
  if timeout "${CURL_TIMEOUT}s" curl --interface "$IFACE" --http1.1 --tls-max 1.2 --resolve "$TEST_HOST" -L --retry 0 -o "$trial_bin" "$TEST_URL" >"$trial_log" 2>&1; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi

  bytes="$(wc -c < "$trial_bin" 2>/dev/null || echo 0)"
  log "TRIAL:${i} BYTES:${bytes}"
  tail -n 1 "$trial_log" | tr -d '\r' | tee -a "$summary_file" >/dev/null

  if (( i % CHECKPOINT_EVERY == 0 )); then
    cp_log="$ARTIFACT_DIR/checkpoints/markers-${i}.log"
    log "CHECKPOINT:${i}"
    journalctl -k --since "$TS" --no-pager | grep -Ei "$MARKERS_REGEX" | tail -n 40 > "$cp_log" || true
    if [[ -s "$cp_log" ]]; then
      sed 's/^/  /' "$cp_log" | tee -a "$summary_file" >/dev/null
    fi
  fi

  if (( i % IFSTATS_EVERY == 0 )); then
    if_log="$ARTIFACT_DIR/checkpoints/ifstats-${i}.txt"
    log "IFSTATS:${i}"
    ip -s link show "$IFACE" | sed -n '1,8p' | tee "$if_log" | tee -a "$summary_file" >/dev/null
  fi
done

log "RESULT OK:${ok} FAIL:${fail}"
log "PING_TAIL"
tail -n 12 "$ping_log" | tee -a "$summary_file" >/dev/null || true

ip -s link show "$IFACE" > "$ifstats_file"
iw dev "$IFACE" link > "$iw_file" 2>&1 || true
journalctl -k --since "$TS" --no-pager | grep -Ei "$MARKERS_REGEX" | tail -n 400 > "$markers_file" || true

log "FINAL_IFSTATS_FILE:${ifstats_file}"
log "FINAL_IW_FILE:${iw_file}"
log "FINAL_KERNEL_MARKERS_FILE:${markers_file}"

if [[ "$fail" -ne 0 ]]; then
  log "GATE_RESULT:FAIL (download failures detected)"
  exit 1
fi

if [[ -s "$markers_file" ]]; then
  log "GATE_RESULT:FAIL (kernel marker signatures detected)"
  exit 1
fi

log "GATE_RESULT:PASS"
exit 0
