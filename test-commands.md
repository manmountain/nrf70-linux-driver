sudo dtoverlay dts/nrf70_rpi5_interposer.dtbo
sudo rmmod nrf_wifi_fmac_sta
sudo insmod ./nrf_wifi_fmac_sta.ko
sudo sysctl -w net.core.wmem_max=16777216
sudo sysctl -w net.core.wmem_default=4194304
sudo ip link set dev nrf_wifi txqueuelen 5000
sudo ip link show nrf_wifi
sudo iw dev nrf_wifi info

# Verify capture encapsulation before using wfb_rx.
# wfb_rx requires IEEE802_11_RADIO; if tcpdump shows only EN10MB,
# RX on this interface is not supported yet.
sudo tcpdump -i nrf_wifi -L
sudo nmcli device set nrf_wifi managed no
sudo ip link set nrf_wifi down
sudo iw dev nrf_wifi set monitor otherbss
sudo iw reg set BO
sudo ip link set nrf_wifi up
sudo iw dev nrf_wifi set channel 149 HT20
sudo ip link show nrf_wifi
sudo iw dev nrf_wifi info
sudo tcpdump -i nrf_wifi -L

# TX examples below use `drone.key`; RX examples on the ground station use `gs.key`.

# Fast monitor/RX debug filters (new cfg80211 instrumentation)
sudo dmesg | grep -E "nrf_wifi_cfg80211_add_vif|nrf_wifi_cfg80211_chg_vif|monitor VIF creation"

# Safe reload helper (brings interface down before rmmod)
sudo ./scripts/safe-reload-driver.sh

# Phase 2/3 monitor RX validation helper
chmod +x ./scripts/validate-monitor-rx.sh
sudo IFACE=nrf_wifi WFB_DIR=/home/goran/Source/wfb-ng ./scripts/validate-monitor-rx.sh

# Single-card test note
# With one nrf7002 on one Pi, you can validate TX pipeline and RX startup
# (monitor + radiotap) but not a meaningful simultaneous TX->RX RF loopback.
# For non-zero RX decode counters, use a second transmitter device.

# Synthetic TX traffic recipe (run on transmitter device)
# Terminal 1 (injector):
cd /home/goran/Source/wfb-ng && sudo ./wfb_tx -p 0 -u 5602 -K drone.key nrf_wifi -l 1000 -Q

# Terminal 2 (fake video payload -> localhost:5602):
gst-launch-1.0 -q \
	videotestsrc is-live=true pattern=smpte ! \
	video/x-raw,width=640,height=360,framerate=30/1 ! \
	x264enc tune=zerolatency bitrate=1200 speed-preset=ultrafast key-int-max=30 ! \
	h264parse ! mpegtsmux alignment=7 ! \
	udpsink host=127.0.0.1 port=5602 sync=false async=false

# Ground station RX validation (run on receiver device)
sudo IFACE=nrf_wifi WFB_DIR=/home/goran/Source/wfb-ng ./scripts/validate-monitor-rx.sh

# Terminal 1
cd /home/goran/Source/wfb-ng && sudo ./wfb_tx -p 0 -u 5602 -K drone.key nrf_wifi -Q

# Terminal 2
python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for i in range(100): s.sendto(b'A'*1024, ('127.0.0.1', 5602)); time.sleep(0.02)
"

# Automated drop-threshold sweep (writes CSV + logs under artifacts/wfb-sweep)
sudo WFB_DIR=/home/goran/Source/wfb-ng \
	IFACE=nrf_wifi \
	DURATION_SEC=12 \
	F_LIST="3000 5000 7000" \
	J_LIST="2 4 8" \
	UDP_INTERVAL_MS_LIST="20 10 5 2 1" \
	./scripts/wfb_tx_sweep.sh

# GStreamer synthetic video load (320p-ish, 16 fps, low bitrate) with best sweep params
# Terminal 1 (wfb_tx):
cd /home/goran/Source/wfb-ng && sudo ./wfb_tx -p 0 -u 5602 -K drone.key nrf_wifi -F 3000 -J 8 -E 2000 -Q

# Terminal 2 (video source to localhost:5602):
gst-launch-1.0 -v \
	videotestsrc is-live=true pattern=ball ! \
	video/x-raw,width=320,height=180,framerate=16/1 ! \
	videoconvert ! \
	openh264enc bitrate=250000 complexity=low gop-size=32 ! \
	h264parse ! mpegtsmux ! \
	udpsink host=127.0.0.1 port=5602 sync=false async=false

# Optional: strict 320x240 instead of 320x180
# replace width=320,height=180 with width=320,height=240

# Optional: if you install x264 plugin, you can use
# x264enc tune=zerolatency speed-preset=ultrafast key-int-max=32 bitrate=250 bframes=0

# Diagnose userspace injection failures (ENOBUFS/EAGAIN) when dmesg is empty
# Terminal 1 (run wfb_tx under strace for sendmsg results):
cd /home/goran/Source/wfb-ng && sudo strace -f -tt -e trace=sendmsg -o /tmp/wfb_sendmsg.strace \
	./wfb_tx -p 0 -u 5602 -K drone.key nrf_wifi -F 3000 -J 4 -E 5000 -R 8388608 -l 1000 -Q

# Terminal 2 (same video source):
gst-launch-1.0 -v \
	videotestsrc is-live=true pattern=ball ! \
	video/x-raw,width=320,height=180,framerate=16/1 ! \
	videoconvert ! \
	openh264enc bitrate=250000 complexity=low gop-size=32 ! \
	h264parse ! mpegtsmux alignment=7 ! \
	udpsink host=127.0.0.1 port=5602 buffer-size=1048576 sync=false async=false

# After Ctrl+C, summarize sendmsg errno causes:
grep -oE 'sendmsg\([^)]*\) = -1 [A-Z0-9_]+' /tmp/wfb_sendmsg.strace | \
	awk '{print $NF}' | sort | uniq -c | sort -nr

# Load ladder (60s per step, stop on first drop):
sudo WFB_DIR=/home/goran/Source/wfb-ng IFACE=nrf_wifi \
	./scripts/wfb_load_ladder.sh

# Optional faster iteration (30s per step):
sudo WFB_DIR=/home/goran/Source/wfb-ng IFACE=nrf_wifi STEP_DURATION_SEC=30 \
	./scripts/wfb_load_ladder.sh