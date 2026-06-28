# Minimal Patch Plan: Make RX Compatible with wfb_rx

Goal: make monitor RX on nrf70 usable by `wfb_rx`, which requires radiotap capture (`DLT_IEEE802_11_RADIO`).

Current breakpoints:

- runtime interface can report `type monitor` but capture type remains `EN10MB`.
- `wfb_rx` fails with `unknown encapsulation on nrf_wifi`.
- monitor VIF create (`iw ... interface add`) may crash in add-VIF path.

## Scope

- Keep existing TX path behavior (already validated with `wfb_tx -Q`).
- Add or expose a safe monitor RX path for radiotap consumers.
- Avoid large firmware protocol redesign in first patch set.

## Phase 1: Stabilize Control Path (No RX Behavior Change Yet)

1. Harden add-VIF path against crash:
   - file: [src/cfg80211_if.c](src/cfg80211_if.c)
   - function: `nrf_wifi_cfg80211_add_vif`
   - actions:
     - add strict NULL/length checks for interface name and MAC handling.
     - if monitor VIF create is not fully supported, return `-EOPNOTSUPP` cleanly instead of dereferencing invalid state.
2. Add explicit log for unsupported monitor VIF create path so failures are diagnosable.

Exit criteria:

- `iw dev ... interface add` returns a clean error (or succeeds) without kernel oops.

## Phase 2: Split Netdev Semantics by IfType

Problem today:

- [src/netdev.c](src/netdev.c) uses `alloc_etherdev(...)` in `nrf_wifi_netdev_add_vif`, locking interface behavior to Ethernet framing.
- RX callback path uses `eth_type_trans(...)`, which is incompatible with radiotap/802.11 monitor capture.

Minimal change set:

1. Introduce monitor-specific netdev setup in `nrf_wifi_netdev_add_vif`:
   - create monitor interfaces with non-Ethernet link-layer type suitable for radiotap capture.
2. Keep STA/AP interfaces on existing Ethernet setup.
3. Route monitor RX frames through a monitor-specific receive function that does not call `eth_type_trans`.

Exit criteria:

- `tcpdump -i <monitor_if> -L` advertises `IEEE802_11_RADIO`.

## Phase 3: Provide Monitor RX Frame Format Expected by Tools

1. Build monitor RX skb as:
   - radiotap header
   - raw 802.11 frame body
2. Attach per-packet metadata (channel/rate/rssi) if available from FMAC callbacks.
3. If metadata is unavailable initially, emit minimal valid radiotap header first, then iterate.

Important dependency:

- If firmware delivers only Ethernet-decapsulated payloads over SPI for monitor mode, full radiotap RX cannot be completed in host driver alone and requires firmware support for raw 802.11 delivery.

Exit criteria:

- `wfb_rx -p 0 -u 5600 -K gs.key <monitor_if> -l 1000` starts and receives packets.

## Phase 4: Keep Existing TX Injection Working

Regression checks for current known-good path:

- `wfb_tx` with `-Q -F 3000 -J 4 -E 5000 -R 8388608 -l 1000` still stable.
- No reintroduction of ENOBUFS regression.
- Load ladder scripts continue to pass.

## Test Matrix (Per Patch Phase)

Run after each phase:

```bash
sudo iw dev nrf_wifi info
sudo tcpdump -i nrf_wifi -L
cd /home/goran/Source/wfb-ng
sudo timeout 8s ./wfb_rx -p 0 -u 5600 -K gs.key nrf_wifi -l 1000; echo "rc=$?"
```

Pass definition:

- no kernel oops,
- radiotap capture advertised,
- `wfb_rx` starts without encapsulation error.