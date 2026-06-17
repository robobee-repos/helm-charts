{{/* vim: set filetype=mustache: */}}

{{/*
Expand the name of the chart.
*/}}
{{- define "tlb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return the proper OpenLDAP image name
*/}}
{{- define "tlb.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper OpenLDAP metrics image name
*/}}
{{- define "tlb.metrics.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.metrics.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper OpenLDAP Docker Image Registry Secret Names
*/}}
{{- define "tlb.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.metrics.image) "global" .Values.global) -}}
{{- end -}}

{{/*
 Create the name of the service account to use
 */}}
{{- define "tlb.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (include "common.names.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Generate chart secret name
*/}}
{{- define "tlb.secretName" -}}
{{ default (include "tlb.name" .) .Values.existingSecret }}
{{- end -}}

{{/*
Returns the available value for certain key in an existing secret (if it exists),
otherwise it generates a random value.
*/}}
{{- define "getValueFromSecret" }}
{{- $len := (default 16 .Length) | int -}}
{{- $obj := (lookup "v1" "Secret" .Namespace .Name).data -}}
{{- if $obj }}
{{- index $obj .Key | b64dec -}}
{{- else -}}
{{- randAlphaNum $len -}}
{{- end -}}
{{- end }}

{{/*
Return OpenLDAP password
*/}}
{{- define "tlb.password" -}}
{{- if .Values.global.tlb.tlbPassword }}
    {{- .Values.global.tlb.tlbPassword -}}
{{- else if .Values.tlbPassword -}}
    {{- .Values.tlbPassword -}}
{{- else -}}
    {{- include "getValueFromSecret" (dict "Namespace" .Release.Namespace "Name" (include "common.names.fullname" .) "Length" 10 "Key" "tlb-password")  -}}
{{- end -}}
{{- end -}}

{{/*
Return OpenLDAP replication password
*/}}
{{- define "tlb.replication.password" -}}
{{- if .Values.global.tlb.replicationPassword }}
    {{- .Values.global.tlb.replicationPassword -}}
{{- else if .Values.replication.password -}}
    {{- .Values.replication.password -}}
{{- else -}}
    {{- include "getValueFromSecret" (dict "Namespace" .Release.Namespace "Name" (include "common.names.fullname" .) "Length" 10 "Key" "tlb-replication-password")  -}}
{{- end -}}
{{- end -}}

{{/*
Return true if we should use an existingSecret.
*/}}
{{- define "tlb.useExistingSecret" -}}
{{- if .Values.existingSecret -}}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Return true if a secret object should be created
*/}}
{{- define "tlb.createSecret" -}}
{{- if not (include "tlb.useExistingSecret" .) -}}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Get the configuration ConfigMap name.
*/}}
{{- define "tlb.configurationCM" -}}
{{- if .Values.configurationConfigMap -}}
{{- printf "%s" (tpl .Values.configurationConfigMap $) -}}
{{- else -}}
{{- printf "%s-configuration" (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Get the extended configuration ConfigMap name.
*/}}
{{- define "tlb.extendedConfigurationCM" -}}
{{- if .Values.extendedConfConfigMap -}}
{{- printf "%s" (tpl .Values.extendedConfConfigMap $) -}}
{{- else -}}
{{- printf "%s-extended-configuration" (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Return true if a configmap should be mounted with OpenLDAP configuration
*/}}
{{- define "tlb.mountConfigurationCM" -}}
{{- if or (.Files.Glob "files/tlb.conf") (.Files.Glob "files/pg_hba.conf") .Values.tlbConfiguration .Values.pgHbaConfiguration .Values.configurationConfigMap }}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Get the initialization scripts ConfigMap name.
*/}}
{{- define "tlb.initdbScriptsCM" -}}
{{- if .Values.initdbScriptsConfigMap -}}
{{- printf "%s" (tpl .Values.initdbScriptsConfigMap $) -}}
{{- else -}}
{{- printf "%s-init-scripts" (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Get the initialization scripts Secret name.
*/}}
{{- define "tlb.initdbScriptsSecret" -}}
{{- printf "%s" (tpl .Values.initdbScriptsSecret $) -}}
{{- end -}}

{{/*
Get the metrics ConfigMap name.
*/}}
{{- define "tlb.metricsCM" -}}
{{- printf "%s-metrics" (include "common.names.fullname" .) -}}
{{- end -}}

{{/*
Get the readiness probe command
*/}}
{{- define "tlb.readinessProbeCommand" -}}
- |
{{- if (include "tlb.database" .) }}
  exec pg_isready -U {{ include "tlb.username" . | quote }} -d "dbname={{ include "tlb.database" . }} {{- if .Values.tls.enabled }} sslcert={{ include "tlb.tlsCert" . }} sslkey={{ include "tlb.tlsCertKey" . }}{{- end }}" -h 127.0.0.1 -p {{ .Values.containerPorts.tlb }}
{{- else }}
  exec pg_isready -U {{ include "tlb.username" . | quote }} {{- if .Values.tls.enabled }} -d "sslcert={{ include "tlb.tlsCert" . }} sslkey={{ include "tlb.tlsCertKey" . }}"{{- end }} -h 127.0.0.1 -p {{ .Values.containerPorts.tlb }}
{{- end }}
{{- if contains "bitnami/" .Values.image.repository }}
  [ -f /opt/bitnami/tlb/tmp/.initialized ] || [ -f /bitnami/tlb/.initialized ]
{{- end -}}
{{- end -}}

{{/*
Compile all warnings into a single message, and call fail.
*/}}
{{- define "tlb.validateValues" -}}
{{- $messages := list -}}
{{- $messages := append $messages (include "tlb.validateValues.psp" .) -}}
{{- $messages := append $messages (include "tlb.validateValues.tls" .) -}}
{{- $messages := without $messages "" -}}
{{- $message := join "\n" $messages -}}

{{- if $message -}}
{{- printf "\nVALUES VALIDATION:\n%s" $message | fail -}}
{{- end -}}
{{- end -}}

{{/*
Validate values of OpenLDAP - If PSP is enabled RBAC should be enabled too
*/}}
{{- define "tlb.validateValues.psp" -}}
{{- if and .Values.psp.create (not .Values.rbac.create) }}
tlb: psp.create, rbac.create
    RBAC should be enabled if PSP is enabled in order for PSP to work.
    More info at https://kubernetes.io/docs/concepts/policy/pod-security-policy/#authorizing-policies
{{- end -}}
{{- end -}}

{{/*
Validate values of OpenLDAP TLS - When TLS is enabled, so must be VolumePermissions
*/}}
{{- define "tlb.validateValues.tls" -}}
{{- if and .Values.tls.enabled (not .Values.volumePermissions.enabled) }}
tlb: tls.enabled, volumePermissions.enabled
    When TLS is enabled you must enable volumePermissions as well to ensure certificates files have
    the right permissions.
{{- end -}}
{{- end -}}

{{/*
Return the path to the cert file.
*/}}
{{- define "tlb.tlsCert" -}}
{{- if .Values.tls.autoGenerated }}
    {{- printf "/opt/bitnami/tlb/certs/tls.crt" -}}
{{- else -}}
    {{- required "Certificate filename is required when TLS in enabled" .Values.tls.certFilename | printf "/opt/bitnami/tlb/certs/%s" -}}
{{- end -}}
{{- end -}}

{{/*
Return the path to the cert key file.
*/}}
{{- define "tlb.tlsCertKey" -}}
{{- if .Values.tls.autoGenerated }}
    {{- printf "/opt/bitnami/tlb/certs/tls.key" -}}
{{- else -}}
{{- required "Certificate Key filename is required when TLS in enabled" .Values.tls.certKeyFilename | printf "/opt/bitnami/tlb/certs/%s" -}}
{{- end -}}
{{- end -}}

{{/*
Return the path to the CA cert file.
*/}}
{{- define "tlb.tlsCACert" -}}
{{- if .Values.tls.autoGenerated }}
    {{- printf "/opt/bitnami/tlb/certs/ca.crt" -}}
{{- else -}}
    {{- printf "/opt/bitnami/tlb/certs/%s" .Values.tls.certCAFilename -}}
{{- end -}}
{{- end -}}

{{/*
Return the path to the CRL file.
*/}}
{{- define "tlb.tlsCRL" -}}
{{- if .Values.tls.crlFilename -}}
{{- printf "/opt/bitnami/tlb/certs/%s" .Values.tls.crlFilename -}}
{{- end -}}
{{- end -}}

{{/*
Return true if a TLS credentials secret object should be created
*/}}
{{- define "tlb.createTlsSecret" -}}
{{- if and .Values.tls.autoGenerated (not .Values.tls.certificatesSecret) }}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Return the path to the CA cert file.
*/}}
{{- define "tlb.tlsSecretName" -}}
{{- if .Values.tls.autoGenerated }}
    {{- printf "%s-crt" (include "common.names.fullname" .) -}}
{{- else -}}
    {{ required "A secret containing TLS certificates is required when TLS is enabled" .Values.tls.certificatesSecret }}
{{- end -}}
{{- end -}}

{{/*
Check if there are rolling tags in the images
*/}}
{{- define "tlb.checkRollingTags" -}}
{{- include "common.warnings.rollingTag" .Values.image }}
{{- include "common.warnings.rollingTag" .Values.metrics.image }}
{{- end -}}
