# Спецификация: реформат логов SOCKS-реле + логирование DNS-решений

**Дата:** 2026-07-23
**Статус:** спецификация (до реализации)
**Файлы:** `../socks/socks-relay.py`, `../socks/dns_split.py`, `../socks/test_socks_relay.py`
**Связано с:** [DNS-split spec](./2026-07-22-socks-relay-dns-split.md) (эта спека — отдельный документ, чтобы не засорять чистую логику DNS).

---

## 1. Проблема

Логи реле сейчас зашумлены техническим мусором, а самого важного при DNS-split —
**решения по DNS** — в них нет вообще.

Пример текущего лога (реальный):
```
... INFO client ('127.0.0.1', 51038): Accepting connection: <socket.socket fd=19, family=2, type=1, proto=0, laddr=('127.0.0.1', 10808), raddr=('127.0.0.1', 51038)>
... INFO client ('127.0.0.1', 51038): Received command 1 for cdn.openai.com:443
... INFO client ('127.0.0.1', 51038): Connected to cdn.openai.com:443: <socks.socksocket fd=20, family=2, type=1, proto=0, laddr=(...), raddr=('cdn.openai.com', 443)>
... INFO client ('127.0.0.1', 50943): Closed connection
```

Проблемы:
1. **Технический мусор** `<socket.socket fd=... family=2 type=1 proto=0 laddr=... raddr=...>` — бесполезен человеку.
2. **3-4 строки на один коннект** (accept / received / connected / closed) — при
   реальной нагрузке половина лога это «Accepting connection».
3. **Нет DNS-решения.** При `--dns-split` реле выбирает internal/external по маске,
   но в логе видно только `Received command 1 for 8.8.8.8:53` и `Closed connection`
   — какое имя резолвили, каким путём, что выбрали и почему — НЕ видно. Пример из
   практики: пользователь увидел в резолве адрес `203.0.113.6` и заподозрил honeypot,
   хотя это был штатный внешний резолв `ws.chatgpt.com` — правильный лог сразу снял
   бы вопрос.

---

## 2. Что НЕ меняется

**Структура строки лога остаётся прежней:**
`%(asctime)s %(name)s %(levelname)s %(message)s` — таймштамп, имя логгера, уровень,
сообщение. Таймштамп, уровни — устраивают. **Меняется только `%(message)s`
(payload)** + добавляется управление уровнем логирования (INFO/DEBUG).

---

## 3. Уровни логирования

- **INFO — по умолчанию.** Одна содержательная строка на событие (коннект, DNS-
  решение), без технического мусора.
- **DEBUG — по флагу/env.** Дополнительно: сырые сокет-детали, тайминги путей, что
  вернул каждый DNS-путь, байты/длительность соединения.

**Как включить DEBUG:**
| Способ | Значение |
|---|---|
| env `LOG_LEVEL` | `debug`/`info` (регистронезависимо); дефолт `info` |
| CLI `--debug` (или `-v`) | включает DEBUG; **перекрывает** env (CLI главнее, как везде в реле) |

По умолчанию (ничего не задано) — INFO. Дебаг-логи по умолчанию НЕ включены.

---

## 4. Формат payload

### 4.1. Идентификатор клиента

Вместо `client ('127.0.0.1', 51038):` — компактный `[51038]` (порт клиента как
короткий id соединения). Порт уникален на время жизни соединения и его достаточно,
чтобы связать строки одного клиента.

### 4.2. Ключевое слово события — КАПСОМ

Первое слово payload — тип события капсом, для читаемости и грепа:
`CONNECT` / `DNS` / (служебные — `LISTEN`, `WARN` и т.п. на своих уровнях).

### 4.3. Коннект — ОДНА строка на INFO (итог с исходом)

Вместо 3-4 строк (accept/received/connected/closed) — **одна итоговая строка** на
INFO, показывающая цель, путь и **исход (всегда)**:

```
[51038] CONNECT ai.example.net:443 path=upstream → ok
[50826] CONNECT 10.42.73.107:443 path=direct → ok
[50830] CONNECT 10.0.0.44:80 path=direct → refused (errno 61)
[50840] CONNECT vi.airline.ru:443 path=upstream → reset by peer
```

