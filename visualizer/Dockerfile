FROM python:3.13-slim

# Set the working directory inside the container
WORKDIR /app

# Install Python dependencies
# Copy requirements file first to leverage Docker layer caching when only
# application code changes.
COPY app/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Copy the application source code
COPY app/ ./

# Expose the port that the Flask app will listen on.  Azure Container Apps
# reads the port either from the container app definition or from this
# Dockerfile.  The port value must match the targetPort specified in the
# Bicep configuration (8080).
EXPOSE 8080

# Run the visualizer application.  Use unbuffered output so logs appear
# immediately in the container logs.
CMD ["python", "-u", "visualizer.py"]