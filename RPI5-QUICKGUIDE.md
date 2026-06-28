# RPI5 Quick Guide (nRF7002-EB2)

This quick guide covers:
- Hardware hookup (Raspberry Pi 5 + nRF7002-EB2)
- Fresh workspace build
- Post-build smoke test
- Soak test
- Loading overlay and driver automatically on boot

## 1. Hardware hookup

Use **nRF7002-EB2 without host MCU** and wire it directly to the Raspberry Pi 5.

### Complete connection table (nRF7002-EB2 to Raspberry Pi 5)

| EB2 signal | RPi physical pin | BCM GPIO | Purpose |
| --- | --- | --- | --- |
| P1: 5V0 | 2 (5V) | - | Main power |
| P1: GND | 9 (GND) | - | Ground |
| P2: VDD | 1 (3.3V) | - | I/O power |
| P2: GND | 14 (GND) | - | Ground |
| P2: MOSI | 19 | GPIO10 | SPI |
| P2: MISO | 21 | GPIO9 | SPI |
| P2: CS | 24 | GPIO8 (CE0) | SPI chip select |
| P2: SCLK | 23 | GPIO11 | SPI clock |
| P2: GND | 20 (GND) | - | Ground |
| P2: VDD | 17 (3.3V) | - | I/O power |
| P2: BUCKEN | 12 | GPIO18 | Buck converter enable |
| P2: IOVDD | 11 | GPIO17 | I/O voltage select (HIGH = 3.3V) |
| P2: HOST_IRQ | 7 | GPIO4 | Interrupt line |

Note: Keep ground common between EB2 and RPi, keep SPI/IRQ wires short, and avoid mixing 5V on I/O lines.

## 2. Fresh workspace build (from your fork)

```bash
cd /home/goran/testbuilds
west init -m https://github.com/manmountain/nrf70-linux-driver.git --mr main
west update
cd nrf70-linux-driver.git
make clean all BOARD=RPI5 MODE=STA
```

Verify artifacts:

```bash
ls -lh nrf_wifi_fmac_sta.ko dts/nrf70_rpi5_interposer.dtbo
```

## 3. Post-build runtime smoke test (3 commands)

### Create Wi-Fi config file (`nrf_wifi_wpa_supplicant.conf`)

```bash
wpa_passphrase "<YOUR_SSID>" "<YOUR_PASSWORD>" > ~/nrf_wifi_wpa_supplicant.conf
chmod 600 ~/nrf_wifi_wpa_supplicant.conf
```

Quick sanity check:

```bash
grep -E '^[[:space:]]*ssid=|^[[:space:]]*psk=' ~/nrf_wifi_wpa_supplicant.conf
```

Then run the smoke test below.

```bash
sudo insmod ./nrf_wifi_fmac_sta.ko && lsmod | grep nrf_wifi_fmac_sta
ip link show nrf_wifi && iw dev nrf_wifi info
sudo wpa_supplicant -Dnl80211 -i nrf_wifi -c ~/nrf_wifi_wpa_supplicant.conf -B && sudo dhclient -4 -1 nrf_wifi && ping -I nrf_wifi -c 4 1.1.1.1
```

Expected:
- Module visible in `lsmod`
- `nrf_wifi` interface exists
- Ping succeeds

## 4. Soak test example

Run from repo root:

```bash
scripts/ci/stability_soak_gate.sh \
  --iface nrf_wifi \
  --wpa-conf ~/nrf_wifi_wpa_supplicant.conf \
  --trials 50 \
  --checkpoint-every 5 \
  --ifstats-every 10
```

Quick shorter run:

```bash
scripts/ci/stability_soak_gate.sh --trials 10 --checkpoint-every 5 --ifstats-every 5
```

Artifacts are written under:

```bash
artifacts/soak-gate/<timestamp>/
```

PASS criteria:
- Script exits `0`
- `summary.txt` ends with `GATE_RESULT:PASS`
- `final_kernel_markers.log` is empty

