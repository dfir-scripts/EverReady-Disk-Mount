#!/bin/bash
# EverReady disk mount
# John Brown  forensic.studygroup@gmail.com
# Mounts disk, disk images (E01,vmdk, vdi, Raw and bitlocker) in a linux evnironment using ewf_mount,qemu-ndb, affuse and bdemount 
# WARNING:  Forcefully disconnects and remounts images and network block devices! 
# Mounts everything in /tmp/ by default
# Images are mounted based on extension: E01, VDI, VHD, VHDX, QCOw2, AFF
# Other wise mount is attempted as raw
# Supports segmented disks images using aff
# 
# Requires ewf_tools, affuse, bdemount and qemu-utils 
# tested using SANS Sift and Ubuntu 18.04

#Produce Red Text Color 
function makered() {
      COLOR='\033[01;31m' # bold red
      RESET='\033[00;00m' # normal white
      MESSAGE=${@:-"${RESET}Error: No message passed"}
      echo -e "${COLOR}${MESSAGE}${RESET}"
}
 
#Produce Green Text Color
function makegreen() {
      COLOR='\033[0;32m' # Green
      RESET='\033[00;00m' # normal white
      MESSAGE=${@:-"${RESET}Error: No message passed"}
      echo -e "${COLOR}${MESSAGE}${RESET}"
}

#Function ask yes or no
function yes-no(){
      read -p "(Y/N)?"
      [ "$(echo $REPLY | tr [:upper:] [:lower:])" == "y" ] &&  YES_NO="yes";
}

######### MOUNT STATUS ######################
# Report mount status
mount_status(){
     mount_stat=$(echo " /tmp/ermount/" && [ "$(ls -A /tmp/ermount/ 2>/dev/null)" ] && makered " Mounted" || makegreen " Not Mounted" )
     raw_stat=$(echo " /tmp/raw/" && [ "$(ls -A /tmp/raw/ 2>/dev/null)" ] && makered " Mounted"  || makegreen " Not Mounted")
     nbd_stat=$(echo " /dev/nbd1/" && [ "$(ls /dev/nbd1 2>/dev/null)" ] && makered " Active"  || makegreen " Inactive")
     vss_stat=$(echo " /tmp/vss/" && [ "$(ls /tmp/vss 2>/dev/null)" ] && makered " Active"  || makegreen " Inactive")
     vsc_stat=$(echo " /tmp/shadow/" && [ "$(ls /tmp/shadow 2>/dev/null)" ] && makered " Active"  || makegreen " Inactive")
     bde_stat=$(echo " /tmp/bde/" && [ "$(ls /tmp/bde 2>/dev/null)" ] && makered " Active"  || makegreen " Inactive")
}

######### MOUNT PREFS ######################
# User supplies input path of the image file or disk
function image_source(){
#makered "Enter Path and Image or Device to Mount"
      read -e -p "Enter Image File or Device Path: " -i "" ipath 
      image_type=$(echo "$ipath"|awk -F . '{print toupper ($NF)}')
      [ ! -f "${ipath}" ] && [ ! -b "${ipath}" ] && makered "File or Device does not exist.." && sleep 2 && clear && exit
      image_name=$(echo $ipath|sed 's/\(.*\)\..*/\1\./')
      [ $image_type == "ISO" ] && return 1
      multi=$image_name"002"
      # Set source image and destination mount point for E01 && umount /tmp/raw 2>/dev/null 
      printf "Image type " 
      makegreen $image_type || makegreen "RAW"
      source_info=$(file "$ipath")
      echo "Source Information"
      makegreen $source_info

}

# User input to set mount directory (Default /tmp/ermount)
function mount_point(){
      # Set Data Source or mount point"
      echo ""
      makegreen "Set Mount Point"
      echo "Set Path or Enter to Accept Default:"
      read -e -p "" -i "/tmp/ermount" mount_dir
      mkdir -p $mount_dir
      [ "$(ls -A $mount_dir)" ] && umount $mount_dir -f -A
      [ "$(ls -A $mount_dir)" ] && echo "$mount_dir busy, try different mount point or reboot" && sleep 2 && exit
      echo ""
}

######### IMAGE OFFSET #####################
# Set partition offset for disk images
function set_image_offset(){  
     blkid $image_src |grep -e "PTTYPE=\|PTUUID=\|PARTUUID=" && \
     makegreen "Set Partition Offset" && \
     fdisk -l $image_src && echo ""  && \
     read -e -p "Enter the starting block: " -i "2048" starting_block && \
     # Next line has been commented. Use default block size of 512 
     # read -e -p "Set disk block size:  " -i "512" block_size && \
     partition_offset=$(echo $(($starting_block * 512))) && \
     makegreen "Offset: $starting_block * 512 = $partition_offset" && \
     offset="offset=$partition_offset" 
}

