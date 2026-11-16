# Reference case: openconnect on a 4 MB / 32 MB router

Measured on a TP-Link TL-MR3420 v1 (Atheros AR7241, MIPS 24Kc, LEDE 17.01.7,
kernel 4.4.182, 4 MB flash, 32 MB RAM, no RTC). Keep the numbers as a sanity
baseline for similar hardware.

## What the box actually had

```
/overlay (mtdblock3)   384K total, 228K used, 156K free
/tmp (tmpfs)           13.7M total
RAM                    28 MB visible, ~19 MB used at boot, ~9 MB free
openconnect in 17.01   absent from every feed
```

`du -sk /overlay/*` reported only 14 KB of files while `df` said 228 KB used —
jffs2 overhead. Do not trust `du` for the free-space decision.

## Package choice

| item | source | note |
|---|---|---|
| openconnect 7.08-8 | 18.06.9 `packages/mips_24kc/packages` | binary only |
| libgnutls 3.5.16, libnettle 3.3, libgmp 6.1.2, libxml2 2.9.4, zlib 1.2.11, libtasn1 4.12 | 17.01.7 | matched to the router's musl |
| vpnc-scripts | 17.01 | replaced, see below |
| resolveip | 17.01 | used by the wrapper path |

Dependency closure of `openconnect 7.08` = 1.43 MB of ipks, but ~3.3 MB
uncompressed once extracted, and 1.62 MB as `tar.gz`.

## Flash budget outcome

Installed to flash: `kmod-scsi-core` (74 KB) + `kmod-usb-storage` (22 KB) +
`kmod-nls-cp437` (2 KB). That moved `/overlay` from 156 KB free to 40 KB free.
`kmod-fs-vfat` (37 KB + nls deps) was rejected because it would have left
~1 KB, below one 64 KB erase block.

Not attempted, for the record: `kmod-fs-ext4` (221 KB), `kmod-fs-exfat` (46 KB),
`kmod-loop` plus a squashfs image (no `mksquashfs` available).

## Payload

```
raw at /dev/sda3 offset 0 : 396 blocks x 4096 B = 1622016 B, gzip'd tar
contents: usr/sbin/openconnect, usr/lib/lib{gnutls,nettle,hogweed,gmp,xml2,tasn1,z}.so*,
          usr/bin/resolveip, lib/modules/4.4.182/tun.ko,
          etc/vpnc-script (upstream generic), etc/ssl/ca-certificates.crt (118 certs)
```

The USB stick was a leftover boot image: GPT, sda1 FAT16 "kernel" (128 MB),
sda2 squashfs (256 MB), sda3 2 GB all zeros, sda4 239 sectors. Only sda3's
first 1.6 MB was written; sda1/sda2 untouched and disclosed to the user.

## Pitfalls hit, in order

1. `openconnect` did not exist in the 17.01 feeds at all. Checking the feed
   `Packages.gz` first would have saved a round trip.
2. Staging the 3.3 MB tar plus a 3.3 MB readback copy in `/tmp` on a 28 MB box
   triggered an OOM that rebooted the router mid-command. The payload had
   already been written, so nothing was lost; the lesson is peak memory.
3. The router had no default route (WAN unplugged, AP-only), so packages came
   from a workstation HTTP server on the LAN, and NTP was unreachable.
4. The clock was stuck at the 2019 firmware build date. TLS failed with
   `certificate not yet activated` even though the CA bundle was correct.
   Fixed with `date -s "<utc>"` + `touch /etc/.timefix`; `sysfixtime` restores
   that mtime at boot.
5. `/lib/netifd/vpnc-script` exits immediately when run standalone because it
   requires `$INTERFACE` and `/lib/netifd/netifd-proto.sh`. Replaced with the
   upstream generic `vpnc-script`, which also carries an OpenWrt DNS path.
6. `--no-cert-check` is removed from this build (7.08, 2020); pinning is
   `--servercert sha256:<pin>` instead.
7. Long SSH one-liners died on this RAM-starved box and lost their output.
   One logical step per connection; background long work to a log file.

## Verification that was accepted

- cold reboot → clock restored to ~now, `/dev/sda3` present, payload md5 equal
  to the written pad file, `oc --version` → `OpenConnect version v7.08`
- local TLS server with a self-signed cert, connected via
  `--resolve vpn-test.local:<ip> vpn-test.local:4443`:
  `SSL negotiation` → certificate verified → `Got HTTP response: HTTP/1.1 404`
  → `Unexpected 404 result from server`. That last line is success for this
  test: the stack negotiated and spoke HTTP, the peer simply is not AnyConnect.

## Rebuild after a firmware upgrade or a new release

1. Re-check `df -k /overlay`; reinstall the storage kmods if they were wiped.
2. Re-download the same package set into `/tmp/ipk`, extract
   `data.tar.gz` from each ipk with `tar xzf <ipk> ./data.tar.gz -O | tar xzf -`.
3. Add `etc/vpnc-script` and `etc/ssl/ca-certificates.crt` into the tree.
4. `tar czf` → `dd conv=sync` → write to the spare partition → md5 verify.
5. Update the block count in `/usr/sbin/oc-load` and reinstall it plus
   `/usr/bin/oc`. Nothing else lives in flash, so nothing else needs replaying.
