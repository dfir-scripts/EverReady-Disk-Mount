Disk Image Mounting Script 

ermount.sh  
Mount/umounts disk images (E01, vmdk, vhd(x), vdi, raw, iso, hfs+, qcow2 and vss) 
Automation script mounts disks images using existing disk mount tools; qemu-nbd, ewfmount, affuse  

USAGE: ermount.sh -s -u -h -rw 
	OPTIONS: 
           -s ermount status 
           -u umount all disks mounted in /tmp and nbd 
           -rw mount image read write 
           -h this help text 
 
      Default mount point: /tmp/ermount 
      Requires: mmls, ewf-tools, afflib3, qemu-utils, mount 
      Warning: forcefully disconnects mounted drives and Network Block Devices 
      When in doubt reboot 