- `path=` — маршрут: `upstream` (через вышестоящий SOCKS), `direct` (direct-net, по
  таблице хоста), `direct-if` (прямой без upstream когда upstream не задан).
- `→ <исход>` — **исход виден ВСЕГДА**: `ok` при успехе; при ошибке — человеческая
  причина + errno/деталь: `refused (errno 61)`, `reset by peer`, `timeout`,
  `unreachable (errno 51)`, `refused by upstream`. Ошибки — на уровне ERROR (как
  сейчас), успех — INFO.
- `accept` (приём соединения) — уходит на **DEBUG**, не отдельной INFO-строкой.

### 4.4. DNS-решение — новая строка (только при `--dns-split`)

Сейчас DNS-решения нет в логе вовсе. Добавить строку **на INFO** для каждого
резолва (пишется из `dns_split` — детали сигнатур и ВСЕ ветки причин в §5.3):

```
[50804] DNS acmefriend.acmebank.ru/A → internal 10.0.0.44 (default in 10.0.0.0/8)
[50807] DNS www.youtube.com/A → external 142.250.1.14 (default not in mask)
[50813] DNS api.corp.local/A → external (default timeout; external answered)
[50816] DNS metrics.corp/A → SERVFAIL (both paths silent)
[50820] DNS x.corp/A → external (name not in allowlist; corp DNS not queried)
```

Формат: `DNS <имя>/<тип> → <вердикт> [<ip>] (<краткая причина>)`.
- **вердикт:** `internal` / `external` / `SERVFAIL`. Формальное определение —
  §5.3 (internal = выбран default-ответ с адресом ∈ маска; external = внешний
  ответ ИЛИ default-без-адреса-в-маске; SERVFAIL = синтезированный).
- **ip:** первый A/AAAA из выбранного ответа; отсутствует для SERVFAIL и ответов
  без адреса (NXDOMAIN) — тогда причина поясняет.
- **причина (кратко):** полный перечень для КАЖДОЙ ветки алгоритма — таблица в §5.3
  (включая `only default answered (not in mask)`, `resolve slot timeout`,
  `resolve error`, `server returned SERVFAIL` — все исходы покрыты причиной).
- Кэш-хит по умолчанию **НЕ** логируется на INFO (иначе шум от повторов); на DEBUG —
  `DNS <имя>/<тип> → <вердикт> (cache hit)`. Ждущий поток (дедуп) — DEBUG
  `(dedup wait)`; INFO-строку пишет владелец резолва (§5.3).

> Полные оба ответа (что вернул external И default, с таймингами) — на DEBUG, не
> INFO. INFO несёт только итог: имя, вердикт, выбранный IP, краткую причину.

### 4.5. Стартовые строки (INFO) — почистить

Оставить содержательные, без мусора. Пример при старте:
```
LISTEN localhost:10808 | iface=en0 upstream=UPSTREAM direct-net=10.0.0.0/8 dns-split=on(/etc/resolv.conf) allowlist=1
```
(одна строка с итоговой конфигурацией вместо нескольких; конкретные значения —
из фактического конфига).

### 4.6. Что уходит на DEBUG

```
[51038] accept fd=6 laddr=127.0.0.1:10808 raddr=127.0.0.1:51038
[51038] upstream bound laddr=192.168.0.2:50790
[50804] DNS query paths: external→8.8.8.8:53 default→10.50.50.50:53
[50804] DNS external answered 142.x in 34ms; default answered 10.0.0.44 in 51ms
[51038] closed (up 0.9s, ↑12KB ↓340KB)
```
— всё сырое (`<socket.socket ...>`, laddr/raddr, тайминги путей, байты, cache-hit) —
только на DEBUG.

---

## 5. Реализация

### 5.1. Уровень логирования

- В `main()`/`resolve_config`: определить уровень из `--debug`/`-v` (CLI) и
  `LOG_LEVEL` env (CLI главнее); `logger.setLevel(logging.DEBUG if debug else INFO)`.
- Формат-строку логгера (`%(asctime)s %(name)s %(levelname)s %(message)s`) НЕ менять.

### 5.2. Полная карта существующих лог-точек → назначение

**Каждая** точка логирования должна получить явное назначение (иначе лог станет
разноформатным). Таблица (строки — на момент написания, свериться при реализации):

