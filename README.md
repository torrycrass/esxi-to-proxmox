# esxi-to-proxmox

A menu-driven shell script for migrating virtual machines from a VMware ESXi host to Proxmox VE. Runs on the Proxmox host and pulls VMs across the wire via SSH and rsync — no vCenter, no VDDK, no VMware CLI gymnastics required.

---

## Background

Migrating VMs off ESXi — especially the free hypervisor tier — is more painful than it should be. The free tier locks out the API and VDDK layer, vSphere Converter is end-of-life, and the ESXi shell tooling is minimal. This script fills that gap by working entirely through SSH, using tools already present on a standard Proxmox VE host.

It was built specifically for the scenario of migrating an on-premise ESXi fleet to Proxmox without cloud involvement, and handles the real-world messiness of that process: thin-provisioned disks, split VMDKs, multi-disk VMs, per-VM network assignments, BIOS/UEFI detection, and large inventories.

---

## Requirements

### Proxmox Host (where the script runs)
- Proxmox VE (Debian-based) — must run as **root**
- `ssh`
- `rsync`
- `qemu-img`
- `qm` (included with Proxmox VE)
- `pvesm` (included with Proxmox VE)
- `python3` (included with Proxmox VE)

### Optional (Proxmox host)
- `sshpass` — required only for password-based auth (`apt-get install sshpass`)
- `virt-v2v` — required for Windows VM migrations (`apt-get install virt-v2v`)

### ESXi Host
- ESXi 6.x or 7.x (free tier supported)
- SSH access enabled: **Host → Actions → Services → Enable Secure Shell**
- `vim-cmd` available (standard on all ESXi installs)
- No vCenter or additional licensing required

---

## Installation

```bash
# On your Proxmox host, as root:
wget https://raw.githubusercontent.com/yourusername/esxi-to-proxmox/main/esxi-migrate.sh
chmod +x esxi-migrate.sh
```

Or clone the repo:

```bash
git clone https://github.com/yourusername/esxi-to-proxmox.git
cd esxi-to-proxmox
chmod +x esxi-migrate.sh
```

> **Note:** The script must be run as root on the Proxmox host. Several operations (`qm`, `pvesm`, writing to Proxmox storage paths) require root. SSH into Proxmox as root, or use `sudo -i` to open a root shell first.

---

## Usage

```bash
bash esxi-migrate.sh [esxi-host-ip]
```

The ESXi host IP is optional — you can also enter it from the menu.

### Menu Overview

```
╔══════════════════════════════════════════════════╗
║      ESXi → Proxmox Migration Tool               ║
╚══════════════════════════════════════════════════╝

  1)  Check prerequisites
  2)  Configure ESXi connection
  3)  Select datastore
  4)  Scan VMs on ESXi
  5)  Display VM list
  6)  Select VMs for migration  (assigns per-VM bridges)
  7)  Configure Proxmox settings  (storage / default bridge / format)
  8)  Manage queue  (remove VMs, reassign bridges, clear)
  9)  ▶  Start migration
 10)  View log
  0)  Exit
```

### Recommended First-Run Order

1. **Option 1** — verify all required tools are present
2. **Option 2** — enter ESXi host IP and authenticate (SSH key recommended)
3. **Option 3** — select the datastore your VMs live on
4. **Option 4** — scan the ESXi host (single SSH session, handles large inventories)
5. **Option 5** — review the VM list with power state, snapshot status, and transfer safety
6. **Option 6** — queue VMs for migration; assign a bridge to each VM at this step
7. **Option 7** — set Proxmox storage target, default bridge, and disk format
8. **Option 8** — optionally adjust the queue (remove VMs, reassign bridges)
9. **Option 9** — start the migration

---

## What It Does (Per VM)

### Transfer
Uses `rsync --sparse` to pull only the data actually written to disk. A 500 GB thin-provisioned VM with 60 GB of actual data transfers ~60 GB, not 500 GB.

**Files included:**
| File | Purpose |
|------|---------|
| `*.vmdk` | VM disk (descriptor + data, including split-chunk VMDKs) |
| `*.vmx` | VM configuration — parsed for CPU, RAM, firmware, OS, NIC type |
| `*.nvram` | BIOS/UEFI state |

**Files excluded:**
| File | Reason |
|------|--------|
| `*.vmsd` | Snapshot database — meaningless outside VMware |
| `*.vmxf` | Extended VMware config — not applicable |
| `*.log` | VMware runtime logs |
| `*.lck` | VMware file lock directories |

### Conversion
Runs `qemu-img convert` on the transferred VMDK descriptor file. Supported output formats (selectable per-VM or as a session default):

