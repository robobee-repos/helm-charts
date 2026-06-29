{{/*
Defines ACME Staging ClusterIssuer.
https://cert-manager.io/docs/configuration/acme/
*/}}
{{- define "certsissuers.acme.issuer.staging" -}}
{{ include "certsissuers.acme.issuer.general" (deepCopy $ | merge (dict "defaults" .Values.defaultsAcmeStaging)) }}
{{- end -}}

{{/*
Defines ACME Production ClusterIssuer.
https://cert-manager.io/docs/configuration/acme/
*/}}
{{- define "certsissuers.acme.issuer.prod" -}}
{{ include "certsissuers.acme.issuer.general" (deepCopy $ | merge (dict "defaults" .Values.defaultsAcmeProd)) }}
{{- end -}}

{{/*
Defines ACME ClusterIssuer.
https://cert-manager.io/docs/configuration/acme/
*/}}
{{- define "certsissuers.acme.issuer.general" -}}
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: {{ default .defaults.name .issuer.name }}
spec:
  acme:
    email: {{ .issuer.email }}
    server: {{ default .defaults.server .issuer.server }}
    privateKeySecretRef:
      name: {{ default .defaults.name .issuer.name }}
    solvers:
{{- if .issuer.solvers }}
{{- range .issuer.solvers }}
{{- include "certsissuers.acme.solvers" . | indent 4 }}
{{- end }}
{{- else }}
{{- range .defaults.solvers }}
{{- include "certsissuers.acme.solvers" . | indent 4 }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Defines ACMEChallengeSolver.
https://cert-manager.io/docs/reference/api-docs/#acme.cert-manager.io/v1.ACMEChallengeSolver
*/}}
{{- define "certsissuers.acme.solvers" -}}
{{- if .http01 }}
- http01:
  {{- if .http01.ingress }}
    ingress:
      class: {{ .http01.ingress.class }}
{{- end }}
  {{- if .http01.gatewayHTTPRoute }}
    gatewayHTTPRoute:
      {{- if .http01.gatewayHTTPRoute.serviceType }}
      serviceType: {{ .http01.gatewayHTTPRoute.serviceType }}
      {{- end }}
      {{- if .http01.gatewayHTTPRoute.labels }}
      labels:
        {{- toYaml .http01.gatewayHTTPRoute.labels | nindent 8 }}
      {{- end }}
      {{- if .http01.gatewayHTTPRoute.parentRefs }}
      parentRefs:
        {{- toYaml .http01.gatewayHTTPRoute.parentRefs | nindent 8 }}
      {{- end }}
      {{- if .http01.gatewayHTTPRoute.podTemplate }}
      podTemplate:
        {{- toYaml .http01.gatewayHTTPRoute.podTemplate | nindent 8 }}
      {{- end }}
{{- end }}
{{- end }}
{{- end -}}
