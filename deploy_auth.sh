#!/bin/bash
# Добавляет регистрацию по email-коду в API Nova Dictate:
#  - база пользователей (SQLite), эндпоинты /request_code и /verify_code
#  - отправка писем через Yandex SMTP
#  - ИИ-эндпоинты /process и /chat теперь требуют валидный токен (регистрацию)
# Ключ YandexGPT не трогаем (он в основном novaapi.service). SMTP-креды кладём
# в systemd drop-in. Запуск в консоли Timeweb (пароль приложения Яндекса — свой):
#   wget -qO /tmp/da.sh https://raw.githubusercontent.com/garnovdy-netizen/nova-dictate-dist/main/deploy_auth.sh \
#     && SMTP_USER='garnovdim@yandex.ru' SMTP_PASS='ПАРОЛЬ_ПРИЛОЖЕНИЯ' bash /tmp/da.sh
set -e

if [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASS" ]; then
  echo "ВНИМАНИЕ: SMTP_USER/SMTP_PASS не заданы — письма отправляться НЕ будут,"
  echo "код входа будет писаться в лог сервиса (journalctl -u novaapi) для теста."
fi

cat > /opt/novaapi/main.py <<'PY'
import os
import re
import ssl
import time
import secrets
import sqlite3
import smtplib
from email.mime.text import MIMEText
from email.utils import formataddr

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

YANDEX_API_KEY = os.environ.get("YANDEX_API_KEY", "")
YANDEX_FOLDER_ID = os.environ.get("YANDEX_FOLDER_ID", "")
YANDEX_MODEL = os.environ.get("YANDEX_MODEL", "yandexgpt/latest")
ACCESS_KEYS = {k.strip() for k in os.environ.get("ACCESS_KEYS", "").split(",") if k.strip()}

SMTP_HOST = os.environ.get("SMTP_HOST", "smtp.yandex.ru")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "465"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASS = os.environ.get("SMTP_PASS", "")
SMTP_FROM = os.environ.get("SMTP_FROM", SMTP_USER or "noreply@novadictate.ru")

DB = "/opt/novaapi/users.db"
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

CLEAN_PROMPT = (
    "Ты — редактор надиктованного текста. Исправь орфографию и пунктуацию, "
    "убери слова-паразиты (ээ, ну, как бы, оговорки и повторы), аккуратно разбей "
    "на предложения и абзацы. Сохрани смысл, лексику, стиль и язык оригинала — "
    "не пересказывай и не сокращай. Верни только исправленный текст, без пояснений и кавычек."
)
CHAT_PROMPT = (
    "Ты — полезный голосовой ассистент Nova Dictate. Отвечай ясно, по существу и "
    "дружелюбно, на языке собеседника (по умолчанию по-русски). Можно использовать "
    "простое форматирование и короткие списки. Не выдумывай факты."
)

app = FastAPI(title="Nova Dictate API")


# ---------- база пользователей ----------

def db():
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    with db() as c:
        c.execute("""CREATE TABLE IF NOT EXISTS users(
            email TEXT PRIMARY KEY, token TEXT, verified INTEGER DEFAULT 0,
            created_at REAL, last_login REAL)""")
        c.execute("""CREATE TABLE IF NOT EXISTS codes(
            email TEXT PRIMARY KEY, code TEXT, expires REAL, created REAL,
            attempts INTEGER DEFAULT 0)""")


init_db()


def token_valid(token: str) -> bool:
    if not token:
        return False
    with db() as c:
        row = c.execute("SELECT 1 FROM users WHERE token=? AND verified=1", (token,)).fetchone()
        return row is not None


def require_access(key: str):
    # Доступ к ИИ: либо админ-ключ из ACCESS_KEYS, либо валидный токен пользователя.
    if key and key in ACCESS_KEYS:
        return
    if token_valid(key):
        return
    raise HTTPException(status_code=403, detail="Требуется регистрация")


# ---------- письма ----------

def send_code_email(to: str, code: str):
    text = (f"Здравствуйте!\n\nВаш код для входа в Nova Dictate: {code}\n\n"
            "Код действует 10 минут. Если вы не запрашивали вход — просто игнорируйте это письмо.")
    msg = MIMEText(text, _charset="utf-8")
    msg["Subject"] = "Код входа — Nova Dictate"
    msg["From"] = formataddr(("Nova Dictate", SMTP_FROM))
    msg["To"] = to
    if not SMTP_USER or not SMTP_PASS:
        print(f"[DEV] код для {to}: {code}", flush=True)
        return
    ctx = ssl.create_default_context()
    with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, context=ctx) as s:
        s.login(SMTP_USER, SMTP_PASS)
        s.sendmail(SMTP_FROM, [to], msg.as_string())


