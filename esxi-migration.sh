#!/bin/bash
#
# esxi-migrate.sh — ESXi to Proxmox VM Migration Tool
# Version 1.1.0
#
# Run from Proxmox host as root. Pulls VMs from ESXi via SSH/rsync.
#
# Requirements: ssh, rsync, qemu-img, qm, pvesm, python3
# Optional:     sshpass (password auth), virt-v2v (Windows VMs)
#
# Usage: bash esxi-migrate.sh [esxi-host-ip]
#

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Globals ──────────────────────────────────────────────────────────────────
SCRIPT_VERSION="1.2.1"
LOG_FILE="/var/log/esxi-migrate-$(date +%Y%m%d-%H%M%S).log"
DEFAULT_STAGING="/var/lib/vz/images/tmp"
SSH_CTL_PATH="/tmp/esxi-mig-ctl"          # SSH ControlMaster socket path

ESXI_HOST=""
ESXI_USER="root"
ESXI_PASS=""
ESXI_USE_KEY=false
ESXI_KEY_PATH="$HOME/.ssh/id_rsa"

DATASTORE_PATH=""
STAGING_PATH="$DEFAULT_STAGING"
PROXMOX_STORAGE=""
BRIDGE="vmbr0"
CONVERT_FORMAT="qcow2"
CONVERT_OPTS=""
MACHINE_TYPE=""        # blank = Proxmox default; "pc" (i440fx) or "q35"
CPU_TYPE="kvm64"       # kvm64 = safe default; "host" = max perf (breaks live migrate)
DISK_BUS="scsi"        # scsi (virtio-scsi-pci), sata, ide, virtio
SCSIHW="virtio-scsi-pci"  # set automatically based on DISK_BUS choice

declare -A VM_IDS=()       # vmname -> vmid
declare -A VM_STATES=()    # vmname -> power state string
declare -A VM_SNAPS=()     # vmname -> snapshot count
declare -A VM_PATHS=()     # vmname -> vmx relative path
declare -A VM_BRIDGE=()    # vmname -> assigned bridge (set at queue time)
declare -a SORTED_VM_NAMES=()
declare -a VM_QUEUE=()
declare -a CONVERTED_DISKS=()

# ─── Logging ──────────────────────────────────────────────────────────────────
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; log "[INFO]  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; log "[WARN]  $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*"; log "[ERROR] $*"; }
section() { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}"; log "=== $* ==="; }
hr()      { printf '%0.s─' {1..72}; echo; }
pause()   { echo ""; read -rp "Press Enter to continue..."; }

# ─── SSH Helpers ──────────────────────────────────────────────────────────────
# ControlMaster=auto keeps one persistent connection; subsequent calls reuse it.
# This avoids ESXi's low per-user SSH connection limits during bulk operations.
_ssh_base_opts() {
    echo "-o StrictHostKeyChecking=accept-new \
          -o ConnectTimeout=15 \
          -o ControlMaster=auto \
          -o ControlPath=${SSH_CTL_PATH} \
          -o ControlPersist=28800"
}

esxi_ssh() {
    local opts; opts=$(_ssh_base_opts)
    if $ESXI_USE_KEY; then
        ssh $opts -i "$ESXI_KEY_PATH" "${ESXI_USER}@${ESXI_HOST}" "$@" 2>/dev/null
    else
        sshpass -p "$ESXI_PASS" ssh $opts "${ESXI_USER}@${ESXI_HOST}" "$@" 2>/dev/null
    fi
}

# Run a multi-line shell script on ESXi via stdin redirection.
# Writes the script to a local temp file on Proxmox, then pipes it as stdin
# to the remote /bin/sh. Avoids base64 (not available on all ESXi builds)
# and sidesteps all SSH quoting/escaping issues entirely.
esxi_run_script() {
    local script="$1"
    local tmp_script exit_code result
    tmp_script=$(mktemp /tmp/esxi-script-XXXXXX.sh)
    printf '%s\n' "$script" > "$tmp_script"

    local opts; opts=$(_ssh_base_opts)
    if $ESXI_USE_KEY; then
        result=$(ssh $opts -i "$ESXI_KEY_PATH" "${ESXI_USER}@${ESXI_HOST}" /bin/sh < "$tmp_script" 2>/dev/null)
        exit_code=$?
    else
        result=$(sshpass -p "$ESXI_PASS" ssh $opts "${ESXI_USER}@${ESXI_HOST}" /bin/sh < "$tmp_script" 2>/dev/null)
        exit_code=$?
    fi

    rm -f "$tmp_script"
    printf '%s\n' "$result"
    return $exit_code
}

# Transfer a single file from ESXi to Proxmox via SSH + cat | dd.
# ESXi does not have rsync, so we use cat on the remote side and
# GNU dd with conv=sparse on the Proxmox side to reconstruct
# thin-provisioned files as sparse files on the destination.
# Note: the full thin-provisioned size travels over the wire (zero blocks
# included), but the destination file is sparse so only written blocks
# consume actual disk space.
esxi_transfer_file() {
    local remote_src="$1"
    local local_dst="$2"
    local opts; opts=$(_ssh_base_opts)

    if $ESXI_USE_KEY; then
        ssh $opts -i "$ESXI_KEY_PATH" "${ESXI_USER}@${ESXI_HOST}"             "cat '${remote_src}'" 2>/dev/null             | dd of="$local_dst" bs=1M conv=sparse status=progress 2>&1
    else
        sshpass -p "$ESXI_PASS" ssh $opts "${ESXI_USER}@${ESXI_HOST}"             "cat '${remote_src}'" 2>/dev/null             | dd of="$local_dst" bs=1M conv=sparse status=progress 2>&1
    fi

    local pipe_rc=("${PIPESTATUS[@]}")
    # PIPESTATUS[0] = ssh/sshpass exit code, PIPESTATUS[1] = dd exit code
    if [[ ${pipe_rc[0]} -ne 0 || ${pipe_rc[1]} -ne 0 ]]; then
        err "Transfer failed: $(basename "$remote_src")  (ssh:${pipe_rc[0]} dd:${pipe_rc[1]})"
        return 1
    fi

    # Guard against silent empty transfers — dd exits 0 even if SSH produced
    # no data (e.g. stale ControlMaster socket, ESXi connection limit hit).
    # A 0-byte transferred file would cause qemu-img to fail downstream.
    local dst_size
    dst_size=$(stat -c%s "$local_dst" 2>/dev/null || echo 0)
    if [[ "${dst_size:-0}" -eq 0 ]]; then
        rm -f "$local_dst"
        err "Transfer produced empty file: $(basename "$remote_src") — retrying without ControlMaster..."

        # Retry with a fresh direct connection (no ControlMaster) to rule out
        # a stale/expired socket as the cause.
        rm -f "${SSH_CTL_PATH}"
        local retry_rc
        if $ESXI_USE_KEY; then
            ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15                 -i "$ESXI_KEY_PATH" "${ESXI_USER}@${ESXI_HOST}"                 "cat '${remote_src}'" 2>/dev/null                 | dd of="$local_dst" bs=1M conv=sparse status=progress 2>&1
        else
            sshpass -p "$ESXI_PASS"                 ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15                 "${ESXI_USER}@${ESXI_HOST}"                 "cat '${remote_src}'" 2>/dev/null                 | dd of="$local_dst" bs=1M conv=sparse status=progress 2>&1
        fi
        retry_rc=("${PIPESTATUS[@]}")
        dst_size=$(stat -c%s "$local_dst" 2>/dev/null || echo 0)
        if [[ ${retry_rc[0]} -ne 0 || ${retry_rc[1]} -ne 0 || "${dst_size:-0}" -eq 0 ]]; then
            rm -f "$local_dst"
            err "Retry also failed for: $(basename "$remote_src")"
            return 1
        fi
        info "Retry succeeded for: $(basename "$remote_src")"
    fi
    return 0
}

