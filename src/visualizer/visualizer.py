import os
import time
from datetime import datetime, timezone
from typing import List, Tuple
from dotenv import load_dotenv
from azure.cosmos import CosmosClient

# Use matplotlib for plotting instead of relying on an external gnuplot
import matplotlib.pyplot as plt
import matplotlib.dates as mdates

load_dotenv()

COSMOSDB_ENDPOINT = os.environ["COSMOSDB_ENDPOINT"]
COSMOSDB_KEY = os.environ["COSMOSDB_KEY"]
DB_NAME = os.getenv("DATABASE_NAME", "sensors")
SUMMARIES = os.getenv("SUMMARIES_CONTAINER", "summaries")
POLL_SECONDS = int(os.getenv("POLL_SECONDS", "10"))
POINTS = int(os.getenv("POINTS", "120"))

def now_utc() -> str:
    """Return the current time in ISO8601 format (UTC)."""
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )

def fetch_points(client) -> List[Tuple[str, float, float, float]]:
    """Fetch the latest temperature summary points from the Cosmos DB container.

    Returns a list of tuples (timestamp, avg_temp, max_temp, min_temp) sorted by timestamp.
    """
    db = client.get_database_client(DB_NAME)
    cont = db.get_container_client(SUMMARIES)
    query = (
        f"SELECT TOP {POINTS} c.timestamp, c.avg_temp, c.max_temp, c.min_temp "
        f"FROM c ORDER BY c.timestamp DESC"
    )
    rows = list(cont.query_items(query=query, enable_cross_partition_query=True))
    # Reverse to have oldest first
    rows.reverse()
    return [
        (r["timestamp"], float(r["avg_temp"]), float(r["max_temp"]), float(r["min_temp"]))
        for r in rows
    ]

def plot_points(points: List[Tuple[str, float, float, float]]) -> None:
    """Plot the temperature summary using matplotlib.

    Args:
        points: A list of tuples (timestamp_str, avg_temp, max_temp, min_temp).
    """
    # Convert timestamps to Python datetime objects
    timestamps = []
    avg_values = []
    max_values = []
    min_values = []
    for ts, avg, mx, mn in points:
        try:
            # Replace 'Z' with '+00:00' for ISO parsing
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except ValueError:
            # Fallback: attempt naive parsing if timezone not provided
            dt = datetime.fromisoformat(ts)
        timestamps.append(dt)
        avg_values.append(avg)
        max_values.append(mx)
        min_values.append(mn)

    # Clear the current figure and plot new data
    plt.clf()
    # Plot each series
    plt.plot(timestamps, avg_values, label="avg")
    plt.plot(timestamps, max_values, label="max")
    plt.plot(timestamps, min_values, label="min")
    # Format axes
    plt.title("Temperature summary (avg/max/min)")
    plt.xlabel("Time (UTC)")
    plt.ylabel("Temperature (°C)")
    plt.grid(True)
    plt.legend(loc="best")
    # Improve date formatting on x-axis
    ax = plt.gca()
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M:%S"))
    plt.gcf().autofmt_xdate()
    # Draw the plot
    plt.tight_layout()
    plt.draw()

def main():
    """Entry point for the visualizer.

    Continuously polls the Cosmos DB summaries container and updates a matplotlib
    plot with the latest temperature statistics. The plot refreshes every
    POLL_SECONDS seconds.
    """
    # Initialize the Cosmos client
    client = CosmosClient(COSMOSDB_ENDPOINT, COSMOSDB_KEY)
    print("Visualizer started. Close the plot window to stop.")

    # Enable interactive mode so the plot updates without blocking
    plt.ion()

    # Create an initial figure
    plt.figure()

    while True:
        points = fetch_points(client)
        if not points:
            print(f"[{now_utc()}] No summary points yet. Waiting...")
            time.sleep(POLL_SECONDS)
            continue
        plot_points(points)
        # Pause for the polling interval to keep the GUI responsive
        plt.pause(POLL_SECONDS)

if __name__ == "__main__":
    main()
