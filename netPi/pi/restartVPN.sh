#!/bin/sh

sudo systemctl stop wg-quick@wg0
sudo systemctl start wg-quick@wg0