# EverReady Disk Mount


## er2.sh: All-in-One Mounting Script

`er2.sh` is a rewrite of the original `ermount.sh` that was created as a companion file for `siftgrab`.  Ermount uses prompts that steps through the mount process. `er2.sh` on the other hand is a more compact and utilitarian providing support for `lvm` volumes and scripted mountings of multiple KAPE `vhdx` images with the goal of simplicity, function and speed.  `ermount.sh` remains to provide an easy method to learn and engage in the mount process.  It also has additional capabilities left out of `er2.sh`  (`vss` and `bitlocker` support). 

### `er2.sh` Features

| Feature                         | Description                                                                                                   |
| :------------------------------ | :------------------------------------------------------------------------------------------------------------ |
| **Universal Format Support**    | Handles VDI, VMDK, VHD/VHDX, QCOW2, E01, AFF, split RAW (`.001`), and more.                                   |
| **Full LVM Support**            | Automatically scans for, activates, and lists LVM Logical Volumes for mounting.                               |
| **Unpartitioned Disk Handling** | Intelligently mounts disks that are formatted as a single filesystem without a partition table.               |
| **Smart Forensic Mounting**     | Uses the correct FUSE tools (`ewfmount`, `affuse`) for forensic images and handles permissions automatically. |
| **Robust Unmounting**           | The `-u` flag properly deactivates LVM, detaches NBD/loop devices, and unmounts FUSE filesystems.             |
| **Intelligent Error Handling**  | Provides detailed diagnostics on mount failures to help you troubleshoot quickly.                             |
| **Future enhancements**         | APFS                                                                                                          |

### `er2.sh` Usage
```bash
Usage: ./er2.sh -i <image_file> [-m <mount_point>] [-f <filesystem>] [-o <output.csv>] [-r ro|rw] [-s] [-u]

Options:
  -i <image_file>    Disk image to mount (required for mounting)
  -m <mount_point>   Mount point directory (default: /mnt/image_mount)
  -f <filesystem>    Force filesystem type (ntfs, ext4, vfat, exfat, hfsplus)
  -o <output.csv>    Output mount details to CSV file
  -r <ro|rw>         Mount mode: ro (read-only) or rw (read-write) (default: ro)
  -s                 Check mount status only
  -u                 Unmount image
  -h, --help         Show this help message

Supported formats:
  Virtual Disks: VDI, VMDK, VHD, VHDX, QCOW, QCOW2
  Forensic Images: E01, AFF, Split RAW (.001, .002, ...)
  Raw Images: .raw, .dd, .img

Examples:
  ./er2.sh -i disk.vmdk                    # Mount VMDK
  ./er2.sh -i evidence.E01 -m /mnt/case1   # Mount E01 to custom location
  ./er2.sh -i image.001                    # Mount FTK split RAW
  ./er2.sh -u -m /mnt/image_mount          # Unmount

```
### Dependencies

To use all features, you may need to install the following tools:

```bash
sudo apt update
sudo apt install -y qemu-utils lvm2 libewf-tools afflib-tools hfsprogs exfatprogs dosfstools
```

---

### EverReady Disk Mount ###
Mount/umounts disk and disk images (E01, vmdk, vhd(x), vdi, raw, iso, hfs+, qcow2 and vss)
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

  Default mount point: /mnt/image_mount
  Minimum requirements: libewf-tools libbde-tools libvshadow-tools afflib-tools, qemu-utils, libfuse2
  Works best with updated drivers from the gift repository (add-apt-repository ppa:gift/stable)
  Warning: forcefully disconnects mounted drives and Network Block Devices
  When in doubt reboot
https://dfir-scripts.medium.com/forensic-mounting-of-disk-images-using-ubuntu-20-04-fe8165fca3eb

Change Log:
Aug 2, 2025
Added -o offset to mount most images using a single command
Now mounts block devices in WSL (vhdx, vmdk, vdi etc) fixed in Windows 11

Oct 7, 2023
Added command line options for disk_image_file (-i), mount_point (-m) and file_system_type (-t) for faster mounting.

Mar 8, 2022
Changed VHD(x) mount from aff to nbd and improved WSL compatibility

Dec 26, 2021
Updated nbd mount error checking and minor updates

Oct 21, 2021
Added nbd mount if affuse fails Fixed issue that prevented entering partition starting block

Mar 23, 2021
Changed default mount location from /tmp/ermount to /mnt/image_mount
Changed working volume mount locations from /tmp/ to /mnt/
Fixed vsc mount option showing when there are no vscs
Updated status formatting to display nvme and other disk types
Changed vhd(x) mounting to affuse for mounting in WSL


## Which Script Should I Use?

| Scenario                                                                               | Recommended Script |
| :------------------------------------------------------------------------------------- | :----------------- |
| Fast flexible no frills. Mounts modern formats, LVM, or complex images.                | **`er2.sh`**       |
| New to mounting process and want learn or go through each step in the mounting process | `ermount.sh`       |

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
