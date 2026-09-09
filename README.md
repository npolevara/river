# CodexRiver LLM gateway

[Русская версия](docs/README.ru.md)

CodexRiver is a small OpenAI-compatible HTTP server written as a standalone
Elixir/OTP application. It has no frontend and no web-framework dependency.
HTTP/1.1 is served directly over `:gen_tcp`, while generation is delegated to
a local [`codex app-server`](https://learn.chatgpt.com/docs/app-server) process.

Supported routes:

- `GET /health` — unauthenticated local readiness check;
- `GET /v1/models`;
- `POST /v1/chat/completions` — JSON, SSE streaming, and function tools;
- `POST /v1/responses` — JSON and Responses API SSE events.

## Self-contained project

Everything required to compile, test, and package CodexRiver is inside this
directory:

```text
clear_elixir/
├── config/
├── docs/
├── lib/codex_river/
├── test/
├── mix.exs
└── mix.lock
```

The Mix project does not import application modules, configuration, or build
files from its parent directory. The Codex CLI is intentionally an external
runtime program: it must be installed and authenticated on the machine where
CodexRiver runs.

## Toolchain versions

The checked-in `.tool-versions` records the toolchain used to verify this
project:

- Elixir `1.20.2` compiled for Erlang/OTP 29;
- Erlang/OTP `29.0.2`;
- Zig `0.16.0`.

The supported version ranges and packaging requirements are:

| Tool | Requirement |
| --- | --- |
| Elixir | `>= 1.17` and `< 2.0` (`mix.exs` uses `~> 1.17`) |
| Erlang/OTP | `>= 25.3`; use a release compatible with the selected Elixir version |
| Zig | Burrito 1.6 documents `0.15.2`; this project is also verified with `0.16.0` |
| `xz` | Required when building Burrito executables |
| `7z` | Required only when building the Windows target |

Elixir and Erlang/OTP are needed to build or run the source project. They are
embedded in a Burrito executable and are therefore not required on the target
machine. The target machine still needs the `codex` executable and its local
credentials.

## Run from source

Make sure `codex` is available in `PATH`, then:

```bash
cd clear_elixir
mix deps.get

CODEX_RIVER_API_TOKENS=local-secret \
CODEX_APP_SERVER_CWD=/absolute/path/to/workspace \
PORT=4005 \
mix run --no-halt
```

Multiple allowed keys are comma-separated:

```bash
CODEX_RIVER_API_TOKENS=team-a-secret,team-b-secret mix run --no-halt
```

For compatibility, a single key is also read from `CODEX_RIVER_API_TOKEN`,
then from `RIVER_API_TOKEN`.

## Context isolation

Isolation is part of the supervision tree:

```text
bearer token A -> SHA-256 id A -> Client A -> codex app-server process A
                                      `-----> fresh ephemeral thread per request

bearer token B -> SHA-256 id B -> Client B -> codex app-server process B
                                      `-----> fresh ephemeral thread per request
```

The raw API key is neither used as a process name nor written to logs. The
same key reuses only its own app-server transport, but every HTTP request
receives a new `thread/start` with `ephemeral: true`. The connection
unsubscribes from that thread after the turn completes. Consequently, requests
do not enter the user's Codex history, different keys cannot share hidden
Codex context, and consecutive stateless requests made with the same key do
not inherit hidden history either. To continue a conversation, the client
sends the required transcript in `messages` again.

## Chat Completions

```bash
curl http://127.0.0.1:4005/v1/chat/completions \
  -H 'Authorization: Bearer local-secret' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "codex-app-server",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

Streaming:

```bash
curl -N http://127.0.0.1:4005/v1/chat/completions \
  -H 'Authorization: Bearer local-secret' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gpt-5.6-terra",
    "messages": [{"role": "user", "content": "Answer briefly."}],
    "stream": true,
    "stream_options": {"include_usage": true}
  }'
