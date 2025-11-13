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
unmount_vhd() {
    local mount_point="$1"
    local nbd_device="/dev/nbd1"

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

    if lsblk | grep -q "nbd1"; then
        if qemu-nbd -d "$nbd_device" >/dev/null 2>&1; then
            print_success "Successfully detached $nbd_device."
        else
            print_error "Failed to detach $nbd_device. Check with 'lsblk | grep nbd1'."
            return 1
        fi
    else
        echo "$nbd_device is not attached."
    fi
    return 0
}

# Function to mount VHD/VHDX
mount_vhd() {
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

    # Load NBD module
    if ! modprobe nbd; then
        print_error "Failed to load NBD module. Verify with 'modinfo nbd'."
        return 1
    fi
    print_success "NBD module loaded."

    # Handle status check
    if [ "$check_status_only" = "true" ]; then
        check_mount_status "$mount_point"
        return $?
    fi

    # Handle unmount
    if [ "$unmount_only" = "true" ]; then
        unmount_vhd "$mount_point"
        return $?
    fi

    # Validate inputs
    if [ -z "$image_path" ]; then
        print_error "Image path required (-i). Usage: './mount_vhd.sh -i image.vhd [-m /mnt/custom] [-f ntfs|ext4] [-o output.csv] [-r ro|rw] [-s] [-u]'"
        return 1
    fi
    if [ ! -f "$image_path" ]; then
        print_error "Image file $image_path does not exist. Verify with 'ls -l $image_path'."
        return 1
    fi
    if [ -n "$filesystem" ] && [[ "$filesystem" != "ntfs" && "$filesystem" != "ext4" ]]; then
        print_error "Invalid filesystem '$filesystem'. Use 'ntfs' or 'ext4'."
        return 1
    fi
    if [ -n "$mount_mode" ] && [[ "$mount_mode" != "ro" && "$mount_mode" != "rw" ]]; then
        print_error "Invalid mount mode '$mount_mode'. Use 'ro' or 'rw'."
        return 1
    fi
    # Default to ntfs and ro
    [ -z "$filesystem" ] && filesystem="ntfs"
    [ -z "$mount_mode" ] && mount_mode="ro"

    # Initialize CSV
    if [ -n "$output_csv" ] && [ ! -e "$output_csv" ]; then
        echo "MountPoint,StartingSector,ByteOffset,Filesystem,MountCommand,PartitionSize,Success" > "$output_csv"
    fi

    # Check mount point
    if mountpoint -q "$mount_point"; then
        print_error "$mount_point is already mounted. Unmount with './mount_vhd.sh -u' or 'sudo umount $mount_point'."
        return 1
    fi

    # Ensure mount point exists and is empty
    if [ -d "$mount_point" ]; then
        if ! rm -rf "$mount_point"/*; then
            print_error "Failed to clear $mount_point: directory is in use or mounted. Run 'mountpoint $mount_point', 'lsof $mount_point', or 'sudo umount $mount_point'."
            return 1
        fi
    fi
    if ! mkdir -p "$mount_point"; then
        print_error "Failed to create $mount_point: check permissions or disk space with 'df -h'."
        return 1
    fi

    # Check dependencies
    if ! command -v fdisk >/dev/null 2>&1; then
        print_error "fdisk not found. Install with 'sudo apt install fdisk' for partition detection."
    fi
    if ! command -v partprobe >/dev/null 2>&1; then
        print_error "partprobe not found. Install with 'sudo apt install parted' for partition detection."
    fi
    if ! command -v qemu-nbd >/dev/null 2>&1; then
        print_error "qemu-nbd not found. Install with 'sudo apt install qemu-utils'."
        return 1
    fi
    if [ "$filesystem" = "ntfs" ] && ! command -v ntfs-3g >/dev/null 2>&1; then
        print_error "ntfs-3g not found. Install with 'sudo apt install ntfs-3g' for NTFS support."
        return 1
    fi

    # Check NBD device
    if lsblk | grep -q "nbd1"; then
        if ! qemu-nbd -d "$nbd_device" >/dev/null 2>&1; then
            print_error "Failed to detach $nbd_device. Check with 'lsblk | grep nbd1'."
            return 1
        fi
    fi

    # Attach VHD to NBD device
    if ! qemu-nbd -r -c "$nbd_device" "$image_path"; then
        print_error "Failed to attach $image_path to $nbd_device. Check qemu-nbd or file access with 'ls -l $image_path'."
        return 1
    fi
    echo
    print_success "NBD device $nbd_device attached."

    # Detect partitions
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$nbd_device" >/dev/null 2>&1 || print_error "partprobe failed on $nbd_device. Partition table may be invalid."
    fi
    local partitions
    partitions=$(lsblk -ln -o NAME | grep "^nbd1p" || true)
    if [ -n "$partitions" ]; then
        local part_count
        part_count=$(echo "$partitions" | wc -l)
        if [ "$part_count" -gt 1 ]; then
            echo "Multiple partitions found:"
            local i=1
            local part_array=()
            for part in $partitions; do
                local part_device="/dev/$part"
                local size="Unknown"
                local fstype="Unknown"
                if command -v lsblk >/dev/null 2>&1; then
                    size=$(lsblk -ln -o SIZE -b "/dev/$part" 2>/dev/null | numfmt --to=iec-i --suffix=B --format="%.2f" || echo "Unknown")
                fi
                if command -v blkid >/dev/null 2>&1; then
                    fstype=$(blkid -o value -s TYPE "$part_device" 2>/dev/null || echo "Unknown")
                fi
                echo "$i) $part_device (Size: $size, Filesystem: $fstype)"
                part_array[$i]="$part_device"
                ((i++))
            done
            echo "Enter partition number (1-$part_count) to mount:"
            read -r choice
            if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$part_count" ]; then
                print_error "Invalid choice. Please select a number between 1 and $part_count."
                return 1
            fi
            local selected_part="${part_array[$choice]}"
            local mount_cmd="mount -t ntfs-3g -o $mount_mode $selected_part $mount_point"
            set +e
            eval "$mount_cmd" >/dev/null 2>&1
            local mount_status=$?
            set -e
            if [ $mount_status -eq 0 ] && mountpoint -q "$mount_point"; then
                local dir_check
                [ "$filesystem" = "ntfs" ] && dir_check=$(ls "$mount_point" | grep -E "^Windows$|^Users$|^Program Files$" || true)
                [ "$filesystem" = "ext4" ] && dir_check=$(ls "$mount_point" | grep "^etc$" || true)
                if [ -n "$dir_check" ] || [ -n "$(ls "$mount_point")" ]; then
                    echo
                    echo "Mount command:"
                    echo " $mount_cmd"
                    echo
                    echo "ls $mount_point"
                    ls "$mount_point" || {
                        print_error "Failed to list contents of $mount_point: possible I/O error. Check with 'ls $mount_point' or 'dmesg'."
                        umount "$mount_point" 2>/dev/null
                        return 1
                    }
                    echo
                    echo
                    print_success "Success!!"
                    echo
                    if [ -n "$output_csv" ]; then
                        local partition_size="Unknown"
                        if command -v fdisk >/dev/null 2>&1; then
                            partition_size=$(fdisk -l "$nbd_device" 2>/dev/null | grep "^$selected_part" | awk '{print $5}' | numfmt --to=iec-i --suffix=B --format="%.2f")
                        fi
                        echo "$mount_point,partition,$selected_part,$filesystem,\"$mount_cmd\",${partition_size:-Unknown},Success" >> "$output_csv"
                    fi
                    return 0
                fi
                umount "$mount_point" 2>/dev/null
            fi
            print_error "Failed to mount $selected_part. Verify filesystem with 'blkid $selected_part'."
            return 1
        else
            local part_device="/dev/$partitions"
            local mount_cmd="mount -t ntfs-3g -o $mount_mode $part_device $mount_point"
            set +e
            eval "$mount_cmd" >/dev/null 2>&1
            local mount_status=$?
            set -e
            if [ $mount_status -eq 0 ] && mountpoint -q "$mount_point"; then
                local dir_check
                [ "$filesystem" = "ntfs" ] && dir_check=$(ls "$mount_point" | grep -E "^Windows$|^Users$|^Program Files$" || true)
                [ "$filesystem" = "ext4" ] && dir_check=$(ls "$mount_point" | grep "^etc$" || true)
                if [ -n "$dir_check" ] || [ -n "$(ls "$mount_point")" ]; then
                    echo
                    echo "Mount command:"
                    echo " $mount_cmd"
                    echo
                    echo "ls $mount_point"
                    ls "$mount_point" || {
                        print_error "Failed to list contents of $mount_point: possible I/O error. Check with 'ls $mount_point' or 'dmesg'."
                        umount "$mount_point" 2>/dev/null
                        return 1
                    }
                    echo
                    echo
                    print_success "Success!!"
                    echo
                    if [ -n "$output_csv" ]; then
                        local partition_size="Unknown"
                        if command -v fdisk >/dev/null 2>&1; then
                            partition_size=$(fdisk -l "$nbd_device" 2>/dev/null | grep "^$part_device" | awk '{print $5}' | numfmt --to=iec-i --suffix=B --format="%.2f")
                        fi
                        echo "$mount_point,partition,$part_device,$filesystem,\"$mount_cmd\",${partition_size:-Unknown},Success" >> "$output_csv"
                    fi
                    return 0
                fi
                umount "$mount_point" 2>/dev/null
            fi
            print_error "Failed to mount $part_device. Verify filesystem with 'blkid $part_device'."
            return 1
        fi
    fi

    # Retry unmounting existing mounts
    for ((i=1; i<=retries; i++)); do
        umount "$mount_point" 2>/dev/null
        if [ $? -eq 0 ] || ! mountpoint -q "$mount_point"; then
            print_success "Existing mounts cleared for $mount_point."
            break
        fi
        if [ "$i" -eq "$retries" ]; then
            print_error "Failed to clear existing mounts for $mount_point after $retries attempts. Check with 'mountpoint $mount_point' or 'lsof $mount_point'."
            return 1
        fi
        sleep $sleep_time
    done

    # Probe starting sectors
    local starting_sectors=(0 17 31 63 2048 4096 34)
    for offset_sectors in "${starting_sectors[@]}"; do
        local byte_offset=$((offset_sectors * 512))
        local mount_cmd="mount -t ntfs-3g -o $mount_mode,offset=$byte_offset $nbd_device $mount_point"
        set +e
        eval "$mount_cmd" >/dev/null 2>&1
        local mount_status=$?
        set -e
        if [ $mount_status -eq 0 ] && mountpoint -q "$mount_point"; then
            local dir_check
            [ "$filesystem" = "ntfs" ] && dir_check=$(ls "$mount_point" | grep -E "^Windows$|^Users$|^Program Files$" || true)
            [ "$filesystem" = "ext4" ] && dir_check=$(ls "$mount_point" | grep "^etc$" || true)
            if [ -n "$dir_check" ] || [ -n "$(ls "$mount_point")" ]; then
                echo
                echo "Mount command:"
                echo " $mount_cmd"
                echo
                echo "ls $mount_point"
                ls "$mount_point" || {
                    print_error "Failed to list contents of $mount_point: possible I/O error. Check with 'ls $mount_point' or 'dmesg'."
                    umount "$mount_point" 2>/dev/null
                    return 1
                }
                echo
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

    print_error "Failed to mount $image_path. Verify filesystem or VHD format with 'file $image_path' or 'fdisk -l $image_path'."
    return 1
}

# Parse command-line options
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
        \?) print_error "Invalid option. Usage: './mount_vhd.sh -i image.vhd [-m /mnt/custom] [-f ntfs|ext4] [-o output.csv] [-r ro|rw] [-s] [-u]'"; exit 1 ;;
    esac
done

# Set default mount point
[ -z "$mount_point" ] && mount_point="/mnt/image_mount"

# Call the function
mount_vhd "$image_path" "$mount_point" "$output_csv" "$filesystem" "$check_status" "$unmount" "$mount_mode"
exit $?