# Cleanly close the SSH ControlMaster when the script exits
cleanup_ssh() {
    local opts; opts=$(_ssh_base_opts)
    if [[ -n "$ESXI_HOST" ]]; then
        if $ESXI_USE_KEY; then
            ssh $opts -i "$ESXI_KEY_PATH" -O exit "${ESXI_USER}@${ESXI_HOST}" &>/dev/null || true
        else
            sshpass -p "$ESXI_PASS" ssh $opts -O exit "${ESXI_USER}@${ESXI_HOST}" &>/dev/null || true
        fi
    fi
}
trap cleanup_ssh EXIT

# ─── 1. Prerequisites ─────────────────────────────────────────────────────────
check_prerequisites() {
    section "Checking Prerequisites"
    local ok=true

    echo "Required:"
    for cmd in ssh rsync qemu-img qm pvesm python3; do
        if command -v "$cmd" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $cmd"
        else
            echo -e "  ${RED}✗${NC} $cmd  ← MISSING"
            ok=false
        fi
    done

    echo ""
    echo "Optional:"
    if command -v sshpass &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} sshpass  (password auth available)"
    else
        echo -e "  ${YELLOW}–${NC} sshpass  (not found — SSH key auth required)"
        echo -e "             Install: apt-get install sshpass"
    fi
    if command -v virt-v2v &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} virt-v2v  (Windows VM conversion available)"
    else
        echo -e "  ${YELLOW}–${NC} virt-v2v  (not found — Windows VMs need manual handling)"
        echo -e "             Install: apt-get install virt-v2v"
    fi

    mkdir -p "$DEFAULT_STAGING"
    echo ""
    info "Default staging directory: $DEFAULT_STAGING"
    info "Log file: $LOG_FILE"

    if ! $ok; then
        err "Required tools missing. Install them and re-run."
    fi
    pause
}

# ─── 2. ESXi Connection ───────────────────────────────────────────────────────
setup_esxi_connection() {
    section "ESXi Connection Setup"

    read -rp "$(echo -e "${CYAN}ESXi host IP or hostname${NC} [${ESXI_HOST:-none}]: ")" input
    [[ -n "$input" ]] && ESXI_HOST="$input"
    [[ -z "$ESXI_HOST" ]] && { err "No host specified."; pause; return 1; }

    read -rp "$(echo -e "${CYAN}ESXi username${NC} [${ESXI_USER}]: ")" input
    [[ -n "$input" ]] && ESXI_USER="$input"

    echo ""
    echo "Authentication method:"
    echo "  1) SSH key (recommended)"
    echo "  2) Password via sshpass"
    read -rp "$(echo -e "${CYAN}Choice${NC} [1]: ")" auth

    if [[ "${auth:-1}" == "2" ]]; then
        if ! command -v sshpass &>/dev/null; then
            err "sshpass not installed. Run: apt-get install sshpass"
            pause; return 1
        fi
        ESXI_USE_KEY=false
        read -rsp "$(echo -e "${CYAN}ESXi Password${NC}: ")" ESXI_PASS
        echo ""
    else
        ESXI_USE_KEY=true
        read -rp "$(echo -e "${CYAN}SSH key path${NC} [${ESXI_KEY_PATH}]: ")" input
        [[ -n "$input" ]] && ESXI_KEY_PATH="$input"
        if [[ ! -f "$ESXI_KEY_PATH" ]]; then
            err "Key file not found: $ESXI_KEY_PATH"
            echo ""
            echo "  Generate a key:"
            echo "    ssh-keygen -t ed25519 -f ~/.ssh/id_esxi"
            echo ""
            echo "  Install it on ESXi (ESXi doesn't support ssh-copy-id directly):"
            echo "    cat ~/.ssh/id_esxi.pub | ssh root@${ESXI_HOST} \\"
            echo "      'cat >> /etc/ssh/keys-root/authorized_keys'"
            pause; return 1
        fi
    fi

    echo ""
    # Clear any stale ControlMaster socket from a previous session
    rm -f "$SSH_CTL_PATH"
    info "Testing connection to ${ESXI_HOST}..."
    if esxi_ssh "echo CONNECTED" 2>&1 | grep -q CONNECTED; then
        info "Connection successful!"
        log "ESXi connection OK: ${ESXI_HOST} as ${ESXI_USER}"
    else
        err "Connection failed. Check credentials."
        err "Confirm SSH is enabled: ESXi → Host → Actions → Services → Enable Secure Shell"
        ESXI_HOST=""
        pause; return 1
    fi
    pause
}

# ─── 3. Datastore Selection ───────────────────────────────────────────────────
select_datastore() {
    [[ -z "$ESXI_HOST" ]] && { err "Configure ESXi connection first (option 2)."; pause; return 1; }
    section "Datastore Selection"

    info "Scanning datastores on ${ESXI_HOST}..."
    # Named datastores only — filter UUID-format symlinks
    local raw
    raw=$(esxi_ssh "ls -1 /vmfs/volumes/ 2>/dev/null" \
        | grep -vE '^[0-9a-f]{8}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{12}$' || true)

    local -a ds_list=()
    if [[ -n "$raw" ]]; then
        echo ""
        local i=1
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            local free
            free=$(esxi_ssh "df -h /vmfs/volumes/${d} 2>/dev/null | awk 'NR==2{print \$4}'" || echo "?")
            printf "  %2d)  %-35s  free: %s\n" "$i" "$d" "$free"
            ds_list+=("$d")
            ((i++))
        done <<< "$raw"
        echo "  $i)  Enter path manually"
        echo ""
        read -rp "$(echo -e "${CYAN}Select${NC} [1]: ")" choice
        choice="${choice:-1}"
        if [[ "$choice" -ge 1 && "$choice" -le "${#ds_list[@]}" ]] 2>/dev/null; then
            DATASTORE_PATH="/vmfs/volumes/${ds_list[$((choice-1))]}"
            info "Datastore: $DATASTORE_PATH"
            pause; return 0
        fi
    else
        warn "Could not auto-detect datastores."
    fi

    read -rp "$(echo -e "${CYAN}Full datastore path${NC}: ")" DATASTORE_PATH
    if ! esxi_ssh "test -d '$DATASTORE_PATH' && echo OK" | grep -q OK; then
        err "Cannot access: $DATASTORE_PATH"; pause; return 1
    fi
    info "Datastore: $DATASTORE_PATH"
    pause
}

