#!/bin/bash
# Colors for output
RED='\033[31m'
GREEN='\033[32m'
NC='\033[0m'
# Function to print in color
print_error() { echo -e "${RED}$1${NC}"; }
print_success() { echo -e "${GREEN}$1${NC}"; }
# Function to check mount status
check_mount_status() {
    local mount_point="$1"
    if mountpoint -q "$mount_point"; then
        print_success "$mount_point is mounted."
        df -h "$mount_point" || print_error "Warning: Unable to retrieve disk usage for $mount_point."
        return 0
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
    
    # Step 3: Detach the NBD device
    if lsblk | grep -q "nbd1"; then
        echo "Detaching NBD device..."
        if qemu-nbd -d "$nbd_device" >/dev/null 2>&1; then
            print_success "Successfully detached $nbd_device."
        else
            print_error "Failed to detach $nbd_device. Check with 'lsblk | grep nbd1'."
            # Try to show what's still using it
            echo "Checking what's still active:"
            lsblk "$nbd_device" 2>/dev/null || true
            return 1
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
    local output_csv="$3"
    local filesystem="$4"
    local check_status_only="$5"
    local unmount_only="$6"
    local mount_mode="$7"
    local retries=5
    local sleep_time=2
    local nbd_device="/dev/nbd1"
    local temp_dir=""
    local ewf_mount=""
    local aff_mount=""
    local splitraw_mount=""
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
        print_error "Image path required (-i). Usage: './mount_vhd.sh -i image.vhd [-m /mnt/custom] [-f ntfs|ext4|vfat|exfat|hfsplus] [-o output.csv] [-r ro|rw] [-s] [-u]'"
        return 1
    fi
    if [ ! -f "$image_path" ]; then
        print_error "Image file $image_path does not exist. Verify with 'ls -l $image_path'."
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
    if [[ "$image_path" =~ \.ova$ ]]; then
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
    if [[ "$image_path" =~ \.ovf$ ]]; then
        ovf_dir=$(dirname "$image_path")
        image_path=$(find "$ovf_dir" -type f -name "*.vmdk" -o -name "*.vhd" -o -name "*.vhdx" -o -name "*.qcow" -o -name "*.qcow2" | head -n 1)
        if [ -z "$image_path" ]; then
            print_error "No disk image found for $image_path. Check directory with 'ls -l $ovf_dir'."
            return 1
        fi
    fi
    # Support E01/EWF images
    if [[ "$image_path" =~ \.[Ee]01$ ]]; then
        ewf_mount="/mnt/raw"
        mkdir -p "$ewf_mount"
        if ! ewfmount "$image_path" "$ewf_mount" >/dev/null 2>&1; then
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
    if [[ "$image_path" =~ \.001$ ]]; then
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
    # Support AFF (Advanced Forensic Format) images
    if [[ "$image_path" =~ \.[Aa][Ff][Ff]$ ]]; then
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
    if [ ! -f "$image_path" ] || ! [[ "$image_path" =~ \.(vhd|vhdx|vdi|qcow|qcow2|vmdk|dd|img|raw)$ || "$image_path" =~ /ewf1$ || "$image_path" =~ /mnt/aff/ || "$image_path" =~ /mnt/raw/ ]]; then
        print_error "Invalid disk image $image_path. Must be .vhd, .vhdx, .vdi, .qcow, .qcow2, .vmdk, .dd, .img, .raw, E01-mounted ewf1, AFF-mounted, or split RAW image."
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
        return 1
    fi
    if [ -n "$output_csv" ] && [ ! -e "$output_csv" ]; then
        echo "MountPoint,StartingSector,ByteOffset,Filesystem,MountCommand,PartitionSize,Success" > "$output_csv"
    fi
    if mountpoint -q "$mount_point"; then
        print_error "$mount_point is already mounted. Unmount with './mount_vhd.sh -u' or 'sudo umount $mount_point'."
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
    if [[ "$image_path" =~ \.ova$ ]] && ! command -v tar >/dev/null 2>&1; then
        print_error "tar not found. Install with 'sudo apt install tar' for OVA support."
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
        return 1
    fi
    if [[ "$image_path" =~ \.[Ee]01$ ]] && ! command -v ewfmount >/dev/null 2>&1; then
        print_error "ewfmount not found. Install with 'sudo apt install libewf' for E01 support."
        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
        return 1
    fi
    if lsblk | grep -q "nbd1"; then
        if ! qemu-nbd -d "$nbd_device" >/dev/null 2>&1; then
            print_error "Failed to detach $nbd_device. Check with 'lsblk | grep nbd1'."
            [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
            [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
            return 1
        fi
    fi
    # Determine if we need -r flag for qemu-nbd
    # FUSE-mounted images (split RAW, AFF) require -r flag due to FUSE permissions
    # Regular images should NOT use -r to allow LVM metadata access
    local qemu_nbd_opts=""
    if [ -n "$splitraw_mount" ] || [ -n "$aff_mount" ]; then
        qemu_nbd_opts="-r"
        echo "Using read-only mode for FUSE-mounted image..."
    fi
    
    # Attach image to NBD device
    if ! qemu-nbd $qemu_nbd_opts -c "$nbd_device" "$image_path"; then
        print_error "Failed to attach $image_path to $nbd_device. Check qemu-nbd or file access with 'ls -l $image_path'."
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
        # First, scan the NBD device and its partitions for PVs
        echo "Scanning for LVM physical volumes..."
        pvscan --cache "$nbd_device"* 2>&1 | grep -v "excluded: device is too small" || true
        sleep 0.5
        
        # Scan for volume groups
        vgscan --mknodes 2>/dev/null || true
        sleep 0.5
        
        # Check if any volume groups were found
        local vgs_found=$(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ')
        if [ -n "$vgs_found" ]; then
            print_success "LVM volume groups detected: $vgs_found"
            for vg in $vgs_found; do
                echo "Activating volume group: $vg"
                if vgchange -ay "$vg" 2>/dev/null; then
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
        else
            echo "No LVM volume groups found on this device."
        fi
    fi
    local partitions
    partitions=$(lsblk -ln -o NAME | grep "^nbd1p" || true)
    
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
        echo "Checking for LVM volumes via lsblk..."
        # Look for lines with TYPE=lvm in lsblk output
        local lvm_from_lsblk=$(lsblk -ln -o NAME,TYPE "$nbd_device" | awk '$2 == "lvm" {print $1}' || true)
        if [ -n "$lvm_from_lsblk" ]; then
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
                [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
                [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
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
            local mount_cmd
            if [ "$mount_fstype" = "ntfs" ]; then
                mount_cmd="mount -t ntfs-3g -o $mount_mode,uid=$(id -u),gid=$(id -g),show_sys_files $selected_part $mount_point"
            elif [ "$mount_fstype" = "vfat" ]; then
                mount_cmd="mount -t vfat -o $mount_mode,uid=$(id -u),gid=$(id -g) $selected_part $mount_point"
            elif [ "$mount_fstype" = "exfat" ]; then
                mount_cmd="mount -t exfat -o $mount_mode,uid=$(id -u),gid=$(id -g) $selected_part $mount_point"
            elif [ "$mount_fstype" = "hfsplus" ]; then
                mount_cmd="mount -t hfsplus -o $mount_mode,uid=$(id -u),gid=$(id -g) $selected_part $mount_point"
            else
                mount_cmd="mount -t $mount_fstype -o $mount_mode $selected_part $mount_point"
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
                        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
                        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
                        return 1
                    }
                    echo
                    print_success "Success!!"
                    echo
                    if [ -n "$output_csv" ]; then
                        local partition_size="Unknown"
                        if command -v fdisk >/dev/null 2>&1; then
                            partition_size=$(fdisk -l "$nbd_device" 2>/dev/null | grep "^$selected_part" | awk '{print $5}' | numfmt --to=iec-i --suffix=B --format="%.2f")
                        fi
                        echo "$mount_point,partition,$selected_part,$mount_fstype,\"$mount_cmd\",${partition_size:-Unknown},Success" >> "$output_csv"
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
            [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
            [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
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
                mount_cmd="mount -t ntfs-3g -o $mount_mode,uid=$(id -u),gid=$(id -g),show_sys_files $part_device $mount_point"
            elif [ "$mount_fstype" = "vfat" ]; then
                mount_cmd="mount -t vfat -o $mount_mode,uid=$(id -u),gid=$(id -g) $part_device $mount_point"
            elif [ "$mount_fstype" = "exfat" ]; then
                mount_cmd="mount -t exfat -o $mount_mode,uid=$(id -u),gid=$(id -g) $part_device $mount_point"
            elif [ "$mount_fstype" = "hfsplus" ]; then
                mount_cmd="mount -t hfsplus -o $mount_mode,uid=$(id -u),gid=$(id -g) $part_device $mount_point"
            else
                mount_cmd="mount -t $mount_fstype -o $mount_mode $part_device $mount_point"
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
                        [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
                        [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
                        return 1
                    }
                    echo
                    print_success "Success!!"
                    echo
                    if [ -n "$output_csv" ]; then
                        local partition_size="Unknown"
                        if command -v fdisk >/dev/null 2>&1; then
                            partition_size=$(fdisk -l "$nbd_device" 2>/dev/null | grep "^$part_device" | awk '{print $5}' | numfmt --to=iec-i --suffix=B --format="%.2f")
                        fi
                        echo "$mount_point,partition,$part_device,$mount_fstype,\"$mount_cmd\",${partition_size:-Unknown},Success" >> "$output_csv"
                    fi
                    return 0
                fi
                umount "$mount_point" 2>/dev/null
            fi
            print_error "Failed to mount $part_device. Verify filesystem with 'blkid $part_device'."
            [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
            [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
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
            [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
            [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
            return 1
        fi
        sleep $sleep_time
    done
    local starting_sectors=(0 1 2 17 31 63 2048 4096 34)
    for offset_sectors in "${starting_sectors[@]}"; do
        local byte_offset=$((offset_sectors * 512))
        local mount_cmd
        if [ "$filesystem" = "ntfs" ]; then
            mount_cmd="mount -t ntfs-3g -o $mount_mode,uid=$(id -u),gid=$(id -g),show_sys_files,offset=$byte_offset $nbd_device $mount_point"
        elif [ "$filesystem" = "vfat" ]; then
            mount_cmd="mount -t vfat -o $mount_mode,uid=$(id -u),gid=$(id -g),offset=$byte_offset $nbd_device $mount_point"
        elif [ "$filesystem" = "exfat" ]; then
            mount_cmd="mount -t exfat -o $mount_mode,uid=$(id -u),gid=$(id -g),offset=$byte_offset $nbd_device $mount_point"
        elif [ "$filesystem" = "hfsplus" ]; then
            mount_cmd="mount -t hfsplus -o $mount_mode,uid=$(id -u),gid=$(id -g),offset=$byte_offset $nbd_device $mount_point"
        else
            mount_cmd="mount -t $filesystem -o $mount_mode,offset=$byte_offset $nbd_device $mount_point"
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
                    [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
                    [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
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
                    echo "$mount_point,$offset_sectors,$byte_offset,$filesystem,\"$mount_cmd\",${partition_size:-Unknown},Success" >> "$output_csv"
                fi
                return 0
            fi
        fi
        umount "$mount_point" 2>/dev/null
    done
    print_error "Failed to mount $image_path. Verify filesystem or image format with 'file $image_path' or 'fdisk -l $image_path'."
    [ -n "$temp_dir" ] && rm -rf "$temp_dir" 2>/dev/null
    [ -n "$ewf_mount" ] && { umount "$ewf_mount" 2>/dev/null; rm -rf "$ewf_mount" 2>/dev/null; }; [ -n "$aff_mount" ] && { fusermount -u "$aff_mount" 2>/dev/null; rm -rf "$aff_mount" 2>/dev/null; }; [ -n "$splitraw_mount" ] && { fusermount -u "$splitraw_mount" 2>/dev/null; rm -rf "$splitraw_mount" 2>/dev/null; }
    return 1
}
# Check for help flag first
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    echo "Usage: $0 -i <image_file> [-m <mount_point>] [-f <filesystem>] [-o <output.csv>] [-r ro|rw] [-s] [-u]"
    echo ""
    echo "Options:"
    echo "  -i <image_file>    Disk image to mount (required for mounting)"
    echo "  -m <mount_point>   Mount point directory (default: /mnt/image_mount)"
    echo "  -f <filesystem>    Force filesystem type (ntfs, ext4, vfat, exfat, hfsplus)"
    echo "  -o <output.csv>    Output mount details to CSV file"
    echo "  -r <ro|rw>         Mount mode: ro (read-only) or rw (read-write) (default: ro)"
    echo "  -s                 Check mount status only"
    echo "  -u                 Unmount image"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Supported formats:"
    echo "  Virtual Disks: VDI, VMDK, VHD, VHDX, QCOW, QCOW2"
    echo "  Forensic Images: E01, AFF, Split RAW (.001, .002, ...)"
    echo "  Raw Images: .raw, .dd, .img"
    echo ""
    echo "Examples:"
    echo "  $0 -i disk.vmdk                    # Mount VMDK"
    echo "  $0 -i evidence.E01 -m /mnt/case1   # Mount E01 to custom location"
    echo "  $0 -i image.001                    # Mount FTK split RAW"
    echo "  $0 -u -m /mnt/image_mount          # Unmount"
    exit 0
fi

check_status=false
unmount=false
while getopts "i:m:f:o:r:su" opt; do
    case $opt in
        i) image_path="$OPTARG" ;;
        m) mount_point="$OPTARG" ;;
        f) filesystem="$OPTARG" ;;
        o) output_csv="$OPTARG" ;;
        r) mount_mode="$OPTARG" ;;
        s) check_status=true ;;
        u) unmount=true ;;
        \?) print_error "Invalid option. Usage: './mount_vhd.sh -i image.vhd [-m /mnt/custom] [-f ntfs|ext4|vfat|exfat|hfsplus] [-o output.csv] [-r ro|rw] [-s] [-u]'"; exit 1 ;;
    esac
done
[ -z "$mount_point" ] && mount_point="/mnt/image_mount"
mount_image "$image_path" "$mount_point" "$output_csv" "$filesystem" "$check_status" "$unmount" "$mount_mode"
exit $?