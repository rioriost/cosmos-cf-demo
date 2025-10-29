#!/bin/sh

# Exit on any error
set -e

# Determine the port on which the internal Python API should listen.
# If API_PORT is not set in the environment, default to 9000.
API_PORT="${API_PORT:-9000}"

# Launch the Python API in the background.  The Flask app binds to
# 0.0.0.0 so Grafana can reach it via localhost inside the container.
# Use the generic POSIX shell instead of Bash to improve portability.
python3 /app/visualizer.py --port "$API_PORT" &

# Start Grafana.  Invoke the grafana-server binary from PATH rather than
# hard-coding its location.  This accommodates Alpine-based images where
# grafana-server may reside under /usr/share/grafana/bin or elsewhere.  The
# --homepath and --packaging flags are required when running outside of the
# default entrypoint.  Logs are sent to stdout.
exec grafana-server --homepath=/usr/share/grafana --packaging=docker