FROM grafana/grafana:10.2.3

# Install the Infinity data source plugin so Grafana can fetch JSON over HTTP.
ENV GF_INSTALL_PLUGINS="yesoreyeram-infinity-datasource"

# Copy provisioning configuration and dashboards into the Grafana image.  These
# files preconfigure the Infinity data source and create a simple dashboard on
# startup.  Grafana automatically loads any .yml files under
# /etc/grafana/provisioning and JSON dashboards under /var/lib/grafana/dashboards.
COPY provisioning/datasources /etc/grafana/provisioning/datasources
COPY provisioning/dashboards /etc/grafana/provisioning/dashboards
COPY dashboards /var/lib/grafana/dashboards

# Expose the default Grafana port
EXPOSE 3000

# Start Grafana.  The base image already defines the entrypoint and command,
# so there is no need to override it here.