# esxi-to-proxmox

A menu-driven shell script for migrating virtual machines from a VMware ESXi host to Proxmox VE. Runs on the Proxmox host and pulls VMs across the wire via SSH — no vCenter, no VDDK, no VMware CLI required.

---

## Background

Migrating VMs off ESXi — especially the free hypervisor tier — is more painful than it should be. The free tier locks out the API and VDDK layer, vSphere Converter is end-of-life, and the ESXi shell tooling is minimal. This script fills that gap by working entirely through SSH using tools already present on a standard Proxmox VE host.

It was built for the scenario of migrating an on-premise ESXi fleet to Proxmox without cloud involvement, and handles the real-world messiness of that process: thin-provisioned disks, split VMDKs, multi-disk VMs, multi-NIC VMs, per-VM network assignments, BIOS/UEFI detection, OS-aware defaults, and large inventories.

---

## Requirements

### Proxmox Host (where the script runs)
- Proxmox VE (Debian-based) — **must run as root**
- `ssh`, `rsync`, `qemu-img`, `qm`, `pvesm`, `python3`

### Optional (Proxmox host)
- `sshpass` — required only for password-based auth (`apt-get install sshpass`)
- `virt-v2v` — required for Windows VM migrations (`apt-get install virt-v2v`)

### ESXi Host
- ESXi 6.x or 7.x (free tier supported)
- SSH access enabled: **Host → Actions → Services → Enable Secure Shell**
- No vCenter or additional licensing required

---

## Staging Space — Important

The script transfers disk files to a local staging directory before converting them. **This directory must have enough free space to hold the transferred disk data.**

> **Do not use your OS drive as staging.** If the root partition fills up during a transfer, Proxmox itself can become unstable or unresponsive. Use a separate data partition or mount point. The default staging path is `/var/lib/vz/images/tmp` — verify this is on a data volume, not your root filesystem, before migrating large VMs.

Check available space before starting:
```bash
df -h /mnt/your-staging-path
```

As a safe rule: ensure staging has at least **1.5× the actual used disk size** of the largest VM you are migrating.

---

## Installation

```bash
# On your Proxmox host, as root:
wget https://raw.githubusercontent.com/yourusername/esxi-to-proxmox/main/esxi-migrate.sh
chmod +x esxi-migrate.sh
bash esxi-migrate.sh [esxi-host-ip]
```

> **Must run as root.** `qm`, `pvesm`, and Proxmox storage paths all require root. SSH in as root or use `sudo -i` first.

---

## Menu Overview

```
  1)  Check prerequisites
  2)  Configure ESXi connection
  3)  Select datastore
  4)  Scan VMs on ESXi
  5)  Display VM list
  6)  Select VMs for migration  (assigns per-VM bridges)
  7)  Configure Proxmox settings  (storage / bridge / format / machine / CPU / disk bus)
  8)  Manage queue  (remove VMs, reassign bridges, clear)
  9)  Start migration
 10)  View log
```

### Recommended First-Run Order
Run options 1 → 2 → 3 → 4 → 7 → 6 → 9. Configure Proxmox settings (option 7) before selecting VMs (option 6) so the session defaults are in place when you queue VMs.

---

## What It Does (Per VM)

### Transfer
Files are transferred in priority order — **metadata first, disk data last**:

1. `.vmx` — VM configuration (CPU, RAM, firmware, OS, NICs)
2. `.nvram` — BIOS/UEFI state
3. VMDK descriptor — small metadata file
4. Flat VMDKs — the large disk data files, always last

This ensures that if a connection issue interrupts a long disk transfer, the VMX is already on disk and VM creation can still proceed correctly.

File transfers use `ssh cat | dd conv=sparse` — ESXi does not include rsync, so this is the reliable alternative. Zero-filled blocks are written as filesystem holes on the destination, preserving thin provisioning. Each file is verified non-empty after transfer and retried with a fresh connection if empty.

**Files excluded:** `*.vmsd`, `*.vmxf`, `*.log`, `*.lck`

### Conversion
`qemu-img convert` runs on the VMDK descriptor. If only a flat VMDK transferred (descriptor missing), the script falls back to treating it as raw. `qemu-img check` runs after conversion to verify integrity.

**Storage format guidance:**

| Storage type | Supported formats | Snapshot support |
|---|---|---|
| LVM-thin | raw only | Yes — native LVM CoW |
| ZFS | raw only | Yes — native ZFS snapshots |
| Directory | raw, qcow2, vmdk | Yes — via qcow2 |

The script detects the storage type and automatically switches to raw if qcow2 is not supported, rather than failing at import time.

### VM Creation
The `.vmx` file is parsed and mapped to Proxmox settings automatically:

| VMX | Proxmox |
|-----|---------|
| `numvcpus` | `--cores` |
| `memsize` | `--memory` |
| `firmware = "efi"` | `--bios ovmf` + EFI disk |
| `firmware = "bios"` / absent | SeaBIOS |
| `guestOS` | `--ostype` (auto-mapped) |
| `ethernetN.virtualDev` | Per-NIC model, prompted individually |

All values are shown before creation and can be overridden at the prompt.

---

## VM Settings Guide

### Machine Type
Both Linux and Windows VMs run on one of two virtual chipsets:

