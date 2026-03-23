#!/bin/bash

# Мониторинг рейса PC320 (Pegasus Airlines, Istanbul → Kutaisi)
# Фаза 1: FlightRadar24 API
# Фаза 2: OpenSky для слежения в воздухе

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

BOT_TOKEN="${BOT_TOKEN:?Укажи BOT_TOKEN в .env}"
CHAT_ID="${CHAT_ID:?Укажи CHAT_ID в .env}"
FLIGHT_NUMBER="${FLIGHT_NUMBER:-PC320}"
DEST_IATA="${DEST_IATA:-KUT}"
ICAO24="${ICAO24:-4bc8cd}"
STATE_FILE="${STATE_FILE:-/tmp/flight_state.txt}"
ERROR_FILE="${ERROR_FILE:-/tmp/flight_error.txt}"
LOG_PREFIX="[${FLIGHT_NUMBER}]"

echo "$LOG_PREFIX Запуск проверки $(date '+%Y-%m-%d %H:%M:%S')"

# Запрашиваем данные рейса через FlightRadar24
RAW=$(curl -s --max-time 20 \
  -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
  "https://api.flightradar24.com/common/v1/flight/list.json?fetchBy=flight&query=${FLIGHT_NUMBER}&limit=25&token=")

# Проверяем ответ API (пустой или ошибка curl)
if [ -z "$RAW" ]; then
    echo "$LOG_PREFIX ОШИБКА: пустой ответ от API"
    if ! grep -q "error_sent" "$ERROR_FILE" 2>/dev/null; then
        echo "error_sent" > "$ERROR_FILE"
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d "chat_id=${CHAT_ID}" \
            -d "text=⚠️ ${FLIGHT_NUMBER}: не удаётся получить данные о рейсе. Слежу дальше..." > /dev/null
        echo "$LOG_PREFIX Telegram алерт отправлен (пустой ответ)"
    else
        echo "$LOG_PREFIX Флаг ошибки уже установлен, молчим"
    fi
    exit 1
fi

# Python3 для парсинга и логики
python3 - "$RAW" "$BOT_TOKEN" "$CHAT_ID" "$STATE_FILE" "$ERROR_FILE" "$FLIGHT_NUMBER" "$DEST_IATA" "$ICAO24" <<'PYEOF'
import sys
import json
import urllib.request
import urllib.parse
import os
from datetime import datetime, timezone, timedelta

raw_json = sys.argv[1]
bot_token = sys.argv[2]
chat_id = sys.argv[3]
state_file = sys.argv[4]
error_file = sys.argv[5]
flight_number = sys.argv[6] if len(sys.argv) > 6 else 'PC320'
dest_iata = sys.argv[7] if len(sys.argv) > 7 else 'KUT'
icao24 = sys.argv[8] if len(sys.argv) > 8 else '4bc8cd'

TZ_ISTANBUL = timezone(timedelta(hours=3))
TZ_KUTAISI  = timezone(timedelta(hours=4))

def fmt_time(ts, tz):
    if ts and ts != 0:
        try:
            return datetime.fromtimestamp(int(ts), tz=tz).strftime('%H:%M')
        except:
            return '?'
    return '-'

def send_telegram(token, chat_id, text):
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    data = urllib.parse.urlencode({
        'chat_id': chat_id,
        'text': text,
        'parse_mode': 'HTML'
    }).encode('utf-8')
    try:
        req = urllib.request.Request(url, data=data, method='POST')
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read())
            return result.get('ok', False)
    except Exception as e:
        print(f"[{flight_number}] ОШИБКА Telegram: {e}", file=sys.stderr)
        return False

def error_flag_set():
    try:
        with open(error_file, 'r') as f:
            return 'error_sent' in f.read()
    except:
        return False

def clear_error_flag():
    try:
        os.remove(error_file)
    except:
        pass

# Проверяем JSON-ответ
try:
    data = json.loads(raw_json)
