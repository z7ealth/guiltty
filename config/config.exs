import Config

# Start the default session and window when the application boots. Tests
# start their own sessions instead.
config :guiltty, autostart: config_env() != :test

# Which renderer binary in priv/ the Window launches. Normally the user's
# config picks it (`renderer: :vulkan` or `:gl`); setting it here overrides
# that. Tests use the OpenGL "-dbg" build, with AddressSanitizer and UBSan
# (the Vulkan one is tested by its own tests).
if config_env() == :test, do: config(:guiltty, renderer: "guiltty_gl-dbg")
