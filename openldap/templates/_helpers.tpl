{{/* vim: set filetype=mustache: */}}

{{/*
Expand the name of the chart.
*/}}
{{- define "openldap.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return the proper OpenLDAP image name
*/}}
{{- define "openldap.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper OpenLDAP metrics image name
*/}}
{{- define "openldap.metrics.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.metrics.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper image name (for the init container volume-permissions image)
*/}}
{{- define "openldap.volumePermissions.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.volumePermissions.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "openldap.imagePullSecrets" -}}
{{ include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.metrics.image .Values.volumePermissions.image) "global" .Values.global) }}
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
Return OpenLDAP postgres user password
*/}}
{{- define "openldap.postgres.password" -}}
{{- if .Values.global.openldap.openldapPostgresPassword }}
    {{- .Values.global.openldap.openldapPostgresPassword -}}
{{- else if .Values.openldapPostgresPassword -}}
    {{- .Values.openldapPostgresPassword -}}
{{- else -}}
    {{- include "getValueFromSecret" (dict "Namespace" .Release.Namespace "Name" (include "common.names.fullname" .) "Length" 10 "Key" "openldap-postgres-password")  -}}
{{- end -}}
{{- end -}}

{{/*
Return OpenLDAP password
*/}}
{{- define "openldap.password" -}}
{{- if .Values.global.openldap.openldapPassword }}
    {{- .Values.global.openldap.openldapPassword -}}
{{- else if .Values.openldapPassword -}}
    {{- .Values.openldapPassword -}}
{{- else -}}
    {{- include "getValueFromSecret" (dict "Namespace" .Release.Namespace "Name" (include "common.names.fullname" .) "Length" 10 "Key" "openldap-password")  -}}
{{- end -}}
{{- end -}}

{{/*
Return OpenLDAP replication password
*/}}
{{- define "openldap.replication.password" -}}
{{- if .Values.global.openldap.replicationPassword }}
    {{- .Values.global.openldap.replicationPassword -}}
{{- else if .Values.replication.password -}}
    {{- .Values.replication.password -}}
{{- else -}}
    {{- include "getValueFromSecret" (dict "Namespace" .Release.Namespace "Name" (include "common.names.fullname" .) "Length" 10 "Key" "openldap-replication-password")  -}}
{{- end -}}
{{- end -}}

