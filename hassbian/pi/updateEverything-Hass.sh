#/bin/bash

#./backup2SD
sudo apt update && sudo apt dist-upgrade -y --fix-missing
sudo apt -y autoremove
sudo apt clean
#sudo apt purge -y $(dpkg -l | awk '/^rc/ { print $2 }')

sudo systemctl stop home-assistant@homeassistant
sudo su -s /bin/bash homeassistant -c "source /srv/homeassistant/bin/activate
pip install --upgrade pip
pip3 install --upgrade homeassistant"
sudo systemctl start home-assistant@homeassistant

#sudo shutdown -r now
