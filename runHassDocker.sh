docker run  \
  --init -d  \
  --name="home-assistant" \
  -v /home/pi/Home-AssistantConfig:/config \
  -v /etc/localtime:/etc/localtime:ro \
  --net=host ttimothy/hass


