#!/bin/bash

sudo echo "blacklist dvb_usb_rtl28xxu" | sudo tee /etc/modprobe.d/blacklist-rtl.conf

echo "📦 Compiling custom local build..."
docker build -t dragonos-pi .

docker run -it \
  --privileged \
  -v /dev/bus/usb:/dev/bus/usb \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  --net=host \
  --name my-dragonos \
  dragonos-pi
