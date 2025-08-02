<b>EverReady Disk Mount</b><br>
Mount/umounts disk and disk images (E01, vmdk, vhd(x), vdi, raw, iso, hfs+, qcow2 and vss)

<b>USAGE: ermount.sh [-h -s -u -b -rw] -i Image_file_or_Disk -m Mount_Point -t File_System_Type -o offset</b>
	
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

**Change Log:**<br>
Aug 2, 2025<br>
  Added -o offset to mount most images using a single command<br>
  Now mounts block devices in WSL (vhdx, vmdk, vdi etc) fixed in Windows 11<br>
  
Oct 7, 2023<br>
  Added command line options for disk_image_file (-i), mount_point (-m) and file_system_type (-t)
  for faster mounting.<br>
  
Mar 8, 2022<br>
  Changed VHD(x) mount from aff to nbd and improved WSL compatibility
  
Dec 26, 2021<br>
  Updated nbd mount error checking and minor updates<br>
  
Oct 21, 2021<br>
  Added nbd mount if affuse fails
  Fixed issue that prevented entering partition starting block 

Mar 23, 2021<br> 
   Changed default mount location from /tmp/ermount to /mnt/image_mount<br>
   Changed working volume mount locations from /tmp/ to /mnt/<br>
   Fixed vsc mount option showing when there are no vscs<br>
   Updated status formatting to display nvme and other disk types<br>
   Changed vhd(x) mounting to affuse for mounting in WSL<br>
