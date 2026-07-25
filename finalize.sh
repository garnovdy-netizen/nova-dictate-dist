#!/bin/bash
# Финализация сервера: nginx для домена + HTTPS + модель (если нет) + авто-обновление.
# Запускается в консоли Timeweb ОДИН раз.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx cron wget certbot python3-certbot-nginx python3-venv python3-pip tar

# --- nginx под домен ---
cat > /etc/nginx/sites-available/novadictate <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name novadictate.ru www.novadictate.ru;
    root /var/www/html;
    index index.html;
    client_max_body_size 50m;
    location / { try_files $uri $uri/ =404; }
}
EOF
ln -sf /etc/nginx/sites-available/novadictate /etc/nginx/sites-enabled/novadictate
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# --- модель: скачать, если её ещё нет ---
if [ ! -f /var/www/html/model.tar.gz ]; then
  echo "=== модели нет, качаю (632МБ) ==="
  python3 -m venv /tmp/hfenv
  /tmp/hfenv/bin/pip install -q huggingface_hub
  /tmp/hfenv/bin/python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download("argmaxinc/whisperkit-coreml", allow_patterns=["openai_whisper-large-v3-v20240930_turbo_632MB/*"], local_dir="/tmp/novamodel")
snapshot_download("openai/whisper-large-v3", allow_patterns=["tokenizer.json","tokenizer_config.json","config.json","generation_config.json"], local_dir="/tmp/novatok")
PY
  tar czf /var/www/html/model.tar.gz -C /tmp novamodel novatok
fi

# --- авто-обновление сайта с GitHub каждые 5 минут ---
cat > /root/nova_update.sh <<'EOF'
#!/bin/bash
B=https://raw.githubusercontent.com/garnovdy-netizen/nova-dictate-dist/main
cd /var/www/html || exit 1
for f in index.html AppIcon.png NovaDictate.dmg; do
  if wget -q -O "$f.new" "$B/$f"; then mv "$f.new" "$f"; else rm -f "$f.new"; fi
done
EOF
chmod +x /root/nova_update.sh
bash /root/nova_update.sh
( crontab -l 2>/dev/null | grep -v nova_update.sh; echo "*/5 * * * * /bin/bash /root/nova_update.sh >/dev/null 2>&1" ) | crontab -
systemctl enable --now cron 2>/dev/null || true

# --- HTTPS (Let's Encrypt) с редиректом на https ---
certbot --nginx -d novadictate.ru -d www.novadictate.ru --non-interactive --agree-tos --redirect -m garnovdim@yandex.ru || echo "certbot: смотри вывод выше"

echo "=== ГОТОВО ==="
echo "-- HTTPS сайт --"; curl -skI https://novadictate.ru/ | head -1
echo "-- модель --"; curl -skI https://novadictate.ru/model.tar.gz | head -1
