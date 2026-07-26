FROM haproxy:3.4

USER root

ARG CONSUL_TEMPLATE_VERSION=0.42.1

# Install required tools and create non-root user/group 1001
RUN apt-get update \
 && apt-get install -y --no-install-recommends wget unzip ca-certificates \
 && groupadd -g 1001 app \
 && useradd --no-create-home --uid 1001 --gid 1001 --shell /usr/sbin/nologin app \
 && mkdir -p /app /templates /etc/haproxy /var/run /var/log/haproxy \
 && chown -R 1001:1001 /app /templates /etc/haproxy /var/run /var/log/haproxy \
 && rm -rf /var/lib/apt/lists/*

# Install consul-template (unpack to /usr/local/bin)
RUN wget -q -O /tmp/consul-template.zip "https://releases.hashicorp.com/consul-template/${CONSUL_TEMPLATE_VERSION}/consul-template_${CONSUL_TEMPLATE_VERSION}_linux_amd64.zip" \
 && unzip /tmp/consul-template.zip -d /usr/local/bin \
 && chmod +x /usr/local/bin/consul-template \
 && rm -f /tmp/consul-template.zip

# Copy entrypoint and reload helper, set permissions and ownership for non-root user
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY haproxy_reload.sh /usr/local/bin/haproxy_reload.sh

RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/haproxy_reload.sh \
 && chown 1001:1001 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/haproxy_reload.sh

# If you want to COPY a default template at build time, use --chown with BuildKit:
# COPY --chown=1001:1001 haproxy.ctmpl /templates/haproxy.ctmpl

# Ensure ownership of /etc/haproxy and other runtime dirs (again, in case of earlier copies)
RUN chown -R 1001:1001 /etc/haproxy /templates /var/run /var/log/haproxy

# Switch to non-root user
USER 1001:1001

WORKDIR /app

# Expose high port so non-root can bind (we use 8080)
EXPOSE 8080

# Entrypoint uses consul-template and haproxy and expects env vars as described in entrypoint
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
