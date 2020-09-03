sudo systemctl stop home-assistant@homeassistant
sudo su -s /bin/bash homeassistant
source /srv/homeassistant/bin/activate
pip3 install --upgrade homeassistant
sudo systemctl start home-assistant@homeassistant
