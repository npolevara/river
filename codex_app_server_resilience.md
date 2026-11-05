# Codex App Server: кэш capabilities и обработка перегрузки

Статус: Proposed  
Дата: 2026-09-22

## Цель

Устранить две независимые проблемы интеграции с `codex app-server`:

1. `model/list` выполняется при каждом запросе с указанным
   `reasoning_effort`, из-за чего несколько token-isolated процессов River
   одновременно обновляют каталог моделей и усиливают сетевой retry storm.
2. Ошибка `serverOverloaded` теряет исходную семантику и преобразуется Router в
   общий `502 backend_error`.

Решение должно уменьшить количество `model/list`, сохранить token isolation,
ограниченно переключать модель при временной перегрузке и возвращать исходную
ошибку после исчерпания попыток.

## Текущее поведение

### Обновление capabilities

[`CodexRiver.CodexAppServer.Client`](lib/codex_river/codex_app_server/client.ex)
создаёт отдельный долгоживущий `codex app-server` для каждого bearer-token hash.

После успешного `thread/start` клиент:

1. получает `selected_model`;
2. если был передан `reasoning_effort`, вызывает `model/list`;
3. находит `supportedReasoningEfforts` выбранной модели;
4. согласовывает requested/effective effort;
5. запускает `turn/start`.

Полученные capabilities сохраняются только внутри текущей операции:

```elixir
%{
  selected_model: nil,
  requested_reasoning_effort: reasoning_effort,
  reasoning_effort: reasoning_effort,
  supported_reasoning_efforts: :unknown
}
```

После завершения операции эти данные удаляются. Следующий запрос с effort снова
вызывает `model/list`.

Если одновременно существуют три token-isolated `Client`, один логический
период обновления способен породить три одинаковых refresh. Кэш только внутри
каждого `Client` уменьшит повторные запросы одного токена, но не устранит
тройной cold refresh.

### Преобразование ошибок

Неуспешный turn возвращается из Client как:

```elixir
{:error, {:app_server_turn_failed, turn["error"]}}
```

Специализированного match для `serverOverloaded` в
[`CodexRiver.HTTP.Router`](lib/codex_river/http/router.ex) нет, поэтому ошибка
попадает в общий обработчик:

```elixir
%{
  message: "The local Codex app-server backend could not complete the request",
  type: "server_error",
  param: nil,
  code: "backend_error",
  status: 502
}
```

В результате вызывающий клиент не может отличить временную нехватку capacity от
ошибки локального gateway.

## Решение 1: общий кэш model capabilities

### Область кэша

Добавить supervised-процесс:

```text
CodexRiver.ModelCapabilities
```

Он должен быть общим для всех token-isolated `Client` в одном экземпляре River.
Это допустимо для текущей архитектуры, потому что API-токены River изолируют
входящих клиентов, а все `codex app-server` наследуют одну локальную
конфигурацию и одну upstream-аутентификацию.

Если в будущем разные Client начнут использовать разные `CODEX_HOME`, аккаунты,
профили или исполняемые файлы, ключ кэша должен включать fingerprint этого
окружения.

### Состояние

Минимальное состояние кэша:

```elixir
%{
  catalog: %{
    "gpt-5.6-sol" => ["low", "medium", "high", "xhigh", "max"],
    "gpt-5.6-terra" => ["none", "low", "medium", "high", "xhigh", "max"]
  },
  expires_at: nil,
  stale_until: nil,
  retry_at: nil,
  refresh_owner: nil,
  waiters: [],
  failure_count: 0
}
```

Время истечения следует считать через `System.monotonic_time/1`, чтобы изменение
системных часов не ломало TTL и backoff.

### Single-flight

При cache miss или обязательном refresh только один Client получает право
выполнить `model/list`.

Остальные операции:

- используют stale-каталог, если он доступен;
- либо регистрируются как waiters и продолжаются после публикации результата;
- не отправляют собственный `model/list`.

После завершения refresh владелец публикует результат в общий кэш, а ожидающие
операции получают capabilities своей `selected_model`.

Если владелец refresh завершается, отключается или достигает timeout, lock должен
быть освобождён, а waiters должны получить контролируемый fallback. Lock не
должен оставаться занятым навсегда.

### Кэшировать весь каталог

