#!/bin/bash
# Скачивает облегчённую модель (632МБ) + токенизатор с HuggingFace на сервер
# и упаковывает для раздачи приложениям. Запускается в консоли Timeweb.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3-venv python3-pip tar
python3 -m venv /tmp/hfenv
/tmp/hfenv/bin/pip install -q huggingface_hub
echo "=== скачиваю модель с HuggingFace (632МБ) ==="
/tmp/hfenv/bin/python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download("argmaxinc/whisperkit-coreml",
    allow_patterns=["openai_whisper-large-v3-v20240930_turbo_632MB/*"],
    local_dir="/tmp/novamodel")
snapshot_download("openai/whisper-large-v3",
    allow_patterns=["tokenizer.json","tokenizer_config.json","config.json","generation_config.json"],
    local_dir="/tmp/novatok")
print("downloaded")
PY
echo "=== упаковываю ==="
tar czf /var/www/html/model.tar.gz -C /tmp novamodel novatok
ls -lh /var/www/html/model.tar.gz
echo "=== MODEL_HOSTED ==="
curl -sI http://localhost/model.tar.gz | head -1
