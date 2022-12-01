{{/*
Create a default fully qualified postgresql name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "gitea.postgresql.fullname" -}}
{{- include "common.names.dependency.fullname" (dict "chartName" "postgresql" "chartValues" .Values.postgresql "context" $) -}}
{{- end -}}

{{/*
Return the proper Gitea image name
*/}}
{{- define "gitea.image" -}}
{{- include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) -}}
{{- end -}}

{{/*
Return the proper image name (for the init container volume-permissions image)
*/}}
{{- define "gitea.volumePermissions.image" -}}
{{- include "common.images.image" ( dict "imageRoot" .Values.volumePermissions.image "global" .Values.global ) -}}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "gitea.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.volumePermissions.image) "global" .Values.global) -}}
{{- end -}}

{{/*
Return  the proper Storage Class
*/}}
{{- define "gitea.storageClass" -}}
{{- include "common.storage.class" (dict "persistence" .Values.persistence "global" .Values.global) -}}
{{- end -}}

{{/*
Gitea credential secret name
*/}}
{{- define "gitea.secretName" -}}
{{- coalesce .Values.existingSecret (include "common.names.fullname" .) -}}
{{- end -}}

{{/*
Gitea root URL
*/}}
{{- define "gitea.rootURL" -}}
{{- if .Values.rootURL -}}
    {{- print .Values.rootURL -}}
{{- else if .Values.ingress.enabled -}}
    {{- printf "http://%s" .Values.ingress.hostname -}}
{{- else if (and (eq .Values.service.type "LoadBalancer") .Values.service.loadBalancerIP) -}}
    {{- $url := printf "http://%s" .Values.service.loadBalancerIP -}}
    {{- $port:= .Values.service.ports.http | toString }}
    {{- if (ne $port "80") -}}
        {{- $url = printf "%s:%s" $url $port -}}
    {{- end -}}
    {{- print $url -}}
{{- end -}}
{{- end -}}

{{/*
 Create the name of the service account to use
 */}}
{{- define "gitea.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{- default (include "common.names.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
    {{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Gitea credential secret name
*/}}
{{- define "gitea.secretKey" -}}
{{- if .Values.existingSecret -}}
    {{- print .Values.existingSecretKey -}}
{{- else -}}
    {{- print "admin-password" -}}
{{- end -}}
{{- end -}}

{{/*
Return the SMTP Secret Name
*/}}
{{- define "gitea.smtpSecretName" -}}
{{- if .Values.smtpExistingSecret }}
    {{- print .Values.smtpExistingSecret -}}
{{- else -}}
    {{- print (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Return the PostgreSQL Hostname
*/}}
{{- define "gitea.databaseHost" -}}
{{- if .Values.postgresql.enabled -}}
              value:{{- print " " -}}
    {{- if eq .Values.postgresql.architecture "replication" }}
        {{- printf "%s-%s" (include "gitea.postgresql.fullname" .) "primary" | trunc 63 | trimSuffix "-" | quote -}}
    {{- else -}}
        {{- print (include "gitea.postgresql.fullname" .) | quote -}}
    {{- end -}}
{{- else -}}
    {{- if .Values.externalDatabase.host -}}
        {{- print .Values.externalDatabase.host -}}
    {{- else -}}
        {{- if .Values.externalDatabase.existingSecret -}}
              valueFrom:
                secretKeyRef:
                  name: {{ include "gitea.databaseSecretName" . }}
                  key: {{ include "gitea.databaseHostKey" . | quote }}
        {{- end -}}
    {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the PostgreSQL Port
*/}}
{{- define "gitea.databasePort" -}}
{{- if .Values.postgresql.enabled -}}
              value:{{- print " " -}}
    {{- print .Values.postgresql.primary.service.ports.postgresql | quote -}}
{{- else -}}
    {{- if .Values.externalDatabase.port -}}
        {{- print .Values.externalDatabase.port -}}
    {{- else -}}
        {{- if .Values.externalDatabase.existingSecret -}}
              valueFrom:
                secretKeyRef:
                  name: {{ include "gitea.databaseSecretName" . }}
                  key: {{ include "gitea.databasePortKey" . | quote }}
        {{- end -}}
    {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the PostgreSQL Database Name
*/}}
{{- define "gitea.databaseName" -}}
{{- if .Values.postgresql.enabled -}}
              value:{{- print " " -}}
    {{- print .Values.postgresql.auth.database | quote -}}
{{- else -}}
    {{- if .Values.externalDatabase.database -}}
        {{- print .Values.externalDatabase.database -}}
    {{- else -}}
        {{- if .Values.externalDatabase.existingSecret -}}
              valueFrom:
                secretKeyRef:
                  name: {{ include "gitea.databaseSecretName" . }}
                  key: {{ include "gitea.databaseDatabaseKey" . | quote }}
        {{- end -}}
    {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the PostgreSQL User
*/}}
{{- define "gitea.databaseUser" -}}
{{- if .Values.postgresql.enabled -}}
              value:{{- print " " -}}
    {{- print .Values.postgresql.auth.username | quote -}}
{{- else -}}
    {{- if .Values.externalDatabase.user -}}
        {{- print .Values.externalDatabase.user -}}
    {{- else -}}
        {{- if .Values.externalDatabase.existingSecret -}}
              valueFrom:
                secretKeyRef:
                  name: {{ include "gitea.databaseSecretName" . }}
                  key: {{ include "gitea.databaseUserKey" . | quote }}
        {{- end -}}
    {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the PostgreSQL Secret Name
*/}}
{{- define "gitea.databaseSecretName" -}}
{{- if .Values.postgresql.enabled }}
    {{- if .Values.postgresql.auth.existingSecret -}}
    {{- print .Values.postgresql.auth.existingSecret -}}
    {{- else -}}
    {{- print (include "gitea.postgresql.fullname" .) -}}
    {{- end -}}
{{- else if .Values.externalDatabase.existingSecret -}}
    {{- print .Values.externalDatabase.existingSecret -}}
{{- else -}}
    {{- printf "%s-%s" (include "common.names.fullname" .) "externaldb" -}}
{{- end -}}
{{- end -}}

{{/*
Return the database host key
*/}}
{{- define "gitea.databaseHostKey" -}}
{{- if .Values.postgresql.enabled -}}
{{- print "host" -}}
{{- else -}}
{{ print .Values.externalDatabase.existingSecretHostKey }}
{{- end -}}
{{- end -}}

{{/*
Return the database port key
*/}}
{{- define "gitea.databasePortKey" -}}
{{- if .Values.postgresql.enabled -}}
{{- print "port" -}}
{{- else -}}
{{ print .Values.externalDatabase.existingSecretPortKey }}
{{- end -}}
{{- end -}}

{{/*
Return the database user key
*/}}
{{- define "gitea.databaseUserKey" -}}
{{- if .Values.postgresql.enabled -}}
{{- print "user" -}}
{{- else -}}
{{ print .Values.externalDatabase.existingSecretUserKey }}
{{- end -}}
{{- end -}}

{{/*
Return the database database key
*/}}
{{- define "gitea.databaseDatabaseKey" -}}
{{- if .Values.postgresql.enabled -}}
{{- print "database" -}}
{{- else -}}
{{ print .Values.externalDatabase.existingSecretDatabaseKey }}
{{- end -}}
{{- end -}}

{{/*
Return the database password key
*/}}
{{- define "gitea.databasePasswordKey" -}}
{{- if .Values.postgresql.enabled -}}
{{- print "password" -}}
{{- else -}}
{{ print .Values.externalDatabase.existingSecretPasswordKey }}
{{- end -}}
{{- end -}}