| Точка (файл:строка) | Сейчас | Куда идёт | Формат |
|---|---|---|---|
| accept `Accepting connection` (~397, INFO) | INFO + `<socket ...>` | **DEBUG**, компактно (`[port] accept ...`) | без repr |
| `Received command` (~455, INFO) | INFO | **свернуть** в итоговую CONNECT-строку | — |
| `Connected to` (~528, INFO) | INFO + repr | → CONNECT-строка `→ ok` | без repr |
| `Closed connection` (~479, INFO) | INFO | **DEBUG** (`[port] closed ...`) | — |
| `could not connect` upstream (~515, ERROR) | ERROR | → CONNECT-строка `→ <ошибка>` (ERROR) | errno→текст |
| `direct-net connect failed` (~583, ERROR) | ERROR | → CONNECT-строка `path=direct → <ошибка>` | errno→текст |
| `direct-net connect` ok (~597, INFO) | INFO + repr | → CONNECT-строка `path=direct → ok` | без repr |
| `Connection interrupted` (~476, INFO) | INFO + `client (..):` | **INFO**, новый префикс `[port] CONNECT ... → interrupted (<деталь>)` | см. чистка repr ниже |
| `Address Type not supported` (~443, ERROR) | ERROR | **ERROR**, `[port] CONNECT <atyp> → unsupported address type` | новый префикс |
| `Command not supported` (~471, ERROR) | ERROR | **ERROR**, `[port] <cmd> → unsupported command` (сохранить cmd/адрес) | новый префикс |
| `DNS connection idle closing` (~629, INFO) | INFO | **DEBUG** (штатное закрытие keep-alive) | `[port]` |
| `unparseable DNS query` (~654, INFO) | INFO | **INFO** сохранить (признак атаки/бага) | `[port] DNS unparseable, closing` |
| `cannot bind UDP relay socket` (~693, ERROR) | ERROR | **ERROR** сохранить | `[port] UDP bind failed: <err>` |
| `upstream UDP associate failed` (~712, ERROR) | ERROR | **ERROR** сохранить | `[port] UDP upstream associate failed: <err>` |
| `UDP ASSOCIATE advertising` (~722, INFO) | INFO + reply-bytes | **INFO** сохранить, включая `reply-bytes` (осознанный диагностический инструмент — НЕ прятать) | `[port] UDP ASSOCIATE → <ep> (reply-bytes=..)` |
| `UDP association closed` (~736, INFO) | INFO | **DEBUG** | `[port] UDP closed` |
| стартовые `Pinning`/`Direct-net`/`DNS-split enabled`/`allowlist` (~1432-1461, INFO) | INFO, неск. строк | **свернуть** в одну `LISTEN ... | iface=.. upstream=.. ...` (§4.5); allowlist — показать паттерны, не `=1` | — |
| стартовые warnings: dns-split-без-`-I` (~1440), allowlist-без-dns-split (~1445), source unusable (~1467) | WARNING | **WARNING, ОТДЕЛЬНЫМИ строками сохранить** (особенно «dns-split без -I = no-op» — терять НЕЛЬЗЯ) | как есть, чистые |
| `dnspython required` (~1453), `cannot bind` listen (~1476) | ERROR | **ERROR** сохранить | — |
| `Socks relay listening` (~1471, INFO) | INFO | часть свёрнутой `LISTEN`-строки | — |
| `Shutting down` (~1486, INFO) | INFO | **INFO** сохранить | — |
| iface IPv4 lookup (~220, DEBUG) | DEBUG | DEBUG, без изменений | — |

### 5.2a. Чистка socket-repr из текстов исключений (обязательно)

`ConnectionInterrupted` собирается в `recv/recvall/sendall` (строки ~362/371/376/383,
и ~623) с текстом `... %s % sock`, вшивающим `<socket.socket fd=.. family=..>` в
сообщение. Оно печатается на INFO (`Connection interrupted`). **Эти тексты обязаны
не содержать socket-repr** (иначе мусор утечёт в INFO и тест §6.7 провалится).
Заменить `%s % sock` на осмысленную краткость (например направление recv/send без
repr сокета) в этих методах.

### 5.2b. errno → текст + фолбэк

