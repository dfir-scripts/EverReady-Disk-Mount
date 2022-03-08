#! /bin/bash
# EverReady disk mount
# John Brown  forensic.studygroup@gmail.com
# Mounts disks, disk images (E01,vmdk, vdi, Raw and bitlocker) in a linux evnironment using ewf_mount,qemu-ndb, affuse and bdemount 
# WARNING:  Forcefully attempts to disconnect and remounts images and network block devices!
# When in doubt, reboot
# Creates directories in /mnt/ for different disk and amge types
# Images are mounted based on extension: E01, VDI, VHD, VHDX, QCOw2, AFF
# Otherwise mount is attempted as raw
# Supports segmented disks images using aff
#
# Requires ewf_tools, affuse, bdemount and qemu-utils

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
     mount_stat=$(echo " /mnt/image_mount/" && [ "$(ls -A /mnt/image_mount/ 2>/dev/null)" ] && makered " Mounted" || makegreen " Not Mounted" )
     raw_stat=$(echo " /mnt/raw/........" && [ "$(ls -A /mnt/raw/ 2>/dev/null)" ] && makered " Mounted" || makegreen " Not Mounted")
     nbd_stat=$(echo " /dev/nbd1/......." && [ "$(ls /dev/nbd1 2>/dev/null)" ] && makered " Active" || makegreen " Inactive")
     vss_stat=$(echo " /mnt/vss/........" && [ "$(ls /mnt/vss 2>/dev/null)" ] && makered " Active" || makegreen " Inactive")
     vsc_stat=$(echo " /mnt/shadow/....." && [ "$(ls /mnt/shadow 2>/dev/null)" ] && makered " Active" || makegreen " Inactive")
     bde_stat=$(echo " /mnt/bde/........" && [ "$(ls /mnt/bde 2>/dev/null)" ] && makered " Active" || makegreen " Inactive")
     makered "Disk Status"
     lsblk -o NAME,SIZE,FSTYPE,FSAVAIL,FSUSE%,MOUNTPOINT 2>/dev/null || lsblk
     echo ""
     makered "ermount Volume Mount Points"
     echo $mount_stat && echo $raw_stat && echo $nbd_stat && echo $vss_stat && echo $vsc_stat && echo $bde_stat
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
      # Set source image and destination mount point for E01 && umount /mnt/raw 2>/dev/null
      printf "Image type "
      makegreen $image_type || makegreen "RAW"
      source_info=$(file "$ipath")
      echo "Source Information"
      makegreen $source_info

}

# User input to set mount directory (Default /mnt/image_mount)
function mount_point(){
      # Set Data Source or mount point"
      echo ""
      makegreen "Set Mount Point"
      echo "Set Path or Enter to Accept Default:"
      read -e -p "" -i "/mnt/image_mount" mount_dir
      mkdir -p $mount_dir
      [ "$(ls -A $mount_dir)" ] && umount $mount_dir -f -A
      [ "$(ls -A $mount_dir)" ] && echo "$mount_dir busy, try different mount point or reboot" && sleep 2 && exit
      echo ""
}

######### IMAGE OFFSET #####################
# Set partition offset for disk images
function set_image_offset(){
     makegreen "Set Partition Offset" && \
     fdisk -l "$image_src" && echo ""  && \
     read -e -p "Enter the starting block: " -i "" starting_block
     # Next line has been commented. Use default block size of 512
     # read -e -p "Set disk block size:  " -i "512" block_size && \
     partition_offset=$(echo $(($starting_block * 512))) && \
     makegreen "Offset: $starting_block * 512 = $partition_offset" && \
     offset="offset=$partition_offset"
}

######### IMAGE MOUNTING ###################
# Mount images in expert witness format as raw image to /mnt/raw
function mount_e01(){
      [ 'which ewfmount' == "" ] && makered "ewf-tools not installed" && sleep 1 && exit
      image_src="/mnt/raw/ewf1"
      [ "$(ls -A /mnt/raw/)" ] && echo "Attempting to remount /mnt/raw/ " && umount /mnt/raw/ -f -A && makegreen "Sucessfully umounted previous E01" 
      makegreen "Executing ewfmount command: ewfmount "${ipath}" /mnt/raw"
      ewfmount "${ipath}" /mnt/raw   && makegreen "Success!" && ipath="/mnt/raw/ewf1" || exit
}

