#!/bin/sh
# Template: build a gzip'd tar payload on a flash-starved router and store it
# raw on a spare partition.  Run on the router; packages come from a local
# HTTP server because the box usually has no uplink.
#
#   PC=http://<workstation>:8080  PKGS="a.ipk b.ipk ..."  sh build-payload.sh
set -e
PC=${PC:-http://192.168.1.225:8080}
DEVICE=${DEVICE:-/dev/sda3}
PKGS=${PKGS:-}
# Files (relative to the extracted package tree) that the app needs at runtime.
FILES=${FILES:-"usr/sbin/openconnect usr/sbin/openconnect-wrapper usr/bin/resolveip
  usr/lib/libgnutls.so.30.14.8 usr/lib/libgnutls.so.30
  usr/lib/libnettle.so.6.3 usr/lib/libnettle.so.6
  usr/lib/libhogweed.so.4.3 usr/lib/libhogweed.so.4
  usr/lib/libgmp.so.10.3.2 usr/lib/libgmp.so.10
  usr/lib/libxml2.so.2.9.4 usr/lib/libxml2.so.2
  usr/lib/libtasn1.so.6.5.4 usr/lib/libtasn1.so.6
  usr/lib/libz.so.1.2.11 usr/lib/libz.so.1
  lib/netifd/vpnc-script
  lib/modules/4.4.182/tun.ko"}

rm -rf /tmp/ipk /tmp/ocroot
mkdir -p /tmp/ipk /tmp/ocroot
cd /tmp/ipk
echo "=== download ==="
for f in $PKGS; do
    wget -q -T 20 -O "$f" "$PC/$f" || echo "MISS $f"
done

echo "=== extract (data.tar.gz only, no opkg) ==="
for f in *.ipk; do
    tar xzf "$f" ./data.tar.gz -O 2>/dev/null | tar xzf - -C /tmp/ocroot 2>/dev/null || echo "BAD $f"
done
rm -rf /tmp/ipk

echo "=== pack in one pass (never stage a second tar) ==="
cd /tmp/ocroot
# shellcheck disable=SC2086
tar czf /tmp/payload.tar.gz $FILES
cd /tmp
rm -rf /tmp/ocroot
ls -l /tmp/payload.tar.gz

echo "=== pad to whole 4096-byte blocks ==="
dd if=/tmp/payload.tar.gz of=/tmp/payload.pad.gz bs=4096 conv=sync 2>/dev/null
SZ=$(wc -c < /tmp/payload.pad.gz)
B=$((SZ / 4096))
echo "PAYLOAD_BLOCKS=$B  BYTES=$SZ"

echo "=== write + verify ==="
dd if=/tmp/payload.pad.gz of="$DEVICE" bs=4096 conv=fsync 2>&1 | tail -1
sync
dd if="$DEVICE" of=/tmp/check.gz bs=4096 count=$B 2>/dev/null
md5sum /tmp/payload.pad.gz /tmp/check.gz
rm -f /tmp/check.gz /tmp/payload.tar.gz /tmp/payload.pad.gz
echo "Now set BLOCKS=$B in /usr/sbin/oc-load"
