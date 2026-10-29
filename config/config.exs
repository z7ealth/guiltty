import Config

# Start the default session when the application boots. Tests start their
# own sessions instead.
config :guiltty, autostart: config_env() != :test
