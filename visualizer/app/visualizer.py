"""
Visualizer service for the Cosmos DB change feed demo.

This module starts a small Flask web application that reads summarised sensor
data from a Cosmos DB container and renders it as a plot using matplotlib.
The plot is served as a PNG image at `/plot.png`, and the root route `/` renders
a simple HTML page that references this image.  The page includes an auto-
refresh mechanism so that the graph updates every few seconds.
The service authenticates to Cosmos DB using the user-assigned managed
identity assigned to its container app via DefaultAzureCredential.

Environment variables expected by this application:

  - COSMOSDB_ENDPOINT: URI of the Cosmos DB account.
  - DATABASE_NAME: Name of the database containing the summaries container (default 'sensors').
  - SUMMARIES_CONTAINER: Name of the container holding summarised readings (default 'summaries').
  - AZURE_CLIENT_ID: Client ID of the user-assigned identity attached to this container app.
  - POLL_SECONDS: Interval in seconds at which the browser page refreshes (default '10').
  - POINTS: Number of most recent points to query from Cosmos DB (default '120').
  - PORT: Port to bind the Flask application to (default '8080').
"""

import io
import os
from datetime import datetime, timezone
from typing import List, Tuple

from flask import Flask, Response, jsonify
import matplotlib

# Use a non-interactive backend suitable for server environments
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates

from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient


# Read configuration from environment variables
COSMOSDB_ENDPOINT = os.environ["COSMOSDB_ENDPOINT"]
DB_NAME = os.environ.get("DATABASE_NAME", "sensors")
SUMMARIES = os.environ.get("SUMMARIES_CONTAINER", "summaries")
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "10"))
POINTS = int(os.environ.get("POINTS", "120"))
PORT = int(os.environ.get("PORT", "8080"))

# Define the list of sensors.  Each sensor will have its own plot.  If you
# change the number of sensors in the generator, update this list accordingly.
SENSOR_IDS = [f"sensor-{i}" for i in range(1, 6)]

# Initialize Cosmos client with managed identity credentials
credential = DefaultAzureCredential()
cosmos_client = CosmosClient(COSMOSDB_ENDPOINT, credential)
db_client = cosmos_client.get_database_client(DB_NAME)
container_client = db_client.get_container_client(SUMMARIES)


def fetch_points(sensor_id: str) -> Tuple[List[datetime], List[float], List[float], List[float]]:
    """Fetch the latest summary points for a specific sensor from the Cosmos DB container.

    Returns separate lists of timestamps, average, maximum and minimum
    temperatures sorted in ascending order.  If no data exists for the sensor,
    returns empty lists.
    """
    query = (
        f"SELECT TOP {POINTS} c.timestamp, c.avg_temp, c.max_temp, c.min_temp "
        f"FROM c WHERE c.sensor_id = @sid ORDER BY c.timestamp DESC"
    )
    params = [
        {"name": "@sid", "value": sensor_id},
    ]
    rows = list(
        container_client.query_items(
            query=query,
            parameters=params,
            enable_cross_partition_query=True,
        )
    )
    # Reverse the rows so that the earliest timestamp is first
    rows.reverse()

    timestamps: List[datetime] = []
    avg_values: List[float] = []
    max_values: List[float] = []
    min_values: List[float] = []

    for r in rows:
        ts_str: str = r.get("timestamp")
        try:
            dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        except Exception:
            try:
                dt = datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            except Exception:
                continue
        timestamps.append(dt)
        avg_values.append(float(r.get("avg_temp", 0)))
        max_values.append(float(r.get("max_temp", 0)))
        min_values.append(float(r.get("min_temp", 0)))
    return timestamps, avg_values, max_values, min_values


def create_plot(sensor_id: str) -> bytes:
    """Generate a PNG image of the latest summary data for a specific sensor.

    Returns the PNG image bytes.  If no data is available, a placeholder
    image with a message is returned.
    """
    ts, avg_vals, max_vals, min_vals = fetch_points(sensor_id)
    fig, ax = plt.subplots()
    if ts:
        ax.plot(ts, avg_vals, label="avg")
        ax.plot(ts, max_vals, label="max")
        ax.plot(ts, min_vals, label="min")
        # Format the x-axis as HH:MM:SS UTC
        ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M:%S"))
        fig.autofmt_xdate()
        ax.set_title(f"{sensor_id} temperature summary")
        ax.set_xlabel("Time (UTC)")
        ax.set_ylabel("Temperature (°C)")
        ax.grid(True)
        ax.legend(loc="best")
    else:
        ax.text(
            0.5,
            0.5,
            f"No data for {sensor_id}",
            ha="center",
            va="center",
            fontsize=14,
        )
        ax.set_axis_off()
    fig.tight_layout()
    buffer = io.BytesIO()
    fig.savefig(buffer, format="png")
    plt.close(fig)
    buffer.seek(0)
    return buffer.getvalue()


app = Flask(__name__)


