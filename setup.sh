#!/bin/bash
# Установка сайта Nova Dictate на сервер (запускается в консоли Timeweb)
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx wget
cd /var/www/html || exit 1
rm -f index.nginx-debian.html
BASE=https://raw.githubusercontent.com/garnovdy-netizen/nova-dictate-dist/main
wget -q -O index.html "$BASE/index.html"
wget -q -O AppIcon.png "$BASE/AppIcon.png"
wget -q -O NovaDictate.dmg "$BASE/NovaDictate.dmg"
systemctl enable --now nginx
systemctl restart nginx
echo "=== ГОТОВО ==="
ls -lh /var/www/html
curl -sI http://localhost | head -1
