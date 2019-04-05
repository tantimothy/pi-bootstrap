sudo cp -r home/homeassistant/.homeassistant/* /home/homeassistant/.homeassistant/
sudo cp home/pi/* /home/pi/
sudo cp -r var/lib/homebridge/ /var/lib/
sudo cp etc/dhcpcd.conf /etc/
sudo cp etc/default/homebridge /etc/default/
sudo cp etc/systemd/system/home-assistant@homeassistant.service /etc/systemd/system/
sudo cp etc/systemd/system/homebridge.service /etc/systemd/system/
sudo cp etc/systemd/system/homebridge.timer /etc/systemd/system/
chmod ug+x /home/pi/backup2SD 
chmod ug+x /home/pi/dup2SD 
chmod ug+x /home/pi/hassupdate 
chmod ug+x /home/pi/restartHass
chmod ug+x /home/pi/restartHomebridge 
chmod ug+x /home/pi/status-hass 
chmod ug+x /home/pi/updateEverything-Hass 

sudo chown -hR homeassistant:homeassistant /home/homeassistant/

# Add user pi to the homeassistant group
sudo usermod -G homeassistant -a pi
# Set-group id on .homeassistant and its sub directories
sudo find /home/homeassistant/.homeassistant -type d -exec sudo chmod --preserve-root u=rwX,g=srwX,o= {} \;
# Fix the permissions on .homeassistant and everything under
sudo chmod --preserve-root -R u=rwX,g+rwX,o= /home/homeassistant/.homeassistant
# Make a link from /home/homeassistant/.homeassistant to /home/pi/.homeassistant
ln -s /home/homeassistant/.homeassistant /home/pi/