Один ответ `model/list` содержит несколько моделей. Нужно накапливать все
страницы до `nextCursor == nil` и сохранять полный корректно распарсенный
каталог, а не только найденную `selected_model`.

Это позволяет одному refresh обслуживать запросы разных моделей.

Некорректные записи отдельной модели не должны инвалидировать корректные записи
остального каталога. Для модели с malformed `supportedReasoningEfforts` следует
сохранить `:unknown` либо пропустить запись согласно текущей политике "не
угадывать capabilities".

### TTL, stale и backoff

Начальные значения:

| Параметр | Значение |
|---|---:|
| Успешный TTL | 10 минут |
| TTL jitter | ±20% |
| Stale interval | 1 час |
| Начальный error backoff | 1 секунда |
| Максимальный error backoff | 30–60 секунд |

Успешный TTL также должен включать jitter, иначе независимые экземпляры River
снова будут обновляться одновременно.

При ошибке refresh:

1. не удалять последний корректный каталог;
2. увеличить `failure_count`;
3. вычислить следующий delay с exponential backoff и jitter;
4. до `retry_at` не разрешать новые refresh;
5. использовать stale-каталог, если его срок ещё не истёк.

Пример full-jitter:

```text
cap = min(max_delay, base_delay * 2^failure_count)
delay = random(0..cap)
```

Для детерминированных тестов источник времени и jitter нужно сделать
инъецируемым либо вынести вычисление delay в чистую функцию.

### Согласование effort

Если capabilities свежие или stale-допустимые, сохранить существующую политику:

- `nil`: не передавать effort и не запрашивать capabilities;
- advertised effort: передавать без изменения;
- `none` или `minimal`, когда они не advertised, но присутствует `low`:
  передавать `low`;
- прочие значения: передавать как есть и сохранять структурированную ошибку
  app-server;
- malformed или отсутствующие metadata: не угадывать значение.

### Инвалидация после отклонения effort

Если RPC `turn/start` отклонён из-за unsupported effort до создания `turn_id`:

1. инвалидировать запись только для `selected_model`;
2. выполнить один принудительный refresh;
3. повторно согласовать effort;
4. повторить `turn/start` не более одного раза;
5. если отказ повторился, вернуть существующий `400 unsupported_value`.

В operation нужен счётчик:

```elixir
capability_retry_count: 0
```

Такой повтор безопасен только при явном RPC-отказе до создания turn. Ошибку
`turn/completed` нельзя считать эквивалентной: turn уже мог начать работу.

## Решение 2: сохранить семантику `serverOverloaded`

### Нормализация `codexErrorInfo`

Поддержать как наблюдавшуюся строковую форму:

```json
{
  "codexErrorInfo": "serverOverloaded",
  "message": "Selected model is at capacity. Please try a different model.",
  "additionalDetails": null
}
```

так и структурированную форму, в которой может присутствовать
`httpStatusCode`.

Рекомендуемая публичная классификация:

| Входная ошибка app-server | HTTP | `code` |
|---|---:|---|
| `codexErrorInfo == "serverOverloaded"` | 503 | `server_overloaded` |
| `HttpConnectionFailed` + upstream `503` | 503 | `upstream_unavailable` |
| Timeout River | 504 | `backend_timeout` |
| Неизвестная backend-ошибка | 502 | `backend_error` |

Для `serverOverloaded` River сознательно определяет публичный статус `503`. Это
не следует описывать как гарантированную передачу upstream-статуса: строковый
payload может не содержать `httpStatusCode`.

Рекомендуемый non-streaming ответ:

```json
{
  "error": {
    "message": "Selected model is at capacity. Please try a different model.",
    "type": "server_error",
    "param": null,
    "code": "server_overloaded"
  }
}
```

Если исходное сообщение отсутствует или имеет неожиданную форму, использовать
стабильный fallback и не включать необработанный внутренний term.

### `Retry-After`

В наблюдавшейся ошибке `additionalDetails` равен `nil`, поэтому настоящий
upstream `Retry-After` недоступен.

Допустимые варианты:

1. передавать upstream `Retry-After`, только если app-server явно предоставит
   его в документированном поле;
2. добавить собственный настраиваемый `Retry-After`, например 5 секунд;
3. не отправлять заголовок и оставить стратегию повтора вызывающему клиенту.