#Mount vmdk, vdi and qcow2 Image types as a network block device
function mount_nbd(){
     [ 'which qemu-nbd' == "" ] && makered "qemu-utils not installed" && sleep 1 && exit
     echo $nbd_stat |grep -q Active && makered "/dev/nbd1 is already in use!!....\nTry $0 -u if umount fails"
     [ -d "/dev/nbd1" ] && qemu-nbd -d /dev/nbd1 2>/dev/null && \
     rmmod nbd 2>/dev/null && makegreen "umounted of nbd suceeded!"
     [ -d "/dev/nbd1" ] && makered "Could not delete existing network block device! try ->  $0 -u" && exit
     modprobe nbd && echo "modprobe nbd"
     makegreen " Excecuting:  qemu-nbd -r -c /dev/nbd1 ${ipath}" && \
     qemu-nbd -r -c /dev/nbd1 "${ipath}" || exit
     ls /dev/nbd1  && makegreen "nbd mount successful!"
     image_src="/dev/nbd1"
     sfdisk -V  $image_src |grep "No errors" || makegreen "Waiting for remount..." && sleep 4
     }


#Mount raw split images using affuse
function mount_aff(){
     [ 'which affuse' == "" ] && makered "afflib-tools not installed" && sleep 1 && exit
     [ "$(ls -A /mnt/raw/)" ] && fusermount -uz /mnt/raw/
     [ "$(ls -A /mnt/raw/)" ] && echo "raw mount point in use, try manual unmount or reboot" && exit
     makegreen "Executing Affuse command: affuse "${ipath}" /mnt/raw"
     affuse "${ipath}" /mnt/raw && image_src=$(find /mnt/raw/ -type f) || mount_nbd
}

# Decrypt bitlocker disks and mount partitions
function bit_locker_mount(){
     [ 'which bdemount' == "" ] && makered "bdemount is not installed" && sleep 1 && exit
     [ "${partition_offset}" != "" ] && offset="-o $partition_offset "
     [ "$(ls -A /mnt/raw/)" ] && \
     echo "" && makered "Bitlocker Encryption!!!" && makered "Enter decryption password or key"
     echo "-p <Password>"
     echo "-r <Authentication Key>"
     echo ""
     read -e -p "" bl_auth
     makegreen "Mounting with bdemount!!  "
     makegreen "bdemount $bl_auth $offset $ipath /mnt/bde"
     bdemount $bl_auth $offset $ipath /mnt/bde
     ls /mnt/bde/bde1 && makegreen "Unlocked!!" && offset="" && image_src="/mnt/bde/bde1"
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
      makegreen "Success!" || makered "Mount Failed! Try $0 -u or reboot"
      echo ""
      [ "$(ls -A $mount_dir)" ] && [ "$fstype" == "ntfs" ] && mount_vss
      exit
}

#Identify and choose whether to mount any vss volumes
function mount_vss(){
      [ 'which vshadowinfo' == "" ] && makered "libvshadow-utils not installed" && sleep 1 && exit
      vss_dir="/mnt/vss"
      vss_info=$(vshadowinfo $image_src 2>/dev/null |grep "Number of stores:"|grep -v "0$")
      vshadowinfo $image_src 2>/dev/null
      [ "${vss_info}" != "" ] && echo "VSCs found! "$vss_info && \
      echo "Mount Volume Shadow Copies?" && yes-no && vsc="yes"
      [ "${offset}" == "yes" ] && offset="-o $offset "
      [ "${vsc}" == "yes" ] && vshadowmount $image_src $offset$vss_dir && \
      ls $vss_dir | while read vsc;
      do
        mkdir -p /mnt/shadow/$vsc
        mount -t ntfs -o ro,loop,show_sys_files,streams_interface=windows /mnt/vss/$vsc /mnt/shadow/$vsc
      done  || exit
      ls /mnt/shadow/ && makegreen "Success! VSCs mounted on /mnt/shadow" || echo "No Volume Shadow Copies mounted"
}

######### UNMOUNT IMAGES ###################

