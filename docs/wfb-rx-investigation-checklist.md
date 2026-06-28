# WFB RX Investigation Checklist (nrf70 + wfb-ng)

Purpose: isolate why monitor mode on `nrf_wifi` still appears as Ethernet (`EN10MB`) and fails in `wfb_rx` with `unknown encapsulation`.

## 1. Safety and Repro Preconditions

- Reboot after any kernel oops before collecting new evidence.
- Load driver cleanly:

```bash
sudo dtoverlay dts/nrf70_rpi5_interposer.dtbo
sudo rmmod nrf_wifi_fmac_sta || true
sudo insmod ./nrf_wifi_fmac_sta.ko
```

## 2. Baseline Interface Snapshot

Run and save outputs before mode changes:

```bash
sudo ip -d link show nrf_wifi
sudo iw dev nrf_wifi info
sudo iw phy phy1 info
sudo tcpdump -i nrf_wifi -L
```

Expected for `wfb_rx` compatibility:

- `tcpdump -L` includes `IEEE802_11_RADIO`.

Observed blocker state in this repo session:

- only `EN10MB (Ethernet)` is listed.

## 3. Monitor Mode Transition Check

```bash
sudo nmcli device set nrf_wifi managed no
sudo ip link set nrf_wifi down
sudo iw dev nrf_wifi set monitor otherbss
sudo iw reg set BO
sudo ip link set nrf_wifi up
sudo iw dev nrf_wifi set channel 149 HT20

sudo iw dev nrf_wifi info
sudo tcpdump -i nrf_wifi -L
```

Interpretation:

- If `iw` shows `type monitor` but `tcpdump -L` still only shows `EN10MB`, monitor iftype is accepted but capture encapsulation is still Ethernet-only.

## 4. wfb_rx Capability Probe

```bash
cd /home/goran/Source/wfb-ng
sudo timeout 8s ./wfb_rx -p 0 -u 5600 -K gs.key nrf_wifi -l 1000; echo "rc=$?"
```

Failure signature:

- `Error: unknown encapsulation on nrf_wifi`

## 5. Crash Path Verification (Do Not Repeat on Main Test Host)

Known crashy path from this session:

```bash
sudo iw dev nrf_wifi interface add mon0 type monitor flags none
```

This previously triggered a kernel oops in add-VIF path (`nrf_wifi_cfg80211_add_vif`).
Avoid repeating unless running a debug kernel and collecting crash artifacts.

## 6. Code Touchpoints To Inspect

- [src/netdev.c](src/netdev.c): `nrf_wifi_netdev_add_vif`
  - uses `alloc_etherdev(...)`, which creates Ethernet netdev semantics.
- [src/netdev.c](src/netdev.c): `nrf_wifi_netdev_frame_rx_callbk_fn`
  - calls `eth_type_trans(...)`, enforcing Ethernet RX handling.
- [src/cfg80211_if.c](src/cfg80211_if.c): `nrf_wifi_cfg80211_chg_vif`
  - monitor mode path is TX-injection oriented and does not establish radiotap RX path.
- [src/cfg80211_if.c](src/cfg80211_if.c): `nrf_wifi_cfg80211_add_vif`
  - add-interface path involved in the observed `iw interface add` crash.

## 7. Exit Criteria

Investigation is complete when all are true:

- `iw dev nrf_wifi info` shows `type monitor`.
- `tcpdump -i nrf_wifi -L` includes `IEEE802_11_RADIO`.
- `wfb_rx` starts without `unknown encapsulation`.
- No kernel oops when creating/changing monitor interfaces.