except Exception as e:
    print(f"[{flight_number}] ОШИБКА парсинга JSON: {e}", file=sys.stderr)
    if not error_flag_set():
        with open(error_file, 'w') as f:
            f.write('error_sent')
        send_telegram(bot_token, chat_id, f"⚠️ {flight_number}: не удаётся получить данные о рейсе. Слежу дальше...")
        print(f"[{flight_number}] Telegram алерт отправлен (ошибка JSON)")
    else:
        print(f"[{flight_number}] Флаг ошибки уже установлен, молчим")
    sys.exit(1)

flights = []
try:
    flights = data['result']['response']['data']
    if not isinstance(flights, list):
        flights = []
except:
    flights = []

print(f"[{flight_number}] Найдено рейсов в ответе: {len(flights)}")

if not flights:
    print(f"[{flight_number}] ОШИБКА: рейсы не найдены в ответе API")
    if not error_flag_set():
        with open(error_file, 'w') as f:
            f.write('error_sent')
        send_telegram(bot_token, chat_id, f"⚠️ {flight_number}: не удаётся получить данные о рейсе. Слежу дальше...")
        print(f"[{flight_number}] Telegram алерт отправлен (рейсы не найдены)")
    else:
        print(f"[{flight_number}] Флаг ошибки уже установлен, молчим")
    sys.exit(1)

now_utc   = datetime.now(timezone.utc)
today_utc = now_utc.strftime('%Y-%m-%d')
today_ist = datetime.now(TZ_ISTANBUL).strftime('%Y-%m-%d')
print(f"[{flight_number}] Сегодня UTC={today_utc}, Istanbul={today_ist}")

candidates = []
for f in flights:
    try:
        dest = f.get('airport', {}).get('destination', {}).get('code', {}).get('iata', '')
        if dest != dest_iata:
            continue
        sched_dep = f.get('time', {}).get('scheduled', {}).get('departure', 0) or 0
        if sched_dep == 0:
            continue
        dep_date_utc = datetime.fromtimestamp(int(sched_dep), tz=timezone.utc).strftime('%Y-%m-%d')
        dep_date_ist = datetime.fromtimestamp(int(sched_dep), tz=TZ_ISTANBUL).strftime('%Y-%m-%d')
        if dep_date_utc == today_utc or dep_date_ist == today_ist:
            candidates.append(f)
    except:
        continue

if not candidates:
    print(f"[{flight_number}] Сегодняшних рейсов {dest_iata} не найдено, берём самый свежий...")
    kut_flights = [f for f in flights
                   if f.get('airport', {}).get('destination', {}).get('code', {}).get('iata', '') == dest_iata]
    if kut_flights:
        candidates = sorted(kut_flights,
                            key=lambda f: f.get('time', {}).get('scheduled', {}).get('departure', 0) or 0,
                            reverse=True)

if not candidates:
    print(f"[{flight_number}] ОШИБКА: рейс {flight_number} -> {dest_iata} не найден")
    print(f"[{flight_number}] Доступные направления:")
    for f in flights:
        ident = f.get('identification', {}).get('number', {}).get('default', '?')
        dest  = f.get('airport', {}).get('destination', {}).get('code', {}).get('iata', '?')
        print(f"  {ident} -> {dest}")
    if not error_flag_set():
        with open(error_file, 'w') as f:
            f.write('error_sent')
        send_telegram(bot_token, chat_id, f"⚠️ {flight_number}: не удаётся получить данные о рейсе. Слежу дальше...")
        print(f"[{flight_number}] Telegram алерт отправлен ({dest_iata} не найден)")
    else:
        print(f"[{flight_number}] Флаг ошибки уже установлен, молчим")
    sys.exit(1)

# Данные успешно получены — проверяем, был ли флаг ошибки
flight = max(candidates, key=lambda f: f.get('time', {}).get('scheduled', {}).get('departure', 0) or 0)

status_text    = flight.get('status', {}).get('text') or 'unknown'
generic_status = (flight.get('status', {}).get('generic', {}) or {}).get('status', {}).get('text') or 'unknown'

if error_flag_set():
    print(f"[{flight_number}] Данные восстановлены после ошибки! Отправляем алерт...")
    send_telegram(bot_token, chat_id, f"✅ {flight_number}: данные восстановлены. Статус: {status_text}")
    clear_error_flag()
    print(f"[{flight_number}] Флаг ошибки удалён")

