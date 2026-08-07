# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AmneziaWG userspace VPN client + web UI addon for Asuswrt-Merlin (aarch64 and ARM32 routers). Provides
DPI-obfuscated WireGuard VPN with per-device policy routing and GeoIP/GeoSite selective routing.
All documentation and UI text is in Russian (README.md) with an English mirror (README_EN.md).

**Target:** aarch64 (GT-AX11000, RT-AX86U, RT-AX88U, etc.) and ARM32 (RT-AC68U and newer HND routers),
Asuswrt-Merlin `384.15`+ / `3006.x`, with Entware installed. Fully userspace -- runs on any kernel
version, no kernel module or module rebuild required per firmware update.

Supports both **AmneziaWG 2.0** (Jc/Jmin/Jmax/S1-S4/H1-H4/I1-I5 obfuscation) and **AmneziaWG 3.0**
(HeaderProtectionKey/ContentPaddingAddition/RekeyAfterTime/RekeyTimeout/RejectAfterTime/
KeepaliveTimeout/MaxHandshakeAttempts) -- the 3.0 fields are optional and only emitted into the
generated config if the corresponding settings are non-empty, so a 2.0-only server config keeps
working unchanged.

## Build

Two independent binaries are cross-compiled and shipped per architecture:

- `amneziawg-go` -- pure Go, no C toolchain or router-specific files needed:
  ```bash
  git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-go.git
  cd amneziawg-go
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o amneziawg-go        # aarch64-3.10
  CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=5 go build -ldflags="-s -w" -o amneziawg-go-arm5  # armv7-2.6
  CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -ldflags="-s -w" -o amneziawg-go-arm   # armv7-3.2
  ```
  Optional, for the lower-RAM models in the support list (256-512MB): bound amneziawg-go's
  buffer pools before building, then launch the daemon with `GOMEMLIMIT=320MiB GOGC=20` (already
  done in `do_start`) -- otherwise the pools grow unbounded under sustained high-throughput
  traffic. Ported from advocdiaboly/asuswrt-merlin-amneziawg@ea58f06 (Dmitry Fomin):
  ```bash
  sed -i 's/PreallocatedBuffersPerPool = 0/PreallocatedBuffersPerPool = 1024/' device/queueconstants_default.go
  ```
- `awg` (amneziawg-tools CLI) -- C, needs a matching cross toolchain per arch. Its Makefile does
  **not** depend on kernel headers/config at all (that's only relevant for a kernel-module build,
  which this project does not use) -- only a working `CC`/`LD`/`AR` and libc:
  - aarch64: Broadcom HND toolchain via `./build.sh` (see `Dockerfile`) -- downloads
    `am-toolchains` (gcc 5.5 / glibc 2.26), needs `libc6-i386 lib32stdc++6 lib32z1` on the build
    host since the toolchain binaries are 32-bit x86.
  - ARM32 (both `armv7-2.6` and `armv7-3.2`, one static binary covers both): `Dockerfile.arm32`,
    self-contained musl.cc cross-toolchain, no router-specific files needed.

Pin the `amneziawg-tools` tag to whatever upstream tag introduced the feature set you need (e.g.
3.0 support landed after `v1.0.20260618`, in the `v3.0.*` tag series) -- check
`amnezia-vpn/amneziawg-tools` tags/`src/config.c` if config fields silently fail to apply.

```bash
./build-ipk.sh   # packages output/* into output/amneziawg_<ver>_<arch>.ipk
```

## Architecture

### Router-side components

**`addon/amneziawg.sh`** -- Main backend script (runs on router). Handles:
- Interface lifecycle: `start`/`stop`/`restart` (spawns `amneziawg-go`, `awg setconf`, `ip link`,
  iptables, ip rule)
- Config generation from Merlin's `custom_settings.txt` (key prefix: `awg_*`) in `generate_config()`
- Per-device routing policy: `vpn_all`, `vpn_geo`, `direct` via ip rules + iptables mangle marks
- GeoIP/GeoSite: downloads per-service domain/CIDR lists from itdoginfo/allow-domains, populates
  ipset (`awg_dst`) + dnsmasq ipset rules
- Web UI addon mounting via Merlin Addons API (`am_get_webui_page`, menuTree.js bind mount)
- Service event dispatch (called from `/jffs/scripts/service-event`)
- Watchdog (cron every 5 min): restarts the tunnel if the interface/process is gone or traffic
  stops passing

**`addon/amneziawg_page.asp`** -- Web UI page (ROG-styled ASP). Communicates with backend via
Merlin's `httpApi` custom settings and service events (`awgstart`, `awgstop`, `awgsaveconf`,
`awgupdategeo`). Reads status from `/www/user/awg_status.htm` (JSON). `parseConfig()` auto-detects
both 2.0 and 3.0 fields when importing a `.conf` file.

**`install.sh` / `install-online.sh`** -- One-shot installers (run on router via SSH).

### Key paths on router
- `/opt/amneziawg/` -- `amneziawg-go`, `awg`, generated `awg0.conf`, `clients.list`, `geo/`
- `/opt/amneziawg/geo/geoip/*.cidr` -- per-service IP ranges (itdoginfo/allow-domains, Subnets/IPv4)
- `/opt/amneziawg/geo/services/*.txt` -- cached per-service domain lists (itdoginfo/allow-domains,
  Services/), downloaded once by `download_all_geo()`
- `/opt/amneziawg/geo/domains/geosite_*.txt` -- subset of the above actually selected via the
  `awg_geosite_services` setting, copied in at `setup_firewall()` time and fed to dnsmasq
- `/jffs/addons/amneziawg/` -- addon script + ASP page
- `/jffs/configs/dnsmasq.conf.add` -- domain-based routing rules (`conf-file=` include, generated
  from `$GEO_DIR/dnsmasq_awg.conf`)
- `/jffs/addons/custom_settings.txt` -- Merlin settings store (all keys prefixed `awg_`)

### Routing model
Three policies per device: `vpn_all` (ip rule -> table 300), `vpn_geo` (iptables fwmark 0x100 +
ipset match -> table 300), `direct`. Default policy applies to unlisted devices. Route table 300,
fwmark 0x100.

### GeoIP/GeoSite source
Lists come from [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains) (plain-text
`Subnets/IPv4/<svc>.lst` and `Services/<svc>.lst`, one entry per line, no parsing needed). Service
name lists (`GEOIP_SERVICES`, `GEOSITE_SERVICES` in `amneziawg.sh`) must match the filenames
actually present in that repo -- not every domain-list service has a matching subnet list (e.g.
CDN-fronted services like `youtube`/`google_ai`/`tiktok` are domain-only, no stable IP ranges).

## Shell scripting notes

All router-side scripts must be POSIX sh (busybox ash) -- no bashisms. The router runs BusyBox with
limited coreutils. `local` is supported by ash but keep variable scoping explicit and avoid arrays.
