# CodexRiver LLM gateway

[English version](../README.md)

CodexRiver — небольшой OpenAI-совместимый HTTP-сервер, реализованный как
самостоятельное приложение на Elixir/OTP. В нём нет фронтенда и зависимости от
веб-фреймворка. HTTP/1.1 работает прямо поверх `:gen_tcp`, а генерация
выполняется локальным процессом
[`codex app-server`](https://learn.chatgpt.com/docs/app-server).

Поддерживаемые маршруты:

- `GET /health` — локальная проверка готовности без авторизации;
- `GET /v1/models`;
- `POST /v1/chat/completions` — JSON, SSE streaming и function tools;
- `POST /v1/responses` — JSON и Responses API SSE events.

## Самодостаточный проект

Всё необходимое для компиляции, тестирования и упаковки CodexRiver находится
внутри этой папки:

```text
clear_elixir/
├── config/
├── docs/
├── lib/codex_river/
├── test/
├── mix.exs
└── mix.lock
```

Mix-проект не импортирует модули приложения, конфигурацию или файлы сборки из
родительской папки. Codex CLI намеренно остаётся внешней runtime-программой:
она должна быть установлена и авторизована на машине, где запускается
CodexRiver.

## Версии инструментов

Добавленный в проект `.tool-versions` фиксирует проверенный toolchain:

- Elixir `1.20.2`, собранный для Erlang/OTP 29;
- Erlang/OTP `29.0.2`;
- Zig `0.16.0`.

Поддерживаемые диапазоны версий и требования для упаковки:

| Инструмент | Требование |
| --- | --- |
| Elixir | `>= 1.17` и `< 2.0` (в `mix.exs` указано `~> 1.17`) |
| Erlang/OTP | `>= 25.3`; версия должна быть совместима с выбранной версией Elixir |
| Zig | В документации Burrito 1.6 указана `0.15.2`; проект также проверен с `0.16.0` |
| `xz` | Нужен для сборки Burrito executable |
| `7z` | Нужен только для сборки Windows target |

Elixir и Erlang/OTP нужны для сборки или запуска проекта из исходников. Они
встраиваются в Burrito executable, поэтому на целевой машине не требуются.
Однако на целевой машине всё ещё нужны executable `codex` и его локальная
авторизация.

## Запуск из исходников

Убедитесь, что `codex` доступен в `PATH`, затем:

```bash
cd clear_elixir
mix deps.get

CODEX_RIVER_API_TOKENS=local-secret \
CODEX_APP_SERVER_CWD=/absolute/path/to/workspace \
PORT=4005 \
mix run --no-halt
```

Несколько разрешённых ключей передаются через запятую:

```bash
CODEX_RIVER_API_TOKENS=team-a-secret,team-b-secret mix run --no-halt
```

Для совместимости одиночный ключ также читается из
`CODEX_RIVER_API_TOKEN`, а затем из `RIVER_API_TOKEN`.

## Изоляция контекста

Изоляция является частью supervisor tree:

```text
bearer token A -> SHA-256 id A -> Client A -> codex app-server process A
                                      `-----> fresh ephemeral thread per request

bearer token B -> SHA-256 id B -> Client B -> codex app-server process B
                                      `-----> fresh ephemeral thread per request
```

Сырой API-ключ не используется как имя процесса и не попадает в логи.
Одинаковый ключ повторно использует только свой app-server transport, но каждый
HTTP-запрос получает новый `thread/start` с `ephemeral: true`. После завершения
turn соединение отписывается от thread. Поэтому запросы не попадают в историю
Codex пользователя, разные ключи не могут разделять скрытый контекст Codex, а
последовательные stateless-запросы одного ключа также не наследуют скрытую
историю. Для продолжения диалога клиент должен снова передать нужный transcript
в `messages`.

## Chat Completions

```bash
curl http://127.0.0.1:4005/v1/chat/completions \
  -H 'Authorization: Bearer local-secret' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "codex-app-server",
    "messages": [{"role": "user", "content": "Привет!"}]
  }'
```

Streaming:

```bash
curl -N http://127.0.0.1:4005/v1/chat/completions \
  -H 'Authorization: Bearer local-secret' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gpt-5.6-terra",
    "messages": [{"role": "user", "content": "Ответь кратко."}],
    "stream": true,
    "stream_options": {"include_usage": true}
  }'
```

Client-defined function tools работают в обычном и потоковом режиме Chat
Completions. CodexRiver просит Codex вернуть вызов функции, но сам её не
исполняет. API-клиент должен выполнить функцию и прислать следующий turn с
`role: "tool"`. Это позволяет агентским клиентам запускать собственные shell,
`rg` и другие tools вместо получения текстового обещания применить их.

## Responses API

```bash
curl http://127.0.0.1:4005/v1/responses \
  -H 'Authorization: Bearer local-secret' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gpt-5.6",
    "reasoning": {"mode": "pro", "effort": "medium"},
    "input": "Review this migration plan."
  }'
```

При `"stream": true` сервер возвращает именованные события
`response.created`, `response.output_text.delta`, `response.output_text.done` и
`response.completed`. Client-defined tools пока реализованы только для
`/v1/chat/completions`.

## Выбор модели

- `codex-app-server` использует `CODEX_APP_SERVER_MODEL`, если переменная
  задана; иначе выбор остаётся за локальной моделью Codex по умолчанию;
- `gpt-5.6` преобразуется в локальный Codex model ID `gpt-5.6-sol`;
- явные ID, например `gpt-5.6-sol`, `gpt-5.6-terra` и `gpt-5.6-luna`,
  передаются в app-server без изменений;
- пробелы по краям model ID удаляются;
- `stream` меняет только wire format ответа, но не выбор модели.

Chat Completions принимает `reasoning_effort`, Responses —
`reasoning.effort`. `reasoning.mode` валидируется и возвращается клиенту, но
CodexRiver пока не сопоставляет `reasoning.mode` с полем app-server.

## Переменные окружения

| Переменная | Назначение | Значение по умолчанию |
| --- | --- | --- |
| `CODEX_RIVER_API_TOKENS` | Разрешённые bearer tokens через запятую | не настроены |
| `PORT` | TCP port | `4005` |
| `CODEX_RIVER_BIND_IP` | IPv4 или IPv6 bind address | `127.0.0.1` |
| `CODEX_APP_SERVER_COMMAND` | Полный путь или имя Codex executable | `codex` |
| `CODEX_APP_SERVER_ARGS` | Дополнительные аргументы после `codex app-server --stdio` | пусто |
| `CODEX_APP_SERVER_CWD` | Workspace для app-server threads | текущая папка |
| `CODEX_APP_SERVER_TIMEOUT_MS` | Timeout одного запроса | `120000` |
| `CODEX_APP_SERVER_SANDBOX` | Sandbox thread (`read-only`, `workspace-write` или `danger-full-access`) | `read-only` |
| `CODEX_APP_SERVER_APPROVAL_POLICY` | Политика подтверждений thread | `never` |
| `CODEX_APP_SERVER_MODEL` | Модель для публичного ID `codex-app-server` | локальная Codex default |
| `RIVER_MODEL` | Публичный compatibility model ID | `codex-app-server` |
| `CODEX_RIVER_LOG_LEVEL` | Минимальный уровень Logger | `info` |
| `CODEX_RIVER_LOG_APP_SERVER` | Вывод полных app-server prompt и ответа на уровне debug | `false` |

По умолчанию сервер доступен только через loopback. При использовании внешнего
интерфейса TLS termination и rate limiting следует настроить на reverse proxy.

Переменные окружения читаются при запуске упакованного приложения и не
запекаются в Burrito executable.

## Логирование app-server prompt и ответа

По умолчанию обмен с app-server не логируется. Для запуска из исходников
одновременно включите логирование обмена и debug-уровень консольных логов:

```bash
CODEX_RIVER_LOG_LEVEL=debug \
CODEX_RIVER_LOG_APP_SERVER=true \
CODEX_RIVER_API_TOKENS=local-secret \
mix run --no-halt
```

Те же переменные работают с Burrito executable:

```bash
CODEX_RIVER_LOG_LEVEL=debug \
CODEX_RIVER_LOG_APP_SERVER=true \
CODEX_RIVER_API_TOKENS=local-secret \
./burrito_out/codex_river_macos_arm64 --no-halt
```

После этого на каждый completion в консоль выводятся ровно один полный вопрос
и один полный ответ:

```text
[debug] CodexRiver -> app-server [token=5eb63bbbe01e] {"model":"gpt-5.6-terra","prompt":"Полный prompt...","reasoningEffort":"high","threadId":"..."}
[debug] app-server -> CodexRiver [token=5eb63bbbe01e] {"content":"Полный ответ...","stopReason":"end_turn","threadId":"...","turnId":"...","usage":{...}}
```

Потоковые notifications `item/agentMessage/delta` и другие промежуточные
сообщения app-server в лог не выводятся. CodexRiver сначала объединяет все
chunks и только потом логирует ответ, даже если сам HTTP-ответ передаётся в
streaming-режиме. При включении этой опции стандартное усечение Logger
отключается, поэтому длинные prompts и ответы сохраняются полностью.

Метка токена содержит только первые 12 символов его SHA-256 идентификатора;
исходный bearer token не передаётся в app-server и не печатается. При этом полные
prompts и ответы могут содержать историю разговора, аргументы функций и
результаты их выполнения. Включайте этот режим только там, где эти данные
допустимо выводить в консоль.

Чтобы одновременно видеть обмен и сохранять его в файл:

```bash
./burrito_out/codex_river_macos_arm64 --no-halt 2>&1 | tee codex-river.log
```

## Сборка одного executable через Burrito

Установите Zig и `xz`. Для Windows target дополнительно установите `7z`.
Рекомендуется собирать на macOS или Linux. При разработке на Windows собирайте
артефакты внутри WSL.

В текущем релизе уже есть готовый executable для Apple Silicon (macOS ARM64):
`burrito_out/codex_river_macos_arm64`. Его можно запускать сразу, без компиляции
проекта; при этом локальный executable `codex` и его авторизация по-прежнему
необходимы.

Один раз подготовьте зависимости:

```bash
cd clear_elixir
MIX_ENV=prod mix deps.get
```

Настроенные targets:

| `BURRITO_TARGET` | Результат |
| --- | --- |
| `macos_arm64` | `burrito_out/codex_river_macos_arm64` |
| `macos_x86_64` | `burrito_out/codex_river_macos_x86_64` |
| `linux_x86_64` | `burrito_out/codex_river_linux_x86_64` |
| `linux_arm64` | `burrito_out/codex_river_linux_arm64` |
| `windows_x86_64` | `burrito_out/codex_river_windows_x86_64.exe` |

### macOS

Apple Silicon:

```bash
BURRITO_TARGET=macos_arm64 MIX_ENV=prod mix release --overwrite
```

Intel:

```bash
BURRITO_TARGET=macos_x86_64 MIX_ENV=prod mix release --overwrite
```

Запуск соответствующего артефакта:

```bash
CODEX_RIVER_API_TOKENS=local-secret \
CODEX_APP_SERVER_CWD=/absolute/path/to/workspace \
PORT=4005 \
./burrito_out/codex_river_macos_arm64 --no-halt
```

### Linux

x86-64:

```bash
BURRITO_TARGET=linux_x86_64 MIX_ENV=prod mix release --overwrite
```

ARM64:

```bash
BURRITO_TARGET=linux_arm64 MIX_ENV=prod mix release --overwrite
```

Запуск соответствующего артефакта на Linux:

```bash
CODEX_RIVER_API_TOKENS=local-secret \
CODEX_APP_SERVER_CWD=/absolute/path/to/workspace \
PORT=4005 \
./burrito_out/codex_river_linux_x86_64 --no-halt
```

### Windows x86-64

Windows executable следует генерировать на macOS, Linux или в WSL. На машине
сборки `7z` должен быть доступен в `PATH`:

```bash
BURRITO_TARGET=windows_x86_64 MIX_ENV=prod mix release --overwrite
```

Запуск в PowerShell на Windows:

```powershell
$env:CODEX_RIVER_API_TOKENS = "local-secret"
$env:CODEX_APP_SERVER_CWD = "C:\path\to\workspace"
$env:PORT = "4005"
.\burrito_out\codex_river_windows_x86_64.exe --no-halt
```

Чтобы одной командой создать все настроенные targets, установите все три
инструмента сборки и не задавайте `BURRITO_TARGET`:

```bash
MIX_ENV=prod mix release --overwrite
```

`--no-halt` не даёт BEAM VM завершиться после запуска приложения. Burrito-файл
является самораспаковывающимся executable с приложением и ERTS, а не одним
файлом исходного Elixir-кода. При первом запуске payload распаковывается во
внутреннюю application-data папку платформы.

Production Burrito executable повторно использует уже распакованный payload с
той же версией приложения. Если во время разработки вы пересобираете `0.1.0`,
один раз удалите закэшированный runtime перед запуском нового бинарника:

```bash
./burrito_out/codex_river_macos_arm64 maintenance uninstall
./burrito_out/codex_river_macos_arm64 --no-halt
```

Для публикуемых сборок следует увеличивать версию приложения в `mix.exs`, тогда
Burrito автоматически установит новый payload.

## Проверка

```bash
mix precommit
```

Тесты запускают настоящий TCP listener и отдельные fake app-server
subprocesses. Они проверяют авторизацию, выбор модели, оба streaming-протокола,
function calling, разделение процессов разных API-ключей и новый ephemeral
app-server thread для каждого запроса.
