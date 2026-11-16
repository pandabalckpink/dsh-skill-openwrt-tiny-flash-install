---
name: openwrt-tiny-flash-install
description: Install or run software on an OpenWrt/LEDE router whose flash is nearly full, by keeping only kernel modules in flash and running the application from a payload stored raw on USB and extracted into tmpfs. Covers openconnect/AnyConnect client setup, CA bundle, clock and vpnc-script pitfalls.
---

# Fitting software onto a 4 MB router

Use this when a package does not fit in `/overlay`, when `opkg install` reports `No space left on device`, or when the router has 4–8 MB flash / 32 MB RAM. Measure first; the numbers decide the strategy, not the package name.

Two hard rules drive everything below:

- **Kernel modules must live in flash.** They are needed at boot to see the USB device at all, so they cannot be stored on that device. Everything else can.
- **tmpfs is RAM.** `/tmp` writes consume the same 32 MB the tunnel needs. Peak memory, not steady state, is what reboots the router.

## 1. Measure

```sh
cat /etc/openwrt_release; cat /tmp/sysinfo/model; free -m; df -k /overlay /tmp
cat /proc/mtd                      # real flash layout; overlay size is the ceiling
cat /proc/filesystems              # ext4/vfat built in, or needing kmods?
ls /lib/modules/$(uname -r)        # what modules already exist
ls /sys/bus/usb/devices/*/idVendor # is a USB host controller even present?
opkg list-installed | wc -l
```

`/overlay` on a 4 MB device is typically 384 KB, and existing files may occupy most of it while `du` reports only a few KB — jffs2 needs room to garbage-collect. Treat free space below roughly one erase block (64 KB) as unusable: plan the in-flash budget to end with at least ~8 KB left.

| free `/overlay` | strategy |
|---|---|
| ≥ app + deps + 8 KB | normal `opkg install`, stop here |
| ~100–150 KB | flash: kernel modules only; app as USB raw payload (sections 3–5) |
| < 60 KB | modules will not fit; either free modules or document that only a RAM-only install is possible |

## 2. Find a real package, and check its ABI

Old releases simply lack newer packages (LEDE 17.01 has no `openconnect`; 18.06 is the first). Read the feed indexes directly instead of guessing:

```
https://archive.openwrt.org/releases/<release>/packages/<arch>/<feed>/Packages.gz
```

Parse `Depends`, `Size` and `Installed-Size` and walk the dependency closure before installing anything. `Installed-Size` is closer to the compressed payload than to the on-disk size of shared libraries, so sum the uncompressed `data.tar.gz` contents for RAM estimates.

When the app exists only in a newer release, take **the app binary from the newer release and the libraries from the router's own release**. That keeps the libc ABI matched; a newer libgnutls drags in newer musl expectations. Verify by running the binary, not by reading its soname.

## 3. Store the payload without a filesystem driver

Mounting FAT/ext4 costs a kernel module (vfat ≈ 37 KB with nls deps, ext4 ≈ 221 KB) — often exactly what does not fit. Instead write a gzip'd tar **raw** into a spare partition and read it back with `dd`. No filesystem module, no mount, no permissions or symlink problems.

```sh
# host side or router side: one pass, never a second intermediate copy
cd /tmp/ocroot && tar czf /tmp/oc.tar.gz usr/sbin/app usr/lib/lib*.so* ...
dd if=/tmp/oc.tar.gz of=/tmp/oc.pad.gz bs=4096 conv=sync 2>/dev/null
B=$(( $(wc -c < /tmp/oc.pad.gz) / 4096 ))
dd if=/tmp/oc.pad.gz of=/dev/sda3 bs=4096 conv=fsync
dd if=/dev/sda3 bs=4096 count=$B | md5sum   # must equal md5sum of oc.pad.gz
```

