{{/*
Global HaProxy configuration.
*/}}
{{- define "haproxy.configuration.global" -}}
global
    log stdout format raw local0
    maxconn 4000
    # generated 2022-01-04, Mozilla Guideline v5.6, HAProxy 2.1, OpenSSL 1.1.1k, intermediate configuration
    # https://ssl-config.mozilla.org/#server=haproxy&version=2.1&config=intermediate&openssl=1.1.1k&guideline=5.6
    # intermediate configuration
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-options prefer-client-ciphers no-sslv3 no-tlsv10 no-tlsv11 no-tls-tickets

    ssl-default-server-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
    ssl-default-server-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-server-options no-sslv3 no-tlsv10 no-tlsv11 no-tls-tickets

    # curl https://ssl-config.mozilla.org/ffdhe2048.txt > /path/to/dhparam
    ssl-dh-param-file /usr/local/etc/haproxy/dhparam
{{- end -}}

{{/*
Defaults HaProxy configuration.
*/}}
{{- define "haproxy.configuration.defaults" -}}
defaults
    mode http

    # See http://cbonte.github.io/haproxy-dconv/1.8/configuration.html#option%20http-server-close
    option http-server-close

    log global
    option httplog
    option dontlognull
    option http-server-close
    option redispatch
    retries 3
    timeout http-request 10s
    timeout queue 1m
    timeout client 1m
    timeout server 1m

    timeout check 10s 
    maxconn 3000

    # From http://stackoverflow.com/questions/21419859/configuring-haproxy-to-work-with-server-sent-events
    # Set the max time to wait for a connection attempt to a server to succeed  
    timeout connect 30s
    # handle a client suddenly disappearing from the net
    timeout client-fin 30s
    option http-server-close

    errorfile 400 /usr/local/etc/haproxy/400.http
    errorfile 403 /usr/local/etc/haproxy/403.http
    errorfile 408 /usr/local/etc/haproxy/408.http
    errorfile 500 /usr/local/etc/haproxy/500.http
    errorfile 502 /usr/local/etc/haproxy/502.http
    errorfile 503 /usr/local/etc/haproxy/503.http
    errorfile 504 /usr/local/etc/haproxy/504.http
{{- end -}}

{{/*
Stats Prometheus frontend.
*/}}
{{- define "haproxy.configuration.prometheus" -}}
frontend stats
   bind *:{{ .Values.metrics.port }}
   http-request use-service prometheus-exporter if { path /metrics }
   stats enable
   stats uri /stats
   stats refresh 10s
{{- end -}}
