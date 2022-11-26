{{/*
Create a default fully qualified resource name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "res.fullname" -}}
{{- .Values.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return the appropriate apiVersion for res.
*/}}
{{- define "common.capabilities.job.apiVersion" -}}
{{- print "batch/v1" -}}
{{- end -}}

{{/*
Return the proper Redmine image name
*/}}
{{- define "res.image" -}}
{{- include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) -}}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "res.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image) "global" .Values.global) -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "res.serviceAccountName" -}}
{{- if .Values.serviceAccount }}
{{- if .Values.serviceAccount.create -}}
{{ default (include "common.names.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
{{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
*/}}
{{- define "mariadbjobs.rootPassword" -}}
{{- if .dbVariables.passwordVariable -}}
{{- print "${" .dbVariables.passwordVariable "}" -}}
{{- else -}}
{{ .db.password }}
{{- end -}}
{{- end -}}

{{/*
*/}}
{{- define "mariadbjobs.databasesCommand" -}}
{{- $values := .Values -}}
{{- range .Values.databases -}}
mysql -h {{ $values.db.host }} -P {{ $values.db.port }} -u{{ $values.db.user }} -p{{ include "mariadbjobs.rootPassword" $values }} -e "CREATE DATABASE IF NOT EXISTS \`{{ . }}\`;";
{{- end -}}
{{- end -}}

{{/*
*/}}
{{- define "mariadbjobs.usersCommand" -}}
{{- $values := .Values -}}
{{- range .Values.users -}}
{{- $user := . -}}
{{- if not $user.hosts -}}
{{- $user := merge $user (dict "hosts" (list "%")) -}}
{{- end -}}
{{- range $user.hosts -}}
{{- $host := . -}}
mysql -h {{ $values.db.host }} -P {{ $values.db.port }} -u{{ $values.db.user }} -p{{ include "mariadbjobs.rootPassword" $values }} -e "CREATE USER IF NOT EXISTS \`{{ $user.name }}\`@'{{ $host }}' IDENTIFIED BY '{{ $user.password }}';";
{{- end -}}
{{- range .databases -}}
{{- $db := . -}}
{{- range $user.hosts -}}
{{- $host := . -}}
mysql -h {{ $values.db.host }} -P {{ $values.db.port }} -u{{ $values.db.user }} -p{{ include "mariadbjobs.rootPassword" $values }} -e "GRANT ALL PRIVILEGES ON \`{{ $db }}\`.* TO \`{{ $user.name }}\`@'{{ $host }}';";
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