######### IMAGE MOUNTING ###################
# Mount images in expert witness format as raw image to /tmp/raw
function mount_e01(){
      [ 'which ewfmount' == "" ] && makered "ewf-tools not installed" && sleep 1 && exit
      image_src="/tmp/raw/ewf1"
      [ "$(ls -A /tmp/raw/)" ] && echo "Attempting to remount /tmp/raw/ " && umount /tmp/raw/ -f -A && makegreen "Sucessfully umounted previous E01" 
      ewfmount "${ipath}" /tmp/raw   && makegreen "Success!" && ipath="/tmp/raw/ewf1" || exit
}

#Mount vmdk, vdi and qcow2 Image types as a network block device
function mount_nbd(){
     [ 'which qemu-nbd' == "" ] && makered "qemu-utils not installed" && sleep 1 && exit
     makered "Current Mount Status: "
     echo $nbd_stat
     echo $mount_stat
     [ -d "/dev/nbd1" ] && qemu-nbd -d /dev/nbd1 2>/dev/null && \
     rmmod nbd 2>/dev/null && echo "Warning: unloading and reloading nbd"
     modprobe nbd && echo "modprobe nbd"
     makegreen "qemu-nbd -r -c /dev/nbd1 "${ipath}"" && \
     qemu-nbd -r -c /dev/nbd1 "${ipath}" && ls /dev/nbd1  && makegreen "Success!" || exit
     image_src="/dev/nbd1"
}

#Mount raw split images using affuse
function mount_aff(){
     [ 'which affuse' == "" ] && makered "afflib-tools not installed" && sleep 1 && exit
     [ "$(ls -A /tmp/raw/)" ] && fusermount -uz /tmp/raw/ 
     [ "$(ls -A /tmp/raw/)" ] && echo "raw mount point in use, try manual unmount or reboot" && exit
     affuse "${ipath}" /tmp/raw && image_src=$(find /tmp/raw/ -type f) 
}

# Decrypt bitlocker disks and mount partitions
function bit_locker_mount(){
     [ 'which bdemount' == "" ] && makered "bdemount is not installed" && sleep 1 && exit
     [ "${partition_offset}" != "" ] && offset="-o $partition_offset "
     [ "$(ls -A /tmp/raw/)" ] && \
     echo "" && makered "Bitlocker Encryption!!!" && makered "Enter decryption password or key"
     echo "-p <Password>" 
     echo "-r <Authentication Key>"
     echo ""
     read -e -p "" bl_auth
     makegreen "Mounting with bdemount!!  "
     makegreen "bdemount $bl_auth $offset $ipath /tmp/bde"
     bdemount $bl_auth $offset $ipath /tmp/bde   
     ls /tmp/bde/bde1 && makegreen "Unlocked!!" && offset="" && image_src="/tmp/bde/bde1"
     mount_image
     exit
}

# Issue Mount command based on image type and prefs
 function mount_image(){
      echo ""
      makegreen "Executing Mount Command....."
      echo "Defaults is ntfs, see mount man pages for a complete list"
      echo "Common filesystem types: ntfs, vfat, ext3, ext4, hfsplus, iso9660, udf" 
      read -e -p "File System Type:  " -i "ntfs" fstype
      [ $fstype == "ntfs" ] && ntfs_support="show_sys_files,streams_interface=windows," && \
      umount_vss
      # Mount image to $mount_dir
      echo $image_src | grep -qiv "/dev/sd" && loop="loop,"
      mount_options="-t $fstype -o $ro_rw,"
      [ $image_type == "ISO" ] && mount_options=""
      [ "${block_device}" != "" ] && mount_options="-o $ro_rw,"
      mount=$(echo "mount $mount_options$loop$ntfs_support$offset "$image_src" $mount_dir"|sed 's/, / /')
      makegreen $mount
      $mount
      echo ""
      [ "$(ls -A $mount_dir)" ] && \
      echo "$ipath Mounted at: $mount_dir"
      echo ""
      ls $mount_dir
      echo ""
      [ "$(ls -A $mount_dir)" ] && \
      makegreen "Success!" || makered "Mount Failed! Try reboot or mount -o "norecovery""
      echo ""
      [ "$(ls -A $mount_dir)" ] && [ "$fstype" == "ntfs" ] && mount_vss 
      exit
}

#Identify and choose whether to mount any vss volumes
function mount_vss(){
      [ 'which vshadowinfo' == "" ] && makered "libvshadow-utils not installed" && sleep 1 && exit
      vss_dir="/tmp/vss"
      vss_info=$(vshadowinfo $image_src 2>/dev/null |grep "Number of stores:") 
      [ "${vss_info}" != "" ] && echo "VSCs found! "$vss_info && \
      echo "Mount Volume Shadow Copies?" && yes-no && vsc="yes"
      [ "${offset}" == "yes" ] && offset="-o $offset "  
      [ "${vsc}" == "yes" ] && vshadowmount $image_src $offset$vss_dir && \
      ls $vss_dir | while read vsc;
      do 
        mkdir -p /tmp/shadow/$vsc
        mount -t ntfs -o ro,loop,show_sys_files,streams_interface=windows /tmp/vss/$vsc /tmp/shadow/$vsc
      done  || exit
      ls /tmp/shadow/ && makegreen "Success! VSCs mounted on /tmp/shadow" || echo "No Volume Shadow Copies mounted"
}

