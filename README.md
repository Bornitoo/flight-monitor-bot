# Flight Monitor Bot / Бот мониторинга рейса

Telegram-бот для отслеживания статуса рейса в реальном времени.
Использует FlightRadar24 API и OpenSky Network.

A Telegram bot for real-time flight status monitoring.
Uses FlightRadar24 API and OpenSky Network.

---

## Возможности / Features

- Уведомление о вылете (с фактическим временем) / Departure alert (with actual time)
- Уведомление о задержке и её изменениях / Delay alert and delay updates
- Уведомление о посадке / Landing alert
- Отслеживание высоты и скорости в воздухе через OpenSky / Altitude & speed tracking via OpenSky
- Автовосстановление после ошибок API / Auto-recovery after API errors

---

## Примеры алертов / Example alerts

**Рейс по расписанию / Scheduled:**
```
🕐 PC320 (Istanbul → Kutaisi)
Статус: Scheduled
По расписанию: 10:30 (UTC+3) → 11:45 (UTC+4)
```

**Задержка / Delay:**
```
⏱ PC320 задержан на 35 мин
По расписанию: 10:30 → Новое время вылета: 11:05 (Istanbul, UTC+3)
```

**Вылетел / Departed:**
```
✈️ PC320 вылетел!
Вылет в 10:42 (Istanbul, UTC+3)
Ожидаемое прибытие в Кутаиси: 11:55 (UTC+4)
🛰 Высота: 10200 м, скорость: 820 км/ч
```

**Приземлился / Landed:**
```
🟢 PC320 приземлился в Кутаиси!
Посадка в 11:58 (Кутаиси, UTC+4)
```

---

## Установка / Installation

### 1. Клонировать репозиторий / Clone the repository

```bash
git clone https://github.com/Bornitoo/flight-monitor-bot.git
cd flight-monitor-bot
```

### 2. Создать .env из шаблона / Create .env from template

```bash
cp .env.example .env
nano .env
```

Заполните переменные / Fill in the variables:

| Переменная | Описание | Пример |
|---|---|---|
| `BOT_TOKEN` | Токен Telegram-бота (от @BotFather) | `1234567890:ABC...` |
| `CHAT_ID` | ID чата или пользователя | `123456789` |
| `FLIGHT_NUMBER` | Номер рейса | `PC320` |
| `DEST_IATA` | IATA-код аэропорта назначения | `KUT` |
| `ICAO24` | ICAO24 hex-код воздушного судна | `4bc8cd` |
| `STATE_FILE` | Путь к файлу состояния | `/tmp/flight_state.txt` |
| `ERROR_FILE` | Путь к файлу ошибок | `/tmp/flight_error.txt` |

### 3. Выдать права на запуск / Make executable

```bash
chmod +x monitor_flight.sh
```

### 4. Запустить вручную для проверки / Run manually to test

```bash
./monitor_flight.sh
```

### 5. Добавить в cron для автоматического мониторинга / Add to cron for automatic monitoring

```bash
crontab -e
```

Добавить строку (проверка каждые 2 минуты) / Add line (check every 2 minutes):

```
*/2 * * * * /path/to/flight-monitor-bot/monitor_flight.sh >> /tmp/flight_monitor.log 2>&1
```

---

## Зависимости / Dependencies

- `bash` >= 4.0
- `curl`
- `python3` >= 3.6
- Telegram Bot Token (получить у [@BotFather](https://t.me/BotFather))

---

## Источники данных / Data sources

- **FlightRadar24 API** — статус рейса, расписание, задержки
- **OpenSky Network** — данные о высоте и скорости в реальном времени (когда самолёт в воздухе)

---

## Лицензия / License

MIT