| Option | Chipset | Recommendation |
|--------|---------|----------------|
| Default | Proxmox decides and pins | Safe for all VMs |
| `pc` | i440FX / PIIX | Windows VMs migrating from VMware (closest to VMware's virtual hardware) |
| `q35` | PCIe / ICH9 | Linux VMs; Windows 10/11 after initial boot confirmed |

Linux VMs boot fine on either. Windows is more sensitive — `pc` is the safer initial choice.

### CPU Type

| Option | Notes |
|--------|-------|
| `kvm64` | Safe default — works across CPU generations, supports live migration |
| `host` | Best performance — passes host CPU features through, ties VM to matching hardware |
| `x86-64-v2-AES` | Good balance — modern baseline with AES acceleration |

### Disk Bus

| Option | Notes |
|--------|-------|
| `scsi` (virtio-scsi-pci) | Best for Linux — kernel has native drivers |
| `sata` | **Best for Windows initially** — boots without extra drivers |
| `ide` | Most compatible fallback |
| `virtio` | Fastest Linux I/O |

> **Windows tip:** Start with `sata`. After booting and installing VirtIO drivers, change to `scsi` for better performance.

### Network Adapter
Set per-NIC at VM creation time. VMware adapter types are automatically mapped:

| VMware | Proxmox |
|--------|---------|
| vmxnet3 | virtio |
| e1000 / e1000e | e1000 |

> **Windows tip:** `e1000` works without extra drivers. Switch to `virtio` after VirtIO drivers are installed.

---

## Multi-NIC VMs

All adapters defined in the VMX are detected automatically. At VM creation you are prompted for bridge and model per NIC:

```
  NIC 1 of 3  (VMware: vmxnet3  →  Proxmox default: virtio)
    Bridge [vmbr0]:
    Model  [virtio]:

  NIC 2 of 3  (VMware: e1000  →  Proxmox default: e1000)
    Bridge [vmbr0]:  vmbr1
    Model  [e1000]:
```

NIC 0 defaults to the bridge assigned at queue time. Additional NICs default to the session bridge.

---

## Troubleshooting Boot Problems

If a migrated VM fails to boot, start with these two settings in the Proxmox web UI:

**1. BIOS type mismatch**
The script auto-detects `firmware = "efi"` in the VMX and sets OVMF, with SeaBIOS as the default for anything else. If a VM was running SeaBIOS in VMware but the VMX firmware line wasn't parsed correctly, it may have been created with the wrong BIOS type. Check:
```bash
grep -i firmware /path/to/vm.vmx
```
If the line is absent or says `bios`, the VM uses SeaBIOS. Correct the BIOS type in Proxmox under VM → Hardware → BIOS. No data is lost changing this setting.

**2. OS type**
The `ostype` setting affects what virtual hardware features Proxmox presents. Linux VMs should be `l26` (Linux 2.6+ kernel). If the VMX `guestOS` string wasn't recognized it may have defaulted to `other`. Change it under VM → Options → OS Type — no reinstallation required.

Common values: `l26` (Linux), `win10` (Windows 10/11/2019/2022), `win8` (Windows 8/2012), `other`.

---

## Windows VMs

Windows VMs need extra handling due to VirtIO driver requirements. Options:

**Option A — SATA/e1000 first (simpler):**
Set disk bus to `sata` and NIC to `e1000` in option 7 before migrating. Windows boots with built-in drivers. Then install VirtIO drivers from the [VirtIO ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso) and switch to scsi/virtio for performance.

**Option B — virt-v2v (automated driver injection):**
```bash
apt-get install virt-v2v
virt-v2v -i vmx '/path/to/vm.vmx' \
  -o local -os /var/lib/vz/images/tmp \
  --bridge vmbr0
```
The script prints the exact command for each detected Windows VM.

---

## Snapshots

VMware snapshot chains cannot be reconstructed by `qemu-img`. Consolidate before migrating:

**ESXi web UI:** Right-click VM → Snapshots → Delete All

The script warns and asks for confirmation if you attempt to queue a VM with active snapshots.

---

## SSH Authentication

SSH key auth is strongly recommended. To install a key on ESXi:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_esxi
cat ~/.ssh/id_esxi.pub | ssh root@your-esxi-host \
  'cat >> /etc/ssh/keys-root/authorized_keys'
```

Password auth is supported via `sshpass` (`apt-get install sshpass`).

---

## Logging

Every run writes a timestamped log to `/var/log/esxi-migrate-YYYYMMDD-HHMMSS.log`. View it from within the script via option 10.

---

## Known Limitations

- **Snapshot consolidation must happen on ESXi** — cannot be done remotely
- **Live VM transfer is not safe** — inconsistent disk state; script warns but cannot prevent
- **Windows VMs require extra steps** — VirtIO drivers or sata/e1000 workaround
- **No rsync on ESXi** — full thin-provisioned size transfers over the wire
- **Must run as root on Proxmox**

---

## TODO

- [ ] Clean up bridge assignment — currently set at queue time, per-NIC at creation, and as session default; some redundancy exists
- [ ] OS-aware VM setting defaults — auto-suggest `q35/scsi/virtio` for Linux and `pc/sata/e1000` for Windows based on detected guestOS
- [ ] Resume interrupted transfers — currently re-runs full transfer if any file failed

---

## Contributing

Issues and PRs welcome. If you hit ESXi version-specific differences in `vim-cmd` output or BusyBox tool availability, open an issue with the raw output — ESXi's environment varies enough between builds that edge cases are expected.

---

## License

MIT