sched_dep = flight.get('time', {}).get('scheduled', {}).get('departure') or 0
sched_arr = flight.get('time', {}).get('scheduled', {}).get('arrival') or 0
est_dep   = flight.get('time', {}).get('estimated', {}).get('departure') or 0
real_dep  = flight.get('time', {}).get('real', {}).get('departure') or 0
real_arr  = flight.get('time', {}).get('real', {}).get('arrival') or 0

delay_min = 0
if est_dep and est_dep != 0 and sched_dep and sched_dep != 0:
    delay_min = int((int(est_dep) - int(sched_dep)) / 60)

print(f"[{flight_number}] Рейс найден: dest={dest_iata} status='{status_text}' generic='{generic_status}'")
print(f"[{flight_number}] sched_dep={sched_dep} est_dep={est_dep} real_dep={real_dep} real_arr={real_arr}")
print(f"[{flight_number}] Задержка: {delay_min} мин")

# Фаза 2: OpenSky (если в воздухе)
opensky_info = ''
if real_dep and real_dep != 0 and (not real_arr or real_arr == 0):
    try:
        req2 = urllib.request.Request(
            f'https://opensky-network.org/api/states/all?icao24={icao24}',
            headers={'User-Agent': 'Mozilla/5.0'}
        )
        with urllib.request.urlopen(req2, timeout=10) as resp2:
            sky_data = json.loads(resp2.read())
        states = sky_data.get('states', [])
        if states:
            state = states[0]
            altitude = state[7] if len(state) > 7 and state[7] else None
            velocity = state[9] if len(state) > 9 and state[9] else None
            if altitude:
                opensky_info = f"\n🛰 Высота: {int(altitude)} м"
            if velocity:
                opensky_info += f", скорость: {int(velocity)} км/ч"
            print(f"[{flight_number}] OpenSky: altitude={altitude}, velocity={velocity}")
        else:
            print(f"[{flight_number}] OpenSky: самолёт не найден в воздухе")
    except Exception as e:
        print(f"[{flight_number}] OpenSky ошибка: {e}")

new_state = f"{generic_status}|{status_text}|{sched_dep}|{est_dep}|{real_dep}|{real_arr}"
print(f"[{flight_number}] Текущее состояние: {new_state}")

old_state = ''
try:
    with open(state_file, 'r') as f:
        old_state = f.read().strip()
except:
    pass

print(f"[{flight_number}] Предыдущее состояние: {old_state}")

if new_state == old_state:
    print(f"[{flight_number}] Изменений нет, уведомление не отправляется")
    sys.exit(0)

print(f"[{flight_number}] Состояние изменилось! Формируем уведомление...")

old_parts = old_state.split('|') if old_state else []
old_generic  = old_parts[0] if len(old_parts) > 0 else ''
old_est_dep  = int(old_parts[3]) if len(old_parts) > 3 and old_parts[3].lstrip('-').isdigit() else 0
old_real_dep = int(old_parts[4]) if len(old_parts) > 4 and old_parts[4].lstrip('-').isdigit() else 0
old_real_arr = int(old_parts[5]) if len(old_parts) > 5 and old_parts[5].lstrip('-').isdigit() else 0

sched_dep_fmt = fmt_time(sched_dep, TZ_ISTANBUL)
est_dep_fmt   = fmt_time(est_dep,   TZ_ISTANBUL)
real_dep_fmt  = fmt_time(real_dep,  TZ_ISTANBUL)
sched_arr_fmt = fmt_time(sched_arr, TZ_KUTAISI)
real_arr_fmt  = fmt_time(real_arr,  TZ_KUTAISI)

messages = []

# 1. Приземлился
if real_arr and real_arr != 0 and old_real_arr == 0:
    messages.append(
        f"🟢 <b>{flight_number} приземлился в Кутаиси!</b>\n"
        f"Посадка в <b>{real_arr_fmt}</b> (Кутаиси, UTC+4)"
    )

# 2. Вылетел
if real_dep and real_dep != 0 and old_real_dep == 0:
    arrival_str = ''
    if sched_arr and sched_arr != 0:
        arrival_str = f"\nОжидаемое прибытие в Кутаиси: <b>{sched_arr_fmt}</b> (UTC+4)"
    messages.append(
        f"✈️ <b>{flight_number} вылетел!</b>\n"
        f"Вылет в <b>{real_dep_fmt}</b> (Istanbul, UTC+3)"
        f"{arrival_str}"
        f"{opensky_info}"
    )

