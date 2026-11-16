# dsh-skill-openwrt-tiny-flash-install

A [DeepSeek Harness](https://github.com/) skill for installing software on an
OpenWrt/LEDE router whose flash is nearly full 鈥?keeping only kernel modules in
flash and running the application from a payload stored **raw on USB** and
extracted into tmpfs on first use.

Written from a real job: installing the `openconnect` VPN client on a
TP-Link TL-MR3420 v1 (4 MB flash, 32 MB RAM, LEDE 17.01.7), where the package
does not exist in the release feed, does not fit in `/overlay`, and the box has
no RTC, no CA bundle and no uplink.

## What it covers

- measuring flash/RAM/module constraints before choosing a strategy
- picking a package from a newer release while keeping the router's own libs (ABI)
- storing a 1.6 MB payload with **no** filesystem driver (no vfat/ext4 kmods)
- a lazy loader + wrapper that costs a few hundred bytes of flash
- keeping peak RAM low enough not to OOM a 32 MB device
- TLS trust anchors: clock via `sysfixtime`, CA bundle, `--servercert` pinning
- the netifd `vpnc-script` trap, and a generic replacement
- verification: cold reboot, md5 readback, real TLS handshake against a local server

## Layout

```
openwrt-tiny-flash-install/
鈹溾攢鈹€ SKILL.md                          the procedure
鈹溾攢鈹€ references/
鈹?  鈹斺攢鈹€ openconnect-case.md           measured numbers, pitfalls, rebuild steps
鈹斺攢鈹€ assets/
    鈹溾攢鈹€ oc                            wrapper (LD_LIBRARY_PATH, tun, --cafile)
    鈹溾攢鈹€ oc-load                       lazy extractor for the USB payload
    鈹溾攢鈹€ build-payload.sh              builds + verifies the raw payload
    鈹溾攢鈹€ serve-http.ps1                no-privilege HTTP server for offline routers
    鈹斺攢鈹€ tls-test-server.ps1           self-signed TLS endpoint for stack testing
```

## Install

```sh
git clone https://github.com/pandabalckpink/dsh-skill-openwrt-tiny-flash-install
mkdir -p ~/.dsh/skills
cp -r dsh-skill-openwrt-tiny-flash-install/openwrt-tiny-flash-install ~/.dsh/skills/
```

Skill roots are scanned at depth 1, so `<root>/<name>/SKILL.md` is what matters.
Use `~/.dsh/skills` for a user-wide skill, or `<project>/.dsh/skills` for one repo.

## Safety notes

- These steps write raw bytes into a USB partition. Confirm the target is blank
  and never overwrite a partition that holds a bootable image without telling
  the user.
- On a 4 MB device, leaving less than one jffs2 erase block (~64 KB) free can
  break future config writes.

## License

MIT.
