#!/bin/sh

systemctl stop wg-quick@wg0
systemctl start wg-quick@wg0