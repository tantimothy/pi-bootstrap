./backup2SD
sudo apt update -y && sudo apt dist-upgrade -y
sudo apt -y autoremove
sudo apt clean
sudo apt purge -y $(dpkg -l | awk '/^rc/ { print $2 }')
pihole -up
wget https://raw.githubusercontent.com/philippe44/AirConnect/master/bin/aircast-arm
chmod +x aircast-arm
sudo mv aircast-arm /var/lib/airconnect/aircast-arm