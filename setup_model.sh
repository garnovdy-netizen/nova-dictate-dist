#!/bin/bash
# Обновляет сайт (новый .dmg) и размещает модель (632МБ) для раздачи.
# Запускается в консоли Timeweb одной командой.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx wget python3-venv python3-pip tar

BASE=https://raw.githubusercontent.com/garnovdy-netizen/nova-dictate-dist/main

echo "=== обновляю файлы сайта ==="
cd /var/www/html
rm -f index.nginx-debian.html
wget -q -O index.html "$BASE/index.html"
wget -q -O AppIcon.png "$BASE/AppIcon.png"
wget -q -O NovaDictate.dmg "$BASE/NovaDictate.dmg"

echo "=== скачиваю модель (632МБ) с HuggingFace ==="
python3 -m venv /tmp/hfenv
/tmp/hfenv/bin/pip install -q huggingface_hub
/tmp/hfenv/bin/python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download("argmaxinc/whisperkit-coreml",
    allow_patterns=["openai_whisper-large-v3-v20240930_turbo_632MB/*"],
    local_dir="/tmp/novamodel")
snapshot_download("openai/whisper-large-v3",
    allow_patterns=["tokenizer.json","tokenizer_config.json","config.json","generation_config.json"],
    local_dir="/tmp/novatok")
print("model downloaded")
PY

echo "=== упаковываю модель ==="
tar czf /var/www/html/model.tar.gz -C /tmp novamodel novatok
systemctl enable --now nginx
systemctl restart nginx

echo "=== ГОТОВО ==="
ls -lh /var/www/html/
echo "-- проверка сайта --"; curl -sI http://localhost/ | head -1
echo "-- проверка модели --"; curl -sI http://localhost/model.tar.gz | head -1
