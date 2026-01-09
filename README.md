# Exdns

Exdns — учебный DNS‑сервер на Elixir с хранением зон в JSON, кэшем процессов, репликацией и HTTP API для CRUD‑управления зонами.

## Возможности

- DNS UDP сервер, обработка запросов и формирование ответов.
- Поддержка ресурсных записей: A, AAAA, NS, PTR, MX, TXT, SOA, CNAME.
- EDNS(0) и DNS Cookies (RFC 6891 / RFC 7873) в Additional.
- Хранение зон в JSON с шардированием по md5.
- Кэш процессов зон: зона загружается/запускается по требованию.
- Валидация JSON‑схемы зон и проверка всех зон при старте.
- Атомарные обновления с версионированием.
- Репликация изменений на кластер нод с quorum/ack и rollback.
- HTTP API (Plug + Bandit) для CRUD операций по зонам с токеном.
- Поддержка release и Docker‑сборки.

## Архитектура

- `Models.Dns.Zone.Storage` — хранение зон на диске (JSON, шардирование, атомарная запись).
- `Models.Dns.Zone.Cache` — кэш процессов и маршрутизация запросов к зоне.
- `Models.Dns.Zone.Server` — процесс зоны, хранит структуру зоны в памяти.
- `Models.Dns.Zone.Cluster` — репликация и RPC к другим нодам.
- `DnsHandler` — обработка DNS запросов и формирование ответов.
- `Http.Router` — HTTP API для CRUD зон.
- `NetHandler.Udp` — UDP сервер.

## Формат зон (JSON)

Пример:

```json
{
  "name": "hello.test",
  "version": 3,
  "records": [
    {"name": "hello.test", "type": "A", "ttl": 300, "data": "1.2.3.4"},
    {"name": "hello.test", "type": "AAAA", "ttl": 300, "data": "2001:db8::1"},
    {"name": "hello.test", "type": "NS", "ttl": 3600, "data": "ns1.hello.test"},
    {"name": "hello.test", "type": "MX", "ttl": 3600, "data": {"preference": 10, "exchange": "mx1.hello.test"}},
    {"name": "hello.test", "type": "TXT", "ttl": 300, "data": "hello"},
    {"name": "hello.test", "type": "CNAME", "ttl": 300, "data": "alias.hello.test"},
    {
      "name": "hello.test",
      "type": "SOA",
      "ttl": 3600,
      "data": {
        "mname": "ns1.hello.test",
        "rname": "hostmaster.hello.test",
        "serial": 2024010101,
        "refresh": 3600,
        "retry": 600,
        "expire": 1209600,
        "minimum": 300
      }
    }
  ]
}
```

Обязательные поля:
- `name` (string)
- `version` (integer)
- `records` (array)
Каждая запись: `name`, `type`, `ttl`, `data`.

## Хранилище и шардирование

Файлы зон хранятся в директории `zones_folder`.
Путь вычисляется по md5 домена:

```
zones_folder/<h0h1>/<h2h3>/<domain>.json
```

Пример:
`hello.com` -> `md5(hello.com)=a7e1...` -> `zones/a7/e1/hello.com.json`

## Конфигурация

Файл: `config/config.exs` (и `config/runtime.exs` для релиза).

Параметры:
- `zones_folder` — путь к зонам (default `./zones`).
- `dns_port` — UDP порт DNS (default `53`).
- `http_port` — HTTP порт API (default `8080`).
- `api_token` — токен для HTTP API (default `changeme`).
- `cluster_topologies` — топологии libcluster.
- `replication_quorum_ratio` — доля ack, нужная для коммита.
- `replication_timeout_ms` — таймаут репликации.

Переменные окружения для релиза:
- `ZONES_FOLDER`
- `DNS_PORT`
- `HTTP_PORT`
- `API_TOKEN`
- `REPLICATION_QUORUM`
- `REPLICATION_TIMEOUT_MS`

## Запуск (dev)

```bash
mix deps.get
mix run --no-halt
```

## HTTP API (CRUD)

Все запросы требуют заголовок:
`Authentication: Bearer <token>`