Нельзя утверждать, что локально сгенерированный заголовок пришёл от upstream.

Если заголовок добавляется, [`CodexRiver.HTTP.Response`](lib/codex_river/http/response.ex)
должен принимать дополнительные error headers, например:

```elixir
%{
  status: 503,
  headers: [{"retry-after", "5"}],
  message: message,
  type: "server_error",
  param: nil,
  code: "server_overloaded"
}
```

## Политика автоматических повторов

### Разрешено повторять автоматически

- `model/list`;
- общий refresh capabilities;
- `turn/start`, только если он был отклонён до создания `turn_id` из-за
  устаревшего effort;
- failed turn с точным `codexErrorInfo == "serverOverloaded"` — через новый
  ephemeral thread и не более четырёх переключений модели;
- read-only операции, для которых явно доказана идемпотентность.

### Нельзя повторять автоматически по умолчанию

- весь `LLM.complete/2`, кроме ограниченного `serverOverloaded` failover;
- turn после получения `turn_id`;
- turn после первого streamed delta;
- turn после `item/started`, tool request, command execution или file change;
- запрос, для которого River уже отдал наблюдаемый клиентом результат.

Причины:

- возможен дублированный текст;
- возможен повтор tool call;
- app-server мог выполнить read-only или иной разрешённый command;
- у River нет idempotency key для agentic-turn;
- при streaming часть ответа могла быть уже отправлена.

При `serverOverloaded` River автоматически создаёт новый ephemeral thread на
соседнем уровне модели и сохраняет фактический reasoning effort. Для старта с
Sol последовательность равна `Sol -> Terra -> Luna -> Terra -> Sol`. После
четырёх переключений следующая ошибка возвращается вызывающему клиенту.

## Streaming

Сейчас Router отправляет HTTP `200` и SSE-заголовки до завершения
`LLM.complete/2`. После этого HTTP-статус изменить нельзя.

Контракт должен различать режимы:

| Режим | Результат при `serverOverloaded` |
|---|---|
| Non-streaming Chat Completions | HTTP 503 + OpenAI-shaped error |
| Non-streaming Responses | HTTP 503 + OpenAI-shaped error |
| Streaming Chat Completions | HTTP 200 + SSE error + `[DONE]` |
| Streaming Responses | HTTP 200 + `response.failed`/error event |

Настоящий HTTP 503 для streaming потребует отложить отправку SSE-заголовков до
подтверждения `turn/start`. Текущий интерфейс `Client.complete/2` не публикует
такое событие, поэтому это отдельное изменение протокола и не входит в первый
этап.

## Граница ответственности Zed

Изменения River уменьшают только запросы, созданные процессами River. Они не
могут управлять refresh-политикой самостоятельных `app-server`, запущенных Zed.

Для Zed отдельно применяются:

- согласованные версии `codex-acp` и `codex`;
- завершение неиспользуемых agent sessions;
- ограничение количества одновременно работающих app-server;
- отдельный `CODEX_HOME`, если повторяются гонки skills/cache;
- retry с backoff и jitter на стороне ACP/Zed, если такая настройка или правка
  доступна.

## Изменения в коде

Предполагаемый scope:

- добавить `lib/codex_river/model_capabilities.ex`;
- добавить `CodexRiver.ModelCapabilities` в supervision tree до динамических
  token clients;
- перевести `Client` с operation-local capabilities на lookup/refresh общего
  каталога;
- добавить single-flight, TTL, stale-on-error и backoff;
- добавить однократную инвалидацию после pre-turn unsupported effort;
- нормализовать `codexErrorInfo` в Router;
- добавить ограниченное переключение
  `gpt-5.6-sol -> gpt-5.6-terra -> gpt-5.6-luna -> gpt-5.6-terra -> gpt-5.6-sol`
  при `serverOverloaded`;
- добавить mapping `serverOverloaded -> 503/server_overloaded`;
- при необходимости расширить `HTTP.Response.error/2` дополнительными
  заголовками;
- добавить конфигурацию TTL, backoff и локального `Retry-After` в
  `config/config.exs`, `config/runtime.exs` и `codex_river.env.example`.

Предлагаемые переменные окружения:

