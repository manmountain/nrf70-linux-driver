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
