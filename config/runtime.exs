import Config

parse_integer = fn name, default ->
  case System.get_env(name) do
    nil -> default
    value -> String.to_integer(value)
  end
end

parse_ip = fn value ->
  case :inet.parse_address(String.to_charlist(value)) do
    {:ok, address} -> address
    {:error, _reason} -> raise "invalid CODEX_RIVER_BIND_IP: #{inspect(value)}"
  end
end

parse_boolean = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    value ->
      case value |> String.trim() |> String.downcase() do
        value when value in ["1", "true", "yes", "on"] -> true
        value when value in ["0", "false", "no", "off"] -> false
        _value -> raise "#{name} must be true/false, 1/0, yes/no, or on/off"
      end
  end
end

log_level =
  case System.get_env("CODEX_RIVER_LOG_LEVEL") do
    nil ->
      nil

    value ->
      case value |> String.trim() |> String.downcase() do
        "debug" -> :debug
        "info" -> :info
        "notice" -> :notice
        "warning" -> :warning
        "error" -> :error
        "critical" -> :critical
        "alert" -> :alert
        "emergency" -> :emergency
        _value -> raise "unsupported CODEX_RIVER_LOG_LEVEL: #{inspect(value)}"
      end
  end

if log_level do
  config :logger, level: log_level
end

log_app_server = parse_boolean.("CODEX_RIVER_LOG_APP_SERVER", nil)

if log_app_server do
  config :logger, truncate: :infinity
end

tokens =
  case System.get_env("CODEX_RIVER_API_TOKENS") do
    nil ->
      [System.get_env("CODEX_RIVER_API_TOKEN"), System.get_env("RIVER_API_TOKEN")]
      |> Enum.reject(&is_nil/1)

    value ->
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
  end

runtime_config =
  [
    port: parse_integer.("PORT", Application.get_env(:codex_river, :port, 4005)),
    bind_ip:
      case System.get_env("CODEX_RIVER_BIND_IP") do
        nil -> Application.get_env(:codex_river, :bind_ip, {127, 0, 0, 1})
        value -> parse_ip.(value)
      end
  ]
  |> then(fn options ->
    if tokens == [], do: options, else: Keyword.put(options, :api_tokens, tokens)
  end)

config :codex_river, runtime_config

if public_model = System.get_env("RIVER_MODEL") do
  config :codex_river, public_model: String.trim(public_model)
end

if codex_model = System.get_env("CODEX_APP_SERVER_MODEL") do
  config :codex_river, codex_model: String.trim(codex_model)
end

codex_app_server_config =
  [
    command: System.get_env("CODEX_APP_SERVER_COMMAND"),
    args:
      System.get_env("CODEX_APP_SERVER_ARGS")
      |> case do
        nil -> nil
        args -> ["app-server", "--stdio" | OptionParser.split(args)]
      end,
    cwd: System.get_env("CODEX_APP_SERVER_CWD"),
    timeout: parse_integer.("CODEX_APP_SERVER_TIMEOUT_MS", nil),
    sandbox: System.get_env("CODEX_APP_SERVER_SANDBOX"),
    approval_policy: System.get_env("CODEX_APP_SERVER_APPROVAL_POLICY"),
    log_app_server: log_app_server
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if codex_app_server_config != [] do
  config :codex_river, CodexRiver.CodexAppServer.Client, codex_app_server_config
end
