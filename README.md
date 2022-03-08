**Linux Disk Image Mounting Script** 

**ermount.sh**  
Mount/umounts disk images (E01, vmdk, vhd(x), vdi, raw, iso, hfs+, qcow2 and vss) 


USAGE: ermount.sh [-h -s -u -b -rw] <br>
* OPTIONS:<br> 
  -h this help text<br>
  -s ermount status<br>
  -u umount all disks mounted in /tmp and /dev/nbd<br>
  -b mount bitlocker encrypted volume<br>
  -rw mount image read write<br>

Default mount point: /tmp/ermount<br>
Requires: mmls, ewf-tools, afflib3, qemu-utils, mount and bdemount for bitlocker decryption<br>
Warning: forcefully disconnects mounted drives and Network Block Devices<br>
When in doubt reboot

**Change Log:**<br>
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
