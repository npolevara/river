defmodule CodexRiver.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)
  @managed_variables ~w(
    CODEX_RIVER_CONFIG_FILE
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
    __BURRITO_BIN_PATH
  )

  setup do
    previous_environment = Map.new(@managed_variables, &{&1, System.get_env(&1)})
    Enum.each(@managed_variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous_environment, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    temp_dir =
      Path.join(System.tmp_dir!(), "codex-river-config-#{System.unique_integer([:positive])}")

    File.mkdir!(temp_dir)
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    %{config_file: Path.join(temp_dir, "codex_river.env"), temp_dir: temp_dir}
  end

  test "loads supported settings from an env file", %{config_file: config_file} do
    File.write!(config_file, """
    # Local River settings
    export CODEX_RIVER_API_TOKENS='first,second'
    PORT=4567
    CODEX_RIVER_LOG_LEVEL=debug
    CODEX_RIVER_LOG_APP_SERVER=true
    LLM_FORCE_LOW=true
    """)

    config = read_runtime(config_file)

    assert System.get_env("CODEX_RIVER_API_TOKENS") == "first,second"
    assert config[:codex_river][:api_tokens] == ["first", "second"]
    assert config[:codex_river][:port] == 4567
    assert config[:logger][:level] == :debug
    assert config[:codex_river][CodexRiver.CodexAppServer.Client][:force_low]
  end

  test "rejects an invalid force-low boolean", %{config_file: config_file} do
    File.write!(config_file, "LLM_FORCE_LOW=maybe\n")

    assert_raise RuntimeError, ~r/LLM_FORCE_LOW must be true\/false/, fn ->
      read_runtime(config_file)
    end
  end

  test "environment variables override values from the file", %{config_file: config_file} do
    File.write!(config_file, "PORT=4567\nCODEX_RIVER_API_TOKENS=file-key\n")
    System.put_env("PORT", "7654")
    System.put_env("CODEX_RIVER_API_TOKENS", "environment-key")

    config = read_runtime(config_file)

    assert config[:codex_river][:port] == 7654
    assert config[:codex_river][:api_tokens] == ["environment-key"]
  end

  test "rejects unknown settings instead of silently ignoring typos", %{config_file: config_file} do
    File.write!(config_file, "CODEX_RIVER_LOG_ACP=true\n")

    assert_raise RuntimeError, ~r/unsupported setting "CODEX_RIVER_LOG_ACP"/, fn ->
      read_runtime(config_file)
    end
  end

  test "Burrito loads the file next to its executable", %{
    config_file: config_file,
    temp_dir: temp_dir
  } do
    File.write!(config_file, "CODEX_RIVER_API_TOKENS=burrito-key\n")
    System.put_env("__BURRITO_BIN_PATH", Path.join(temp_dir, "codex_river"))

    config = Config.Reader.read!(@runtime_config, env: :prod)

    assert config[:codex_river][:api_tokens] == ["burrito-key"]
  end

  defp read_runtime(config_file) do
    System.put_env("CODEX_RIVER_CONFIG_FILE", config_file)
    Config.Reader.read!(@runtime_config, env: :test)
  end
end
