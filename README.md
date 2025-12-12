# EverReady Disk Mount

## `er2.sh`: The All-in-One Mounting Script

`er2.sh` is a complete rewrite of the original `ermount.sh`, designed for speed, automation, and advanced use cases. It is a more compact and utilitarian tool, providing support for LVM volumes and most virtual and forensic image formats.

### `er2.sh` Features

| Feature | Description |
|:--------|:------------|
| **Universal Format Support** | Natively handles VDI, VMDK, VHD/VHDX, QCOW2, E01, AFF, split RAW (`.001`), ISOs, and more. |
| **Safe Read-Only by Default** | All images are mounted read-only by default to prevent accidental modifications. |
| **Explicit LVM Support** | Use the `-l` flag to enable LVM support when needed. LVM activation requires write access and will modify the image. |
| **Case-Insensitive Extensions** | Works with any case combination (`.VHDX`, `.VhDx`, `.vhdx` all work). |
| **Flat VMDK Support** | Automatically detects and handles flat VMDK files (descriptor + `-flat.vmdk` data file). |
| **Forensically Sound Mounting** | Uses `noload` for ext4 and `norecover` for NTFS to prevent journal replay that would modify the image. |
| **Comprehensive LVM Cleanup** | Properly deactivates LVM volumes and cleans up `/dev/mapper` devices on unmount or error. |
| **Unpartitioned Disk Handling** | Intelligently mounts disks that are formatted as a single filesystem without a partition table. |
| **Smart Forensic Mounting** | Uses the correct FUSE tools (`ewfmount`, `affuse`) with proper permissions (`allow_root`) for forensic images. |
| **Robust Unmounting** | The `-u` flag properly deactivates LVM, detaches NBD devices (with `rmmod` fallback), and unmounts FUSE filesystems. |
| **Intelligent Error Handling** | Provides detailed, actionable diagnostics on mount failures to help you troubleshoot quickly. |
| **Pre-flight Checks** | Prevents errors by checking if mount points or NBD devices are already in use before starting. |

### `er2.sh` Usage

```shell
Usage: er2.sh -i <image> [-m mount/point] [-f filesystem] [-l] [-o offset] [-r ro|rw] [-s] [-u]

Required:
  -i <image>         Disk image file or ISO

Optional:
  -m <mount/point>   Mount point directory (default: /mnt/image_mount)
  -f <filesystem>    Filesystem type: ntfs, ext4, vfat, exfat, hfsplus
  -l                 Enable LVM support (allows image modification)
  -o <offset>        Manual byte offset for partition mounting
  -r <ro|rw>         Mount mode: ro (read-only, default) or rw (read-write)
  -s                 Status - Check mount status only
  -u                 Unmount - Unmount image and cleanup
  -h, --help         Show this help message

Supported Formats:
  Virtual Disks:     VDI, VMDK, VHD, VHDX, QCOW, QCOW2
  Forensic Images:   E01, AFF, Split RAW (.001, .002, ...)
  Raw Images:        .raw, .dd, .img, .iso

Examples:
  # Mount a virtual disk (read-only)
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

#### LVM Support

**By default, all images are mounted read-only for safety.** This protects the vast majority of images (non-LVM) from accidental modification.

If your image contains LVM volumes, you must use the `-l` flag:

```shell
sudo er2.sh -i disk.dd -m /mnt/disk -l
```

**Why?** LVM activation requires writing metadata to the disk image, which will:
- Modify the image file
- Change its cryptographic hash (MD5/SHA-1/SHA-256)
- Affect chain of custody for forensic evidence

The script will detect LVM volumes and guide you if you forget the `-l` flag.

#### Forensic Mounting

The script uses forensically sound mount options:
- **ext2/ext3/ext4**: Mounted with `noload` to prevent journal replay
- **NTFS**: Mounted with `norecover` to prevent log file replay
- **E01/AFF**: Always read-only (FUSE limitation), LVM not supported

These options prevent the hash changes documented in [Maxim Suhanov's research](https://dfir.ru/2018/12/02/the-ro-option-is-not-a-solution/).

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
|:---------|:-------------------|
| Fast, flexible, no-frills mounting of modern formats, LVM, or complex images. | **`er2.sh`** |
| New to the mounting process and want to learn or go through each step interactively. | `ermount.sh` |
| Need to mount VSS (Volume Shadow Copies) or BitLocker-encrypted volumes. | `ermount.sh` |

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
