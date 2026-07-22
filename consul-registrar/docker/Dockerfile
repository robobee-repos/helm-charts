# lightweight but compatible base with apt for build deps
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=off \
    POETRY_VIRTUALENVS_CREATE=false

# Install build/runtime deps (for wheels that need compilation), and ca certs
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      gcc \
      libssl-dev \
      libffi-dev \
      ca-certificates \
      curl \
    && rm -rf /var/lib/apt/lists/*

# App directory
WORKDIR /app

# Copy dependency list and install
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# Copy the controller script and the entrypoint
COPY consul_k8s_registrar.py /app/consul_k8s_registrar.py
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Create a system user/group with UID/GID 1001 and own /app and entrypoint
RUN groupadd -g 1001 app \
  && useradd --no-create-home --uid 1001 --gid 1001 --shell /usr/sbin/nologin app \
  && chown -R 1001:1001 /app /usr/local/bin/docker-entrypoint.sh

USER app

# Entrypoint + default command
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["python", "/app/consul_k8s_registrar.py"]
