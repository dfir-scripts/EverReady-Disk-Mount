#!/bin/bash

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31mError: This script must be run as root or with sudo.\033[0m"
    echo "Usage: sudo $0 [options]"
    exit 1
fi

# Colors for output
RED='\033[31m'
GREEN='\033[32m'
NC='\033[0m'
# Function to print in color
print_error() { echo -e "${RED}$1${NC}"; }
print_success() { echo -e "${GREEN}$1${NC}"; }
# LVM cleanup function for er3.sh

# Function to cleanup LVM volumes and /dev/mapper devices
cleanup_lvm() {
    local nbd_device="${1:-/dev/nbd1}"
    local verbose="${2:-true}"
    
    if [ "$verbose" = "true" ]; then
        echo "Checking for active LVM volumes to deactivate..."
    fi
    
    # Check if LVM tools are available
    if ! command -v vgchange >/dev/null 2>&1; then
        return 0
    fi
    
    # Step 1: Check for /dev/mapper devices related to this NBD device
    local mapper_devices=$(ls -1 /dev/mapper/ 2>/dev/null | grep -v '^control$' || true)
    
    if [ -n "$mapper_devices" ]; then
        if [ "$verbose" = "true" ]; then
            echo "Found /dev/mapper devices:"
            echo "$mapper_devices" | sed 's/^/  - \/dev\/mapper\//'
        fi
        
        # Step 2: For each mapper device, check if it's associated with our NBD device
        for mapper_dev in $mapper_devices; do
            local mapper_path="/dev/mapper/$mapper_dev"
            
            # Check if this is an LVM device
            if lvs "$mapper_path" >/dev/null 2>&1; then
                # Get the volume group name
                local vg_name=$(lvs --noheadings -o vg_name "$mapper_path" 2>/dev/null | tr -d ' ')
                
                if [ -n "$vg_name" ]; then
                    # Check if this VG is on our NBD device
                    local pv_devices=$(pvs --noheadings -o pv_name -S vg_name="$vg_name" 2>/dev/null | tr -d ' ')
                    
                    # Check if any PV is on the NBD device
                    if echo "$pv_devices" | grep -q "^${nbd_device}"; then
                        if [ "$verbose" = "true" ]; then
                            echo "Deactivating LVM device: $mapper_path (VG: $vg_name)"
                        fi
                        
                        # Deactivate this specific logical volume
                        lvchange -an "$mapper_path" 2>/dev/null || true
                    fi
                fi
            fi
        done
    fi
    
    # Step 3: Deactivate all volume groups on this NBD device
    local vgs_on_nbd=$(pvs --noheadings -o vg_name -S "pv_name=~^${nbd_device}" 2>/dev/null | tr -d ' ' | sort -u || true)
    
    if [ -n "$vgs_on_nbd" ]; then
        for vg in $vgs_on_nbd; do
            if [ "$verbose" = "true" ]; then
                echo "Deactivating volume group: $vg"
            fi
            
            if vgchange -an "$vg" 2>/dev/null; then
                if [ "$verbose" = "true" ]; then
                    print_success "Deactivated volume group: $vg"
                fi
            else
                if [ "$verbose" = "true" ]; then
                    echo "Warning: Could not deactivate volume group: $vg"
                fi
            fi
        done
        
        # Give LVM time to clean up
        sleep 1
    fi
    
    # Step 4: Final check - verify no mapper devices remain for this NBD
    local remaining_mappers=$(ls -1 /dev/mapper/ 2>/dev/null | grep -v '^control$' || true)
    
    if [ -n "$remaining_mappers" ]; then
        for mapper_dev in $remaining_mappers; do
            local mapper_path="/dev/mapper/$mapper_dev"
            
            # Check if still associated with our NBD device
            if lvs "$mapper_path" >/dev/null 2>&1; then
                local pv_devices=$(pvs --noheadings -o pv_name -S "lv_path=$mapper_path" 2>/dev/null | tr -d ' ')
                
                if echo "$pv_devices" | grep -q "^${nbd_device}"; then
                    if [ "$verbose" = "true" ]; then
                        echo "Warning: Mapper device still active: $mapper_path"
                        echo "Attempting force deactivation..."
                    fi
                    
                    # Try force deactivation
                    dmsetup remove "$mapper_dev" 2>/dev/null || true
                fi
            fi
        done
    fi
    
    # Step 5: Remove any stale PV cache entries
    if command -v pvs >/dev/null 2>&1; then
        pvs --cache 2>/dev/null || true
    fi
    
    if [ "$verbose" = "true" ]; then
        echo "LVM cleanup complete."
    fi
    
    return 0
}

# Function to check if LVM cleanup is needed
check_lvm_active() {
    local nbd_device="${1:-/dev/nbd1}"
    
    # Quick check: any mapper devices exist?
    local mapper_count=$(ls -1 /dev/mapper/ 2>/dev/null | grep -v '^control$' | wc -l)
    
    if [ "$mapper_count" -gt 0 ]; then
        # Check if any are on our NBD device
        if command -v pvs >/dev/null 2>&1; then
            local vgs_on_nbd=$(pvs --noheadings -o vg_name -S "pv_name=~^${nbd_device}" 2>/dev/null | tr -d ' ' | sort -u || true)
            
            if [ -n "$vgs_on_nbd" ]; then
                return 0  # LVM cleanup needed
            fi
        fi
    fi
    
    return 1  # No LVM cleanup needed
}

# Smart cleanup wrapper function

# Function to perform full cleanup with automatic LVM detection
cleanup_and_exit() {
    local nbd_device="${1:-/dev/nbd1}"
    local temp_dir="$2"
    local ewf_mount="$3"
    local aff_mount="$4"
    local splitraw_mount="$5"
    local verbose="${6:-false}"
    
    # Check if LVM cleanup is needed (only if LVM tools are available)
    if command -v vgchange >/dev/null 2>&1; then
        if check_lvm_active "$nbd_device"; then
            if [ "$verbose" = "true" ]; then
                echo "Active LVM detected, cleaning up..."
            fi
            cleanup_lvm "$nbd_device" "$verbose"
        fi
    fi
    
    # Detach NBD device
    qemu-nbd -d "$nbd_device" >/dev/null 2>&1
    
    # Clean up temporary directories
    [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
    [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }
    [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }
    [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
    
    # ALWAYS remove LVM filter at the end of cleanup
    remove_lvm_filter
}
# Function to check mount status
check_mount_status() {
    local mount_point="$1"
    if mountpoint -q "$mount_point"; then
        print_success "$mount_point is mounted."
        df -h "$mount_point" || print_error "Warning: Unable to retrieve disk usage for $mount_point."
        return 0
# Function to create temporary LVM filter to prevent auto-activation
create_lvm_filter() {
    local filter_file="/etc/lvm/lvm.conf.d/er2-temp-$$.conf"
    
    # Skip if already exists (shouldn't happen, but safe)
    if [ -f "$filter_file" ]; then
        return 0
    fi
    
    # Check if LVM is installed
    if ! command -v pvscan >/dev/null 2>&1; then
        # LVM not installed, no filter needed
        return 0
    fi
    
    echo "Creating temporary LVM filter to prevent auto-activation..."
    mkdir -p /etc/lvm/lvm.conf.d
    
    cat >"$filter_file" <<'EOF'
# Temporary filter created by er2.sh
# Prevents udev from auto-activating LVM on NBD devices
# This file will be automatically removed when er2.sh exits
devices {
    global_filter = [ "r|/dev/nbd.*|", "a|.*|" ]
}
EOF
    
    # Refresh LVM to pick up new config
    pvscan --cache >/dev/null 2>&1 || true
    
    echo "✓ LVM auto-activation blocked for NBD devices."
}

# Function to remove temporary LVM filter
remove_lvm_filter() {
    local filter_file="/etc/lvm/lvm.conf.d/er2-temp-$$.conf"
    
    if [ -f "$filter_file" ]; then
        echo "Removing temporary LVM filter..."
        rm -f "$filter_file"
        # Refresh LVM to pick up config change
        if command -v pvscan >/dev/null 2>&1; then
            pvscan --cache >/dev/null 2>&1 || true
        fi
    fi
}
    else
        print_error "$mount_point is not mounted."
        return 1
    fi
}
# Function to unmount and detach
unmount_image() {
    local mount_point="$1"
    local nbd_device="/dev/nbd1"
    local temp_dir="$2"
    local ewf_mount="$3"
    local aff_mount="$4"
    # Step 1: Unmount the filesystem
    if mountpoint -q "$mount_point"; then
        if umount "$mount_point"; then
            print_success "Successfully unmounted $mount_point."
        else
            print_error "Failed to unmount $mount_point. Check processes with 'lsof $mount_point' or force with 'sudo umount -l $mount_point'."
            return 1
        fi
    else
        echo "$mount_point is not mounted."
    fi
    
    # Step 2: Deactivate LVM volumes BEFORE detaching NBD
    if command -v vgchange >/dev/null 2>&1; then
        # Check for any active LVM volumes on this NBD device
        local lvm_on_nbd=$(lsblk -ln -o NAME,TYPE "$nbd_device" 2>/dev/null | awk '$2 == "lvm" {print $1}' || true)
        if [ -n "$lvm_on_nbd" ]; then
            echo "Found active LVM volumes, deactivating..."
            # Get all active volume groups
            local active_vgs=$(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ')
            if [ -n "$active_vgs" ]; then
                for vg in $active_vgs; do
                    echo "Deactivating volume group: $vg"
                    if vgchange -an "$vg" 2>/dev/null; then
                        print_success "Deactivated volume group: $vg"
                    else
                        print_warning "Could not deactivate volume group: $vg (may not be on this device)"
                    fi
                done
                # Give LVM time to clean up
                sleep 1
            fi
        fi
    fi
    
    # Step 3: Detach the NBD device with retry logic
    # Check if NBD device is actually attached (has non-zero size)
    local nbd_size=$(cat /sys/block/nbd1/size 2>/dev/null || echo "0")
    if [ "$nbd_size" != "0" ]; then
        echo "Detaching NBD device..."
        local detach_success=false
        
        # Try qemu-nbd -d up to 3 times
        for attempt in 1 2 3; do
            if qemu-nbd -d "$nbd_device" >/dev/null 2>&1; then
                # Verify device is actually detached by checking size
                sleep 0.5
                local verify_size=$(cat /sys/block/nbd1/size 2>/dev/null || echo "0")
                if [ "$verify_size" = "0" ]; then
                    print_success "Successfully detached $nbd_device."
                    detach_success=true
                    break
                else
                    echo "Device still shows size $verify_size, not fully detached"
                fi
            else
                if [ $attempt -lt 3 ]; then
                    echo "Detach attempt $attempt failed, retrying..."
                    sleep 1
                fi
            fi
        done
        
        # If qemu-nbd -d failed, try aggressive rmmod approach
        if [ "$detach_success" = false ]; then
            print_error "qemu-nbd -d failed after 3 attempts. Trying aggressive cleanup..."
            echo "Attempting to unload NBD kernel module (rmmod nbd)..."
            
            if rmmod nbd 2>/dev/null; then
                print_success "Successfully unloaded NBD module."
                # Verify module is unloaded
                if ! lsmod | grep -q "^nbd "; then
                    print_success "NBD module fully unloaded."
                    # Reload the module for future use
                    sleep 1
                    modprobe nbd max_part=8 2>/dev/null || true
                    detach_success=true
                else
                    print_error "NBD module still loaded after rmmod."
                fi
            else
                print_error "Failed to detach $nbd_device even with rmmod."
                print_error "NBD device may still be in use by another process."
                echo "Checking what's still active:"
                lsblk "$nbd_device" 2>/dev/null || true
                echo "Try manually: sudo rmmod nbd && sudo modprobe nbd"
                return 1
            fi
        fi
    else
        echo "$nbd_device is not attached."
    fi
    # Unmount /mnt/raw/ewf1 if it exists
    if [ -f "/mnt/raw/ewf1" ]; then
        if umount "/mnt/raw/ewf1" 2>/dev/null; then
            print_success "Successfully unmounted /mnt/raw/ewf1."
        else
            echo "/mnt/raw/ewf1 is not mounted or already unmounted."
        fi
    fi
    if [ -n "$ewf_mount" ] && mountpoint -q "$ewf_mount"; then
        if umount "$ewf_mount"; then
            print_success "Successfully unmounted EWF mount $ewf_mount."
        else
            print_error "Failed to unmount EWF mount $ewf_mount."
            return 1
        fi
    fi
    # Unmount AFF FUSE mount if present
    if [ -n "$aff_mount" ] && mountpoint -q "$aff_mount"; then
        if fusermount -u "$aff_mount" 2>/dev/null; then
            print_success "Successfully unmounted AFF mount $aff_mount."
        else
            print_error "Failed to unmount AFF mount $aff_mount."
            return 1
        fi
    fi
    # Also check /mnt/aff explicitly
    if mountpoint -q "/mnt/aff" 2>/dev/null; then
        if fusermount -u "/mnt/aff" 2>/dev/null; then
            print_success "Successfully unmounted /mnt/aff."
        fi
    fi
    # Unmount split RAW FUSE mount if present (uses /mnt/raw)
    # Note: This is checked after EWF unmount since they share /mnt/raw
    if [ -n "$splitraw_mount" ] && mountpoint -q "$splitraw_mount" 2>/dev/null; then
        if fusermount -u "$splitraw_mount" 2>/dev/null; then
            print_success "Successfully unmounted split RAW at $splitraw_mount."
        fi
    fi
    # Clean up temporary directories
    [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
    [ -n "$ewf_mount" ] && rm -rf "$ewf_mount" 2>/dev/null
    [ -n "$aff_mount" ] && rm -rf "$aff_mount" 2>/dev/null
    [ -n "$splitraw_mount" ] && rm -rf "$splitraw_mount" 2>/dev/null
    return 0
}
# Function to mount disk image
mount_image() {
    local image_path="$1"
    local mount_point="$2"
    local lvm_mode="$3"
    local filesystem="$4"
    local check_status_only="$5"
    local unmount_only="$6"
    local mount_mode="$7"
    local manual_offset="$8"
    local retries=5
    local sleep_time=2
    local nbd_device="/dev/nbd1"
    local temp_dir=""
    local ewf_mount=""
    local aff_mount=""
    local splitraw_mount=""
    
    # ALWAYS create LVM filter to prevent auto-activation (regardless of -l flag)
    # This ensures LVM never activates without explicit user consent
    create_lvm_filter
    
    if ! modprobe nbd; then
        print_error "Failed to load NBD module. Verify with 'modinfo nbd'."
        return 1
    fi
    if [ "$check_status_only" = "true" ]; then
        check_mount_status "$mount_point"
        return $?
    fi
    if [ "$unmount_only" = "true" ]; then
        unmount_image "$mount_point" "$temp_dir" "/mnt/raw" "/mnt/aff"
        return $?
    fi
    if [ -z "$image_path" ]; then
        echo ""
        echo "Error: Image path required (-i)"
        echo ""
        SCRIPT_NAME=$(basename "$0")
        echo "$SCRIPT_NAME mounts multiple image types"
        echo "Usage: $SCRIPT_NAME -i <image> [-m mount/point] [-f filesystem] [-l] [-o offset] [-r ro|rw] [-s] [-u]"
        echo ""
        echo "Required:"
        echo "  -i <image>         Disk image file or ISO"
        echo ""
        echo "Optional:"
        echo "  -f <filesystem>    Filesystem type: ntfs, ext4, vfat, exfat, hfsplus"
        echo "  -l                 Enable LVM support (allows image modification)"
        echo "  -s                 Status - Check mount status only"
        echo "  -u                 Unmount - Unmount image and cleanup"
        echo "  -r <ro|rw>         Mount mode: ro (read-only) or rw (read-write)"
        echo ""
        echo "For full help: $SCRIPT_NAME -h"
        echo ""
        return 1
    fi
    # Check if image file exists
    if [ ! -f "$image_path" ]; then
        echo ""
        echo "Error: Image file $image_path does not exist"
        echo "Verify with: ls -l $image_path"
        echo ""
        return 1
    fi
    if [ -n "$filesystem" ] && [[ "$filesystem" != "ntfs" && "$filesystem" != "ext4" && "$filesystem" != "vfat" && "$filesystem" != "exfat" && "$filesystem" != "hfsplus" ]]; then
        print_error "Invalid filesystem '$filesystem'. Use 'ntfs', 'ext4', 'vfat', 'exfat', or 'hfsplus'."
        return 1
    fi
    if [ -n "$mount_mode" ] && [[ "$mount_mode" != "ro" && "$mount_mode" != "rw" ]]; then
        print_error "Invalid mount mode '$mount_mode'. Use 'ro' or 'rw'."
        return 1
    fi
    [ -z "$filesystem" ] && filesystem="ntfs"
    [ -z "$mount_mode" ] && mount_mode="ro"
    
    # LVM mode confirmation screen
    if [ "$lvm_mode" = true ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "ℹ️  LVM MODE ENABLED - IMAGE WILL BE MODIFIED"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "You have enabled LVM support with the -l flag."
        echo ""
        echo "WHAT WILL HAPPEN:"
        echo "  • Global LVM filter will be created (blocks auto-activation)"
        echo "  • Image will be attached to NBD device"
        echo "  • LVM will be scanned and detected"
        echo "  • You will be prompted for confirmation before activation"
        echo "  • LVM metadata WILL BE MODIFIED upon activation (unavoidable)"
        echo "  • The cryptographic hash (MD5/SHA-1/SHA-256) WILL CHANGE"
        echo ""
        echo "PROTECTION:"
        echo "  • Auto-activation is BLOCKED (requires your explicit confirmation)"
        echo "  • Filesystem metadata protected (noload/norecover options)"
        echo "  • File data protected (read-only mount)"
        echo "  • Only LVM metadata will be modified (unavoidable)"
        echo ""
        echo "RECOMMENDATION:"
        echo "  • Only use -l flag on WORKING COPIES, not original evidence"
        echo "  • Ensure chain of custody is documented"
        echo "  • Consider using hardware write-blockers for originals"
        echo ""
        echo "Image to mount: $image_path"
        echo "Mount point: $mount_point"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Proceeding with LVM-enabled mount..."
        echo ""
    fi
    
    # Pre-flight checks: Detect if mount points or NBD device are already in use
    echo "Performing pre-flight checks..."
    
    # Check if /mnt/raw is already mounted
    if mountpoint -q /mnt/raw 2>/dev/null; then
        print_error "/mnt/raw is already mounted (from previous operation)."
        print_error "Unmount first: sudo $0 -u -m $mount_point"
        echo "Or check what's mounted: mount | grep /mnt/raw"
        return 1
    fi
    
    # Check if /mnt/aff is already mounted
    if mountpoint -q /mnt/aff 2>/dev/null; then
        print_error "/mnt/aff is already mounted (from previous operation)."
        print_error "Unmount first: sudo $0 -u -m $mount_point"
        echo "Or check what's mounted: mount | grep /mnt/aff"
        return 1
    fi
    
    # Check if NBD device is already in use
    local nbd_check_size=$(cat /sys/block/nbd1/size 2>/dev/null || echo "0")
    if [ "$nbd_check_size" != "0" ]; then
        print_error "NBD device /dev/nbd1 is already in use (attached to another image)."
        print_error "Unmount first: sudo $0 -u -m $mount_point"
        echo "Or check status: lsblk | grep nbd1"
        return 1
    fi
    
    print_success "Pre-flight checks passed."
    
    # Convert to lowercase for case-insensitive extension matching throughout
    image_path_lower=$(echo "$image_path" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$image_path_lower" =~ \.ova$ ]]; then
        temp_dir="/tmp/ova_extracted_$$"
        mkdir -p "$temp_dir"
        tar -xvf "$image_path" -C "$temp_dir" >/dev/null 2>&1 || {
            print_error "Failed to extract $image_path. Verify with 'tar -tvf $image_path'."
            rm -rf "$temp_dir" 2>/dev/null
            return 1
        }
        image_path=$(find "$temp_dir" -type f -name "*.vmdk" -o -name "*.vhd" -o -name "*.vhdx" -o -name "*.qcow" -o -name "*.qcow2" | head -n 1)
        if [ -z "$image_path" ]; then
            print_error "No disk image found in $image_path. Check contents with 'tar -tvf $image_path'."
            rm -rf "$temp_dir" 2>/dev/null
            return 1
        fi
    fi
    if [[ "$image_path_lower" =~ \.ovf$ ]]; then
        ovf_dir=$(dirname "$image_path")
        image_path=$(find "$ovf_dir" -type f -name "*.vmdk" -o -name "*.vhd" -o -name "*.vhdx" -o -name "*.qcow" -o -name "*.qcow2" | head -n 1)
        if [ -z "$image_path" ]; then
            print_error "No disk image found for $image_path. Check directory with 'ls -l $ovf_dir'."
            return 1
        fi
    fi
    # Support E01/EWF images
    if [[ "$image_path_lower" =~ \.e01$ ]]; then
        # Ensure FUSE allows root access (required for qemu-nbd)
        if [ ! -f /etc/fuse.conf ] || ! grep -q "user_allow_other" /etc/fuse.conf 2>/dev/null; then
            echo "user_allow_other" | sudo tee /etc/fuse.conf >/dev/null 2>&1
        fi
        ewf_mount="/mnt/raw"
        mkdir -p "$ewf_mount"
        if ! ewfmount -X allow_root "$image_path" "$ewf_mount" >/dev/null 2>&1; then
            print_error "Failed to mount $image_path with ewfmount. Verify with 'ewfmount --help'."
            rm -rf "$ewf_mount" 2>/dev/null
            return 1
        fi
        image_path="$ewf_mount/ewf1"
        if [ ! -f "$image_path" ]; then
            print_error "EWF raw image $image_path not found. Check ewfmount setup."
            umount "$ewf_mount" 2>/dev/null
            rm -rf "$ewf_mount" 2>/dev/null
            return 1
        fi
    fi
    # Support split RAW images (.001, .002, .003) created by FTK Imager
    # Note: AFF files can also use .001 extension, so we need to verify the format
    if [[ "$image_path_lower" =~ \.001$ ]]; then
        # Check if this is actually an AFF file by examining magic bytes
        local file_type=$(file -b "$image_path" 2>/dev/null || echo "unknown")
        
        if [[ "$file_type" =~ AFF|"Advanced Forensic Format" ]]; then
            # This is an AFF file, not a split RAW - skip this section
            # It will be handled by the .aff detection later (after renaming)
            echo "Detected AFF format file with .001 extension (not split RAW)"
            # AFF files with .001 extension need to be handled specially
            # Treat it like a .aff file
            if [ ! -f /etc/fuse.conf ] || ! grep -q "user_allow_other" /etc/fuse.conf 2>/dev/null; then
                echo "user_allow_other" | sudo tee /etc/fuse.conf >/dev/null 2>&1
            fi
            aff_mount="/mnt/aff"
            mkdir -p "$aff_mount"
            echo "Mounting AFF image with affuse..."
            if ! affuse -o allow_root "$image_path" "$aff_mount" >/dev/null 2>&1; then
                print_error "Failed to mount AFF $image_path with affuse. Verify with 'affuse --help'."
                rm -rf "$aff_mount" 2>/dev/null
                return 1
            fi
            local original_aff_basename=$(basename "$image_path")
            if [ -f "$aff_mount/${original_aff_basename}.raw" ]; then
                image_path="$aff_mount/${original_aff_basename}.raw"
            elif [ -f "$aff_mount/${original_aff_basename%.*}.raw" ]; then
                image_path="$aff_mount/${original_aff_basename%.*}.raw"
            elif [ -f "$aff_mount/$original_aff_basename" ]; then
                image_path="$aff_mount/$original_aff_basename"
            else
                echo "Available files in $aff_mount:"
                ls -la "$aff_mount/" 2>/dev/null || true
                print_error "AFF raw image not found in $aff_mount. Check affuse setup."
                fusermount -u "$aff_mount" 2>/dev/null
                rm -rf "$aff_mount" 2>/dev/null
                return 1
            fi
            echo "AFF mounted at: $image_path"
        else
            # This is a split RAW file (FTK Imager format)
            echo "Detected split RAW image (FTK Imager format)"
            # Ensure FUSE allows root access (required for qemu-nbd)
            if [ ! -f /etc/fuse.conf ] || ! grep -q "user_allow_other" /etc/fuse.conf 2>/dev/null; then
                echo "user_allow_other" | sudo tee /etc/fuse.conf >/dev/null 2>&1
            fi
            splitraw_mount="/mnt/raw"
            mkdir -p "$splitraw_mount"
            echo "Mounting split RAW image with affuse..."
            if ! affuse -o allow_root "$image_path" "$splitraw_mount" >/dev/null 2>&1; then
                print_error "Failed to mount split RAW $image_path with affuse. Verify with 'affuse --help'."
                rm -rf "$splitraw_mount" 2>/dev/null
                return 1
            fi
        # affuse creates a raw file - it keeps the original basename with .raw appended
        # e.g., roberto.001 becomes roberto.001.raw
        local original_basename=$(basename "$image_path")
        # Try different possible names that affuse might create
        if [ -f "$splitraw_mount/${original_basename}.raw" ]; then
            # Most common: basename.001.raw
            image_path="$splitraw_mount/${original_basename}.raw"
        elif [ -f "$splitraw_mount/${original_basename%.*}.raw" ]; then
            # Alternative: basename.raw (without .001)
            image_path="$splitraw_mount/${original_basename%.*}.raw"
        elif [ -f "$splitraw_mount/$original_basename" ]; then
            # No .raw extension
            image_path="$splitraw_mount/$original_basename"
        else
            # List what affuse actually created
            echo "Available files in $splitraw_mount:"
            ls -la "$splitraw_mount/" 2>/dev/null || true
            print_error "Split RAW image not found in $splitraw_mount. Check affuse setup."
            fusermount -u "$splitraw_mount" 2>/dev/null
            rm -rf "$splitraw_mount" 2>/dev/null
            return 1
        fi
            echo "Split RAW mounted at: $image_path"
        fi
    fi
    # Support ISO images
    if [[ "$image_path_lower" =~ \.iso$ ]]; then
        echo "Detected ISO image: $image_path"
        echo "Mounting ISO directly with loop device..."
        # ISOs can be mounted directly - no NBD needed
        mkdir -p "$mount_point"
        if mount -o loop,ro "$image_path" "$mount_point" 2>/dev/null; then
            print_success "Successfully mounted ISO to $mount_point"
            echo ""
            echo "Contents:"
            ls "$mount_point"
            echo ""
            print_success "Success!!"
            return 0
        else
            print_error "Failed to mount ISO $image_path"
            echo "Verify ISO file: file $image_path"
            return 1
        fi
    fi
    # Support AFF (Advanced Forensic Format) images
    if [[ "$image_path_lower" =~ \.aff$ ]]; then
        # Ensure FUSE allows root access (required for qemu-nbd)
        if [ ! -f /etc/fuse.conf ] || ! grep -q "user_allow_other" /etc/fuse.conf 2>/dev/null; then
            echo "user_allow_other" | sudo tee /etc/fuse.conf >/dev/null 2>&1
        fi
        aff_mount="/mnt/aff"
        mkdir -p "$aff_mount"
        if ! affuse -o allow_root "$image_path" "$aff_mount" >/dev/null 2>&1; then
            print_error "Failed to mount $image_path with affuse. Verify with 'affuse --help'."
            rm -rf "$aff_mount" 2>/dev/null
            return 1
        fi
        # AFF creates a raw file with .raw extension
        # affuse keeps the original filename and appends .raw
        # e.g., 16GB-aff.aff becomes 16GB-aff.aff.raw
        local original_aff_basename=$(basename "$image_path")
        # Try different possible names that affuse might create
        if [ -f "$aff_mount/${original_aff_basename}.raw" ]; then
            # Most common: keeps .aff and adds .raw (e.g., file.aff.raw)
            image_path="$aff_mount/${original_aff_basename}.raw"
        elif [ -f "$aff_mount/${original_aff_basename%.*}.raw" ]; then
            # Alternative: strips .aff and adds .raw (e.g., file.raw)
            image_path="$aff_mount/${original_aff_basename%.*}.raw"
        elif [ -f "$aff_mount/$original_aff_basename" ]; then
            # No .raw extension
            image_path="$aff_mount/$original_aff_basename"
        else
            # List what affuse actually created
            echo "Available files in $aff_mount:"
            ls -la "$aff_mount/" 2>/dev/null || true
            print_error "AFF raw image not found in $aff_mount. Check affuse setup."
            fusermount -u "$aff_mount" 2>/dev/null
            rm -rf "$aff_mount" 2>/dev/null
            return 1
        fi
        echo "AFF mounted at: $image_path"
    fi
    # Validate file extension
    if ! [[ "$image_path_lower" =~ \.(vhd|vhdx|vdi|qcow|qcow2|vmdk|dd|img|raw|iso)$ || "$image_path" =~ /ewf1$ || "$image_path" =~ /mnt/aff/ || "$image_path" =~ /mnt/raw/ ]]; then
        echo ""
        echo "Error: Invalid disk image $image_path"
        echo "Must be: .vhd, .vhdx, .vdi, .qcow, .qcow2, .vmdk, .dd, .img, .raw, .iso"
        echo "Or: E01-mounted ewf1, AFF-mounted, or split RAW image"
        echo ""
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
        return 1
    fi
    if [ -n "$log_csv" ] && [ ! -e "$log_csv" ]; then
        echo "MountPoint,StartingSector,ByteOffset,Filesystem,MountCommand,PartitionSize,Success" > "$log_csv"
    fi
    if mountpoint -q "$mount_point"; then
        print_error "Mount point $mount_point is already in use."
        print_error "Try unmounting first: sudo $0 -u -m $mount_point"
        echo "Or check what's mounted: mount | grep $mount_point"
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
        return 1
    fi
    if [ -d "$mount_point" ]; then
        if ! rm -rf "$mount_point"/*; then
            print_error "Failed to clear $mount_point: directory is in use or mounted. Run 'mountpoint $mount_point', 'lsof $mount_point', or 'sudo umount $mount_point'."
            [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
            [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
            return 1
        fi
    fi
    if ! mkdir -p "$mount_point"; then
        print_error "Failed to create $mount_point: check permissions or disk space with 'df -h'."
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
        return 1
    fi
    if ! command -v fdisk >/dev/null 2>&1; then
        print_error "fdisk not found. Install with 'sudo apt install fdisk' for partition detection."
    fi
    if ! command -v partprobe >/dev/null 2>&1; then
        print_error "partprobe not found. Install with 'sudo apt install parted' for partition detection."
    fi
    if ! command -v qemu-nbd >/dev/null 2>&1; then
        print_error "qemu-nbd not found. Install with 'sudo apt install qemu-utils'."
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
        return 1
    fi
    if [ "$filesystem" = "ntfs" ] && ! command -v ntfs-3g >/dev/null 2>&1; then
        print_error "ntfs-3g not found. Install with 'sudo apt install ntfs-3g' for NTFS support."
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
        return 1
    fi
    if [ "$filesystem" = "vfat" ] && ! command -v mount.vfat >/dev/null 2>&1; then
        print_error "vfat support not found. Install with 'sudo apt install dosfstools'."
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
        return 1
    fi
    if [ "$filesystem" = "exfat" ] && ! command -v mount.exfat >/dev/null 2>&1; then
        print_error "exfat support not found. Install with 'sudo apt install exfatprogs'."
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
        return 1
    fi
    if [ "$filesystem" = "hfsplus" ] && ! command -v mount.hfsplus >/dev/null 2>&1; then
        print_error "hfsplus support not found. Install with 'sudo apt install hfsprogs'."
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
        return 1
    fi
    if [[ "$image_path_lower" =~ \.ova$ ]] && ! command -v tar >/dev/null 2>&1; then
        print_error "tar not found. Install with 'sudo apt install tar' for OVA support."
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
        return 1
    fi
    if [[ "$image_path_lower" =~ \.e01$ ]] && ! command -v ewfmount >/dev/null 2>&1; then
        print_error "ewfmount not found. Install with 'sudo apt install libewf' for E01 support."
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        return 1
    fi
    if lsblk | grep -q "nbd1"; then
        echo "NBD device $nbd_device is already in use. Attempting to detach..."
        if ! qemu-nbd -d "$nbd_device" >/dev/null 2>&1; then
            print_error "Failed to detach $nbd_device - device is in use."
            print_error "Try unmounting first: sudo $0 -u -m /mnt/image_mount"
            echo "Or manually detach: sudo qemu-nbd -d $nbd_device"
            [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
            [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
            return 1
        fi
    fi
    # Determine if we need -r flag for qemu-nbd
    # NBD mounting strategy:
    # - Forensic images (E01, AFF, Split RAW): Always read-only (-r flag)
    # - Other images: Read-only by default (-r flag) for safety
    # - LVM mode (-l flag): Writable (no -r flag) to allow LVM activation
    local qemu_nbd_opts=""
    local is_raw_image=false
    local is_virtual_disk=false
    
    if [ -n "$ewf_mount" ] || [ -n "$splitraw_mount" ] || [ -n "$aff_mount" ]; then
        # Forensic images: always read-only (FUSE limitation)
        qemu_nbd_opts="-r -f raw"
        echo "Using read-only mode for forensic image..."
    elif [[ "$image_path_lower" =~ \.(dd|raw|img)$ ]]; then
        # Raw images
        is_raw_image=true
        if [ "$lvm_mode" = true ]; then
            # LVM mode: writable (user explicitly requested)
            qemu_nbd_opts="-f raw"
            echo "Detected raw disk image format (LVM mode enabled)..."
        else
            # Default: read-only for safety
            qemu_nbd_opts="-r -f raw"
            echo "Detected raw disk image format (read-only)..."
        fi
    else
        # Virtual disks (VMDK, VDI, QCOW2, etc.)
        is_virtual_disk=true
        if [ "$lvm_mode" = true ]; then
            # LVM mode: writable (user explicitly requested)
            qemu_nbd_opts=""
            echo "Detected virtual disk image format (LVM mode enabled)..."
        else
            # Default: read-only for safety
            qemu_nbd_opts="-r"
            echo "Detected virtual disk image format (read-only)..."
        fi
    fi
    
    # Check for flat VMDK files and adjust options
    if [[ "$image_path_lower" =~ \.vmdk$ ]]; then
        # Check if it's a flat VMDK by examining file size and content
        local file_size=$(stat -c%s "$image_path" 2>/dev/null || stat -f%z "$image_path" 2>/dev/null)
        
        # Flat VMDK descriptors are typically small (< 10KB)
        if [ "$file_size" -lt 10240 ]; then
            if grep -q -i "createType.*=.*\".*flat\|createType.*=.*\".*vmfs" "$image_path" 2>/dev/null; then
                echo "Detected flat VMDK descriptor file..."
                # For flat VMDKs, we need to use the -flat.vmdk file with -f raw
                local flat_file="${image_path%.vmdk}-flat.vmdk"
                if [ -f "$flat_file" ]; then
                    echo "Using flat VMDK data file: $flat_file"
                    image_path="$flat_file"
                    # For flat VMDK, always use -f raw
                    # Preserve -r flag only if it was already set (forensic images)
                    if [[ " $qemu_nbd_opts " =~ " -r " ]]; then
                        qemu_nbd_opts="-r -f raw"
                    else
                        qemu_nbd_opts="-f raw"
                    fi
                else
                    print_error "Flat VMDK descriptor found but data file not found: $flat_file"
                    cleanup_and_exit "$nbd_device" "$temp_dir" "$ewf_mount" "$aff_mount" "$splitraw_mount" false
                    return 1
                fi
            fi
        # If filename contains "-flat", it's already the data file
        elif [[ "$image_path_lower" =~ -flat\.vmdk$ ]]; then
            echo "Detected flat VMDK data file..."
            # Preserve -r flag if it was set
            if [[ " $qemu_nbd_opts " =~ " -r " ]]; then
                qemu_nbd_opts="-r -f raw"
            else
                qemu_nbd_opts="-f raw"
            fi
        fi
    fi
    
    # Attach image to NBD device
    if ! qemu-nbd $qemu_nbd_opts -c "$nbd_device" "$image_path"; then
        print_error "Failed to attach image to NBD device."
        print_error "Possible causes:"
        echo "  1. NBD device $nbd_device is already in use - try: sudo $0 -u -m $mount_point"
        echo "  2. File permissions issue - check: ls -l $image_path"
        echo "  3. Invalid or corrupted image file"
        echo "  4. NBD kernel module not loaded - try: sudo modprobe nbd"
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
        return 1
    fi
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$nbd_device" >/dev/null 2>&1 || print_error "partprobe failed on $nbd_device. Partition table may be invalid."
    fi
    # Give kernel time to recognize partitions
    sleep 1
    
    # Diagnostic: Show what partitions exist
    echo "Detected partitions:"
    lsblk "$nbd_device" 2>/dev/null || echo "lsblk failed"
    echo ""
    echo "Partition types:"
    blkid "$nbd_device"* 2>/dev/null || echo "blkid found no partitions"
    echo ""
    
    # Scan for LVM physical volumes and activate volume groups
    if command -v pvscan >/dev/null 2>&1; then
        # First, scan the NBD device and its partitions for PVs (silently)
        pvscan --cache --config 'devices { filter=[ "a|/dev/nbd.*|", "r|.*|" ] }' "$nbd_device"* >/dev/null 2>&1 || true
        sleep 0.5
        
        # Scan for volume groups (silently)
        vgscan --mknodes --config 'devices { filter=[ "a|/dev/nbd.*|", "r|.*|" ] }' >/dev/null 2>&1 || true
        sleep 0.5
        
        # Check if any volume groups were found
        local vgs_found=$(vgs --noheadings -o vg_name --config 'devices { filter=[ "a|/dev/nbd.*|", "r|.*|" ] }' 2>/dev/null | tr -d ' ')
        if [ -n "$vgs_found" ]; then
            # Only show messages if LVM is actually detected
            echo "Scanning for LVM physical volumes..."
            print_success "LVM volume groups detected: $vgs_found"
            
            # Check if user specified -l flag for LVM support
            if [ "$lvm_mode" = false ]; then
                # LVM detected but -l flag not specified
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "⚠️  LVM Volume Groups Detected"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "This image contains LVM volume groups: $vgs_found"
                echo ""
                echo "LVM activation requires write access and will modify the image."
                echo "The image is currently mounted read-only for safety."
                echo ""
                echo "To mount this image with LVM support, use:"
                echo "  sudo $(basename "$0") -i $image_path -m $mount_point -l"
                echo ""
                if [ -n "$filesystem" ]; then
                    echo "  (with filesystem: sudo $(basename "$0") -i $image_path -m $mount_point -l -f $filesystem)"
                    echo ""
                fi
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                print_error "Cannot proceed without -l flag for LVM support."
                echo "Cleaning up and exiting..."
                cleanup_and_exit "$nbd_device" "$temp_dir" "$ewf_mount" "$aff_mount" "$splitraw_mount" false
                return 1
            fi
            
            # LVM mode enabled, proceed with warnings
            # Provide accurate container-specific warnings
            if [ "$is_raw_image" = true ]; then
                # Raw images - CAN be modified
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "⚠️  WARNING: LVM Metadata Modification Required"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "Activating LVM volume groups requires writing metadata to the disk image."
                echo "This will ALTER the image file and change its cryptographic hash."
                echo ""
                echo "WHAT GETS MODIFIED:"
                echo "  • LVM metadata (activation state, timestamps, counters)"
                echo "  • This is unavoidable - required for LVM to function"
                echo "  • Filesystem metadata will be protected (noload/norecover options)"
                echo ""
                echo "FORENSIC IMPACT:"
                echo "  • The image file's hash (MD5/SHA-1/SHA-256) will change"
                echo "  • Chain of custody may be affected"
                echo "  • Original evidence integrity cannot be verified after activation"
                echo ""
                echo "AUTO-ACTIVATION PREVENTION:"
                echo "  • Global LVM filter is active (prevents udev auto-activation)"
                echo "  • LVM will ONLY activate if you confirm below"
                echo "  • Without confirmation, LVM remains inactive and image unchanged"
                echo ""
                echo "RECOMMENDED PRACTICE:"
                echo "  • Only proceed if this is a verified working copy"
                echo "  • Never use this on original evidence"
                echo "  • Document this action in your forensic notes"
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                read -r -p "Do you want to proceed with LVM activation? (yes/no): " lvm_proceed
                
                if [[ ! "$lvm_proceed" =~ ^[Yy]([Ee][Ss])?$ ]]; then
                    echo ""
                    print_error "LVM activation cancelled by user."
                    echo "Cleaning up and exiting..."
                    cleanup_lvm "$nbd_device" true
                    qemu-nbd -d "$nbd_device" >/dev/null 2>&1
                    [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
                    [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }
                    [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }
                    [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
                    return 1
                fi
                echo ""
                print_success "User confirmed. Proceeding with LVM activation..."
                echo ""
            # Warn user for virtual disks with LVM (less severe than raw images)
            elif [ -z "$ewf_mount" ] && [ -z "$aff_mount" ] && [ -z "$splitraw_mount" ]; then
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "ℹ️  INFO: LVM Metadata Modification"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "Activating LVM volume groups will write metadata to the virtual disk."
                echo "This is normal for virtual disk images (VMDK, VHDX, VDI, QCOW2)."
                echo ""
                echo "NOTE:"
                echo "  • Virtual disk metadata will be updated"
                echo "  • This is expected behavior for working copies"
                echo "  • The virtual disk file will be modified"
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                read -r -p "Do you want to proceed with LVM activation? (yes/no): " lvm_proceed
                
                if [[ ! "$lvm_proceed" =~ ^[Yy]([Ee][Ss])?$ ]]; then
                    echo ""
                    print_error "LVM activation cancelled by user."
                    echo "Cleaning up and exiting..."
                    cleanup_lvm "$nbd_device" true
                    qemu-nbd -d "$nbd_device" >/dev/null 2>&1
                    [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
                    return 1
                fi
                echo ""
                print_success "User confirmed. Proceeding with LVM activation..."
                echo ""
            fi
            
            # Now activate the volume groups
            for vg in $vgs_found; do
                echo "Activating volume group: $vg"
                if vgchange -ay --config 'devices { filter=[ "a|/dev/nbd.*|", "r|.*|" ] }' "$vg" 2>/dev/null; then
                    print_success "Activated volume group: $vg"
                else
                    print_warning "Could not activate volume group: $vg"
                fi
            done
            # Give LVM time to create device nodes
            sleep 1
            
            # Verify logical volumes are available
            echo "Checking for logical volumes..."
            lvs 2>/dev/null || true
        fi
        # If no LVM found, don't print anything (silent)
    fi
    local partitions
    # Get all partitions, but filter out LVM2_member types (they can't be mounted directly)
    local all_parts=$(lsblk -ln -o NAME | grep "^nbd1p" || true)
    partitions=""
    for part in $all_parts; do
        local part_type=$(blkid -o value -s TYPE "/dev/$part" 2>/dev/null || echo "")
        # Skip LVM2_member partitions - only their logical volumes can be mounted
        if [ "$part_type" != "LVM2_member" ]; then
            if [ -z "$partitions" ]; then
                partitions="$part"
            else
                partitions="$partitions"$'\n'"$part"
            fi
        fi
    done
    
    # Check if the device itself is a filesystem (unpartitioned disk)
    if [ -z "$partitions" ]; then
        echo "No partitions found, checking if device is directly formatted..."
        local device_fs=$(blkid -o value -s TYPE "$nbd_device" 2>/dev/null || true)
        if [ -n "$device_fs" ]; then
            echo "Device $nbd_device is directly formatted as: $device_fs"
            # Add the device itself as the "partition" to mount
            partitions="nbd1"
        fi
    fi
    
    # Also check for LVM logical volumes using lvs
    local lvm_volumes=$(lvs --noheadings -o lv_path 2>/dev/null | tr -d ' ' || true)
    
    # Fallback: If lvs fails, parse lsblk output for LVM devices
    if [ -z "$lvm_volumes" ]; then
        # Look for lines with TYPE=lvm in lsblk output (silently)
        local lvm_from_lsblk=$(lsblk -ln -o NAME,TYPE "$nbd_device" | awk '$2 == "lvm" {print $1}' || true)
        if [ -n "$lvm_from_lsblk" ]; then
            echo "Checking for LVM volumes via lsblk..."
            echo "Found LVM volumes in lsblk output:"
            for lv_name in $lvm_from_lsblk; do
                # Convert name to device path
                local lv_path="/dev/mapper/$lv_name"
                if [ -b "$lv_path" ]; then
                    echo "  - $lv_path"
                    lvm_volumes="$lvm_volumes"$'\n'"$lv_path"
                fi
            done
        fi
    fi
    
    if [ -n "$lvm_volumes" ]; then
        echo "LVM logical volumes detected:"
        for lv in $lvm_volumes; do
            echo "  - $lv"
            # Add LVM volumes to partitions list (use full path)
            partitions="$partitions"$'\n'"$lv"
        done
    fi
    if [ -n "$partitions" ]; then
        local part_count
        part_count=$(echo "$partitions" | wc -l)
        if [ "$part_count" -gt 1 ]; then
            echo "Multiple partitions found:"
            local i=1
            local part_array=()
            for part in $partitions; do
                # Handle both regular partitions and LVM volumes
                if [[ "$part" =~ ^/ ]]; then
                    # Already a full path (LVM volume)
                    local part_device="$part"
                else
                    # Regular partition
                    local part_device="/dev/$part"
                fi
                local size="Unknown"
                local fstype="Unknown"
                if command -v lsblk >/dev/null 2>&1; then
                    size=$(lsblk -ln -o SIZE -b "$part_device" 2>/dev/null | numfmt --to=iec-i --suffix=B --format="%.2f" || echo "Unknown")
                fi
                if command -v blkid >/dev/null 2>&1; then
                    fstype=$(blkid -o value -s TYPE "$part_device" 2>/dev/null || echo "Unknown")
                fi
                # For LVM, also show volume group info
                if [[ "$part_device" =~ ^/dev/mapper/ ]] || [[ "$part_device" =~ ^/dev/.*/.* ]]; then
                    local vg_info=$(lvs --noheadings -o vg_name "$part_device" 2>/dev/null | tr -d ' ' || echo "")
                    if [ -n "$vg_info" ]; then
                        echo "$i) $part_device (VG: $vg_info, Size: $size, Filesystem: $fstype)"
                    else
                        echo "$i) $part_device (Size: $size, Filesystem: $fstype)"
                    fi
                else
                    echo "$i) $part_device (Size: $size, Filesystem: $fstype)"
                fi
                part_array[$i]="$part_device"
                ((i++))
            done
            echo "Enter partition number (1-$part_count) to mount:"
            read -r choice
            if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$part_count" ]; then
                print_error "Invalid choice. Please select a number between 1 and $part_count."
                cleanup_and_exit "$nbd_device" "$temp_dir" "$ewf_mount" "$aff_mount" "$splitraw_mount" false
                return 1
            fi
            local selected_part="${part_array[$choice]}"
            echo "Selected device: $selected_part"
            
            # Try to detect filesystem type
            local mount_fstype="$filesystem"
            local blkid_fstype=""
            if command -v blkid >/dev/null 2>&1; then
                blkid_fstype=$(blkid -o value -s TYPE "$selected_part" 2>/dev/null || echo "")
                if [ -n "$blkid_fstype" ]; then
                    echo "Detected filesystem: $blkid_fstype"
                    case "$blkid_fstype" in
                        vfat|fat12|fat16|fat32) mount_fstype="vfat" ;;
                        exfat) mount_fstype="exfat" ;;
                        ntfs) mount_fstype="ntfs" ;;
                        ext4|ext3|ext2) mount_fstype="ext4" ;;
                        hfsplus) mount_fstype="hfsplus" ;;
                        *) mount_fstype="$blkid_fstype" ;;
                    esac
                else
                    echo "blkid could not detect filesystem type"
                    if [ -n "$filesystem" ]; then
                        echo "Using user-specified filesystem: $filesystem"
                        mount_fstype="$filesystem"
                    else
                        echo "Defaulting to ext4"
                        mount_fstype="ext4"
                    fi
                fi
            fi
            echo "Will attempt to mount as: $mount_fstype"
            
            # Check if device is already mounted (e.g., by automount)
            local existing_mount=$(mount | grep "^$selected_part " | awk '{print $3}')
            if [ -n "$existing_mount" ]; then
                echo ""
                echo "Notice: $selected_part is already mounted at: $existing_mount"
                echo ""
                echo "Options:"
                echo "  1) Use existing mount location: $existing_mount"
                echo "  2) Unmount and remount to: $mount_point"
                echo "  3) Cancel"
                echo ""
                read -r -p "Enter choice (1-3): " mount_choice
                
                case "$mount_choice" in
                    1)
                        echo ""
                        print_success "Using existing mount at: $existing_mount"
                        echo ""
                        return 0
                        ;;
                    2)
                        echo "Unmounting $selected_part from $existing_mount..."
                        if umount "$selected_part" 2>/dev/null; then
                            print_success "Successfully unmounted."
                        else
                            echo ""
                            echo "Error: Failed to unmount $selected_part"
                            echo "It may be in use. Try: lsof | grep $existing_mount"
                            echo ""
                            cleanup_and_exit "$nbd_device" "$temp_dir" "$ewf_mount" "$aff_mount" "$splitraw_mount" false
                            return 1
                        fi
                        ;;
                    3)
                        echo "Cancelled."
                        cleanup_and_exit "$nbd_device" "$temp_dir" "$ewf_mount" "$aff_mount" "$splitraw_mount" false
                        return 1
                        ;;
                    *)
                        echo "Invalid choice. Cancelled."
                        cleanup_and_exit "$nbd_device" "$temp_dir" "$ewf_mount" "$aff_mount" "$splitraw_mount" false
                        return 1
                        ;;
                esac
            fi
            
            local mount_cmd
            if [ "$mount_fstype" = "ntfs" ]; then
                mount_cmd="mount -t ntfs-3g -o $mount_mode,norecover,streams_interface=windows,uid=$(id -u),gid=$(id -g),show_sys_files $selected_part $mount_point"
            elif [ "$mount_fstype" = "vfat" ]; then
                mount_cmd="mount -t vfat -o $mount_mode,uid=$(id -u),gid=$(id -g) $selected_part $mount_point"
            elif [ "$mount_fstype" = "exfat" ]; then
                mount_cmd="mount -t exfat -o $mount_mode,uid=$(id -u),gid=$(id -g) $selected_part $mount_point"
            elif [ "$mount_fstype" = "hfsplus" ]; then
                mount_cmd="mount -t hfsplus -o $mount_mode,uid=$(id -u),gid=$(id -g) $selected_part $mount_point"
            else
                # For ext2/ext3/ext4, add noload to prevent journal replay
                if [[ "$mount_fstype" =~ ^ext[234]$ ]]; then
                    mount_cmd="mount -t $mount_fstype -o $mount_mode,noload $selected_part $mount_point"
                else
                    mount_cmd="mount -t $mount_fstype -o $mount_mode $selected_part $mount_point"
                fi
            fi
            set +e
            eval "$mount_cmd" >/dev/null 2>&1
            local mount_status=$?
            set -e
            if [ $mount_status -eq 0 ] && mountpoint -q "$mount_point"; then
                local dir_check
                case "$mount_fstype" in
                    ntfs) dir_check=$(ls "$mount_point" | grep -E "^Windows$|^Users$|^Program Files$" || true) ;;
                    ext4) dir_check=$(ls "$mount_point" | grep "^etc$" || true) ;;
                    vfat|exfat) dir_check=$(ls "$mount_point" | grep -E "^EFI$|^Boot$|^bootmgr$" || true) ;;
                    hfsplus) dir_check=$(ls "$mount_point" | grep -E "^System$|^Users$|^\.HFS\+ Private Directory Data" || true) ;;
                esac
                if [ -n "$dir_check" ] || [ -n "$(ls "$mount_point")" ]; then
                    echo
                    echo "Mount command:"
                    echo " $mount_cmd"
                    echo
                    echo "ls $mount_point"
                    ls "$mount_point" || {
                        print_error "Failed to list contents of $mount_point: possible I/O error. Check with 'ls $mount_point' or 'dmesg'."
                        umount "$mount_point" 2>/dev/null
                        cleanup_and_exit "$nbd_device" "$temp_dir" "$ewf_mount" "$aff_mount" "$splitraw_mount" false
                        return 1
                    }
                    echo
                    print_success "Success!!"
                    echo
                    if [ -n "$log_csv" ]; then
                        local partition_size="Unknown"
                        if command -v fdisk >/dev/null 2>&1; then
                            partition_size=$(fdisk -l "$nbd_device" 2>/dev/null | grep "^$selected_part" | awk '{print $5}' | numfmt --to=iec-i --suffix=B --format="%.2f")
                        fi
                        echo "$mount_point,partition,$selected_part,$mount_fstype,\"$mount_cmd\",${partition_size:-Unknown},Success" >> "$log_csv"
                    fi
                    return 0
                fi
                umount "$mount_point" 2>/dev/null
            fi
            echo "Mount failed. Running diagnostics..."
            echo "Device: $selected_part"
            echo "Filesystem type attempted: $mount_fstype"
            echo "Mount command: $mount_cmd"
            echo ""
            echo "Checking device accessibility:"
            ls -l "$selected_part" 2>&1 || echo "Device file not accessible"
            echo ""
            echo "Trying blkid:"
            blkid "$selected_part" 2>&1 || echo "blkid failed"
            echo ""
            echo "Checking dmesg for errors:"
            dmesg | tail -10
            echo ""
            print_error "Failed to mount $selected_part. Check diagnostics above."
            cleanup_and_exit "$nbd_device" "$temp_dir" "$ewf_mount" "$aff_mount" "$splitraw_mount" false
            return 1
        else
            local part_device="/dev/$partitions"
            local mount_fstype="$filesystem"
            if command -v blkid >/dev/null 2>&1; then
                local blkid_fstype
                blkid_fstype=$(blkid -o value -s TYPE "$part_device" 2>/dev/null)
                if [ -n "$blkid_fstype" ]; then
                    case "$blkid_fstype" in
                        vfat|fat12|fat16|fat32) mount_fstype="vfat" ;;
                        exfat) mount_fstype="exfat" ;;
                        ntfs) mount_fstype="ntfs" ;;
                        ext4|ext3|ext2) mount_fstype="ext4" ;;
                        hfsplus) mount_fstype="hfsplus" ;;
                    esac
                fi
            fi
            local mount_cmd
            if [ "$mount_fstype" = "ntfs" ]; then
                mount_cmd="mount -t ntfs-3g -o $mount_mode,norecover,streams_interface=windows,uid=$(id -u),gid=$(id -g),show_sys_files $part_device $mount_point"
            elif [ "$mount_fstype" = "vfat" ]; then
                mount_cmd="mount -t vfat -o $mount_mode,uid=$(id -u),gid=$(id -g) $part_device $mount_point"
            elif [ "$mount_fstype" = "exfat" ]; then
                mount_cmd="mount -t exfat -o $mount_mode,uid=$(id -u),gid=$(id -g) $part_device $mount_point"
            elif [ "$mount_fstype" = "hfsplus" ]; then
                mount_cmd="mount -t hfsplus -o $mount_mode,uid=$(id -u),gid=$(id -g) $part_device $mount_point"
            else
                # For ext2/ext3/ext4, add noload to prevent journal replay
                if [[ "$mount_fstype" =~ ^ext[234]$ ]]; then
                    mount_cmd="mount -t $mount_fstype -o $mount_mode,noload $part_device $mount_point"
                else
                    mount_cmd="mount -t $mount_fstype -o $mount_mode $part_device $mount_point"
                fi
            fi
            set +e
            eval "$mount_cmd" >/dev/null 2>&1
            local mount_status=$?
            set -e
            if [ $mount_status -eq 0 ] && mountpoint -q "$mount_point"; then
                local dir_check
                case "$mount_fstype" in
                    ntfs) dir_check=$(ls "$mount_point" | grep -E "^Windows$|^Users$|^Program Files$" || true) ;;
                    ext4) dir_check=$(ls "$mount_point" | grep "^etc$" || true) ;;
                    vfat|exfat) dir_check=$(ls "$mount_point" | grep -E "^EFI$|^Boot$|^bootmgr$" || true) ;;
                    hfsplus) dir_check=$(ls "$mount_point" | grep -E "^System$|^Users$|^\.HFS\+ Private Directory Data" || true) ;;
                esac
                if [ -n "$dir_check" ] || [ -n "$(ls "$mount_point")" ]; then
                    echo
                    echo "Mount command:"
                    echo " $mount_cmd"
                    echo
                    echo "ls $mount_point"
                    ls "$mount_point" || {
                        print_error "Failed to list contents of $mount_point: possible I/O error. Check with 'ls $mount_point' or 'dmesg'."
                        umount "$mount_point" 2>/dev/null
                        cleanup_and_exit "$nbd_device" "$temp_dir" "$ewf_mount" "$aff_mount" "$splitraw_mount" false
                        return 1
                    }
                    echo
                    print_success "Success!!"
                    echo
                    if [ -n "$log_csv" ]; then
                        local partition_size="Unknown"
                        if command -v fdisk >/dev/null 2>&1; then
                            partition_size=$(fdisk -l "$nbd_device" 2>/dev/null | grep "^$part_device" | awk '{print $5}' | numfmt --to=iec-i --suffix=B --format="%.2f")
                        fi
                        echo "$mount_point,partition,$part_device,$mount_fstype,\"$mount_cmd\",${partition_size:-Unknown},Success" >> "$log_csv"
                    fi
                    return 0
                fi
                umount "$mount_point" 2>/dev/null
            fi
            print_error "Failed to mount $part_device."
            print_error "Possible causes:"
            echo "  1. Unsupported or corrupted filesystem"
            echo "  2. Device is already mounted elsewhere"
            echo "  3. Insufficient permissions"
            echo "Check filesystem type: blkid $part_device"
            echo "Check if mounted: mount | grep $part_device"
            cleanup_and_exit "$nbd_device" "$temp_dir" "$ewf_mount" "$aff_mount" "$splitraw_mount" false
            return 1
        fi
    fi
    for ((i=1; i<=retries; i++)); do
        umount "$mount_point" 2>/dev/null
        if [ $? -eq 0 ] || ! mountpoint -q "$mount_point"; then
            print_success "Existing mounts cleared for $mount_point."
            break
        fi
        if [ "$i" -eq "$retries" ]; then
            print_error "Failed to clear existing mounts for $mount_point after $retries attempts. Check with 'mountpoint $mount_point' or 'lsof $mount_point'."
            cleanup_and_exit "$nbd_device" "$temp_dir" "$ewf_mount" "$aff_mount" "$splitraw_mount" false
            return 1
        fi
        sleep $sleep_time
    done
    local starting_sectors=(0 1 2 17 31 63 2048 4096 34)
    for offset_sectors in "${starting_sectors[@]}"; do
        local byte_offset=$((offset_sectors * 512))
        local mount_cmd
        if [ "$filesystem" = "ntfs" ]; then
            mount_cmd="mount -t ntfs-3g -o $mount_mode,norecover,streams_interface=windows,uid=$(id -u),gid=$(id -g),show_sys_files,offset=$byte_offset $nbd_device $mount_point"
        elif [ "$filesystem" = "vfat" ]; then
            mount_cmd="mount -t vfat -o $mount_mode,uid=$(id -u),gid=$(id -g),offset=$byte_offset $nbd_device $mount_point"
        elif [ "$filesystem" = "exfat" ]; then
            mount_cmd="mount -t exfat -o $mount_mode,uid=$(id -u),gid=$(id -g),offset=$byte_offset $nbd_device $mount_point"
        elif [ "$filesystem" = "hfsplus" ]; then
            mount_cmd="mount -t hfsplus -o $mount_mode,uid=$(id -u),gid=$(id -g),offset=$byte_offset $nbd_device $mount_point"
        else
            # For ext2/ext3/ext4, add noload to prevent journal replay
            if [[ "$filesystem" =~ ^ext[234]$ ]]; then
                mount_cmd="mount -t $filesystem -o $mount_mode,noload,offset=$byte_offset $nbd_device $mount_point"
            else
                mount_cmd="mount -t $filesystem -o $mount_mode,offset=$byte_offset $nbd_device $mount_point"
            fi
        fi
        set +e
        eval "$mount_cmd" >/dev/null 2>&1
        local mount_status=$?
        set -e
        if [ $mount_status -eq 0 ] && mountpoint -q "$mount_point"; then
            local dir_check
            case "$filesystem" in
                ntfs) dir_check=$(ls "$mount_point" | grep -E "^Windows$|^Users$|^Program Files$" || true) ;;
                ext4) dir_check=$(ls "$mount_point" | grep "^etc$" || true) ;;
                vfat|exfat) dir_check=$(ls "$mount_point" | grep -E "^EFI$|^Boot$|^bootmgr$" || true) ;;
                hfsplus) dir_check=$(ls "$mount_point" | grep -E "^System$|^Users$|^\.HFS\+ Private Directory Data" || true) ;;
            esac
            if [ -n "$dir_check" ] || [ -n "$(ls "$mount_point")" ]; then
                echo
                echo "Mount command:"
                echo " $mount_cmd"
                echo
                echo "ls $mount_point"
                ls "$mount_point" || {
                    print_error "Failed to list contents of $mount_point: possible I/O error. Check with 'ls $mount_point' or 'dmesg'."
                    umount "$mount_point" 2>/dev/null
                    cleanup_and_exit "$nbd_device" "$temp_dir" "$ewf_mount" "$aff_mount" "$splitraw_mount" false
                    return 1
                }
                echo
                print_success "Success!!"
                echo
                if [ -n "$output_csv" ]; then
                    local partition_size="Unknown"
                    if command -v fdisk >/dev/null 2>&1; then
                        partition_size=$(fdisk -l "$nbd_device" 2>/dev/null | grep "^$nbd_device" | head -n 1 | awk '{print $5}' | numfmt --to=iec-i --suffix=B --format="%.2f")
                    fi
                    echo "$mount_point,$offset_sectors,$byte_offset,$filesystem,\"$mount_cmd\",${partition_size:-Unknown},Success" >> "$log_csv"
                fi
                return 0
            fi
        fi
        umount "$mount_point" 2>/dev/null
    done
    print_error "Failed to mount $image_path. Verify filesystem or image format with 'file $image_path' or 'fdisk -l $image_path'."
    cleanup_and_exit "$nbd_device" "$temp_dir" "$ewf_mount" "$aff_mount" "$splitraw_mount" false
    return 1
}
# Check for help flag first
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    SCRIPT_NAME=$(basename "$0")
    echo ""
    echo "$SCRIPT_NAME - Mounts multiple disk image types"
    echo ""
    echo "Usage: $SCRIPT_NAME -i <image> [-m mount/point] [-f filesystem] [-l] [-o offset] [-r ro|rw] [-s] [-u]"
    echo ""
    echo "Required:"
    echo "  -i <image>         Disk image file or ISO"
    echo ""
    echo "Optional:"
    echo "  -m <mount/point>   Mount point directory (default: /mnt/image_mount)"
    echo "  -f <filesystem>    Filesystem type: ntfs, ext4, vfat, exfat, hfsplus"
    echo "  -l                 Enable LVM support (allows image modification)"
    echo "  -o <offset>        Manual byte offset for partition mounting"
    echo "  -r <ro|rw>         Mount mode: ro (read-only, default) or rw (read-write)"
    echo "  -s                 Status - Check mount status only"
    echo "  -u                 Unmount - Unmount image and cleanup"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Supported Formats:"
    echo "  Virtual Disks:     VDI, VMDK, VHD, VHDX, QCOW, QCOW2"
    echo "  Forensic Images:   E01, AFF, Split RAW (.001, .002, ...)"
    echo "  Raw Images:        .raw, .dd, .img, .iso"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME -i disk.vmdk"
    echo "  $SCRIPT_NAME -i evidence.E01 -m /mnt/case1"
    echo "  $SCRIPT_NAME -i lvm_disk.dd -m /mnt/lvm -l"
    echo "  $SCRIPT_NAME -i image.001 -f ntfs"
    echo "  $SCRIPT_NAME -i ubuntu.iso"
    echo "  $SCRIPT_NAME -u -m /mnt/image_mount"
    echo ""
    exit 0
fi

check_status=false
unmount=false
lvm_mode=false
manual_offset=""
while getopts "i:m:f:lo:r:su" opt; do
    case $opt in
        i) image_path="$OPTARG" ;;
        m) mount_point="$OPTARG" ;;
        f) filesystem="$OPTARG" ;;
        l) lvm_mode=true ;;
        o) manual_offset="$OPTARG" ;;
        r) mount_mode="$OPTARG" ;;
        s) check_status=true ;;
        u) unmount=true ;;
        \?) 
            echo ""
            echo "Error: Invalid option"
            echo ""
            SCRIPT_NAME=$(basename "$0")
            echo "Usage: $SCRIPT_NAME -i <image> [-m mount/point] [-f filesystem] [-l] [-o offset] [-r ro|rw] [-s] [-u]"
            echo "For full help: $SCRIPT_NAME -h"
            echo ""
            exit 1 
            ;;
    esac
done
[ -z "$mount_point" ] && mount_point="/mnt/image_mount"
mount_image "$image_path" "$mount_point" "$lvm_mode" "$filesystem" "$check_status" "$unmount" "$mount_mode" "$manual_offset"
exit $?