@app.route('/')
def index():
    """Render the home page with a grid of sensor plots.

    The layout uses two columns.  Each sensor section includes a red indicator that
    becomes visible when new data is detected.  A small JavaScript snippet
    periodically fetches the latest summary timestamps and updates the
    corresponding plots and indicators when changes occur.
    """
    timestamp = datetime.now(timezone.utc).timestamp()
    # Build HTML for each sensor in a two-column grid
    grid_items = ""
    for sid in SENSOR_IDS:
        grid_items += f"""
        <div class='grid-item'>
            <h2>{sid}<span id='icon-{sid}' class='update-icon'>●</span></h2>
            <img id='plot-{sid}' src='/plot/{sid}.png?tick={timestamp}' alt='{sid} plot'>
        </div>
        """
    # Create the HTML page.  JavaScript polls the /api/summary-timestamps endpoint
    # every two seconds to detect updates.  When an update is detected for a
    # sensor, the corresponding image is reloaded and a red indicator is shown
    # briefly next to the sensor name.
    html = f"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <title>Temperature Summaries</title>
        <style>
            body {{ font-family: Arial, sans-serif; margin: 40px; }}
            h1 {{ text-align: center; }}
            .grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }}
            .grid-item {{ text-align: center; }}
            .grid-item img {{ max-width: 100%; height: auto; border: 1px solid #ccc; }}
            .update-icon {{ visibility: hidden; margin-left: 8px; color: red; }}
        </style>
    </head>
    <body>
        <h1>Temperature summaries (avg/max/min) per sensor</h1>
        <div class='grid'>
            {grid_items}
        </div>
        <script>
        const sensorIds = {SENSOR_IDS};
        let lastTimestamps = {{}};
        sensorIds.forEach(id => {{ lastTimestamps[id] = null; }});
        async function checkUpdates() {{
            try {{
                const resp = await fetch('/api/summary-timestamps');
                const data = await resp.json();
                sensorIds.forEach(id => {{
                    const ts = data[id];
                    // If first time or timestamp increased, update plot and show indicator
                    if (!lastTimestamps[id] || (ts && ts > lastTimestamps[id])) {{
                        const img = document.getElementById('plot-' + id);
                        img.src = '/plot/' + id + '.png?tick=' + Date.now();
                        lastTimestamps[id] = ts;
                        const icon = document.getElementById('icon-' + id);
                        icon.style.visibility = 'visible';
                        setTimeout(() => {{ icon.style.visibility = 'hidden'; }}, 3000);
                    }}
                }});
            }} catch (err) {{
                console.error('Error checking updates', err);
            }}
        }}
        // Check for updates every 2 seconds
        setInterval(checkUpdates, 2000);
        </script>
    </body>
    </html>
    """
    return html


@app.route('/plot/<sensor_id>.png')
def plot_png(sensor_id: str) -> Response:
    """Serve the latest plot for a specific sensor as a PNG image."""
    try:
        image_bytes = create_plot(sensor_id)
        return Response(image_bytes, mimetype='image/png')
    except Exception as ex:
        # Return a simple error image if something goes wrong
        fig, ax = plt.subplots()
        ax.text(
            0.5,
            0.5,
            f"Error generating plot for {sensor_id}:\n{ex}",
            ha='center',
            va='center',
            wrap=True,
        )
        ax.set_axis_off()
        buffer = io.BytesIO()
        fig.savefig(buffer, format="png")
        plt.close(fig)
        buffer.seek(0)
        return Response(buffer.getvalue(), mimetype='image/png')

# ------------------------------------------------------------------------------
# API endpoint: summary timestamps
#
# The JavaScript on the index page polls this endpoint to detect when new
# summaries have been written for each sensor.  The endpoint returns a JSON
# object mapping sensor IDs to their most recent summary timestamp.  If a
# sensor has no summaries yet, the value will be null.

@app.route('/api/summary-timestamps')
def api_summary_timestamps():
    """Return the latest summary timestamp for each sensor.

    Queries the summaries container for the most recent summary document
    corresponding to each sensor ID.  The result is a dictionary where each
    key is a sensor ID and each value is the timestamp string or None.
    """
    results = {}
    for sid in SENSOR_IDS:
        query = (
            "SELECT TOP 1 c.timestamp FROM c WHERE c.sensor_id = @sid ORDER BY c.timestamp DESC"
        )
        params = [
            {"name": "@sid", "value": sid},
        ]
        items = list(
            container_client.query_items(
                query=query,
                parameters=params,
                enable_cross_partition_query=True,
            )
        )
        if items:
            results[sid] = items[0].get("timestamp")
        else:
            results[sid] = None
    return jsonify(results)


if __name__ == '__main__':
    # When running locally, enable debug mode for easier troubleshooting.  Bind
    # to all interfaces so that Docker can expose the port.  Honour the PORT
    # environment variable so that the container app can configure the target port.
    app.run(host='0.0.0.0', port=PORT, debug=bool(os.environ.get('DEBUG', False)))