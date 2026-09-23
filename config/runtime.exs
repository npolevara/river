import Config

supported_file_variables =
  MapSet.new(~w(
    CODEX_RIVER_API_TOKENS
    CODEX_RIVER_API_TOKEN
    RIVER_API_TOKEN
    PORT
    CODEX_RIVER_BIND_IP
    CODEX_APP_SERVER_COMMAND
    CODEX_APP_SERVER_ARGS
    CODEX_APP_SERVER_CWD
    CODEX_APP_SERVER_TIMEOUT_MS
    CODEX_APP_SERVER_SANDBOX
    CODEX_APP_SERVER_APPROVAL_POLICY
    CODEX_APP_SERVER_MODEL
    LLM_FORCE_LOW
    RIVER_MODEL
    CODEX_RIVER_LOG_LEVEL
    CODEX_RIVER_LOG_APP_SERVER
  ))

explicit_config_file = System.get_env("CODEX_RIVER_CONFIG_FILE")
config_environment = config_env()

config_file =
  case explicit_config_file do
    nil ->
      if config_environment == :test do
        nil
      else
        case System.get_env("__BURRITO_BIN_PATH") do
          nil -> Path.expand("codex_river.env")
          executable -> executable |> Path.dirname() |> Path.join("codex_river.env")
        end
      end

    path ->
      case String.trim(path) do
        "" -> nil
        path -> Path.expand(path)
      end
  end

parse_file_value = fn value, path, line_number ->
  value = String.trim(value)

  cond do
    byte_size(value) >= 2 and
        ((String.starts_with?(value, "\"") and String.ends_with?(value, "\"")) or
           (String.starts_with?(value, "'") and String.ends_with?(value, "'"))) ->
      String.slice(value, 1, String.length(value) - 2)

    String.starts_with?(value, ["\"", "'"]) or String.ends_with?(value, ["\"", "'"]) ->
      raise "#{path}:#{line_number}: unmatched quote"

    true ->
      value
  end
end

if config_file do
  if File.regular?(config_file) do
    file_values =
      config_file
      |> File.stream!()
      |> Stream.with_index(1)
      |> Enum.reduce(%{}, fn {line, line_number}, values ->
        line = String.trim(line)

        cond do
          line == "" or String.starts_with?(line, "#") ->
            values

          true ->
            line = String.replace_prefix(line, "export ", "")

            case String.split(line, "=", parts: 2) do
              [name, value] ->
                name = String.trim(name)

                unless MapSet.member?(supported_file_variables, name) do
                  raise "#{config_file}:#{line_number}: unsupported setting #{inspect(name)}"
                end

                Map.put(values, name, parse_file_value.(value, config_file, line_number))

              _parts ->
                raise "#{config_file}:#{line_number}: expected NAME=value"
            end
        end
      end)

    Enum.each(file_values, fn {name, value} ->
      if is_nil(System.get_env(name)), do: System.put_env(name, value)
    end)
  else
    if explicit_config_file && String.trim(explicit_config_file) != "" do
      raise "CODEX_RIVER_CONFIG_FILE does not exist: #{config_file}"
    end
  end
end

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
force_low = parse_boolean.("LLM_FORCE_LOW", nil)

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
    force_low: force_low,
    log_app_server: log_app_server
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if codex_app_server_config != [] do
  config :codex_river, CodexRiver.CodexAppServer.Client, codex_app_server_config
end