# ---------- модели запросов ----------

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


class EmailReq(BaseModel):
    email: str


class CodeReq(BaseModel):
    email: str
    code: str


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


# ---------- эндпоинты ----------

@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/request_code")
def request_code(req: EmailReq):
    email = req.email.strip().lower()
    if not EMAIL_RE.match(email):
        raise HTTPException(status_code=400, detail="Некорректный email")
    now = time.time()
    with db() as c:
        row = c.execute("SELECT created FROM codes WHERE email=?", (email,)).fetchone()
        if row and now - row["created"] < 60:
            raise HTTPException(status_code=429, detail="Код уже отправлен. Подождите минуту.")
        code = f"{secrets.randbelow(1000000):06d}"
        c.execute("REPLACE INTO codes(email, code, expires, created, attempts) VALUES(?,?,?,?,0)",
                  (email, code, now + 600, now))
    try:
        send_code_email(email, code)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Не удалось отправить письмо: {e}")
    return {"ok": True}


@app.post("/verify_code")
def verify_code(req: CodeReq):
    email = req.email.strip().lower()
    code = req.code.strip()
    now = time.time()
    with db() as c:
        row = c.execute("SELECT code, expires, attempts FROM codes WHERE email=?", (email,)).fetchone()
        if not row:
            raise HTTPException(status_code=400, detail="Сначала запросите код")
        if row["attempts"] >= 5:
            raise HTTPException(status_code=429, detail="Слишком много попыток. Запросите новый код.")
        if now > row["expires"]:
            raise HTTPException(status_code=400, detail="Код истёк. Запросите новый.")
        if code != row["code"]:
            c.execute("UPDATE codes SET attempts=attempts+1 WHERE email=?", (email,))
            raise HTTPException(status_code=400, detail="Неверный код")
        urow = c.execute("SELECT token FROM users WHERE email=?", (email,)).fetchone()
        token = urow["token"] if urow and urow["token"] else secrets.token_hex(16)
        if urow:
            c.execute("UPDATE users SET verified=1, last_login=?, token=? WHERE email=?",
                      (now, token, email))
        else:
            c.execute("INSERT INTO users(email, token, verified, created_at, last_login) VALUES(?,?,1,?,?)",
                      (email, token, now, now))
        c.execute("DELETE FROM codes WHERE email=?", (email,))
    return {"token": token, "email": email}


@app.post("/process")
async def process(req: Req):
    require_access(req.key)
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
    require_access(req.key)
    if not req.messages:
        raise HTTPException(status_code=400, detail="Пустой запрос")
    messages = [{"role": "system", "text": CHAT_PROMPT}]
    for m in req.messages:
        role = "assistant" if m.role == "assistant" else "user"
        messages.append({"role": role, "text": m.text})
    return {"text": await ask_yandex(messages, temperature=0.6)}
PY

# --- SMTP-креды в systemd drop-in (основной novaapi.service не трогаем) ---
mkdir -p /etc/systemd/system/novaapi.service.d
cat > /etc/systemd/system/novaapi.service.d/smtp.conf <<EOF
[Service]
Environment=SMTP_HOST=${SMTP_HOST:-smtp.yandex.ru}
Environment=SMTP_PORT=${SMTP_PORT:-465}
Environment=SMTP_USER=${SMTP_USER}
Environment=SMTP_PASS=${SMTP_PASS}
Environment=SMTP_FROM=${SMTP_FROM:-$SMTP_USER}
EOF

systemctl daemon-reload
systemctl restart novaapi
sleep 2

echo "-- health --"; curl -sS http://127.0.0.1:8000/health; echo
echo "-- тест: запрос кода на свой email (проверь почту) --"
if [ -n "$TEST_EMAIL" ]; then
  curl -sS -X POST http://127.0.0.1:8000/request_code -H "Content-Type: application/json" \
    -d "{\"email\":\"$TEST_EMAIL\"}"; echo
fi
echo "-- проверка гейта ИИ без токена (должно быть 403) --"
curl -sS -o /dev/null -w "HTTP %{http_code}\n" -X POST http://127.0.0.1:8000/chat \
  -H "Content-Type: application/json" -d '{"messages":[{"role":"user","text":"привет"}]}'
echo "=== ГОТОВО: регистрация по email развёрнута ==="