# ─── 4. Scan VMs ──────────────────────────────────────────────────────────────
enumerate_vms() {
    [[ -z "$ESXI_HOST" || -z "$DATASTORE_PATH" ]] && {
        err "Complete ESXi connection (2) and datastore (3) first."
        pause; return 1
    }
    section "Scanning VMs on ${ESXI_HOST}"

    # This entire scan runs as ONE SSH session using a base64-encoded script.
    # Avoids ESXi's connection limits and the overhead of 3 SSH handshakes per VM.
    #
    # The remote script:
    #   1. Calls vim-cmd once to get all VM inventory
    #   2. Loops over VMIDs to get power state and snapshot count
    # Output format:  ===VMS===   (vm list)  ===DETAILS===  (vmid|state|snaps)
    local batch_script='#!/bin/sh
VMLIST=$(vim-cmd vmsvc/getallvms 2>/dev/null)
printf "===VMS===\n"
printf "%s\n" "$VMLIST"
printf "===DETAILS===\n"
VMIDS=$(printf "%s\n" "$VMLIST" | grep -E "^[[:space:]]*[0-9]+" | awk "{print \$1}")
for VMID in $VMIDS; do
    STATE=$(vim-cmd vmsvc/power.getstate $VMID 2>/dev/null | tail -1)
    SNAPS=$(vim-cmd vmsvc/snapshot.get $VMID 2>/dev/null | grep -c "Snapshot Name" 2>/dev/null || echo 0)
    printf "%s|%s|%s\n" "$VMID" "${STATE:-Unknown}" "${SNAPS:-0}"
done'

    info "Running batch scan — single SSH session for all VMs..."
    info "(This takes a moment for large inventories)"

    local batch_output
    batch_output=$(esxi_run_script "$batch_script") || {
        err "Batch scan failed on ESXi."; pause; return 1
    }

    if [[ -z "$batch_output" ]]; then
        err "ESXi returned no data."; pause; return 1
    fi

    # Parse on Proxmox with Python3.
    # Python handles VM names with spaces, special chars, all edge cases.
    # Data is passed via stdin to avoid embedding it in the script string.
    local py_parser
    py_parser=$(mktemp /tmp/esxi-parse-XXXXXX.py)
    cat > "$py_parser" << 'PYEOF'
import sys, re

data = sys.stdin.read()
lines = data.split('\n')
section = None
vms = {}        # vmid -> {name, vmx}
details = {}    # vmid -> {state, snaps}

for line in lines:
    line = line.rstrip('\r')
    if line == '===VMS===':
        section = 'vms'
        continue
    elif line == '===DETAILS===':
        section = 'details'
        continue

    if not line.strip():
        continue

    if section == 'vms':
        # Format: VMID  NAME  [DATASTORE] path/to/vm.vmx  GuestOS  Version
        # VM names can contain spaces; [datastore] is the anchor point.
        m = re.match(r'^\s*(\d+)\s+(.+?)\s+\[[^\]]+\]\s+(\S+\.vmx)', line)
        if m:
            vmid = m.group(1)
            name = m.group(2).strip()
            vmx  = m.group(3).strip()
            vms[vmid] = {'name': name, 'vmx': vmx}

    elif section == 'details':
        parts = line.split('|', 2)
        if len(parts) == 3:
            vmid, state, snaps = parts
            snaps = snaps.strip()
            if not snaps.isdigit():
                snaps = '0'
            details[vmid] = {'state': state.strip(), 'snaps': snaps}

# Output sorted by VMID
for vmid in sorted(vms.keys(), key=lambda x: int(x)):
    d = vms[vmid]
    det = details.get(vmid, {'state': 'Unknown', 'snaps': '0'})
    print(f"VM|{vmid}|{d['name']}|{d['vmx']}|{det['state']}|{det['snaps']}")
PYEOF

    local parsed
    parsed=$(echo "$batch_output" | python3 "$py_parser")
    local py_exit=$?
    rm -f "$py_parser"

    if [[ $py_exit -ne 0 || -z "$parsed" ]]; then
        err "Python3 parsing failed."
        warn "Raw ESXi output (first 20 lines for diagnostics):"
        echo "$batch_output" | head -20
        pause; return 1
    fi

    # Load into bash arrays
    VM_IDS=(); VM_STATES=(); VM_SNAPS=(); VM_PATHS=(); SORTED_VM_NAMES=()

    while IFS='|' read -r tag vmid vmname vmx state snaps; do
        [[ "$tag" != "VM" ]] && continue
        [[ -z "$vmname" ]] && continue
        VM_IDS["$vmname"]="$vmid"
        VM_PATHS["$vmname"]="$vmx"
        VM_STATES["$vmname"]="$state"
        VM_SNAPS["$vmname"]="${snaps:-0}"
        SORTED_VM_NAMES+=("$vmname")
    done <<< "$parsed"

    if [[ ${#VM_IDS[@]} -eq 0 ]]; then
        err "No VMs found after parsing. Check datastore path and ESXi access."
        warn "Raw scan output:"
        echo "$batch_output" | head -30
        pause; return 1
    fi

    info "Scan complete — ${#VM_IDS[@]} VM(s) found."
    log "Scanned ${#VM_IDS[@]} VMs from ${ESXI_HOST}"
    pause
}

# ─── 5. Display VM List ───────────────────────────────────────────────────────
display_vm_list() {
    [[ ${#VM_IDS[@]} -eq 0 ]] && {
        warn "No VMs loaded. Run scan first (option 4)."; pause; return 1
    }

    # Build the full table and pipe to less so large inventories are navigable.
    # less -R preserves ANSI color codes.
    {
        echo ""
        echo -e "${BOLD}Virtual Machines on ${ESXI_HOST} — ${#VM_IDS[@]} total${NC}"
        echo ""
        printf "${BOLD}%-4s %-38s %-14s %-12s %-14s${NC}\n" \
            "#" "VM Name" "Power State" "Snapshots" "Transfer OK?"
        hr

        local i=1
        for vmname in "${SORTED_VM_NAMES[@]}"; do
            local state="${VM_STATES[$vmname]:-Unknown}"
            local snaps="${VM_SNAPS[$vmname]:-0}"
            local state_c snap_c safe_c

            if   echo "$state" | grep -qi "off";     then state_c="${GREEN}Powered Off${NC}"
            elif echo "$state" | grep -qi " on";     then state_c="${RED}Powered On${NC}"
            elif echo "$state" | grep -qi "suspend"; then state_c="${YELLOW}Suspended${NC}"
            else state_c="$state"; fi

            if [[ "${snaps:-0}" -gt 0 ]] 2>/dev/null; then
                snap_c="${YELLOW}${snaps} snap(s)${NC}"
            else
                snap_c="${GREEN}None${NC}"
            fi

            if echo "$state" | grep -qi "off" && [[ "${snaps:-0}" -eq 0 ]] 2>/dev/null; then
                safe_c="${GREEN}YES${NC}"
            elif [[ "${snaps:-0}" -gt 0 ]] 2>/dev/null; then
                safe_c="${YELLOW}CONSOLIDATE${NC}"
            else
                safe_c="${RED}NO (running)${NC}"
            fi

            printf "%-4s %-38s %-23b %-21b %-12b\n" \
                "$i" "$vmname" "$state_c" "$snap_c" "$safe_c"
            ((i++))
        done

        echo ""
        hr
        echo -e "  ${GREEN}Powered Off + No Snapshots${NC} = safe to transfer"
        echo -e "  ${YELLOW}CONSOLIDATE${NC}               = delete snapshots in ESXi first"
        echo -e "  ${RED}NO (running)${NC}              = shut down in ESXi before migrating"
        echo ""
        echo "  Use arrow keys / PgUp PgDn to scroll.  Press q to return."
    } | less -R
}

# ─── 6. Select VMs for Migration ──────────────────────────────────────────────
select_vms_for_migration() {
    [[ ${#VM_IDS[@]} -eq 0 ]] && {
        warn "No VMs loaded. Run scan first (option 4)."; pause; return 1
    }

    display_vm_list

    section "Select VMs for Migration Queue"
    echo ""
    echo "  Entry format:  numbers, ranges, or 'all' (powered-off VMs only)"
    echo "  Examples:      1 3 5   |   2-8   |   1-4 7 9-12   |   all"
    echo ""
    echo -e "  Enter ${BOLD}0${NC} or ${BOLD}q${NC} to return to the main menu without changes."
    echo ""

    # Show bridge options once here for reference
    local bridges
    bridges=$(ip link show type bridge 2>/dev/null \
        | grep -oP '(?<=^\d{1,3}: )\w+(?=:)' | tr '\n' '  ')
    echo -e "  Available bridges: ${CYAN}${bridges:-none found}${NC}"
    echo -e "  Each VM's bridge can be set individually below, or changed later via option 8."
    echo ""

    read -rp "$(echo -e "${CYAN}VM selection${NC}: ")" selection

    # Exit without changes
    if [[ -z "$selection" || "$selection" == "0" || "${selection,,}" == "q" ]]; then
        return 0
    fi

    # Expand range tokens and plain numbers
    local -a nums=()
    for token in $selection; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((n=${BASH_REMATCH[1]}; n<=${BASH_REMATCH[2]}; n++)); do
                nums+=("$n")
            done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            nums+=("$token")
        fi
    done

    # "all" = every powered-off VM
    if [[ "${selection,,}" == "all" ]]; then
        nums=()
        local i=1
        for vmname in "${SORTED_VM_NAMES[@]}"; do
            if echo "${VM_STATES[$vmname]}" | grep -qi "off"; then
                nums+=("$i")
            fi
            ((i++))
        done
        [[ ${#nums[@]} -eq 0 ]] && { warn "No powered-off VMs found."; pause; return 0; }
    fi

    local added=0
    for num in "${nums[@]}"; do
        local idx=$((num - 1))
        if [[ $idx -lt 0 || $idx -ge ${#SORTED_VM_NAMES[@]} ]] 2>/dev/null; then
            warn "Invalid number: $num — skipping"; continue
        fi
        local vmname="${SORTED_VM_NAMES[$idx]}"

        # Skip duplicates
        local already=false
        for q in "${VM_QUEUE[@]}"; do [[ "$q" == "$vmname" ]] && already=true; done
        if $already; then warn "$vmname already in queue — skipping."; continue; fi

        local state="${VM_STATES[$vmname]}"
        local snaps="${VM_SNAPS[$vmname]:-0}"
        local do_add=true

        if echo "$state" | grep -qi " on"; then
            warn "$vmname is POWERED ON — transferring a live VM risks data inconsistency."
            read -rp "$(echo -e "${CYAN}Queue anyway?${NC} [y/N]: ")" c
            [[ "${c,,}" != "y" ]] && do_add=false
        fi

        if $do_add && [[ "${snaps:-0}" -gt 0 ]] 2>/dev/null; then
            warn "$vmname has ${snaps} snapshot(s) — disk state may be inconsistent without consolidation."
            warn "Best practice: delete all snapshots in ESXi (Snapshots → Delete All) before migrating."
            read -rp "$(echo -e "${CYAN}Queue anyway?${NC} [y/N]: ")" c
            [[ "${c,,}" != "y" ]] && do_add=false
        fi

        if $do_add; then
            # Bridge assignment per VM at queue time
            read -rp "$(echo -e "${CYAN}  Bridge for '${vmname}'${NC} [${BRIDGE}]: ")" vm_br
            VM_BRIDGE["$vmname"]="${vm_br:-$BRIDGE}"
            VM_QUEUE+=("$vmname")
            info "Queued: $vmname  →  bridge: ${VM_BRIDGE[$vmname]}"
            ((added++))
        fi
    done

    echo ""
    info "$added VM(s) added. Queue now has ${#VM_QUEUE[@]} VM(s)."
    if [[ ${#VM_QUEUE[@]} -gt 0 ]]; then
        echo ""
        printf "  ${BOLD}%-4s %-38s %s${NC}\n" "#" "VM Name" "Bridge"
        hr
        local i=1
        for q in "${VM_QUEUE[@]}"; do
            printf "  %-4s %-38s %s\n" "$i" "$q" "${VM_BRIDGE[$q]:-$BRIDGE}"
            ((i++))
        done
    fi
    pause
}

# ─── 7. Proxmox Settings ──────────────────────────────────────────────────────
configure_proxmox_settings() {
    section "Proxmox Settings"

    # Staging path
    echo ""
    read -rp "$(echo -e "${CYAN}Staging directory${NC} [${DEFAULT_STAGING}]: ")" input
    STAGING_PATH="${input:-$DEFAULT_STAGING}"
    mkdir -p "$STAGING_PATH"
    local avail
    avail=$(df -h "$STAGING_PATH" | awk 'NR==2{print $4}')
    info "Staging space available: $avail"

    # Proxmox storage target
    echo ""
    info "Proxmox storage targets (image-capable):"
    pvesm status --content images 2>/dev/null | tail -n +2 | \
        awk '{printf "  %-22s type=%-14s avail=%s\n", $1, $2, $5}' || true
    echo ""
    read -rp "$(echo -e "${CYAN}Storage name${NC} [e.g. local-lvm]: ")" input
    PROXMOX_STORAGE="${input:-local-lvm}"
    if ! pvesm status 2>/dev/null | grep -q "^${PROXMOX_STORAGE}[[:space:]]"; then
        warn "Storage '${PROXMOX_STORAGE}' not confirmed in pvesm — verify spelling."
    fi

    # Default bridge (per-VM overrides are set in option 6 or 8)
    echo ""
    info "Available bridges:"
    ip link show type bridge 2>/dev/null \
        | grep -oP '(?<=^\d{1,3}: )\w+(?=:)' \
        | while read -r br; do echo "  $br"; done
    echo ""
    echo -e "  ${YELLOW}Note: Per-VM bridges are set during VM selection (option 6) or queue management (option 8).${NC}"
    echo -e "  ${YELLOW}This sets the fallback default for any VM without an individual assignment.${NC}"
    echo ""
    read -rp "$(echo -e "${CYAN}Default bridge${NC} [${BRIDGE}]: ")" input
    BRIDGE="${input:-$BRIDGE}"

    # Disk conversion format
    echo ""
    echo "Default disk conversion format:"
    echo "  1) qcow2 thin-provisioned   (Proxmox default — supports snapshots)"
    echo "  2) qcow2 compressed         (smaller file, slightly higher CPU on I/O)"
    echo "  3) raw thin-provisioned     (best I/O performance, no snapshot support)"
    echo "  4) raw pre-allocated/thick  (full disk size allocated, max compatibility)"
    read -rp "$(echo -e "${CYAN}Format${NC} [1]: ")" fmt
    case "${fmt:-1}" in
        1) CONVERT_FORMAT="qcow2"; CONVERT_OPTS=""    ;;
        2) CONVERT_FORMAT="qcow2"; CONVERT_OPTS="-c"  ;;
        3) CONVERT_FORMAT="raw";   CONVERT_OPTS="-S 0";;
        4) CONVERT_FORMAT="raw";   CONVERT_OPTS=""    ;;
        *) CONVERT_FORMAT="qcow2"; CONVERT_OPTS=""    ;;
    esac

    # Storage format vs type advisory
    echo ""
    local storage_type
    storage_type=$(pvesm status 2>/dev/null | awk -v s="$PROXMOX_STORAGE" '$1==s{print $2}')
    if [[ "$storage_type" == "lvmthin" || "$storage_type" == "lvm" || "$storage_type" == "zfspool" ]]; then
        if [[ "$CONVERT_FORMAT" == "qcow2" ]]; then
            warn "Storage '${PROXMOX_STORAGE}' (type: ${storage_type}) only supports raw format."
            warn "qcow2 will be rejected at import time — switching default format to raw."
            warn "Proxmox snapshots still work via LVM/ZFS native CoW on this storage type."
            CONVERT_FORMAT="raw"; CONVERT_OPTS="-S 0"
        fi
    fi

    # Machine type
    echo ""
    echo "Machine type (virtual chipset):"
    echo "  1) Default — let Proxmox decide  (safe, Proxmox pins version automatically)"
    echo "  2) pc        i440FX / PIIX        (most compatible with VMware migrations)"
    echo "  3) q35       PCIe / ICH9          (recommended for Windows 10/11 long-term)"
    read -rp "$(echo -e "${CYAN}Machine type${NC} [1]: ")" mt
    case "${mt:-1}" in
        2) MACHINE_TYPE="pc"  ;;
        3) MACHINE_TYPE="q35" ;;
        *) MACHINE_TYPE=""    ;;
    esac

    # CPU type
    echo ""
    echo "CPU type:"
    echo "  1) kvm64   Safe default — compatible across all hosts"
    echo "  2) host    Pass through host CPU — best performance, breaks live migration"
    echo "  3) x86-64-v2-AES  Baseline x86-64 v2 with AES — good balance"
    read -rp "$(echo -e "${CYAN}CPU type${NC} [1]: ")" ct
    case "${ct:-1}" in
        2) CPU_TYPE="host"          ;;
        3) CPU_TYPE="x86-64-v2-AES" ;;
        *) CPU_TYPE="kvm64"         ;;
    esac

    # Disk bus type
    echo ""
    echo "Disk bus / controller for imported VMs:"
    echo "  1) scsi   virtio-scsi-pci  (best for Linux; Windows needs VirtIO drivers)"
    echo "  2) sata   AHCI SATA        (Windows-compatible without extra drivers)"
    echo "  3) ide    IDE/PATA         (most compatible, slowest — use if sata fails)"
    echo "  4) virtio virtio-blk       (fastest Linux I/O; Windows needs VirtIO drivers)"
    echo ""
    echo -e "  ${YELLOW}For Windows migrations: sata is recommended until VirtIO drivers are installed.${NC}"
    echo -e "  ${YELLOW}For Linux migrations:   scsi (virtio-scsi) is recommended.${NC}"
    read -rp "$(echo -e "${CYAN}Disk bus${NC} [1]: ")" db
    case "${db:-1}" in
        2) DISK_BUS="sata"   ;;
        3) DISK_BUS="ide"    ;;
        4) DISK_BUS="virtio" ;;
        *) DISK_BUS="scsi"   ;;
    esac

    # scsi controller flag — only used for scsi bus
    case "$DISK_BUS" in
        scsi)   SCSIHW="virtio-scsi-pci" ;;
        sata)   SCSIHW="" ;;
        ide)    SCSIHW="" ;;
        virtio) SCSIHW="" ;;
    esac

    echo ""
    info "Settings confirmed:"
    info "  Staging:         $STAGING_PATH  (${avail} available)"
    info "  Proxmox storage: $PROXMOX_STORAGE  (type: ${storage_type:-unknown})"
    info "  Default bridge:  $BRIDGE"
    info "  Disk format:     $CONVERT_FORMAT ${CONVERT_OPTS}"
    info "  Machine type:    ${MACHINE_TYPE:-default}"
    info "  CPU type:        $CPU_TYPE"
    info "  Disk bus:        $DISK_BUS"
    pause
}