Рядом с существующим маппингом errno→SOCKS-reply (строки ~508-513/575-580) завести
errno→текст:
`ECONNREFUSED`→`refused`, `ECONNRESET`→`reset by peer`, `ETIMEDOUT`→`timeout`,
`EHOSTUNREACH`→`unreachable`, `ENETUNREACH`→`network unreachable`.
**Фолбэк (обязателен):** если у ошибки нет `errno` (`socks.ProxyError` от PySocks,
`ConnectionInterrupted` от bind-к-интерфейсу) — печатать **полный `str(err)`**
(как сейчас делает L515), чтобы не потерять информацию против текущего поведения.

### 5.3. DNS-решение (dns_split.py) — сигнатуры и ВСЕ ветки

**Смена сигнатур (честно — это не только текст):**
- `_do_resolve` возвращает не только `chosen_msg`, а `(chosen_msg, verdict, reason)`,
  где `verdict ∈ {internal, external, servfail}`, `reason` — строка причины.
  Определение вердикта: `internal` = выбран ответ дефолтного пути и в нём есть адрес
  ∈ маска; `external` = выбран внешний ответ (или дефолтный-без-адреса-в-маске);
  `servfail` = синтезированный SERVFAIL.
- `resolve_split` получает **`client_id`** (порт клиента для `[port]`), передаётся из
  `handle_dns_split`. Дефолт (`client_id=None`) — чтобы ~10 прямых вызовов
  `resolve_split` в тестах не сломались; при `None` префикс `[?]` или без него.
- `has_addr_in` — для причины `default in <cidr>` нужно знать, КАКАЯ сеть совпала:
  вернуть совпавшую сеть (или None), а не bool. Правка сигнатуры.

**Причина для КАЖДОЙ ветки `_do_resolve` (§5.2 DNS-split spec) — покрыть все:**
| Ветка | verdict | reason |
|---|---|---|
| default-ответ ∈ маска (ранний или финал) | internal | `default in <совпавший cidr>` |
| external выбран, default ответил вне маски | external | `default not in mask` |
| external выбран, default молчал (timeout) | external | `default timeout; external answered` |
| external выбран, default не запрашивался (allowlist) | external | `name not in allowlist; corp DNS not queried` |
| external выбран, default source unusable (loopback/пусто) | external | `default source unusable` |
| **только default ответил, адрес НЕ в маске** (ветка L413) | external | `only default answered (not in mask)` |
| синтезированный SERVFAIL (оба молчат) | servfail | `both paths silent` |
| SERVFAIL при исчерпании семафора | servfail | `resolve slot timeout` |
| SERVFAIL из except (исключение владельца) | servfail | `resolve error` |
| SERVFAIL, присланный сервером | external | `server returned SERVFAIL` (вердикт external — ответ пришёл извне) |

> Чтобы различить причины «default не стартовал» (unusable vs not-in-allowlist),
> завести флаг при установке `default_done` — какая из трёх причин (спека §5.2
> DNS-split слила их в одну ветку; для лога нужно сохранить различие).

**waiter-путь:** ждущий поток отдаёт клиенту ответ (или SERVFAIL) — он ТОЖЕ логирует
DNS-строку (с пометкой `(via inflight)` на DEBUG), чтобы «строка на каждый резолв»
из §4.4 не терялась для ждущих. Либо: логировать только у владельца, а для ждущих —
DEBUG `(dedup)`. Выбрано: владелец логирует INFO; ждущий — DEBUG `(dedup wait)`.

**cache-hit:** INFO не логировать; DEBUG — `[port] DNS <имя>/<тип> → <verdict> (cache hit)`.

**Логгер:** `logging.getLogger("socks-relay")` (тот же именованный логгер реле;
lazy — после настройки в socks-relay.py). В standalone-тестах уйдёт в lastResort,
безвредно; caplog совместим.

### 5.4. Объём и регрессии (честно)

**Не только тексты.** Реформат INFO-строк CONNECT/DNS — да, тексты (свёртка в 4
существующих точках, без буферизации, без смены потока управления). НО часть
DEBUG-строк §4.6 требует **новых вычислений**:
- байты/длительность соединения (`↑12KB ↓340KB`, `up 0.9s`) — счётчики + таймер в
  `exchange_loop`;