Маршруты:
- `GET /zones/:name` — получить зону.
- `PUT /zones/:name` — создать/заменить зону (body: JSON зоны).
- `PATCH /zones/:name` — частичное обновление (body: JSON).
- `DELETE /zones/:name` — удалить зону.

Пример:

```bash
curl -H "Authentication: Bearer changeme" \
  http://localhost:8080/zones/hello.test
```

### HTTP CRUD (OpenAPI‑style)

Base URL: `http://<host>:<http_port>`

Auth:
```
Authentication: Bearer <token>
```

Common errors:
- `401 Unauthorized` — отсутствует/неверный токен.
- `400 Bad Request` — неверный JSON.
- `404 Not Found` — зона не найдена.
- `422 Unprocessable Entity` — не проходит валидация схемы.
- `500 Internal Server Error` — ошибка хранения/репликации.

#### GET /zones/{name}
Description: получить текущую зону.

Response 200:
```json
{
  "name": "hello.test",
  "version": 3,
  "records": [ ... ]
}
```

Response 404:
```json
{"error": "not_found"}
```

#### PUT /zones/{name}
Description: создать или полностью заменить зону.

Request body:
```json
{
  "name": "hello.test",
  "version": 1,
  "records": [ ... ]
}
```

Notes:
- `name` в URL и в теле должны совпадать.
- при успехе версия сохраняется как есть (можно передать следующую).

Response 200:
```json
{"status": "ok", "version": 1}
```

Response 422:
```json
{"error": "validation_failed", "details": "..."}
```

#### PATCH /zones/{name}
Description: частичное обновление зоны.

Request body (любой поднабор полей):
```json
{
  "version": 2,
  "records": [ ... ]
}
```

Notes:
- если `records` отсутствует, остаются старые.
- `version` должен быть больше текущей.

Response 200:
```json
{"status": "ok", "version": 2}
```

#### DELETE /zones/{name}
Description: удалить зону.

Response 200:
```json
{"status": "ok"}
```

Response 404:
```json
{"error": "not_found"}
```

## DNS запросы

DNS сервер слушает UDP порт `dns_port`.
Обработка запросов:
- парсит запрос,
- достает нужную зону,
- формирует ответ (A/AAAA/NS/PTR/MX/TXT/SOA/CNAME).

## Репликация и кластер

Включен libcluster, автоматическое соединение нод.
Изменения зон реплицируются на другие ноды через RPC:
- применяется локально,
- отправляется на другие ноды,
- требуется quorum/ack для коммита,
- при недостижении quorum — rollback (локально и на ack нодах).

## Валидация зон

При старте приложения все зоны в `zones_folder` проверяются на валидность.
Ошибочные зоны пишутся в лог.

## Release

```bash
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix release
```

Запуск:
```
_build/prod/rel/exdns/bin/exdns start
```

Или через алиас:
```
mix prep_release
```

### Конфигурация release

Release читает параметры из `config/runtime.exs`.
Переменные окружения:
- `ZONES_FOLDER` — путь к зонам (по умолчанию `./zones`).
- `DNS_PORT` — UDP порт DNS (по умолчанию `53`).
- `HTTP_PORT` — HTTP порт API (по умолчанию `8080`).
- `API_TOKEN` — токен доступа для HTTP API (по умолчанию `changeme`).
- `REPLICATION_QUORUM` — доля ack для коммита (по умолчанию `0.5`).
- `REPLICATION_TIMEOUT_MS` — таймаут репликации (по умолчанию `2000`).

Пример запуска release:
```bash
API_TOKEN=secret HTTP_PORT=8081 \
ZONES_FOLDER=/data/zones \
_build/prod/rel/exdns/bin/exdns start
```

## Docker

Сборка:
```bash
docker build -t exdns .
```

Запуск:
```bash
docker run -p 53:53/udp -p 8080:8080 \
  -e API_TOKEN=changeme \
  -e ZONES_FOLDER=/data/zones \
  -v %cd%\\zones:/data/zones \
  exdns
```

### Docker Compose

```bash
docker compose up --build
```

## Тесты

```bash
mix test
```

## Логи

Подробные логи включены в большинстве модулей:
- `info` для основных операций,
- `debug` для внутренних шагов.
