#!/bin/bash
# Патч: добавляет эндпоинт /transcribe (распознавание речи через Yandex SpeechKit)
# к уже развёрнутому API Nova Dictate. Секреты НЕ нужны — YANDEX_API_KEY/FOLDER
# уже заданы в systemd (novaapi.service). ВАЖНО: у сервис-аккаунта, которому
# принадлежит ключ, должна быть роль ai.speechkit-stt.user (см. инструкцию).
# Запуск в консоли Timeweb:
#   wget -qO /tmp/stt.sh https://raw.githubusercontent.com/garnovdy-netizen/nova-dictate-dist/main/deploy_stt.sh && bash /tmp/stt.sh
set -e

cat > /opt/novaapi/main.py <<'PY'
import os
import httpx
from fastapi import FastAPI, HTTPException, Request
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
    if not req.messages:
        raise HTTPException(status_code=400, detail="Пустой запрос")
    messages = [{"role": "system", "text": CHAT_PROMPT}]
    for m in req.messages:
        role = "assistant" if m.role == "assistant" else "user"
        messages.append({"role": role, "text": m.text})
    return {"text": await ask_yandex(messages, temperature=0.6)}


# Облачное распознавание речи (для Intel/Windows — гибридный режим).
# Тело запроса — сырые аудио-байты (по умолчанию LPCM 16 кГц моно, 16-бит).
# Параметры в query: lang (ru-RU), sampleRate (16000), format (lpcm).
# Лимит короткого распознавания SpeechKit v1: ~30 сек, ≤1 МБ.
@app.post("/transcribe")
async def transcribe(request: Request):
    audio = await request.body()
    if not audio:
        raise HTTPException(status_code=400, detail="Пустое аудио")
    if len(audio) > 1_048_576:
        raise HTTPException(status_code=413, detail="Слишком длинная запись для облачного режима (макс ~30 сек)")
    if not YANDEX_API_KEY or not YANDEX_FOLDER_ID:
        raise HTTPException(status_code=500, detail="Сервер не настроен")

    qp = request.query_params
    params = {
        "folderId": YANDEX_FOLDER_ID,
        "lang": qp.get("lang", "ru-RU"),
        "format": qp.get("format", "lpcm"),
        "sampleRateHertz": qp.get("sampleRate", "16000"),
    }
    headers = {"Authorization": f"Api-Key {YANDEX_API_KEY}"}
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            r = await client.post(
                "https://stt.api.cloud.yandex.net/speech/v1/stt:recognize",
                params=params, headers=headers, content=audio)
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"SpeechKit недоступен: {e}")
    if r.status_code != 200:
        raise HTTPException(status_code=502, detail=f"SpeechKit: {r.text[:300]}")
    try:
        result = r.json().get("result", "")
    except ValueError:
        raise HTTPException(status_code=502, detail="Неожиданный ответ SpeechKit")
    return {"text": result}
PY

systemctl restart novaapi
sleep 2
echo "-- health --"; curl -sS http://127.0.0.1:8000/health; echo
echo "-- проверка, что /transcribe зарегистрирован (пустое тело → 400) --"
curl -sS -o /dev/null -w "пустое аудио → HTTP %{http_code} (ожидаем 400)\n" \
  -X POST http://127.0.0.1:8000/transcribe
echo "-- реальная проверка SpeechKit: сгенерим 1 сек тишины LPCM 16кГц и отправим --"
head -c 32000 /dev/zero > /tmp/silence.raw
curl -sS -X POST "http://127.0.0.1:8000/transcribe?lang=ru-RU&sampleRate=16000&format=lpcm" \
  --data-binary @/tmp/silence.raw -H "Content-Type: application/octet-stream" | head -c 300
echo
echo "=== ГОТОВО. Если вместо текста пришла ошибка про роль/права — значит у"
echo "    сервис-аккаунта нет роли ai.speechkit-stt.user (см. инструкцию). ==="