######### UNMOUNT IMAGES ###################

function umount_all(){
      echo "Umount commands sent to drives mounted in /tmp and NBD unloaded" && echo ""
      umount_vss
      [ "$(ls -A /tmp/bde 2>/dev/null)" ] && umount /tmp/bde -f -A || fusermount -uz /tmp/bde 2>/dev/null
      [ "$(ls -A /tmp/ermount 2>/dev/null)" ] && umount /tmp/ermount -f -A || fusermount -uz /tmp/ermount 2>/dev/null
      [ "$(ls -A /tmp/raw/ 2>/dev/null)" ] && umount /tmp/raw -f -A || fusermount -uz /tmp/raw/ 2>/dev/null
      ls /dev/nbd1p1 2>/dev/null && qemu-nbd -d /dev/nbd1 2>/dev/null
      lsmod |grep -i ^nbd && rmmod nbd 2>/dev/null && echo "Warning: unloading Network Block Device"
      rmdir /tmp/ermount 2>/dev/null
      rmdir /tmp/raw 2>/dev/null
      rmdir /tmp/bde 2>/dev/null
      mount_status
}

#Identify and umount any previously mounted vss volumes
function umount_vss(){
      vss_dir="/tmp/vss"
      #umount any existing mounts
      fusermount -uz $vss_dir 2>/dev/null || return 1
      ls /tmp/shadow/ 2>/dev/null|while read vsc;
      do 
        umount /tmp/shadow/$vsc 2>/dev/null
        rmdir /tmp/shadow/$vsc 2>/dev/null
        echo "/tmp/shadow/$vsc umounted"
      done 
      rmdir /tmp/vss 2>/dev/null
}

######### Help File ###################
get_help(){
makegreen "EverReady Disk Mount"
makegreen "Mount/umounts disk and disk images (E01, vmdk, vhd(x), vdi, raw, iso, hfs+, qcow2 and vss)"
echo "Automation script mounts disks read only using disk mount tools; qemu-nbd, ewfmount, affuse, bdemount  

USAGE: ermount.sh [-h -s -u -b -rw]
	OPTIONS:
           -h this help text
           -s ermount status
           -u umount all disks mounted in /tmp and nbd
           -b mount bitlocker encrypted volume
           -rw mount image read write


      Default mount point: /tmp/ermount
      Requires: ewf-tools, afflib3, qemu-utils, mount and bdemount for bitlocker decryption
      Warning: forcefully disconnects mounted drives and Network Block Devices
      When in doubt reboot
"
}

###### END OF FUNTIONS  ############## 

###### COMMAND EXECUTION ############# 
clear
#check root requirements 
[ `whoami` != 'root' ] && makered "Requires Root Access!" && sleep 1 && exit

# Setup mount directories and display physical devices
mkdir -p /tmp/raw 2>/dev/null  
mkdir -p /tmp/vss 2>/dev/null
mkdir -p /tmp/bde 2>/dev/null

#Get drive status and process any cli parameters
[ "${1}" == "-h" ] && get_help && exit 
[ "${1}" == "-u" ] && mount_status && mount_dir="/tmp/ermount" && umount_all
mount_status    
[ "${1}" == "-u" ] || [ "${1}" == "-s" ] &&  echo "ERMount Mount Point Status:" && \
echo $mount_stat && echo $raw_stat && echo $nbd_stat && echo $vss_stat && echo $vsc_stat && echo $bde_stat && \
echo "" && echo "Physical Disks: /dev/sd<n>" && lsblk -f /dev/sd* && echo "" && exit
[ "${1}" != "-rw" ] && ro_rw="ro" ||ro_rw="rw"
[ "${1}" == "-b" ] 

# start mounting process and select source image and mount point
makegreen "ERMount a disk, disk image or VM"
image_source
mount_point

# Send to mounting function based on image type
[ -f "$image_name"002"" ] &&  echo $multi "Multiple raw disk segments detected, mounting with affuse" && mount_aff
echo $image_type | grep -qie "AFF$" && mount_aff
echo $image_type | grep -ie "E01$\|S01" && mount_e01
echo $image_type | grep -ie "VMDK$\|VDI$\|QCOW2$\|VHD$\|VHDX$" && mount_nbd 

# If no image type detected, process as raw
[ "$image_src" == "" ] && image_src="${ipath}"
is_device=$(echo "$image_src" | grep -i "/dev/sd")
[ "${is_device}" != "" ] && [ "${1}" != "-b" ] && lsblk -f /dev/sd* && mount_image
[ "${is_device}" != "" ] && [ "${1}" == "-b" ] && bit_locker_mount

# Set image offset if needed
set_image_offset
# Decrypt bitlocker if "-b" is specified
[ "${1}" == "-b" ] && bit_locker_mount
# mount image and detect any volume shadow copies
mount_image

