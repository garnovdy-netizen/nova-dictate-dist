#!/bin/bash
# Патч: добавляет эндпоинт /chat (диалог с YandexGPT) в уже развёрнутый API.
# Секреты НЕ нужны — YANDEX_API_KEY/FOLDER уже заданы в systemd (novaapi.service).
# Запуск в консоли Timeweb:
#   wget -qO /tmp/uc.sh https://raw.githubusercontent.com/garnovdy-netizen/nova-dictate-dist/main/update_chat.sh && bash /tmp/uc.sh
set -e

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

systemctl restart novaapi
sleep 2
echo "-- health --"; curl -sS http://127.0.0.1:8000/health; echo
echo "-- тест /chat --"
curl -sS -X POST http://127.0.0.1:8000/chat -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","text":"Ответь одним словом: столица Франции?"}]}' | head -c 300
echo
echo "=== ГОТОВО: эндпоинт /chat добавлен ==="