```text
CODEX_RIVER_MODEL_CAPABILITIES_TTL_MS=600000
CODEX_RIVER_MODEL_CAPABILITIES_STALE_MS=3600000
CODEX_RIVER_MODEL_CAPABILITIES_RETRY_BASE_MS=1000
CODEX_RIVER_MODEL_CAPABILITIES_RETRY_MAX_MS=60000
CODEX_RIVER_OVERLOAD_RETRY_AFTER_SECONDS=5
LLM_FORCE_LOW=false
```

Значения должны валидироваться как неотрицательные целые числа. Пустые или
некорректные значения не должны молча превращаться в ноль.

## Тесты

### Model capabilities

Расширить fake app-server и покрыть:

1. два последовательных запроса одной модели вызывают `model/list` один раз;
2. capabilities разных моделей берутся из одного загруженного каталога;
3. параллельные операции одного Client используют один refresh;
4. разные token-isolated Client используют общий single-flight;
5. после TTL запускается ровно один новый refresh;
6. TTL содержит jitter;
7. ошибка refresh включает exponential backoff;
8. запросы до `retry_at` не запускают новый refresh;
9. stale-каталог используется при временной ошибке refresh;
10. malformed metadata не приводит к угадыванию effort;
11. unsupported effort инвалидирует одну модель и вызывает не более одного
    повторного refresh;
12. запрос без effort не обращается к capabilities cache и не вызывает
    `model/list`.

### HTTP errors

Покрыть:

1. non-streaming Chat Completions возвращает `503/server_overloaded`;
2. non-streaming Responses возвращает `503/server_overloaded`;
3. исходное безопасное сообщение сохраняется;
4. локальный `Retry-After` присутствует, если функция включена;
5. streaming Chat Completions возвращает SSE error и завершает поток;
6. streaming Responses возвращает error event;
7. неизвестная app-server ошибка остаётся `502/backend_error`;
8. timeout остаётся `504/backend_timeout`;
9. строковая и структурированная формы `codexErrorInfo` нормализуются одинаково.

Тесты времени и jitter не должны использовать реальные долгие `sleep`. Нужно
инъецировать clock/random либо тестировать чистые функции расчёта срока и delay.

## Наблюдаемость

Добавить структурированные метрики или логи без токенов, prompt и response body:

```text
model_capabilities.cache_hit
model_capabilities.stale_hit
model_capabilities.cache_miss
model_capabilities.refresh_started
model_capabilities.refresh_succeeded
model_capabilities.refresh_failed
model_capabilities.refresh_coalesced
model_capabilities.backoff_ms
app_server.server_overloaded
```

Логировать model id, возраст кэша, failure count и рассчитанный backoff. Не
логировать bearer token, полный `CODEX_HOME`, prompt или содержимое ответа.

## Критерии приёмки

- Повторные запросы с effort не вызывают `model/list` до истечения TTL.
- Три token-isolated Client не создают три одновременных refresh.
- При сетевой ошибке последний корректный каталог продолжает использоваться в
  пределах stale interval.
- Повторы refresh имеют exponential backoff и jitter.
- Нет бесконечного цикла при отклонении reasoning effort.
- `serverOverloaded` возвращает `503/server_overloaded` в non-streaming API.
- Неизвестные backend-ошибки сохраняют `502/backend_error`.
- River повторяет failed turn только при точном `serverOverloaded`, используя
  новый ephemeral thread и не более четырёх переключений модели.
- Streaming API возвращает корректное error event без попытки изменить уже
  отправленный HTTP 200.
- Все существующие тесты и проектные проверки проходят.

## Не входит в scope

- Изменение внутренней retry-политики Zed или `codex-acp`.
- Автоматическое переключение моделей вне фиксированной цепочки перегрузки.
- Автоматический retry полного agentic-turn для ошибок, отличных от
  `serverOverloaded`.
- Обещание, что `low` семантически равно отключённому reasoning.
- Передача вымышленного upstream `Retry-After`.
- Изменение token-isolation или объединение app-server процессов разных
  bearer-токенов.

## Источник

- [OpenAI Codex App Server documentation](https://learn.chatgpt.com/docs/app-server) —
  структура ошибок `codexErrorInfo`, передача upstream `httpStatusCode` при его
  наличии и рекомендация exponential backoff с jitter при перегрузке.