# 3. Задержка
if not any('вылетел' in m or 'приземлился' in m for m in messages):
    old_delay = 0
    if old_est_dep and old_est_dep != 0 and sched_dep and sched_dep != 0:
        old_delay = int((old_est_dep - int(sched_dep)) / 60)

    if delay_min > 0 and old_delay == 0:
        messages.append(
            f"⏱ <b>{flight_number} задержан на {delay_min} мин</b>\n"
            f"По расписанию: {sched_dep_fmt} → Новое время вылета: <b>{est_dep_fmt}</b> (Istanbul, UTC+3)"
        )
    elif delay_min > 0 and old_delay > 0 and abs(delay_min - old_delay) >= 5:
        diff = delay_min - old_delay
        sign = '+' if diff > 0 else ''
        messages.append(
            f"⏱ <b>{flight_number}: задержка изменилась ({sign}{diff} мин)</b>\n"
            f"Итого задержка: {delay_min} мин. Вылет в <b>{est_dep_fmt}</b> (Istanbul, UTC+3)"
        )
    elif delay_min == 0 and old_delay > 0:
        messages.append(
            f"✅ <b>{flight_number}: задержка снята</b>\n"
            f"Вылет по расписанию: <b>{sched_dep_fmt}</b> (Istanbul, UTC+3)"
        )

# 4. Изменился generic-статус
if generic_status != old_generic and generic_status not in ('unknown', ''):
    status_map = {
        'scheduled': '🕐 По расписанию',
        'estimated':  '⏳ Ожидается (уточнено время)',
        'departed':   '✈️ Вылетел',
        'en-route':   '✈️ В пути',
        'landed':     '🛬 Приземлился',
        'cancelled':  '❌ Отменён',
        'delayed':    '⏱ Задержан',
    }
    readable = status_map.get(generic_status, generic_status)
    already_covered = any(
        'вылетел' in m or 'приземлился' in m or 'задержан' in m.lower() or 'задержка' in m.lower()
        for m in messages
    )
    if not already_covered:
        messages.append(
            f"📋 <b>{flight_number}: статус изменился</b>\n"
            f"Новый статус: <b>{readable}</b>\n"
            f"({status_text})"
        )

# 5. Первый запуск
if not old_state and not messages:
    delay_str = ''
    if delay_min > 0:
        delay_str = f"\n⏱ Задержка: <b>{delay_min} мин</b>. Вылет в <b>{est_dep_fmt}</b>"
    elif delay_min < 0:
        delay_str = f"\n⏩ Вылет раньше на {abs(delay_min)} мин"
    status_map = {
        'scheduled': '🕐', 'estimated': '⏳',
        'departed': '✈️', 'en-route': '✈️',
        'landed': '🛬', 'cancelled': '❌', 'delayed': '⏱',
    }
    emoji = status_map.get(generic_status, 'ℹ️')
    messages.append(
        f"{emoji} <b>{flight_number} (Istanbul → Kutaisi)</b>\n"
        f"Статус: <b>{status_text}</b>\n"
        f"По расписанию: {sched_dep_fmt} (UTC+3) → {sched_arr_fmt} (UTC+4)"
        f"{delay_str}"
        f"{opensky_info}"
    )

timestamp = datetime.now(TZ_ISTANBUL).strftime('%H:%M %d.%m.%Y')
for msg in messages:
    full_msg = msg + f"\n\n<i>{timestamp}</i>"
    ok = send_telegram(bot_token, chat_id, full_msg)
    if ok:
        print(f"[{flight_number}] Telegram отправлен: {msg[:80].strip()}")
    else:
        print(f"[{flight_number}] ОШИБКА отправки Telegram")

try:
    with open(state_file, 'w') as f:
        f.write(new_state)
    print(f"[{flight_number}] Состояние сохранено: {new_state}")
except Exception as e:
    print(f"[{flight_number}] ОШИБКА сохранения состояния: {e}")

PYEOF
