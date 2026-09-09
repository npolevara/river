import Config

config :logger, level: :warning

config :codex_river,
  port: 0,
  api_tokens: ["test-token-a", "test-token-b"]

config :codex_river, CodexRiver.CodexAppServer.Client,
  command: System.find_executable("ruby"),
  args: [Path.expand("../test/support/fake_codex_app_server.rb", __DIR__)],
  cwd: Path.expand("..", __DIR__),
  timeout: 5_000,
  sandbox: "read-only",
  approval_policy: "never"
