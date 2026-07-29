#!/bin/bash
# Разворачивает API-прокси Nova Dictate (YandexGPT) на сервере.
# Ключ Яндекса передаётся через переменные окружения (не хранится в репозитории).
# Запуск в консоли Timeweb:
#   curl -fsSL <url>/deploy_api.sh -o /tmp/d.sh && YANDEX_KEY='...' YANDEX_FOLDER='...' bash /tmp/d.sh
set -e
export DEBIAN_FRONTEND=noninteractive

if [ -z "$YANDEX_KEY" ] || [ -z "$YANDEX_FOLDER" ]; then
  echo "ОШИБКА: задай YANDEX_KEY и YANDEX_FOLDER перед запуском."; exit 1
fi

apt-get update -y
apt-get install -y python3-venv python3-pip nginx

mkdir -p /opt/novaapi

# --- код сервера ---
cat > /opt/novaapi/main.py <<'PY'
import os
import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

YANDEX_API_KEY = os.environ.get("YANDEX_API_KEY", "")
YANDEX_FOLDER_ID = os.environ.get("YANDEX_FOLDER_ID", "")
YANDEX_MODEL = os.environ.get("YANDEX_MODEL", "yandexgpt/latest")
ACCESS_KEYS = {k.strip() for k in os.environ.get("ACCESS_KEYS", "").split(",") if k.strip()}

CLEAN_PROMPT = (
    "Ты — редактор текста, надиктованного голосом и распознанного на слух. "
    "Исправь орфографию и пунктуацию, аккуратно раздели на предложения и абзацы, "
    "убери слова-паразиты (ээ, ну, как бы), оговорки и повторы. "
    "Текст распознан по звучанию, поэтому в нём попадаются слова, ошибочно услышанные "
    "вместо похожих по звуку — исправляй их по смыслу и логике фразы, когда это очевидно "
    "из контекста (например, «прошлю» → «пришлю», «на встречу» ↔ «навстречу»). "
    "Сохрани смысл, стиль, тон и язык оригинала — не пересказывай, не сокращай и ничего "
    "не добавляй от себя. Верни только исправленный текст, без пояснений и кавычек."
)

CHAT_PROMPT = (
    "Ты — полезный голосовой ассистент Nova Dictate. Отвечай ясно, по существу и "
    "дружелюбно, на языке собеседника (по умолчанию по-русски). Можно использовать "
    "простое форматирование и короткие списки. Не выдумывай факты."
)

app = FastAPI(title="Nova Dictate API")


class Req(BaseModel):
    action: str
    text: str
    language: str = ""
    key: str = ""


class ChatMessage(BaseModel):
    role: str
    text: str


class ChatReq(BaseModel):
    messages: list[ChatMessage]
    key: str = ""


def system_prompt(action: str, language: str) -> str:
    if action == "clean":
        return CLEAN_PROMPT
    if action == "translate":
        lang = language or "English"
        return (f"Переведи текст на {lang}. Сохрани смысл, тон и форматирование. "
                "Ответь только переводом, без пояснений, транскрипции и кавычек.")
    raise HTTPException(status_code=400, detail=f"Неизвестное действие: {action}")


async def ask_yandex(messages, temperature=0.6, max_tokens=2000):
    if not YANDEX_API_KEY or not YANDEX_FOLDER_ID:
        raise HTTPException(status_code=500, detail="Сервер не настроен")
    body = {
        "modelUri": f"gpt://{YANDEX_FOLDER_ID}/{YANDEX_MODEL}",
        "completionOptions": {"stream": False, "temperature": temperature, "maxTokens": max_tokens},
        "messages": messages,
    }
    headers = {"Authorization": f"Api-Key {YANDEX_API_KEY}", "Content-Type": "application/json"}
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            r = await client.post(
                "https://llm.api.cloud.yandex.net/foundationModels/v1/completion",
                json=body, headers=headers)
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"Не удалось связаться с YandexGPT: {e}")
    if r.status_code != 200:
        raise HTTPException(status_code=502, detail=f"YandexGPT: {r.text[:300]}")
    try:
        result = r.json()["result"]["alternatives"][0]["message"]["text"].strip()
    except (KeyError, IndexError, ValueError):
        raise HTTPException(status_code=502, detail="Неожиданный ответ YandexGPT")
    if not result:
        raise HTTPException(status_code=502, detail="YandexGPT вернул пустой текст")
    return result


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/process")
async def process(req: Req):
    if ACCESS_KEYS and req.key not in ACCESS_KEYS:
        raise HTTPException(status_code=403, detail="Неверный или отсутствующий ключ доступа")
    text = req.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="Пустой текст")
    messages = [
        {"role": "system", "text": system_prompt(req.action, req.language)},
        {"role": "user", "text": text},
    ]
    return {"text": await ask_yandex(messages, temperature=0.3)}


@app.post("/chat")
async def chat(req: ChatReq):
    if ACCESS_KEYS and req.key not in ACCESS_KEYS:
        raise HTTPException(status_code=403, detail="Неверный или отсутствующий ключ доступа")
    if not req.messages:
        raise HTTPException(status_code=400, detail="Пустой запрос")
    messages = [{"role": "system", "text": CHAT_PROMPT}]
    for m in req.messages:
        role = "assistant" if m.role == "assistant" else "user"
        messages.append({"role": role, "text": m.text})
    return {"text": await ask_yandex(messages, temperature=0.6)}
PY

# --- окружение (venv) ---
python3 -m venv /opt/novaapi/venv
/opt/novaapi/venv/bin/pip install -q fastapi uvicorn httpx pydantic

# --- systemd-сервис с секретами (ключ Яндекса тут, не в коде) ---
cat > /etc/systemd/system/novaapi.service <<EOF
[Unit]
Description=Nova Dictate API (YandexGPT proxy)
After=network.target

[Service]
Environment=YANDEX_API_KEY=${YANDEX_KEY}
Environment=YANDEX_FOLDER_ID=${YANDEX_FOLDER}
Environment=ACCESS_KEYS=${ACCESS_KEYS}
WorkingDirectory=/opt/novaapi
ExecStart=/opt/novaapi/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now novaapi
sleep 2
systemctl restart novaapi

# --- nginx: проксируем /api/ на uvicorn, сохраняя HTTPS ---
CERT=/etc/letsencrypt/live/novadictate.ru/fullchain.pem
KEY=/etc/letsencrypt/live/novadictate.ru/privkey.pem
cat > /etc/nginx/sites-available/novadictate <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name novadictate.ru www.novadictate.ru;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name novadictate.ru www.novadictate.ru;
    ssl_certificate ${CERT};
    ssl_certificate_key ${KEY};
    root /var/www/html;
    index index.html;
    client_max_body_size 50m;
    location /api/ {
        proxy_pass http://127.0.0.1:8000/;
        proxy_set_header Host \$host;
        proxy_read_timeout 120s;
    }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
ln -sf /etc/nginx/sites-available/novadictate /etc/nginx/sites-enabled/novadictate
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "=== ГОТОВО: API развёрнут ==="
sleep 2
echo "-- health --"; curl -sS http://127.0.0.1:8000/health
echo; echo "-- тест YandexGPT (чистка) --"
curl -sS -X POST http://127.0.0.1:8000/process -H "Content-Type: application/json" \
  -d '{"action":"clean","text":"привет эээ ну как бы сегодня хорошая погода да"}' | head -c 400
echo
