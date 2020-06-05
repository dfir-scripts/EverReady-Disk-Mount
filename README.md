Disk Image Mounting Script 

ermount.sh  
Mount/umounts disk images (E01, vmdk, vhd(x), vdi, raw, iso, hfs+, qcow2 and vss) 
Automation script mounts disks images using existing disk mount tools; qemu-nbd, ewfmount, affuse  

USAGE: ermount.sh [-h -s -u -b -rw] 
	OPTIONS:<br> 
           -h this help text<br>
           -s ermount status<br>
           -u umount all disks mounted in /tmp and /dev/nbd<br>
           -b mount bitlocker encrypted volume<br>
           -rw mount image read write<br>

 
      Default mount point: /tmp/ermount
      Requires: mmls, ewf-tools, afflib3, qemu-utils, mount and bdemount for bitlocker decryption
      Warning: forcefully disconnects mounted drives and Network Block Devices
      When in doubt reboot