- тайминги путей DNS (`in 34ms`) — засечка времени в worker'ах;
- `has_addr_in` → совпавшая сеть (см. §5.3).

**Решение по объёму:** DEBUG-строки с новыми вычислениями (байты/тайминги) —
**вторая очередь** (реализовать после INFO-реформата, отдельно), чтобы не тащить
счётчики в горячий цикл в рамках «реформата логов». Обязательная первая очередь:
INFO CONNECT/DNS-строки, чистка repr, уровень INFO/DEBUG, сохранение всех
существующих точек по §5.2. `has_addr_in`→сеть — нужна для INFO-причины
`default in <cidr>`, поэтому в первой очереди.

**Функциональная логика** (маршрутизация, выбор DNS, кэш, соединения) — не трогать.
Прежние функциональные тесты целы.

---

## 6. Тесты

Логи — побочный эффект, но ключевые строки стоит закрепить (через `caplog` или
перехват logger'а):
1. **CONNECT-исход в логе:** успешный коннект → INFO со `path=... → ok`; отказ →
   ERROR со `→ refused (errno ...)`.
2. **DNS-решение internal:** ответ ∈ маска → INFO `DNS name/A → internal <ip> (default in ...)`.
3. **DNS-решение external:** ответ ∉ маска → INFO `... → external <ip> (default not in mask)`.
4. **DNS SERVFAIL:** оба молчат → INFO `... → SERVFAIL (both paths silent)`.
5. **DNS allowlist:** имя не в allowlist → INFO `... → external (name not in allowlist...)`.
6. **Уровень:** по умолчанию INFO (нет accept-строк/сырых сокетов в выводе); с
   `--debug`/`LOG_LEVEL=debug` — DEBUG-строки появляются.
7. **Нет технического мусора:** в INFO-выводе нет `<socket.socket ...>` / `fd=` /
   `family=` — в т.ч. из текстов `ConnectionInterrupted` (§5.2a).
8. **Регрессия:** прежние функциональные тесты (маршрутизация/DNS/кэш) целы.
9. **DNS-причина для непокрытых веток:** «только default ответил, не в маске» →
   `external (only default answered...)`; semaphore-timeout SERVFAIL →
   `SERVFAIL (resolve slot timeout)`; server-SERVFAIL → `external (server returned SERVFAIL)`.
10. **Сохранённые точки:** тест, что стартовый warning «dns-split без -I = no-op»
    (§5.2) присутствует; что `unparseable DNS` остаётся INFO; что UDP-ошибки
    (bind/associate) остаются ERROR.
11. **Фолбэк ошибки без errno:** ошибка от upstream без `errno` (ProxyError) →
    в CONNECT-строке полный `str(err)`, не пусто (§5.2b).
12. **`direct-if` путь:** прямой connect когда upstream не задан → `path=direct-if`.

---

## 7. Открытые вопросы / решения по умолчанию

Приняты дефолты (поправить на ревью, если не так):
1. **Одна строка на коннект** (accept→DEBUG). Выбрано ради чистоты.
2. **Причина DNS в INFO — краткая** (вердикт + IP + одна причина). Полные оба пути
   → DEBUG.
3. **DEBUG включается** env `LOG_LEVEL=debug` И флагом `--debug`/`-v` (оба; CLI
   главнее). Дефолт INFO.
4. **ip в DNS-строке** — первый A/AAAA из выбранного ответа; полный список — DEBUG.
5. **Кэш-хит** на INFO не логируется (шум); на DEBUG — да.
6. **UDP ASSOCIATE — исключение из «одна строка».** UDP-сессия многошаговая
   (associate → relay → close); для неё остаётся advertising-строка (INFO, с
   `reply-bytes` — осознанный диагностический инструмент, НЕ прятать) + closed
   (DEBUG). «Одна строка на коннект» — про TCP CONNECT, не про UDP.
7. **Две очереди реализации (§5.4):** первая — INFO CONNECT/DNS + чистка repr +
   уровень + сохранение всех точек + `has_addr_in`→сеть. Вторая (отдельно, после) —
   DEBUG-строки со счётчиками байт/таймингами (требуют вычислений в горячем цикле).
   Реализатор делает первую очередь; вторая — по явному запросу.