## 5. Load overlay + driver automatically on boot

### 5.1 Install DTS overlay

```bash
sudo cp dts/nrf70_rpi5_interposer.dtbo /boot/firmware/overlays/
```

Add to `/boot/firmware/config.txt`:

```ini
dtoverlay=nrf70_rpi5_interposer
```

### 5.2 Install module into kernel tree

```bash
KVER="$(uname -r)"
sudo install -D -m 0644 nrf_wifi_fmac_sta.ko \
  "/lib/modules/${KVER}/kernel/drivers/net/wireless/nrf_wifi_fmac_sta.ko"
sudo depmod -a
```

### 5.3 Enable module auto-load

```bash
echo nrf_wifi_fmac_sta | sudo tee /etc/modules-load.d/nrf70-wifi.conf >/dev/null
```

### 5.4 Reboot and verify

```bash
sudo reboot
```

After boot:

```bash
lsmod | grep nrf_wifi_fmac_sta
ip link show nrf_wifi
```

## 6. Optional: quick teardown

```bash
sudo killall wpa_supplicant 2>/dev/null || true
sudo dhclient -r nrf_wifi 2>/dev/null || true
sudo rmmod nrf_wifi_fmac_sta
```

## 7. WFB TX over monitor mode (camera + test source)

This section uses the stable TX settings validated in this repo:

- `-Q` enabled (qdisc path)
- `-F 3000 -J 4 -E 5000 -R 8388608 -l 1000`

### 7.1 Prepare monitor interface

```bash
sudo ip link set nrf_wifi down
sudo iw dev nrf_wifi set monitor otherbss
sudo iw reg set BO
sudo ip link set nrf_wifi up
sudo iw dev nrf_wifi set channel 149 HT20
ip link show nrf_wifi && iw dev nrf_wifi info
```

### 7.2 Queue/buffer tuning (required)

Apply these before running `wfb_tx`:

```bash
sudo sysctl -w net.core.wmem_max=16777216
sudo sysctl -w net.core.wmem_default=4194304
sudo ip link set dev nrf_wifi txqueuelen 5000
```

### 7.3 Terminal 1: start `wfb_tx`

Run from your `wfb-ng` checkout:

```bash
cd /home/goran/Source/wfb-ng
sudo ./wfb_tx -p 0 -u 5602 -K drone.key nrf_wifi \
  -F 3000 -J 4 -E 5000 -R 8388608 -l 1000 -Q
```

### 7.4 Terminal 2A: DSI camera source (libcamera)

Uses Raspberry Pi camera stack and pushes H.264 into `wfb_tx` via UDP localhost.

Note: On newer Raspberry Pi images the command is `rpicam-vid` (not `libcamera-vid`).

```bash
rpicam-vid -n -t 0 \
  --width 1280 --height 720 --framerate 30 --bitrate 4000000 \
  --inline --codec h264 --libav-format h264 -o - | \
gst-launch-1.0 -v fdsrc ! h264parse ! mpegtsmux alignment=7 ! \
  udpsink host=127.0.0.1 port=5602 buffer-size=1048576 sync=false async=false
```

Note: `h264parse` / `mpegtsmux` may print timestamp and VUI warnings when the
camera stream is piped over stdin. If `wfb_tx` shows non-zero `PKT`/`TX_ANT`
counters and `tcpdump` sees UDP on port 5602, the stream is working.

If needed, lower camera load first:

```bash
rpicam-vid -n -t 0 \
  --width 640 --height 360 --framerate 24 --bitrate 1200000 \
  --inline --codec h264 --libav-format h264 -o - | \
gst-launch-1.0 -v fdsrc ! h264parse ! mpegtsmux alignment=7 ! \
  udpsink host=127.0.0.1 port=5602 buffer-size=1048576 sync=false async=false
```

### 7.5 Terminal 2B: synthetic test source (no camera required)

