# Astra Linux ISO to Docker Patch Images

[![Build and Push Astra Linux Docker Images](https://github.com/runalsh/astra-iso-patch/actions/workflows/build-and-push.yml/badge.svg)](https://github.com/runalsh/astra-iso-patch/actions/workflows/build-and-push.yml)

Automated Docker images for exact Astra Linux Special Edition releases (**1.8**, **1.7**) built directly from official DVD/Installation ISOs into **`runalsh/astra-iso-patch`** and **`ghcr.io/runalsh/astra-iso-patch`**, with full `systemd` (PID 1) support.

---

## ❓ Problem Statement

Official Astra Linux base images or raw VM installations:
- **Heavily bloated on disk (4–10 GB)** due to hardware device firmware (`/usr/lib/firmware` ~1.7 GB), Linux kernel binaries and modules (`/usr/lib/modules` ~650 MB), and bootloaders.
- Official `ubi` container images distributed via registry are heavily stripped down, lacking `systemd` / PID 1 init support and missing essential administration tools (`sudo`, `curl`, `iproute2`, `mc`, `vim`, `ssh`).
- This project builds full-featured Docker images directly from official installation ISOs, strips non-container hardware bloat, and provides out-of-the-box support for **`systemd` (PID 1)**.

---

## 📦 Presets

| Preset Name | Description | Key Components | Image Size |
|---|---|---|---|
| **`server`** *(default)* | Full server environment (analogous to base VM install) | `systemd`, `openssh-server`, `sudo`, `curl`, `mc`, `vim`, `p7zip`, `lsof`, `rsync`, `ufw`, `parsec` (Astra SE tools), `python3`, `apt` | **~424 MB** (~130 MB compressed) |
| **`minimal`** | Clean headless base | `systemd`, `apt`, `sudo`, `curl`, `iproute2`, `procps`, `ca-certificates`, `python3` | **~350 MB** (~100 MB compressed) |

---

## ✂️ What is Stripped from the ISO (Size Optimization)

A standard virtual machine installation of Astra Linux takes **~4.1 GB** of disk space. After container-tailored optimizations, the final Docker image is reduced to **~424 MB** (saving over **3.6 GB / >89%**):

| Component / Path | What it is | Why it is safe to remove in Docker | Disk Space Saved |
|---|---|---|---|
| **Hardware Firmware** (`/usr/lib/firmware`, `/lib/firmware`) | GPU, Wi-Fi, audio, NIC device firmware | Containers do not interact with bare-metal chips. | **~1.7 GB** |
| **Linux Kernel & Modules** (`/usr/lib/modules`, `/lib/modules`, `/boot/*`) | Kernel binary (`vmlinuz`), `initrd`, kernel modules | Containers share the host Linux OS kernel. | **~730 MB** |
| **Printing & Scanner Stacks** (`cups*`, `sane*`, `ghostscript`) | Print spooler daemons and printer drivers | Not used in automated container environments. | **~120 MB** |
| **Hardware & ACPI Daemons** (`acpid`, `wireless-tools`, `wpasupplicant`) | Power management and wireless device daemons | Containers do not manage hardware power states. | **~40 MB** |
| **Non-RU/EN Locales** (`/usr/share/locale/*`) | Translations for hundreds of unneeded languages | Containers strictly preserve `ru_RU.UTF-8`, `en_US.UTF-8`, `POSIX`. | **~60 MB** |
| **Documentation & Manuals** (`/usr/share/{doc,man,info}`) | Package READMEs, changelogs, man pages | Not needed for automated runtime or CI pipelines. | **~100 MB** |
| **Package Caches & Logs** (`/var/cache/apt/*`, `/var/lib/apt/lists/*`, `/var/log/*`) | APT index caches and temporary install logs | Refreshed dynamically during `apt-get update`. | **~40 MB** |
| **Total Savings** | | | **~3.6+ GB (>89% reduction)** |

---

## ⚡ Systemd (PID 1) Compatibility

- Masked unnecessary hardware getty consoles (`getty.target`, `console-getty.service`) and `udev`.
- Container environment is flagged with `container=docker` and `STOPSIGNAL SIGRTMIN+3`.
- Running with `/sbin/init` achieves active systemd PID 1 state with auto-started SSH service.
- Default remote repositories in `/etc/apt/sources.list` point directly to official Astra Linux mirrors (`download.astralinux.ru`).

---

## 🛠 Quick Start

### 1. Building Docker Images Locally

```bash
# Build default 'server' preset from an ISO file
./build.sh "/path/to/astra-installation-1.8.6.iso"

# Build minimal preset
./build.sh --preset minimal "/path/to/astra-installation-1.8.6.iso"

# Build with extra packages included
./build.sh --include "git,htop,iotop" "/path/to/astra-installation-1.8.6.iso"
```

### 2. Run Container with Systemd

```bash
docker run -d --name astra \
  --privileged \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  runalsh/astra-iso-patch:1.8.6
```

### 3. Connect into Container

```bash
docker exec -it astra bash
```
