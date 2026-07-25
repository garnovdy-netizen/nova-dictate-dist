#!/bin/bash
# Ставит авто-обновление сайта: сервер сам тянет свежий .dmg/страницу с GitHub каждые 5 минут.
# Запускается в консоли Timeweb ОДИН раз.
set -e
apt-get install -y cron wget >/dev/null 2>&1 || true
systemctl enable --now cron 2>/dev/null || true

cat > /root/nova_update.sh <<'EOF'
#!/bin/bash
B=https://raw.githubusercontent.com/garnovdy-netizen/nova-dictate-dist/main
cd /var/www/html || exit 1
for f in index.html AppIcon.png NovaDictate.dmg; do
  if wget -q -O "$f.new" "$B/$f"; then mv "$f.new" "$f"; else rm -f "$f.new"; fi
done
EOF
chmod +x /root/nova_update.sh

# первый прогон прямо сейчас
bash /root/nova_update.sh

# крон каждые 5 минут (без дублей)
( crontab -l 2>/dev/null | grep -v nova_update.sh; echo "*/5 * * * * /bin/bash /root/nova_update.sh >/dev/null 2>&1" ) | crontab -

echo "=== АВТООБНОВЛЕНИЕ УСТАНОВЛЕНО ==="
ls -lh /var/www/html/
curl -sI http://localhost/NovaDictate.dmg | head -1
