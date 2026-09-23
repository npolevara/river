import Config

config :codex_river,
  bind_ip: {127, 0, 0, 1},
  port: 4005,
  api_tokens: [],
  public_model: "codex-app-server",
  codex_model: nil,
  model_aliases: %{"gpt-5.6" => "gpt-5.6-sol"},
  llm_adapter: CodexRiver.CodexAppServer,
  start_server: true

config :codex_river, CodexRiver.CodexAppServer.Client,
  command: "codex",
  args: ["app-server", "--stdio"],
  timeout: 120_000,
  sandbox: "read-only",
  approval_policy: "never",
  force_low: false,
  log_app_server: false

import_config "#{config_env()}.exs"