{{/*
Return true if we should use an existingSecret.
*/}}
{{- define "openldap.useExistingSecret" -}}
{{- if .Values.existingSecret -}}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Return true if a secret object should be created
*/}}
{{- define "openldap.createSecret" -}}
{{- if not (include "openldap.useExistingSecret" .) -}}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Get the configuration ConfigMap name.
*/}}
{{- define "openldap.configurationCM" -}}
{{- if .Values.configurationConfigMap -}}
{{- printf "%s" (tpl .Values.configurationConfigMap $) -}}
{{- else -}}
{{- printf "%s-configuration" (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Get the extended configuration ConfigMap name.
*/}}
{{- define "openldap.extendedConfigurationCM" -}}
{{- if .Values.extendedConfConfigMap -}}
{{- printf "%s" (tpl .Values.extendedConfConfigMap $) -}}
{{- else -}}
{{- printf "%s-extended-configuration" (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Return true if a configmap should be mounted with OpenLDAP configuration
*/}}
{{- define "openldap.mountConfigurationCM" -}}
{{- if or (.Files.Glob "files/openldap.conf") (.Files.Glob "files/pg_hba.conf") .Values.openldapConfiguration .Values.pgHbaConfiguration .Values.configurationConfigMap }}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Get the initialization scripts ConfigMap name.
*/}}
{{- define "openldap.initdbScriptsCM" -}}
{{- if .Values.initdbScriptsConfigMap -}}
{{- printf "%s" (tpl .Values.initdbScriptsConfigMap $) -}}
{{- else -}}
{{- printf "%s-init-scripts" (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Get the initialization scripts Secret name.
*/}}
{{- define "openldap.initdbScriptsSecret" -}}
{{- printf "%s" (tpl .Values.initdbScriptsSecret $) -}}
{{- end -}}

{{/*
Get the metrics ConfigMap name.
*/}}
{{- define "openldap.metricsCM" -}}
{{- printf "%s-metrics" (include "common.names.fullname" .) -}}
{{- end -}}

{{/*
Get the readiness probe command
*/}}
{{- define "openldap.readinessProbeCommand" -}}
- |
{{- if (include "openldap.database" .) }}
  exec pg_isready -U {{ include "openldap.username" . | quote }} -d "dbname={{ include "openldap.database" . }} {{- if .Values.tls.enabled }} sslcert={{ include "openldap.tlsCert" . }} sslkey={{ include "openldap.tlsCertKey" . }}{{- end }}" -h 127.0.0.1 -p {{ .Values.containerPorts.openldap }}
{{- else }}
  exec pg_isready -U {{ include "openldap.username" . | quote }} {{- if .Values.tls.enabled }} -d "sslcert={{ include "openldap.tlsCert" . }} sslkey={{ include "openldap.tlsCertKey" . }}"{{- end }} -h 127.0.0.1 -p {{ .Values.containerPorts.openldap }}
{{- end }}
{{- if contains "bitnami/" .Values.image.repository }}
  [ -f /opt/bitnami/openldap/tmp/.initialized ] || [ -f /bitnami/openldap/.initialized ]
{{- end -}}
{{- end -}}

{{/*
Compile all warnings into a single message, and call fail.
*/}}
{{- define "openldap.validateValues" -}}
{{- $messages := list -}}
{{- $messages := append $messages (include "openldap.validateValues.ldapConfigurationMethod" .) -}}
{{- $messages := append $messages (include "openldap.validateValues.psp" .) -}}
{{- $messages := append $messages (include "openldap.validateValues.tls" .) -}}
{{- $messages := without $messages "" -}}
{{- $message := join "\n" $messages -}}

{{- if $message -}}
{{- printf "\nVALUES VALIDATION:\n%s" $message | fail -}}
{{- end -}}
{{- end -}}

{{/*
Validate values of Postgresql - If ldap.url is used then you don't need the other settings for ldap
*/}}
{{- define "openldap.validateValues.ldapConfigurationMethod" -}}
{{- if and .Values.ldap.enabled (and (not (empty .Values.ldap.url)) (not (empty .Values.ldap.server))) }}
openldap: ldap.url, ldap.server
    You cannot set both `ldap.url` and `ldap.server` at the same time.
    Please provide a unique way to configure LDAP.
    More info at https://www.openldap.org/docs/current/auth-ldap.html
{{- end -}}
{{- end -}}

{{/*
Validate values of Postgresql - If PSP is enabled RBAC should be enabled too
*/}}
{{- define "openldap.validateValues.psp" -}}
{{- if and .Values.psp.create (not .Values.rbac.create) }}
openldap: psp.create, rbac.create
    RBAC should be enabled if PSP is enabled in order for PSP to work.
    More info at https://kubernetes.io/docs/concepts/policy/pod-security-policy/#authorizing-policies
{{- end -}}
{{- end -}}

{{/*
Validate values of Postgresql TLS - When TLS is enabled, so must be VolumePermissions
*/}}
{{- define "openldap.validateValues.tls" -}}
{{- if and .Values.tls.enabled (not .Values.volumePermissions.enabled) }}
openldap: tls.enabled, volumePermissions.enabled
    When TLS is enabled you must enable volumePermissions as well to ensure certificates files have
    the right permissions.
{{- end -}}
{{- end -}}

{{/*
Return the path to the cert file.
*/}}
{{- define "openldap.tlsCert" -}}
{{- if .Values.tls.autoGenerated }}
    {{- printf "/opt/bitnami/openldap/certs/tls.crt" -}}
{{- else -}}
    {{- required "Certificate filename is required when TLS in enabled" .Values.tls.certFilename | printf "/opt/bitnami/openldap/certs/%s" -}}
{{- end -}}
{{- end -}}

{{/*
Return the path to the cert key file.
*/}}
{{- define "openldap.tlsCertKey" -}}
{{- if .Values.tls.autoGenerated }}
    {{- printf "/opt/bitnami/openldap/certs/tls.key" -}}
{{- else -}}
{{- required "Certificate Key filename is required when TLS in enabled" .Values.tls.certKeyFilename | printf "/opt/bitnami/openldap/certs/%s" -}}
{{- end -}}
{{- end -}}

{{/*
Return the path to the CA cert file.
*/}}
{{- define "openldap.tlsCACert" -}}
{{- if .Values.tls.autoGenerated }}
    {{- printf "/opt/bitnami/openldap/certs/ca.crt" -}}
{{- else -}}
    {{- printf "/opt/bitnami/openldap/certs/%s" .Values.tls.certCAFilename -}}
{{- end -}}
{{- end -}}

{{/*
Return the path to the CRL file.
*/}}
{{- define "openldap.tlsCRL" -}}
{{- if .Values.tls.crlFilename -}}
{{- printf "/opt/bitnami/openldap/certs/%s" .Values.tls.crlFilename -}}
{{- end -}}
{{- end -}}

{{/*
Return true if a TLS credentials secret object should be created
*/}}
{{- define "openldap.createTlsSecret" -}}
{{- if and .Values.tls.autoGenerated (not .Values.tls.certificatesSecret) }}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Return the path to the CA cert file.
*/}}
{{- define "openldap.tlsSecretName" -}}
{{- if .Values.tls.autoGenerated }}
    {{- printf "%s-crt" (include "common.names.fullname" .) -}}
{{- else -}}
    {{ required "A secret containing TLS certificates is required when TLS is enabled" .Values.tls.certificatesSecret }}
{{- end -}}
{{- end -}}