function umount_all(){
      echo "Umount commands sent to all $0 drives mounts" && echo ""
      umount_vss
      [ "$(ls -A /mnt/bde 2>/dev/null)" ] && umount /mnt/bde -f -A || fusermount -uz /mnt/bde 2>/dev/null
      [ "$(ls -A /mnt/image_mount 2>/dev/null)" ] && umount /mnt/image_mount -f -A || fusermount -uz /mnt/image_mount 2>/dev/null
      [ "$(ls -A /mnt/raw/ 2>/dev/null)" ] && umount /mnt/raw -f -A || fusermount -uz /mnt/raw/ 2>/dev/null
      ls /dev/nbd1p1 2>/dev/null && qemu-nbd -d /dev/nbd1 2>/dev/null
      lsmod |grep -i ^nbd && rmmod nbd 2>/dev/null && echo "Warning: unloading Network Block Device"
      mount_status
      exit
}

#Identify and umount any previously mounted vss volumes
function umount_vss(){
      vss_dir="/mnt/vss"
      #umount any existing mounts
      fusermount -uz $vss_dir 2>/dev/null || return 1
      ls /mnt/shadow/ 2>/dev/null|while read vsc;
      do
        umount /mnt/shadow/$vsc 2>/dev/null
        rmdir /mnt/shadow/$vsc 2>/dev/null
        echo "/mnt/shadow/$vsc umounted"
      done
}

######### Help message ###################
get_help(){
makegreen "EverReady Disk Mount"
makegreen "Mount/umounts disk and disk images (E01, vmdk, vhd(x), vdi, raw, iso, hfs+, qcow2 and vss)"
echo "
USAGE: $0 [-h -s -u -b -rw]
	OPTIONS:
           -h this help text
           -s ermount status
           -u umount all disks from $0 mount points
           -b mount bitlocker encrypted volume
           -rw mount image read write

      Default mount point: /mnt/image_mount
      Minimum requirements: ewf-tools, afflib3, qemu-utils, libvshadow-utils, libbde-utils
      Works best with updated drivers from the gift repository (add-apt-repository ppa:gift/stable)
      Warning: forcefully disconnects mounted drives and Network Block Devices
      When in doubt reboot
"
}

######### WSL mount help message ###################
wsl_mount(){
  makegreen "WSL Detected"
  makered "No support for mounting block devices"
  echo "
  Attach VHD(x) in Windows Disk Manager and then mount drive letter using drvfs

  ex:
  sudo mount -t drvfs D: /mnt/image_mount

  "
  exit
}

###### END OF FUNTIONS  ##############

###### COMMAND EXECUTION #############
clear
#check root requirements
[ `whoami` != 'root' ] && makered "Requires Root Access!" && sleep 1 && exit
wsl=$(cat /proc/version |grep -i 'microsoft')

# Setup mount directories and display physical devices
mkdir -p /mnt/raw 2>/dev/null
mkdir -p /mnt/vss 2>/dev/null
mkdir -p /mnt/bde 2>/dev/null

#Process Cli params and get mount status
[ "${1}" == "-h" ] && get_help && exit
[ "${1}" == "-u" ] && umount_all
[ "${1}" == "-s" ] && mount_status && exit
mount_status
[ "${1}" != "-rw" ] && ro_rw="ro" ||ro_rw="rw"
##### [ "${1}" == "-b" ]

# start mounting process and select source image and mount point
makegreen "Use ERMount to mount a disk, disk image"
image_source
mount_point

# Send to mounting function based on image type
echo $image_type | grep -qie "E01$\|S01" && mount_e01
echo $image_type | grep -qie "AFF$" && mount_aff
[ -f "$image_name"002"" ] && mount_aff
[ "${wsl}" == "" ] && echo $image_type | grep -ie "VHD$\|VHDX$\|VMDK$\|VDI$\|QCOW2$" && mount_nbd
[ "${wsl}" != "" ] && echo $image_type | grep -ie "VMDK$\|VDI$" && mount_aff
[ "${wsl}" != "" ] && echo $image_type | grep -ie "VHD$\|VHDX$" && wsl_mount


# If no image type detected, process as raw
[ "$image_src" == "" ] && image_src="${ipath}"
is_device=$(echo "$image_src" | grep -i "/dev/" |grep -vi "nbd1")
[ "${is_device}" != "" ] && [ "${1}" != "-b" ] && fdisk -l |grep $image_src && mount_image
[ "${is_device}" != "" ] && [ "${1}" == "-b" ] && bit_locker_mount

# Set image offset if needed
partx -s "$image_src" 2>/dev/null | grep ^" 1" && set_image_offset
# Decrypt bitlocker if "-b" is specified
[ "${1}" == "-b" ] && bit_locker_mount
# mount image and detect any volume shadow copies
mount_image
