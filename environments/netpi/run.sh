#!/bin/bash

docker compose up -d

docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'your_secret_password'