- `conv=sync` pads the final block with zeros so the loader can use a fixed `count`; `tar` stops at its end-of-archive marker and ignores the padding.
- Pick a partition that is blank (all zeros) and never the one holding an existing image. Writing into an image's `rootfs_data` area is acceptable only after telling the user, because booting that stick later may be affected.
- Record `B` in the loader. Ship the loader and wrapper in flash (a few hundred bytes); they are the only writable-state cost.

## 4. Loader and wrapper in flash

The loader is idempotent, extracts on first use, and never runs at boot:

```sh
#!/bin/sh
T=/tmp/opt
[ -x "$T/usr/sbin/app" ] && exit 0
[ -b /dev/sda3 ] || { echo "no /dev/sda3"; exit 1; }
rm -rf /tmp/oc.tmp; mkdir -p /tmp/oc.tmp
dd if=/dev/sda3 bs=4096 count=396 2>/dev/null | gunzip -c | tar xf - -C /tmp/oc.tmp || { rm -rf /tmp/oc.tmp; exit 1; }
chmod 755 /tmp/oc.tmp/usr/sbin/app
rm -rf "$T"; mv /tmp/oc.tmp "$T"
```

The wrapper sets `LD_LIBRARY_PATH` and `PATH`, creates `/dev/net/tun`, `insmod`s `tun.ko` from the payload, then `exec`s the binary with `"$@"`. Copy working versions from `assets/oc` and `assets/oc-load`.

## 5. Keep the peak low

- Stream instead of staging: `dd | gunzip | tar x` avoids a 1.5 MB temp copy.
- Delete each intermediate the moment it is consumed; a tar, a padded copy and a readback copy together triple the footprint.
- Extract only what runs: binaries, needed libs, one script, one kernel module.
- Prefer an app version built with the router's own libraries; a smaller dependency closure is also a smaller RAM bill.
- Tell the user how to unload: `rm -rf /tmp/opt`.

## 6. Time and trust anchors

Minimal images have no RTC and often no CA bundle, and both break TLS in ways the error message hides:

- Wrong clock → `certificate not yet activated` / `certificate has expired`, even with a correct CA. Check `date` before blaming certificates.
- No `/etc/ssl/certs` → every public certificate fails. Ship a CA bundle inside the payload and pass it as `--cafile` unless the user supplies their own.
- No RTC → the clock resets at boot. OpenWrt's `sysfixtime` restores it from the newest mtime under `/etc`, so `date -s` plus `touch /etc/.timefix` survives reboots; `ntpd` corrects it once there is an uplink.
- Offline devices can still validate: pin with `--servercert sha256:<pin>` when the clock cannot be trusted.

## 7. Verify like it is production

1. Reboot the router, reconnect, confirm `date`, `ls -l /dev/sdX`, and that the payload md5 still matches.
2. Run the wrapper's `--version`.
3. Prove TLS end to end: serve a self-signed certificate from the workstation (`assets/tls-test-server.ps1`), connect with `--resolve <name>:<ip> <name>:<port>`, and expect `SSL negotiation`, a verified certificate, and an HTTP response. A protocol error such as `Unexpected 404` means the stack is good; a certificate error is not acceptable.
4. Remove the test certificate from the CA bundle afterwards by re-extracting the payload, and state the remaining limits: USB must stay plugged in, RAM headroom, throughput ceiling.

## Anti-patterns

- Installing vfat/ext4 to "just mount the stick" when flash is the constraint — the driver is the thing that does not fit.
- Staging the payload twice in `/tmp`; the second copy is what triggers the OOM reboot.
- Using OpenWrt's `/lib/netifd/vpnc-script` standalone: it requires `$INTERFACE` and exits. Use the upstream generic script.
- Repartitioning or formatting a stick that holds a bootable image without explicit approval.
- Long multi-step SSH one-liners on a memory-starved box: the session dies mid-command and the output is lost. One logical step per connection, background jobs to a log file, read the log in a separate call.

See `references/openconnect-case.md` for the measured numbers, the exact package set, and the rebuild-after-firmware-upgrade procedure.
