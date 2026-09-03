# name=Dockerfile
FROM python:3.11-slim

# Install minimal extras
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create app directory and non-root user
ENV APP_DIR=/app
RUN mkdir -p ${APP_DIR} /data
WORKDIR ${APP_DIR}

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy app
COPY app.py .

# Use a non-root user
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser ${APP_DIR} /data
USER appuser

# Configurable envs:
# INTERVAL (seconds), OUTFILE (path), NAMESPACE, POD_REGEX, TRY_INCLUSTER_FIRST
ENV INTERVAL=60
ENV OUTFILE=/data/k8s_metrics.csv
ENV TRY_INCLUSTER_FIRST=true

VOLUME ["/data"]
CMD ["python", "app.py"]
