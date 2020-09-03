lsblk -f
df -h

sudo dd if=/dev/mmcblk0 of=/dev/sda bs=1M
sudo fsck -y /dev/sda2
./backup2SD
