#!/bin/bash

# Adapted from:
# https://gist.githubusercontent.com/joemiller/6049831/raw/f2a458c3afcb3b57cb7a6d9cb3d9534482982086/raid_ephemeral.sh
#
# this script will attempt to detect any ephemeral drives on an EC2 node and create a LVM mounted /opt
# It should be run early on the first boot of the system.
#
# Beware, This script is NOT fully idempotent.
#

METADATA_URL_BASE="http://169.254.169.254/2012-01-12"

yum -y -d0 install curl

# Take into account xvdb or sdb
root_drive=`df -h | grep -v grep | awk 'NR==2{print $1}'`


if [ "$root_drive" == "/dev/xvda1" ]; then
  echo "Detected 'xvd' drive naming scheme (root: $root_drive)"
  DRIVE_SCHEME='xvd'
else
  echo "Detected 'sd' drive naming scheme (root: $root_drive)"
  DRIVE_SCHEME='sd'
fi


# figure out how many ephemerals we have by querying the metadata API, and then:
#  - convert the drive name returned from the API to the hosts DRIVE_SCHEME, if necessary
#  - verify a matching device is available in /dev/
drives=""
ephemeral_count=0
ephemerals=$(curl --silent $METADATA_URL_BASE/meta-data/block-device-mapping/ | grep ephemeral)
for e in $ephemerals; do
  echo "Probing $e .."
  device_name=$(curl --silent $METADATA_URL_BASE/meta-data/block-device-mapping/$e)
  # might have to convert 'sdb' -> 'xvdb'
  device_name=$(echo $device_name | sed "s/sd/$DRIVE_SCHEME/")
  device_path="/dev/$device_name"

  # test that the device actually exists since you can request more ephemeral drives than are available
  # for an instance type and the meta-data API will happily tell you it exists when it really does not.
  if [ -b $device_path ]; then
    echo "Detected ephemeral disk: $device_path"
    drives="$drives $device_path"
    ephemeral_count=$((ephemeral_count + 1 ))
  else
    echo "Ephemeral disk $e, $device_path is not present. skipping"
  fi
done


if [ "$ephemeral_count" = 0 ]; then
  echo "No ephemeral disk detected. exiting"
  exit 0
fi


# ephemeral0 is typically mounted for us already. umount it here
umount /mnt
umount /media/*


# overwrite first few blocks in case there is a filesystem
for drive in $drives; do
  dd if=/dev/zero of=$drive bs=4096 count=1024
done

partprobe

for drive in $drives
do
    pvcreate $drive
done

vgcreate /dev/vg01 $drives
lvcreate -l 100%FREE -n lvol_opt vg01

mkfs -t ext4 /dev/vg01/lvol_opt

mkdir -p /opt
mount -t ext4 -o noatime /dev/vg01/lvol_opt /opt

# Remove xvdb/sdb from fstab
chmod 777 /etc/fstab
sed -i "/${DRIVE_SCHEME}b/d" /etc/fstab
sed -i "/ephemeral/d" /etc/fstab


# Make /opt appear on reboot
echo "/dev/vg01/lvol_opt /opt ext4 noatime 0 0" | tee -a /etc/fstab