# ─── 8. Queue Management ──────────────────────────────────────────────────────
manage_queue() {
    while true; do
        section "Queue Management"

        if [[ ${#VM_QUEUE[@]} -eq 0 ]]; then
            warn "Queue is empty."
            pause; return
        fi

        echo ""
        printf "  ${BOLD}%-4s %-38s %s${NC}\n" "#" "VM Name" "Bridge"
        hr
        local i=1
        for q in "${VM_QUEUE[@]}"; do
            printf "  %-4s %-38s %s\n" "$i" "$q" "${VM_BRIDGE[$q]:-$BRIDGE}"
            ((i++))
        done
        echo ""
        echo "  Commands:"
        echo "    r <#>            Remove VM from queue"
        echo "    b <#> <bridge>   Reassign bridge for a VM"
        echo "    c                Clear entire queue"
        echo "    q                Return to main menu"
        echo ""
        read -rp "$(echo -e "${CYAN}Command${NC}: ")" cmd arg1 arg2

        case "$cmd" in
            r)
                if [[ "$arg1" =~ ^[0-9]+$ ]]; then
                    local idx=$((arg1-1))
                    if [[ $idx -ge 0 && $idx -lt ${#VM_QUEUE[@]} ]]; then
                        local removed="${VM_QUEUE[$idx]}"
                        VM_QUEUE=("${VM_QUEUE[@]:0:$idx}" "${VM_QUEUE[@]:$((idx+1))}")
                        unset "VM_BRIDGE[$removed]"
                        info "Removed from queue: $removed"
                    else
                        warn "Invalid number: $arg1"
                    fi
                else
                    warn "Usage: r <number>"
                fi ;;
            b)
                if [[ "$arg1" =~ ^[0-9]+$ && -n "$arg2" ]]; then
                    local idx=$((arg1-1))
                    if [[ $idx -ge 0 && $idx -lt ${#VM_QUEUE[@]} ]]; then
                        local vn="${VM_QUEUE[$idx]}"
                        VM_BRIDGE["$vn"]="$arg2"
                        info "Bridge for '$vn' set to: $arg2"
                    else
                        warn "Invalid number: $arg1"
                    fi
                else
                    warn "Usage: b <number> <bridge>"
                fi ;;
            c)
                read -rp "$(echo -e "${CYAN}Clear entire queue?${NC} [y/N]: ")" confirm
                if [[ "${confirm,,}" == "y" ]]; then
                    VM_QUEUE=()
                    VM_BRIDGE=()    # simple assignment clears global; declare here would create a local shadow
                    info "Queue cleared."
                fi ;;
            q|"")
                return ;;
            *)
                warn "Unknown command: $cmd" ;;
        esac
        echo ""
    done
}

# ─── VMX Parser ───────────────────────────────────────────────────────────────
parse_vmx() {
    local vmx="$1"
    VMX_CPU=$(grep -im1 '^numvcpus'      "$vmx" | cut -d= -f2 | tr -d ' '\''"' || echo "1")
    VMX_RAM=$(grep -im1 '^memsize'       "$vmx" | cut -d= -f2 | tr -d ' '\''"' || echo "512")
    VMX_FIRMWARE=$(grep -im1 '^firmware' "$vmx" | cut -d= -f2 | tr -d ' '\''"' || echo "bios")
    VMX_GUESTOS=$(grep -im1 '^guestOS'   "$vmx" | cut -d= -f2 | tr -d ' '\''"' || echo "other")
    VMX_CPU="${VMX_CPU:-1}"; VMX_RAM="${VMX_RAM:-512}"

    # Disk references (all disks attached to this VM)
    VMX_DISKS=()
    while IFS= read -r dl; do
        local f; f=$(echo "$dl" | cut -d= -f2 | tr -d ' '\''"')
        [[ "$f" == *.vmdk ]] && VMX_DISKS+=("$f")
    done < <(grep -i '\.fileName' "$vmx" | grep -i 'vmdk' || true)

    # Guest OS → Proxmox ostype
    case "${VMX_GUESTOS,,}" in
        *windows*2022*|*windows*2019*|*windows*10*|*windows11*) VMX_OSTYPE="win10" ;;
        *windows*2016*)   VMX_OSTYPE="win10" ;;
        *windows*2012*)   VMX_OSTYPE="win8"  ;;
        *windows*7*)      VMX_OSTYPE="win7"  ;;
        *ubuntu*|*debian*|*linux*64*|*centos*|*rhel*|*fedora*) VMX_OSTYPE="l26" ;;
        *linux*)          VMX_OSTYPE="l26"   ;;
        *)                VMX_OSTYPE="other" ;;
    esac

    # NIC detection — scan all ethernetX.virtualDev entries in order.
    # Builds VMX_NICS as an array of "index:vmware_dev:proxmox_model" tuples.
    # Skips adapters explicitly marked ethernet X.present = "FALSE".
    VMX_NICS=()
    while IFS= read -r nic_line; do
        # Extract the adapter index from the key name
        local nic_idx
        nic_idx=$(echo "$nic_line" | grep -o 'ethernet[0-9]*' | grep -o '[0-9]*')

        # Skip if adapter is explicitly disabled
        local present
        present=$(grep -im1 "^ethernet${nic_idx}.present" "$vmx" | cut -d= -f2 | tr -d ' '\''"')
        [[ "${present,,}" == "false" ]] && continue

        # Extract the VMware device type and map to Proxmox model
        local nic_dev nic_model
        nic_dev=$(echo "$nic_line" | cut -d= -f2 | tr -d ' '\''"')
        case "${nic_dev,,}" in
            vmxnet3)      nic_model="virtio" ;;
            e1000|e1000e) nic_model="e1000"  ;;
            *)            nic_model="virtio"  ;;
        esac

        VMX_NICS+=("${nic_idx}:${nic_dev}:${nic_model}")
    done < <(grep -i 'ethernet[0-9]*\.virtualDev' "$vmx" | sort)

    # Fallback: if no NICs detected in VMX, assume one e1000
    if [[ ${#VMX_NICS[@]} -eq 0 ]]; then
        VMX_NICS=("0:e1000:e1000")
    fi
}

# ─── Transfer VM ──────────────────────────────────────────────────────────────
transfer_vm() {
    local vmname="$1"
    local vmx_rel="${VM_PATHS[$vmname]:-}"
    local vmdir_rel
    [[ -n "$vmx_rel" ]] && vmdir_rel=$(dirname "$vmx_rel") || vmdir_rel="$vmname"

    local src="${DATASTORE_PATH}/${vmdir_rel}"
    local dst="${STAGING_PATH}/${vmname}"

    section "Transferring: $vmname"
    info "Source:  ${ESXI_HOST}:${src}"
    info "Dest:    ${dst}"

    # Pre-flight space check
    local src_b avail_b
    src_b=$(esxi_ssh "du -sb '${src}' 2>/dev/null | cut -f1" || echo "0")
    avail_b=$(df --output=avail -B1 "$STAGING_PATH" 2>/dev/null | tail -1 || echo "0")
    if [[ "${src_b:-0}" -gt "${avail_b:-0}" ]] 2>/dev/null; then
        local src_h avail_h
        src_h=$(numfmt --to=iec "${src_b:-0}" 2>/dev/null || echo "${src_b:-?}")
        avail_h=$(numfmt --to=iec "${avail_b:-0}" 2>/dev/null || echo "${avail_b:-?}")
        warn "Possible space issue: VM ~${src_h}, staging available ~${avail_h}"
        read -rp "$(echo -e "${CYAN}Proceed anyway?${NC} [y/N]: ")" c
        [[ "${c,,}" != "y" ]] && return 1
    fi

    mkdir -p "$dst"

    # Build a prioritized file list — small metadata files transfer first,
    # flat VMDKs (the large data files) transfer last. This ensures that if
    # the connection has any issue during a long VMDK transfer, the VMX and
    # descriptor are already on disk so conversion and VM creation can proceed.
    #
    # Priority order:
    #   1) .vmx           — VM configuration (needed for CPU/RAM/NIC/firmware detection)
    #   2) .nvram         — BIOS/UEFI state
    #   3) descriptor .vmdk  — small metadata file that references the flat data
    #   4) -flat.vmdk     — actual disk data (potentially hundreds of GB, always last)

    local all_files
    all_files=$(esxi_ssh "find '${src}' -maxdepth 1 -type f \( \
        -name '*.vmdk' -o -name '*.vmx' -o -name '*.nvram' \
        \) 2>/dev/null") || {
        err "Could not list files in ${src}"; return 1
    }

    if [[ -z "$all_files" ]]; then
        err "No transferable files found in ${src}"; return 1
    fi

    # Split into priority buckets then combine
    local vmx_files nvram_files desc_files flat_files
    vmx_files=$(echo  "$all_files" | grep '\.vmx$'        || true)
    nvram_files=$(echo "$all_files" | grep '\.nvram$'      || true)
    # Descriptor VMDKs: end in .vmdk but NOT -flat.vmdk, NOT -delta.vmdk,
    # NOT split chunks (-s001.vmdk etc)
    desc_files=$(echo  "$all_files" | grep '\.vmdk$'         | grep -v '\-flat\.vmdk$'         | grep -v '\-delta\.vmdk$'         | grep -vE '\-s[0-9]{3}\.vmdk$' || true)
    # Flat/split/delta VMDKs — the large ones, always last
    flat_files=$(echo  "$all_files" | grep '\.vmdk$'         | grep -vE "$desc_files" 2>/dev/null         | grep -E '(\-flat\.vmdk$|\-delta\.vmdk$|\-s[0-9]{3}\.vmdk$)' || true)
    # Any remaining VMDKs not caught above
    other_vmdks=$(echo "$all_files" | grep '\.vmdk$'         | grep -v '\-flat\.vmdk$'         | grep -v '\-delta\.vmdk$'         | grep -vE '\-s[0-9]{3}\.vmdk$'         | grep -v "$(echo "$desc_files" | tr '
' '|' | sed 's/|$//')" 2>/dev/null || true)

    # Build ordered list: vmx → nvram → descriptors → flat/large VMDKs
    local file_list=""
    for bucket in "$vmx_files" "$nvram_files" "$desc_files" "$flat_files"; do
        [[ -n "$bucket" ]] && file_list+="${bucket}"$'
'
    done
    file_list=$(echo "$file_list" | grep -v '^$' || true)

    if [[ -z "$file_list" ]]; then
        err "File list empty after sorting — check ESXi path and permissions"; return 1
    fi

    local total_files; total_files=$(echo "$file_list" | grep -c '.' || echo 0)
    info "Transfer order ($total_files files — metadata first, disk data last):"
    local preview_num=1
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local sz
        sz=$(esxi_ssh "du -sh '${f}' 2>/dev/null | cut -f1" || echo "?")
        printf "    %2d) %-50s %s
" "$preview_num" "$(basename "$f")" "$sz"
        ((preview_num++))
    done <<< "$file_list"
    echo ""

    local file_num=0
    local any_failed=false

    while IFS= read -r remote_file; do
        [[ -z "$remote_file" ]] && continue
        local fname; fname=$(basename "$remote_file")
        ((file_num++))
        info "[$file_num/$total_files] $fname"
        log "Transferring: ${ESXI_HOST}:${remote_file} → ${dst}/${fname}"

        esxi_transfer_file "$remote_file" "${dst}/${fname}" || {
            any_failed=true
            # For metadata files (vmx/nvram/descriptor) a failure is critical
            if [[ "$fname" == *.vmx || "$fname" == *.nvram ]]; then
                warn "Metadata file failed — VM creation will be impaired without it."
            fi
            read -rp "$(echo -e "${CYAN}Continue with remaining files?${NC} [Y/n]: ")" c
            [[ "${c,,}" == "n" ]] && return 1
        }
    done <<< "$file_list"

    if $any_failed; then
        warn "Transfer completed with errors — some files may be missing."
        log "Transfer PARTIAL: $vmname"
    else
        info "Transfer complete: $vmname"
        log "Transfer OK: $vmname"
    fi
}

# ─── Convert Disks ────────────────────────────────────────────────────────────
convert_vm() {
    local vmname="$1"
    local vmdir="${STAGING_PATH}/${vmname}"
    CONVERTED_DISKS=()

    section "Converting Disks: $vmname"

    # Descriptor VMDKs only — skip flat, delta, and split-chunk files.
    # The descriptor is the small metadata file that references the actual data.
    # qemu-img reads the descriptor and resolves split/flat automatically.
    local -a descs=()
    while IFS= read -r f; do
        [[ "$f" == *-flat.vmdk   ]] && continue
        [[ "$f" == *-delta.vmdk  ]] && continue
        [[ "$f" =~ -s[0-9]{3}\.vmdk$ ]] && continue
        descs+=("$f")
    done < <(find "$vmdir" -maxdepth 1 -name "*.vmdk" | sort)

    # Fallback: if no descriptor found, check for flat VMDKs and treat them
    # as raw disk images. This handles the case where the descriptor failed
    # to transfer but the data file made it across (or where ESXi stores the
    # disk as a single file without a separate -flat partner).
    if [[ ${#descs[@]} -eq 0 ]]; then
        warn "No VMDK descriptor files found — checking for flat VMDKs to use as raw images..."
        local -a flat_vmdks=()
        while IFS= read -r f; do
            flat_vmdks+=("$f")
        done < <(find "$vmdir" -maxdepth 1 -name "*-flat.vmdk" | sort)

        if [[ ${#flat_vmdks[@]} -eq 0 ]]; then
            err "No usable VMDK files found in $vmdir"
            return 1
        fi

        warn "${#flat_vmdks[@]} flat VMDK(s) found — will convert as raw disk images."
        warn "Disk geometry metadata from the descriptor will not be available."
        warn "The conversion should still produce a bootable disk in most cases."
        echo ""
        read -rp "$(echo -e "${CYAN}Proceed with raw conversion?${NC} [Y/n]: ")" c
        [[ "${c,,}" == "n" ]] && return 1

        # Swap in the flat files and force raw input format
        descs=("${flat_vmdks[@]}")
        CONVERT_FORMAT_OVERRIDE_INPUT="raw"
    fi

    info "${#descs[@]} disk(s) to convert."

    # Allow per-VM format override (session default shown as reference)
    echo ""
    echo "Conversion format [session default: ${CONVERT_FORMAT} ${CONVERT_OPTS:-thin}]:"
    echo "  1) Use session default"
    echo "  2) qcow2 thin    3) qcow2 compressed    4) raw thin    5) raw thick"
    read -rp "$(echo -e "${CYAN}Format${NC} [1]: ")" fmt

    local cfmt="$CONVERT_FORMAT" copts="$CONVERT_OPTS"
    case "${fmt:-1}" in
        2) cfmt="qcow2"; copts=""    ;;
        3) cfmt="qcow2"; copts="-c" ;;
        4) cfmt="raw";   copts="-S 0";;
        5) cfmt="raw";   copts=""    ;;
    esac

    local dnum=0
    for desc in "${descs[@]}"; do
        local base; base=$(basename "$desc" .vmdk)
        local out="${vmdir}/${base}.${cfmt}"

        info "Converting disk $((dnum+1))/${#descs[@]}: $(basename "$desc") → $(basename "$out")"
        log "qemu-img: $desc → $out fmt=$cfmt"

        # Use raw input format if the fallback path set the override
        local in_fmt="${CONVERT_FORMAT_OVERRIDE_INPUT:-vmdk}"
        if qemu-img convert -p -f "$in_fmt" $copts -O "$cfmt" "$desc" "$out"; then
            info "Conversion complete."

            if qemu-img check "$out" &>/dev/null; then
                info "Integrity check: OK"
            else
                warn "qemu-img check flagged warnings — review before booting."
            fi

            echo ""
            qemu-img info "$out"
            echo ""

            CONVERTED_DISKS+=("$out")
            ((dnum++))
        else
            err "Conversion failed: $(basename "$desc")"
            log "Conversion FAIL: $desc"
            return 1
        fi
    done
    unset CONVERT_FORMAT_OVERRIDE_INPUT
}

# ─── Create Proxmox VM ────────────────────────────────────────────────────────
create_proxmox_vm() {
    local vmname="$1"
    local vmdir="${STAGING_PATH}/${vmname}"
    local vm_bridge="${VM_BRIDGE[$vmname]:-$BRIDGE}"

    section "Creating Proxmox VM: $vmname"

    local vmx; vmx=$(find "$vmdir" -maxdepth 1 -name "*.vmx" | head -1)
    [[ -z "$vmx" ]] && { err "No VMX file found in $vmdir"; return 1; }

    parse_vmx "$vmx"

    echo ""
    printf "${BOLD}Detected from VMX file:${NC}\n"
    hr
    printf "  %-20s %s\n"    "CPU cores:"      "${VMX_CPU:-1}"
    printf "  %-20s %s MB\n" "Memory:"         "${VMX_RAM:-512}"
    printf "  %-20s %s\n"    "Firmware:"       "${VMX_FIRMWARE:-bios}"
    printf "  %-20s %s  →  Proxmox ostype: %s\n" "Guest OS:" "$VMX_GUESTOS" "$VMX_OSTYPE"
    printf "  %-20s %s\n"    "Disks to import:" "${#CONVERTED_DISKS[@]}"
    printf "  %-20s %s NIC(s) detected:\n" "Network:" "${#VMX_NICS[@]}"
    local nic_entry
    for nic_entry in "${VMX_NICS[@]}"; do
        local ni nd nm; IFS='::' read -r ni nd nm <<< "$nic_entry"
        printf "    NIC %s: %s  →  %s\n" "$ni" "$nd" "$nm"
    done
    hr
    echo ""
    echo "Adjust values or press Enter to accept each:"
    echo ""

    read -rp "$(echo -e "${CYAN}CPU cores${NC} [${VMX_CPU:-1}]: ")"   input; local cpu="${input:-${VMX_CPU:-1}}"
    read -rp "$(echo -e "${CYAN}Memory MB${NC} [${VMX_RAM:-512}]: ")" input; local ram="${input:-${VMX_RAM:-512}}"

    # VMID
    local vmid
    vmid=$(pvesh get /cluster/nextid 2>/dev/null || \
           echo $(( $(qm list 2>/dev/null | tail -n+2 | awk '{print $1}' | sort -n | tail -1) + 1 )))
    read -rp "$(echo -e "${CYAN}VMID${NC} [${vmid}]: ")" input; vmid="${input:-$vmid}"

    # Available bridges (shown once, referenced per NIC below)
    local bridges
    bridges=$(ip link show type bridge 2>/dev/null \
        | grep -oP '(?<=^\d{1,3}: )\w+(?=:)' | tr '\n' '  ')
    echo ""
    echo -e "  Available bridges: ${CYAN}${bridges:-none found}${NC}"

    # Per-NIC bridge and model configuration.
    # NIC 0 defaults to the bridge assigned at queue time.
    # Additional NICs default to the session bridge.
    local -a NET_ARGS=()
    local pnic_num=0
    for nic_entry in "${VMX_NICS[@]}"; do
        local ni nd nm; IFS='::' read -r ni nd nm <<< "$nic_entry"
        local default_br
        [[ $pnic_num -eq 0 ]] && default_br="$vm_bridge" || default_br="$BRIDGE"
        echo ""
        echo -e "  ${BOLD}NIC $((pnic_num+1)) of ${#VMX_NICS[@]}${NC}  (VMware: ${nd}  →  Proxmox default: ${nm})"
        read -rp "$(echo -e "    ${CYAN}Bridge${NC} [${default_br}]: ")" input
        local this_br="${input:-$default_br}"
        read -rp "$(echo -e "    ${CYAN}Model${NC}  [${nm}]: ")" input
        local this_model="${input:-$nm}"
        NET_ARGS+=("--net${pnic_num} ${this_model},bridge=${this_br}")
        log "NIC $pnic_num: model=$this_model bridge=$this_br (vmware: $nd)"
        ((pnic_num++))
    done

    # Firmware flag — UEFI also requires an EFI disk for variable storage
    local bios_flag=""
    local is_uefi=false
    if echo "${VMX_FIRMWARE:-bios}" | grep -qi "efi"; then
        info "UEFI firmware detected — enabling OVMF in Proxmox."
        bios_flag="--bios ovmf"
        is_uefi=true
    fi

    echo ""
    info "Creating VM shell (VMID: $vmid, Name: $vmname, NICs: ${#VMX_NICS[@]})..."

    # Build qm create command with all NIC arguments expanded
    local qm_cmd="qm create $vmid --name $vmname --memory $ram --cores $cpu"
    qm_cmd+=" --ostype $VMX_OSTYPE --cpu ${CPU_TYPE:-kvm64}"
    [[ -n "${MACHINE_TYPE:-}" ]]  && qm_cmd+=" --machine $MACHINE_TYPE"
    [[ -n "${SCSIHW:-}" ]]        && qm_cmd+=" --scsihw $SCSIHW"
    qm_cmd+=" $bios_flag"
    for net_arg in "${NET_ARGS[@]}"; do
        qm_cmd+=" $net_arg"
    done

    if ! eval "$qm_cmd" 2>&1 | tee -a "$LOG_FILE"; then
        err "qm create failed."; return 1
    fi

    log "qm create: vmid=$vmid name=$vmname cpu=$cpu ram=$ram nics=${#VMX_NICS[@]}"

    # UEFI VMs need an EFI disk — Proxmox stores UEFI variables there.
    # Without it the VM silently falls back to SeaBIOS or fails to boot.
    # pre-enrolled-keys=0 skips Secure Boot key enrollment (safer default).
    if $is_uefi; then
        info "Adding EFI disk for UEFI variable storage..."
        if ! qm set "$vmid"             --efidisk0 "${PROXMOX_STORAGE}:0,format=raw,efitype=4m,pre-enrolled-keys=0"             2>&1 | tee -a "$LOG_FILE"; then
            warn "EFI disk creation failed — VM may not boot correctly via UEFI."
            warn "Add manually: qm set $vmid --efidisk0 ${PROXMOX_STORAGE}:0,format=raw,efitype=4m,pre-enrolled-keys=0"
        fi
    fi

    # Import and attach each converted disk using the configured bus type
    local dnum=0
    local bus="${DISK_BUS:-scsi}"
    for disk in "${CONVERTED_DISKS[@]}"; do
        [[ -f "$disk" ]] || continue
        local ext="${disk##*.}"
        info "Importing disk $((dnum+1)): $(basename "$disk") → ${PROXMOX_STORAGE} (bus: ${bus})"
        qm importdisk "$vmid" "$disk" "$PROXMOX_STORAGE" --format "$ext" 2>&1 | tee -a "$LOG_FILE"
        qm set "$vmid" --${bus}${dnum} "${PROXMOX_STORAGE}:vm-${vmid}-disk-${dnum}" 2>&1 | tee -a "$LOG_FILE"
        if [[ $dnum -eq 0 ]]; then
            qm set "$vmid" --boot c --bootdisk ${bus}0 2>&1 | tee -a "$LOG_FILE"
        fi
        ((dnum++))
    done

    info "VM ready: $vmname  (VMID: $vmid,  Disks: $dnum,  NICs: ${#VMX_NICS[@]})"
    log "VM created: $vmname VMID=$vmid disks=$dnum nics=${#VMX_NICS[@]}"

    # Windows advisory
    if echo "${VMX_GUESTOS:-}" | grep -qi "windows"; then
        echo ""
        echo -e "${YELLOW}╔═════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  WINDOWS VM DETECTED                                        ║${NC}"
        echo -e "${YELLOW}║  This VM will likely not boot — VirtIO drivers are missing. ║${NC}"
        echo -e "${YELLOW}║  Recommended: delete this Proxmox VM and use virt-v2v:      ║${NC}"
        echo -e "${YELLOW}║                                                              ║${NC}"
        echo -e "${YELLOW}║  virt-v2v -i vmx '<path-to-vmx>'                            ║${NC}"
        echo -e "${YELLOW}║    -o local -os ${vmdir}                                    ║${NC}"
        echo -e "${YELLOW}║    --bridge ${vm_bridge}                                    ║${NC}"
        echo -e "${YELLOW}╚═════════════════════════════════════════════════════════════╝${NC}"
    fi

    # Cleanup prompt
    echo ""
    read -rp "$(echo -e "${CYAN}Remove staging files for '${vmname}'?${NC} [y/N]: ")" c
    if [[ "${c,,}" == "y" ]]; then
        rm -rf "$vmdir"
        info "Staging files removed."
        log "Staging cleaned: $vmdir"
    fi
}

# ─── Run Migration Queue ──────────────────────────────────────────────────────
run_migration() {
    if [[ ${#VM_QUEUE[@]} -eq 0 ]]; then
        warn "Queue is empty. Select VMs first (option 6)."; pause; return
    fi

    # Preflight validation
    local ready=true
    [[ -z "$ESXI_HOST" ]]       && { err "ESXi not configured (option 2).";       ready=false; }
    [[ -z "$DATASTORE_PATH" ]]  && { err "Datastore not selected (option 3).";    ready=false; }
    [[ -z "$PROXMOX_STORAGE" ]] && { err "Proxmox storage not set (option 7).";   ready=false; }
    $ready || { pause; return 1; }

    section "Migration — ${#VM_QUEUE[@]} VM(s)"
    echo ""
    printf "  ${BOLD}%-4s %-38s %s${NC}\n" "#" "VM Name" "Bridge"
    hr
    local i=1
    for q in "${VM_QUEUE[@]}"; do
        printf "  %-4s %-38s %s\n" "$i" "$q" "${VM_BRIDGE[$q]:-$BRIDGE}"
        ((i++))
    done
    echo ""
    read -rp "$(echo -e "${CYAN}Start migration?${NC} [Y/n]: ")" c
    [[ "${c,,}" == "n" ]] && return

    local success=0 failed=0
    local -a failed_list=()

    for vmname in "${VM_QUEUE[@]}"; do
        echo ""
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}${CYAN}  Processing: $vmname${NC}"
        echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log "=== BEGIN: $vmname ==="

        if transfer_vm "$vmname" && convert_vm "$vmname" && create_proxmox_vm "$vmname"; then
            echo -e "${GREEN}✓ $vmname — completed successfully${NC}"
            log "=== DONE: $vmname ==="
            ((success++))
        else
            echo -e "${RED}✗ $vmname — failed${NC}"
            log "=== FAIL: $vmname ==="
            failed_list+=("$vmname")
            ((failed++))
            echo ""
            read -rp "Continue with the next VM? [Y/n]: " c
            [[ "${c,,}" == "n" ]] && break
        fi
    done

    section "Migration Summary"
    echo -e "  ${GREEN}Succeeded: $success${NC}"
    echo -e "  ${RED}Failed:    $failed${NC}"
    if [[ ${#failed_list[@]} -gt 0 ]]; then
        echo "  Failed VMs:"
        for f in "${failed_list[@]}"; do echo -e "    ${RED}✗${NC} $f"; done
    fi
    echo ""
    info "Full log: $LOG_FILE"
    pause
}

# ─── View Log ─────────────────────────────────────────────────────────────────
view_log() {
    if [[ -f "$LOG_FILE" ]]; then
        less "$LOG_FILE"
    else
        warn "Log file not yet created: $LOG_FILE"
        pause
    fi
}

# ─── Main Menu ────────────────────────────────────────────────────────────────
show_main_menu() {
    while true; do
        clear
        echo -e "${BOLD}${BLUE}"
        echo "╔══════════════════════════════════════════════════╗"
        echo "║      ESXi → Proxmox Migration Tool               ║"
        echo "║                         v${SCRIPT_VERSION}                    ║"
        echo "╚══════════════════════════════════════════════════╝"
        echo -e "${NC}"

        printf "  %-20s ${CYAN}%s${NC}\n" "ESXi host:"     "${ESXI_HOST:-not configured}"
        printf "  %-20s ${CYAN}%s${NC}\n" "Datastore:"     "${DATASTORE_PATH:-not selected}"
        printf "  %-20s ${CYAN}%s VM(s)${NC}\n" "VMs scanned:" "${#VM_IDS[@]}"
        printf "  %-20s ${CYAN}%s${NC}\n" "Storage target:" "${PROXMOX_STORAGE:-not set}"
        printf "  %-20s ${CYAN}%s${NC}\n" "Disk format:"   "${CONVERT_FORMAT}"
        printf "  %-20s ${CYAN}machine=%-8s cpu=%-12s bus=%s${NC}\n" "VM settings:" \
            "${MACHINE_TYPE:-default}" "${CPU_TYPE:-kvm64}" "${DISK_BUS:-scsi}"
        printf "  %-20s ${CYAN}%s VM(s)${NC}\n" "Queue:"   "${#VM_QUEUE[@]}"
        echo ""
        hr
        echo "  1)  Check prerequisites"
        echo "  2)  Configure ESXi connection"
        echo "  3)  Select datastore"
        echo "  4)  Scan VMs on ESXi"
        echo "  5)  Display VM list"
        echo "  6)  Select VMs for migration  (assigns per-VM bridges)"
        echo "  7)  Configure Proxmox settings  (storage / default bridge / format)"
        echo "  8)  Manage queue  (remove VMs, reassign bridges, clear)"
        echo "  9)  ▶  Start migration"
        echo " 10)  View log"
        echo "  0)  Exit"
        hr
        read -rp "$(echo -e "${CYAN}Choice${NC}: ")" choice

        case "$choice" in
            1)  check_prerequisites ;;
            2)  setup_esxi_connection ;;
            3)  select_datastore ;;
            4)  enumerate_vms ;;
            5)  display_vm_list ;;
            6)  select_vms_for_migration ;;
            7)  configure_proxmox_settings ;;
            8)  manage_queue ;;
            9)  run_migration ;;
            10) view_log ;;
            0)  echo "Exiting."; log "Script exited normally."; exit 0 ;;
            *)  warn "Invalid choice." ;;
        esac
    done
}

# ─── Entry Point ──────────────────────────────────────────────────────────────
main() {
    mkdir -p "$(dirname "$LOG_FILE")" "$DEFAULT_STAGING"
    log "ESXi Migration Tool v${SCRIPT_VERSION} started by $(whoami) on $(hostname)"
    [[ $# -gt 0 ]] && ESXI_HOST="$1"
    show_main_menu
}

main "$@"
