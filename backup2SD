lsblk -f
df -h

# copy /boot partition from p1 to sda1
sudo mount /dev/mmcblk0p1 /mnt/sdsrc/
sudo mount /dev/sda1 /mnt/sdbak/
sudo rsync -aHv --delete-during /mnt/sdsrc/ /mnt/sdbak/
sudo umount -l /dev/mmcblk0p1
sudo umount -l /dev/sda1

# copy everything else to sda2
sudo mount /dev/sda2 /mnt/sdbak/
sudo rsync -aHv --delete-during --exclude-from=//home/pi/rsync-exclude.txt / /mnt/sdbak/
sudo umount -l /dev/sda2
sudo fsck -y /dev/sda2
