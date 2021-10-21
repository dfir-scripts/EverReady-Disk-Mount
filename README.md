**Linux Disk Image Mounting Script** 

**ermount.sh**  
Mount/umounts disk images (E01, vmdk, vhd(x), vdi, raw, iso, hfs+, qcow2 and vss) 
Automation script mounts disks images using existing disk mount tools; qemu-nbd, ewfmount, affuse 


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
Oct 21, 2021
  Try try mounting nbd when affuse fails 

Mar 23, 2021<br> 
   Changed default mount location from /tmp/ermount to /mnt/image_mount<br>
   Changed working volume mount locations from /tmp/ to /mnt/<br>
   Fixed vsc mount option showing when there are no vscs<br>
   Updated status formatting to display nvme and other disk types<br>
   Changed vhd(x) mounting to affuse for mounting in WSL<br>