| Format | Notes |
|--------|-------|
| `qcow2` thin *(default)* | Proxmox native, supports snapshots |
| `qcow2` compressed | Smaller file, slightly higher CPU overhead on I/O |
| `raw` thin | Best I/O performance, no snapshot support |
| `raw` thick | Full pre-allocation, maximum compatibility |

Runs `qemu-img check` after conversion to verify image integrity before import.

### VM Creation
Reads the `.vmx` file and maps settings to Proxmox equivalents:

| VMX Setting | Proxmox Setting |
|-------------|----------------|
| `numvcpus` | `--cores` |
| `memsize` | `--memory` |
| `firmware = "efi"` | `--bios ovmf` |
| `guestOS` | `--ostype` (mapped to Proxmox type) |
| `ethernet0.virtualDev = "vmxnet3"` | `--net0 virtio,...` |
| `ethernet0.virtualDev = "e1000"` | `--net0 e1000,...` |

All detected values are shown and can be overridden before the VM is created. VMID is auto-assigned via Proxmox but can be changed at the prompt.

---

## VM Safety Indicators

The VM list display flags each VM for safe transfer:

| Indicator | Meaning |
|-----------|---------|
| `YES` (green) | Powered off, no snapshots — safe to transfer |
| `CONSOLIDATE` (yellow) | Has snapshots — see note below |
| `NO (running)` (red) | VM is powered on — risk of inconsistent disk state |

### Snapshots

VMware snapshot chains cannot be reconstructed by `qemu-img`. Before migrating any VM with snapshots, consolidate them in ESXi first:

**ESXi web UI:** Right-click VM → Snapshots → Delete All

The script will warn you and ask for confirmation if you attempt to queue a VM with active snapshots.

---

## Per-VM Bridge Assignment

Each VM can be assigned to a different Proxmox bridge at queue time (option 6). The session default bridge is used as the starting value but can be overridden per VM. Assignments can be reviewed and changed anytime via option 8 (queue manager) or at the final confirmation step before each VM is created.

---

## Windows VMs

The script detects Windows guest OS from the `.vmx` file and warns before creation. Windows VMs migrated via `qemu-img` will likely **not boot** without VirtIO drivers. The recommended path for Windows is `virt-v2v`, which injects drivers automatically:

```bash
apt-get install virt-v2v

virt-v2v -i vmx '/path/to/vm.vmx' \
  -o local -os /var/lib/vz/images/tmp \
  --bridge vmbr0
```

The script displays the exact `virt-v2v` command for each detected Windows VM.

---

## Multi-Disk VMs

VMs with multiple VMDKs are handled automatically. The script finds all VMDK descriptor files in the VM directory, converts each one, and attaches them as sequential SCSI devices (`scsi0`, `scsi1`, etc.) on the Proxmox VM.

## Split VMDKs (2 GB chunks)

VMDKs split into 2 GB chunks (common on older VMware deployments) are handled transparently. `qemu-img` reads the descriptor file and reassembles the chunks automatically. All split files are included in the rsync transfer.

---

## SSH Authentication

SSH key authentication is strongly recommended over password auth. To set up key access to an ESXi host (ESXi doesn't support `ssh-copy-id` directly):

```bash
# Generate a key if you don't have one
ssh-keygen -t ed25519 -f ~/.ssh/id_esxi

# Install it on ESXi
cat ~/.ssh/id_esxi.pub | ssh root@your-esxi-host \
  'cat >> /etc/ssh/keys-root/authorized_keys'
```

Password auth is supported via `sshpass` if needed.

---

## Logging

Every migration run writes a timestamped log to `/var/log/esxi-migrate-YYYYMMDD-HHMMSS.log`. The log captures all SSH operations, rsync transfers, conversion commands, `qm` invocations, and success/failure status per VM. Viewable from within the script via option 10.

---

## Known Limitations

- **Snapshot consolidation must happen on ESXi** — the script cannot consolidate snapshots remotely; this is a VMware-side operation
- **Live VM migration is not safe** — the script warns but cannot prevent transferring a running VM; the resulting disk image may be inconsistent
- **Windows VMs require `virt-v2v`** — direct `qemu-img` conversion produces a non-bootable result without driver injection
- **ESXi free tier only** — the script uses SSH and `vim-cmd`, not the vSphere API; vCenter environments could use this approach but there may be better options available to licensed users
- **Must run as root on Proxmox** — `qm`, `pvesm`, and Proxmox storage paths all require root access

---

## Contributing

Issues and pull requests welcome. If you run into ESXi version-specific output format differences (particularly in `vim-cmd` output), opening an issue with the raw output is the most helpful thing you can do — ESXi's BusyBox environment varies enough between versions that edge cases are expected.

---

## License

MIT