```

Client-defined function tools work in both regular and streaming Chat
Completions. CodexRiver asks Codex to return a function call but does not
execute it. The API client must run the function and submit the following
`role: "tool"` turn. This lets agent clients execute their own shell, `rg`, and
other tools instead of receiving a textual promise to use them.

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

With `"stream": true`, the server emits named `response.created`,
`response.output_text.delta`, `response.output_text.done`, and
`response.completed` events. Client-defined tools are currently implemented
only for `/v1/chat/completions`.

## Model selection

- `codex-app-server` uses `CODEX_APP_SERVER_MODEL` when set; otherwise it
  leaves model selection to the local Codex default;
- `gpt-5.6` maps to the local Codex model ID `gpt-5.6-sol`;
- explicit IDs such as `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna` are
  passed to app-server unchanged;
- surrounding whitespace in a model ID is removed;
- `stream` changes only the response wire format, not model selection.

Chat Completions accepts `reasoning_effort`; Responses accepts
`reasoning.effort`. `reasoning.mode` is validated and returned to the client,
but CodexRiver does not currently map `reasoning.mode` to an app-server field.

## Environment variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `CODEX_RIVER_API_TOKENS` | Comma-separated allowed bearer tokens | not configured |
| `PORT` | TCP port | `4005` |
| `CODEX_RIVER_BIND_IP` | IPv4 or IPv6 bind address | `127.0.0.1` |
| `CODEX_APP_SERVER_COMMAND` | Full path or command name of the Codex executable | `codex` |
| `CODEX_APP_SERVER_ARGS` | Extra arguments after `codex app-server --stdio` | empty |
| `CODEX_APP_SERVER_CWD` | Workspace used for app-server threads | current directory |
| `CODEX_APP_SERVER_TIMEOUT_MS` | Timeout for one request | `120000` |
| `CODEX_APP_SERVER_SANDBOX` | Thread sandbox (`read-only`, `workspace-write`, or `danger-full-access`) | `read-only` |
| `CODEX_APP_SERVER_APPROVAL_POLICY` | Thread approval policy | `never` |
| `CODEX_APP_SERVER_MODEL` | Model used for the public `codex-app-server` ID | local Codex default |
| `RIVER_MODEL` | Public compatibility model ID | `codex-app-server` |
| `CODEX_RIVER_LOG_LEVEL` | Minimum Logger level | `info` |
| `CODEX_RIVER_LOG_APP_SERVER` | Log complete app-server prompts and answers at debug level | `false` |

The server binds to loopback by default. If it is bound to an external
interface, terminate TLS and apply rate limiting at a reverse proxy.

Environment variables are read when the packaged application starts; they are
not baked into a Burrito executable.

## App-server prompt and answer logging

App-server exchange logging is disabled by default. Enable both the exchange
log and debug-level console output when running from source:

```bash
CODEX_RIVER_LOG_LEVEL=debug \
CODEX_RIVER_LOG_APP_SERVER=true \
CODEX_RIVER_API_TOKENS=local-secret \
mix run --no-halt
```

The same variables work with a Burrito executable:

```bash
CODEX_RIVER_LOG_LEVEL=debug \
CODEX_RIVER_LOG_APP_SERVER=true \
CODEX_RIVER_API_TOKENS=local-secret \
./burrito_out/codex_river_macos_arm64 --no-halt
```

The console prints exactly one complete question and one complete answer for
each completion:

```text
[debug] CodexRiver -> app-server [token=5eb63bbbe01e] {"model":"gpt-5.6-terra","prompt":"Complete prompt...","reasoningEffort":"high","threadId":"..."}
[debug] app-server -> CodexRiver [token=5eb63bbbe01e] {"content":"Complete answer...","stopReason":"end_turn","threadId":"...","turnId":"...","usage":{...}}
```

Streaming `item/agentMessage/delta` notifications and other intermediate
app-server messages are not logged. CodexRiver assembles all chunks before
logging the answer, even when the HTTP response itself is streamed. Logger
truncation is disabled while this option is enabled, so long prompts and
answers remain complete.

The token label is only the first 12 characters of its SHA-256 identifier; the
raw bearer token is never passed to app-server or printed. Complete prompts and
answers can still contain conversation transcripts, function arguments, and
function results. Enable this mode only when that data is safe to write to the
console.

To display the exchange and save it at the same time:

```bash
./burrito_out/codex_river_macos_arm64 --no-halt 2>&1 | tee codex-river.log
```

## Build single-file executables with Burrito

Install Zig and `xz`. Install `7z` as well before building the Windows target.
Builds are best performed on macOS or Linux. When developing on Windows, use
WSL to build the artifacts.

The current release already includes a prebuilt Apple Silicon (macOS ARM64)
executable at `burrito_out/codex_river_macos_arm64`. It can be run immediately
without compiling the project; the local `codex` executable and its credentials
are still required.

Prepare dependencies once:

```bash
cd clear_elixir
MIX_ENV=prod mix deps.get
```

Configured targets:

| `BURRITO_TARGET` | Output |
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

Run the matching artifact:

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

Run the matching artifact on Linux:

```bash
CODEX_RIVER_API_TOKENS=local-secret \
CODEX_APP_SERVER_CWD=/absolute/path/to/workspace \
PORT=4005 \
./burrito_out/codex_river_linux_x86_64 --no-halt
```

### Windows x86-64

Generate the Windows executable from macOS, Linux, or WSL. The build machine
must have `7z` available in `PATH`:

```bash
BURRITO_TARGET=windows_x86_64 MIX_ENV=prod mix release --overwrite
```

Run it from PowerShell on Windows:

```powershell
$env:CODEX_RIVER_API_TOKENS = "local-secret"
$env:CODEX_APP_SERVER_CWD = "C:\path\to\workspace"
$env:PORT = "4005"
.\burrito_out\codex_river_windows_x86_64.exe --no-halt
```

To generate every configured target in one invocation, ensure all three build
tools are installed and omit `BURRITO_TARGET`:

```bash
MIX_ENV=prod mix release --overwrite
```

`--no-halt` keeps the BEAM VM alive after application startup. A Burrito file
is a self-extracting executable containing the application and ERTS, not a
single Elixir source file. On first launch, its payload is unpacked into the
platform application-data directory.

A production Burrito executable reuses an already unpacked payload with the
same application version. When rebuilding `0.1.0` during development, remove
the cached runtime once before starting the new binary:

```bash
./burrito_out/codex_river_macos_arm64 maintenance uninstall
./burrito_out/codex_river_macos_arm64 --no-halt
```

Published builds should increment the application version in `mix.exs` so that
Burrito installs the new payload automatically.

## Verification

```bash
mix precommit
```

The tests start a real TCP listener and separate fake app-server subprocesses.
They cover authorization, model selection, both streaming protocols, function
calling, process separation between API keys, and a new ephemeral app-server
thread for every request.
