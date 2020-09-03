#/bin/bash

pihole -v 
pihole status
service darkstat status
service ntopng status
systemctl status redis-server 
sudo ipsec verify
sudo cat /var/log/openvpn-status.log
less +F /var/log/openvpn.log
less +F /var/log/auth.log
