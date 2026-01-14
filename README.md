# EverReady Disk Mount

## `er2.sh`: The All-in-One Mounting Script

`er2.sh` is a complete rewrite of the original `ermount.sh`, designed for speed, automation, and advanced use cases. It is a more compact and utilitarian tool, providing support for LVM volumes and most virtual and forensic image formats.

### `er2.sh` Features

| Feature | Description |
| --- | --- |
| **Universal Format Support** | Natively handles VDI, VMDK, VHD/VHDX, QCOW2, E01, AFF, split RAW (`.001`), ISOs, and more. |
| **Always Read-Only** | All images are mounted read-only using `qemu-nbd -r` to guarantee forensic integrity. |
| **LVM Support** | *Use the **`-l`** flag to scan and activate LVM volumes. LVM is activated in read-only mode—no writes to the image.* |
| **Case-Insensitive Extensions** | Works with any case combination (`.VHDX`, `.VhDx`, `.vhdx` all work). |
| **Flat VMDK Support** | Automatically detects and handles flat VMDK files (descriptor + `-flat.vmdk` data file). |
| **Forensically Sound Mounting** | Uses `noload` for ext4 and `norecover` for NTFS to prevent journal replay. |
| **Comprehensive LVM Cleanup** | Properly deactivates LVM volumes and cleans up `/dev/mapper` devices on unmount or error. |
| **Unpartitioned Disk Handling** | Intelligently mounts disks that are formatted as a single filesystem without a partition table. |
| **Smart Forensic Mounting** | Uses the correct FUSE tools (`ewfmount`, `affuse`) with proper permissions (`allow_root`) for forensic images. |
| **Robust Unmounting** | The `-u` flag properly deactivates LVM, detaches NBD devices (with `rmmod` fallback), and unmounts FUSE filesystems. |
| **Intelligent Error Handling** | Provides detailed, actionable diagnostics on mount failures to help you troubleshoot quickly. |
| **Pre-flight Checks** | Prevents errors by checking if mount points or NBD devices are already in use before starting. |

### `er2.sh` Usage

```shell
Usage: er2.sh -i <image> [-m mount/point] [-f filesystem] [-l] [-o offset] [-s] [-u]

Required:
  -i <image>         Disk image file or ISO

Optional:
  -m <mount/point>   Mount point directory (default: /mnt/image_mount)
  -f <filesystem>    Filesystem type: ntfs, ext4, vfat, exfat, hfsplus
  -l                 Enable LVM support (scans and activates LVM volumes)
  -o <offset>        Manual byte offset for partition mounting
  -s                 Status - Check mount status only
  -u                 Unmount - Unmount image and cleanup
  -h, --help         Show this help message

Supported Formats:
  Virtual Disks:     VDI, VMDK, VHD, VHDX, QCOW, QCOW2
  Forensic Images:   E01, AFF, Split RAW (.001, .002, ...)
  Raw Images:        .raw, .dd, .img, .iso

Examples:
  # Mount a virtual disk
  er2.sh -i disk.vmdk

  # Mount a forensic image
  er2.sh -i evidence.E01 -m /mnt/case1

  # Mount an image with LVM volumes
  er2.sh -i lvm_disk.dd -m /mnt/lvm -l

  # Mount a split RAW image
  er2.sh -i image.001 -f ntfs

  # Mount an ISO
  er2.sh -i ubuntu.iso

  # Unmount
  er2.sh -u -m /mnt/image_mount
```

### Important Notes

#### Read-Only Mounting

**All images are mounted strictly read-only.** The script uses `qemu-nbd -r` for all image types, which guarantees that the underlying image file is never modified. This ensures:

- **Forensic integrity** is always preserved

- **Cryptographic hashes** (MD5/SHA-1/SHA-256) remain unchanged

- **Chain of custody** is maintained for legal proceedings

#### LVM Support

If your image contains LVM volumes, use the `-l` flag to scan and activate them:

```shell
sudo er2.sh -i disk.dd -m /mnt/disk -l
```

**How it works:**

- The script creates a temporary LVM filter to prevent auto-activation of host LVM volumes

- Volume groups on the NBD device are scanned with `vgscan`

- LVM volumes are activated with `vgchange -ay`

- Since the NBD device is read-only (`qemu-nbd -r`), LVM reads metadata without writing to the image

- On cleanup, all LVM volumes are properly deactivated before detaching the NBD device

The script will detect LVM volumes and prompt you if you forget the `-l` flag.

#### Forensic Mounting

The script uses forensically sound mount options for all supported filesystems:

| Filesystem | Mount Options | Purpose |
| --- | --- | --- |
| ext2/ext3/ext4 | `noload` | Prevents journal replay |
| NTFS | `norecover` | Prevents log file replay |
| E01/AFF | Read-only via FUSE + `qemu-nbd -r` | FUSE tools present raw image to NBD |

These options, combined with `qemu-nbd -r`, prevent the hash changes documented in [Maxim Suhanov's research](https://dfir.ru/2020/05/24/how-mounting-a-disk-image-can-change-it/).

### Dependencies

To use all features, you may need to install the following tools:

```shell
sudo apt update
sudo apt install -y qemu-utils lvm2 ewf-tools afflib-tools hfsprogs exfatprogs dosfstools ntfs-3g parted
```

---

## `ermount.sh`: The Original Interactive Mounter

`ermount.sh` remains as an interactive, step-by-step approach for mounting images, making it ideal for learning the mount process. It also retains support for legacy formats not included in `er2.sh`, such as VSS (Volume Shadow Copies) and BitLocker-encrypted volumes.

### `ermount.sh` Usage

```shell
USAGE: ermount.sh [-h -s -u -b -rw] -i Image_file_or_Disk -m Mount_Point -t File_System_Type -o offset

OPTIONAL:
       -i Image file or disk source to mount
       -m Mount point (Default /mnt/image_mount)
       -t File system type (Default NTFS)
       -o Image offset
       -h This help text
       -s ermount status
       -u umount all disks from $0 mount points
       -b mount bitlocker encrypted volume
       -rw mount image read write
```

---

## Which Script Should I Use?

| Scenario | Recommended Script |
| --- | --- |
| Fast, flexible, no-frills mounting of modern formats, LVM, or complex images. | **`er2.sh`** |
| New to the mounting process and want to learn or go through each step interactively. | `ermount.sh` |
| Need to mount VSS (Volume Shadow Copies) or BitLocker-encrypted volumes. | `ermount.sh` |

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

