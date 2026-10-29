import Config

# Start the default session and window when the application boots. Tests
# start their own sessions instead.
config :guiltty, autostart: config_env() != :test

# Which renderer binary in priv/ the Window launches. The "-debug" build has
# AddressSanitizer and UBSan; tests always use it.
config :guiltty,
  renderer:
    if(config_env() == :test, do: "guiltty_gl-dbg", else: "guiltty_gl")
