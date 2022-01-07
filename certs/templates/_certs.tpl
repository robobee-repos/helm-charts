{{/*
Defines Certificate.
https://cert-manager.io/docs/usage/certificate/
*/}}
{{- define "certs.certificate" -}}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .cert.name }}
  namespace: {{ .Release.Namespace | quote }}
spec:
  secretName: {{ default (print .cert.name "-tls") .cert.secretName }}
{{- if .cert.duration }}
  duration: {{ .cert.duration }}
{{- end }}
{{- if .cert.renewBefore }}
  renewBefore: {{ .cert.renewBefore }}
{{- end }}
{{- if .cert.subject }}
  subject:
    {{ toYaml .cert.subject }}
{{- end }}
  # At least one of a DNS Name, URI, or IP address is required.
{{- if .cert.dnsNames }}
  dnsNames:
{{- range .cert.dnsNames }}
    - {{ . }}
{{- end }}
{{- end }}
{{- if .cert.dnsNames }}
  uris:
{{- range .cert.uris }}
    - {{ . }}
{{- end }}
{{- end }}
{{- if .cert.ipAddresses }}
  ipAddresses:
{{- range .cert.ipAddresses }}
    - {{ . }}
{{- end }}
{{- end }}
  # Issuer references are always required.
  issuerRef:
    name: {{ .cert.issuer.name }}
    # We can reference ClusterIssuers by changing the kind here.
    # The default value is Issuer (i.e. a locally namespaced Issuer)
    kind: {{ default "Issuer" .cert.issuer.kind }}
    # This is optional since cert-manager will default to this value however
    # if you are using an external issuer, change this to that issuer group.
    group: {{ default "cert-manager.io" .cert.issuer.group }}
{{- end -}}