```bash
gst-launch-1.0 -v \
  videotestsrc is-live=true pattern=ball ! \
  video/x-raw,width=320,height=180,framerate=16/1 ! \
  videoconvert ! \
  openh264enc bitrate=250000 complexity=low gop-size=32 ! \
  h264parse ! mpegtsmux alignment=7 ! \
  udpsink host=127.0.0.1 port=5602 buffer-size=1048576 sync=false async=false
```

### 7.6 Expected behavior

- `wfb_tx` `TX_ANT` should show non-zero injected and zero/near-zero dropped.
- `PKT` should show non-zero incoming and injected.

### 7.7 Optional diagnostics

If drops reappear, trace send errors:

```bash
cd /home/goran/Source/wfb-ng
sudo strace -f -tt -e trace=sendmsg -o /tmp/wfb_sendmsg.strace \
  ./wfb_tx -p 0 -u 5602 -K drone.key nrf_wifi \
  -F 3000 -J 4 -E 5000 -R 8388608 -l 1000 -Q

grep -oE 'sendmsg\([^)]*\) = -1 [A-Z0-9_]+' /tmp/wfb_sendmsg.strace | \
  awk '{print $NF}' | sort | uniq -c | sort -nr
```

### 7.8 Ground station (receive commands)

Run these on the ground station side (receiver), using the same channel and the matching key pair: `drone.key` on TX and `gs.key` on RX.

Ground station monitor setup:

```bash
sudo ip link set nrf_wifi down
sudo iw dev nrf_wifi set monitor otherbss
sudo iw reg set BO
sudo ip link set nrf_wifi up
sudo iw dev nrf_wifi set channel 149 HT20
ip link show nrf_wifi && iw dev nrf_wifi info
```

Terminal 1: run `wfb_rx` and forward recovered stream to localhost UDP 5600:

`wfb_rx` needs a capture interface that exposes radiotap (`DLT_IEEE802_11_RADIO`).
On this driver, creating an extra monitor VIF with `iw dev ... interface add`
can trigger a kernel crash, so do not use that path unless the driver is fixed.
If the existing `nrf_wifi` monitor setup still fails with `unknown encapsulation`,
stop there and reboot before retrying.

Quick capability check:

```bash
sudo tcpdump -i nrf_wifi -L
```

If this shows only `EN10MB (Ethernet)`, `wfb_rx` cannot run on `nrf_wifi` yet,
even when `iw dev nrf_wifi info` reports `type monitor`.

```bash
cd /home/goran/Source/wfb-ng
sudo ./wfb_rx -p 0 -u 5600 -K gs.key nrf_wifi -l 1000
```

Terminal 2A: live video preview from recovered MPEG-TS stream:

```bash
gst-launch-1.0 -v \
  udpsrc port=5600 buffer-size=1048576 ! \
  tsdemux ! h264parse ! avdec_h264 ! videoconvert ! autovideosink sync=false
```

Terminal 2B: optional record recovered stream to file:

```bash
gst-launch-1.0 -e -v \
  udpsrc port=5600 buffer-size=1048576 ! \
  filesink location=rx_capture.ts
```

### 7.9 TX host / RX host checklist (must match)

Before debugging drops, verify these parameters are aligned on both sides:

- Key file: TX `-K` and RX `-K` must be the same key content.
- Channel + width: both hosts set the same channel and `HT20`/band settings.
- Radio port: TX `-p` equals RX `-p`.
- Link ID / epoch (if used): TX `-i`/`-e` must match RX `-i`/`-e`.
- Interface mode: both interfaces are in monitor mode and `UP`.
- Region/regulatory domain: both hosts use the same `iw reg` domain.
- Local UDP handoff: TX app sends to `wfb_tx -u` port; RX app reads from `wfb_rx -u` port.
- Time sanity: host clocks should be roughly sane (no extreme drift).

Quick check commands:

```bash
# On both TX and RX hosts
ip link show nrf_wifi
iw dev nrf_wifi info
iw reg get | head -n 20

# On TX host
pgrep -af wfb_tx

# On RX host
pgrep -af wfb_rx
```
