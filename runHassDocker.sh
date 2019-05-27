docker run -d \
  --name hass \
  --net=host \
  -v /etc/localtime:/etc/localtime:ro \
  -v /home/pi/home-assistant/configuration:/config \
  lroguet/rpi-home-assistant:latest