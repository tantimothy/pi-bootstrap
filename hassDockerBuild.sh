if cd ~/rpi-home-assistant; then git pull; else git clone https://github.com/lroguet/rpi-home-assistant/; fi

cd /home/pi/pi-bootstrap/hassDocker
docker build -t ttimothy/hass .

cd ~/rpi-home-assistant
./build.sh