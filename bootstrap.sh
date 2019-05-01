sudo apt update && sudo apt upgrade

if cd ~/Dropbox-Uploader; then git pull; else git clone https://github.com/andreafabrizi/Dropbox-Uploader.git; fi

cd ~
curl -sSL get.docker.com | sh
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker pi

