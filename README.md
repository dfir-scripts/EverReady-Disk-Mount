# EverReady Disk Mount

## `er2.sh`: The All-in-One Mounting Script
---
`er2.sh` is a complete rewrite of the original `ermount.sh`, designed for speed, automation, and advanced use cases. It is a more compact and utilitarian tool, providing support for LVM volumes and most virtual and forensic image formats.

### `er2.sh` Features

| Feature                         | Description                                                                                                          |
| :------------------------------ | :------------------------------------------------------------------------------------------------------------------- |
| **Universal Format Support**    | Natively handles VDI, VMDK, VHD/VHDX, QCOW2, E01, AFF, split RAW (`.001`), ISOs, and more.                           |
| **Full LVM Support**            | Automatically scans for, activates, and lists LVM Logical Volumes for mounting.                                      |
| **Unpartitioned Disk Handling** | Intelligently mounts disks that are formatted as a single filesystem without a partition table.                      |
| **Smart Forensic Mounting**     | Uses the correct FUSE tools (`ewfmount`, `affuse`) with proper permissions (`allow_root`) for forensic images.       |
| **Robust Unmounting**           | The `-u` flag properly deactivates LVM, detaches NBD devices (with `rmmod` fallback), and unmounts FUSE filesystems. |
| **Intelligent Error Handling**  | Provides detailed, actionable diagnostics on mount failures to help you troubleshoot quickly.                        |
| **Pre-flight Checks**           | Prevents errors by checking if mount points or NBD devices are already in use before starting.                       |

### `er2.sh` Usage

```bash
Usage: er2.sh -i <image> [-m mount/point] [-f filesystem] [-l log.csv] [-o offset] [-r ro|rw] [-s] [-u]

Required:
  -i <image>         Disk image file or ISO

Optional:
  -m <mount/point>   Mount point directory (default: /mnt/image_mount)
  -f <filesystem>    Filesystem type: ntfs, ext4, vfat, exfat, hfsplus
  -l <log.csv>       Log mount details to CSV file
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
  er2.sh -i disk.vmdk
  er2.sh -i evidence.E01 -m /mnt/case1 -l mount.csv
  er2.sh -i image.001 -f ntfs
  er2.sh -i ubuntu.iso
  er2.sh -u -m /mnt/image_mount
```

### Dependencies

To use all features, you may need to install the following tools:

```bash
sudo apt update
sudo apt install -y qemu-utils lvm2 libewf-tools afflib-tools hfsprogs exfatprogs dosfstools
```

---

## `ermount.sh`: The Original Interactive Mounter

`ermount.sh` remains as an interactive, step-by-step approach for mounting images, making it ideal for learning the mount process. It also retains support for legacy formats not included in `er2.sh`, such as VSS (Volume Shadow Copies) and BitLocker-encrypted volumes.

### `ermount.sh` Usage

```bash
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

| Scenario                                                                             | Recommended Script |
| :----------------------------------------------------------------------------------- | :----------------- |
| Fast, flexible, no-frills mounting of modern formats, LVM, or complex images.        | **`er2.sh`**       |
| New to the mounting process and want to learn or go through each step interactively. | `ermount.sh`       |
| Need to mount VSS (Volume Shadow Copies) or BitLocker-encrypted volumes.             | `ermount.sh`       |

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
