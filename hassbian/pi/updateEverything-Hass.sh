./backup2SD
sudo apt update && sudo apt dist-upgrade -y --fix-missing
sudo apt -y autoremove
sudo apt clean
#sudo apt purge -y $(dpkg -l | awk '/^rc/ { print $2 }')

sudo systemctl stop home-assistant@homeassistant.service
sudo su -s /bin/bash homeassistant -c "source /srv/homeassistant/bin/activate
pip install --upgrade pip
pip3 install --upgrade homeassistant"
sudo systemctl start home-assistant@homeassistant.service

sudo npm update -g homebridge
#sudo npm update -g homebridge-platform-wemo
#sudo npm update -g homebridge-hs100
sudo npm update -g homebridge-homeassistant
sudo npm update -g homebridge-camera-ffmpeg-omx

#sudo shutdown -r now
