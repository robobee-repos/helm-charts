{{/* vim: set filetype=mustache: */}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "matomo.mariadb.fullname" -}}
{{- include "common.names.dependency.fullname" (dict "chartName" "mariadb" "chartValues" .Values.mariadb "context" $) -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "matomo.memcached.fullname" -}}
{{- include "common.names.dependency.fullname" (dict "chartName" "memcached" "chartValues" .Values.memcached "context" $) -}}
{{- end -}}

{{/*
Return the proper Matomo image name
*/}}
{{- define "matomo.image" -}}
{{- include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) -}}
{{- end -}}

{{/*
Return the proper image name (for the init container volume-permissions image)
*/}}
{{- define "matomo.volumePermissions.image" -}}
{{- include "common.images.image" ( dict "imageRoot" .Values.volumePermissions.image "global" .Values.global ) -}}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "matomo.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.volumePermissions.image) "global" .Values.global) -}}
{{- end -}}

{{/*
 Create the name of the service account to use
 */}}
{{- define "matomo.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (include "common.names.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "matomo.customHTAccessCM" -}}
{{- printf "%s" .Values.customHTAccessCM -}}
{{- end -}}

{{/*
Return the Matomo configuration secret
*/}}
{{- define "matomo.configSecretName" -}}
{{- if .Values.existingMatomoConfigurationSecret -}}
    {{- printf "%s" (tpl .Values.existingMatomoConfigurationSecret $) -}}
{{- else -}}
    {{- printf "%s-configuration" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Return true if a secret object should be created for Matomo configuration
*/}}
{{- define "matomo.createConfigSecret" -}}
{{- if and .Values.matomoConfiguration (not .Values.existingMatomoConfigurationSecret) }}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Return the Matomo Apache configuration configmap
*/}}
{{- define "matomo.apache.configmapName" -}}
{{- if .Values.existingApacheConfigurationConfigMap -}}
    {{- printf "%s" (tpl .Values.existingApacheConfigurationConfigMap $) -}}
{{- else -}}
    {{- printf "%s-apache-configuration" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Return true if a secret object should be created for Apache configuration
*/}}
{{- define "matomo.apache.createConfigmap" -}}
{{- if and .Values.apacheConfiguration (not .Values.existingApacheConfigurationConfigMap) }}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Return the MariaDB Hostname
*/}}
{{- define "matomo.databaseHost" -}}
{{- if .Values.mariadb.enabled }}
    {{- if eq .Values.mariadb.architecture "replication" }}
        {{- printf "%s-primary" (include "matomo.mariadb.fullname" .) | trunc 63 | trimSuffix "-" -}}
    {{- else -}}
        {{- printf "%s" (include "matomo.mariadb.fullname" .) -}}
    {{- end -}}
{{- else -}}
    {{- printf "%s" .Values.externalDatabase.host -}}
{{- end -}}
{{- end -}}

{{/*
Return the MariaDB Port
*/}}
{{- define "matomo.databasePort" -}}
{{- if .Values.mariadb.enabled }}
    {{- printf "3306" -}}
{{- else -}}
    {{- printf "%d" (.Values.externalDatabase.port | int ) -}}
{{- end -}}
{{- end -}}

{{/*
Return the MariaDB Database Name
*/}}
{{- define "matomo.databaseName" -}}
{{- if .Values.mariadb.enabled }}
    {{- printf "%s" .Values.mariadb.auth.database -}}
{{- else -}}
    {{- printf "%s" .Values.externalDatabase.database -}}
{{- end -}}
{{- end -}}

{{/*
Return the MariaDB User
*/}}
{{- define "matomo.databaseUser" -}}
{{- if .Values.mariadb.enabled }}
    {{- printf "%s" .Values.mariadb.auth.username -}}
{{- else -}}
    {{- printf "%s" .Values.externalDatabase.user -}}
{{- end -}}
{{- end -}}

{{/*
Return the MariaDB Secret Name
*/}}
{{- define "matomo.databaseSecretName" -}}
{{- if .Values.mariadb.enabled }}
    {{- if .Values.mariadb.auth.existingSecret -}}
        {{- printf "%s" .Values.mariadb.auth.existingSecret -}}
    {{- else -}}
        {{- printf "%s" (include "matomo.mariadb.fullname" .) -}}
    {{- end -}}
{{- else if .Values.externalDatabase.existingSecret -}}
    {{- include "common.tplvalues.render" (dict "value" .Values.externalDatabase.existingSecret "context" $) -}}
{{- else -}}
    {{- printf "%s-externaldb" (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Return the Memcached Hostname
*/}}
{{- define "matomo.cacheHost" -}}
{{- if .Values.memcached.enabled }}
    {{- $releaseNamespace := .Release.Namespace }}
    {{- $clusterDomain := .Values.clusterDomain }}
    {{- printf "%s.%s.svc.%s" (include "matomo.memcached.fullname" .) $releaseNamespace $clusterDomain -}}
{{- else -}}
    {{- printf "%s" .Values.externalCache.host -}}
{{- end -}}
{{- end -}}

{{/*
Return the Memcached Port
*/}}
{{- define "matomo.cachePort" -}}
{{- if .Values.memcached.enabled }}
    {{- printf "11211" -}}
{{- else -}}
    {{- printf "%d" (.Values.externalCache.port | int ) -}}
{{- end -}}
{{- end -}}

{{/*
Return the Matomo Secret Name
*/}}
{{- define "matomo.secretName" -}}
{{- if .Values.existingSecret }}
    {{- printf "%s" .Values.existingSecret -}}
{{- else -}}
    {{- printf "%s" (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Return the SMTP Secret Name
*/}}
{{- define "matomo.smtpSecretName" -}}
{{- if .Values.smtpExistingSecret }}
    {{- printf "%s" .Values.smtpExistingSecret -}}
{{- else -}}
    {{- printf "%s" (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Compile all warnings into a single message.
*/}}
{{- define "matomo.validateValues" -}}
{{- $messages := list -}}
{{- $messages := append $messages (include "matomo.validateValues.configuration" .) -}}
{{- $messages := append $messages (include "matomo.validateValues.htaccess" .) -}}
{{- $messages := append $messages (include "matomo.validateValues.database" .) -}}
{{- $messages := append $messages (include "matomo.validateValues.cache" .) -}}
{{- $messages := without $messages "" -}}
{{- $message := join "\n" $messages -}}
{{- if $message -}}
{{-   printf "\nVALUES VALIDATION:\n%s" $message | fail -}}
{{- end -}}
{{- end -}}

{{/*
Validate values of Matomo - Custom wp-config.php
*/}}
{{- define "matomo.validateValues.configuration" -}}
{{- if and (or .Values.matomoConfiguration .Values.existingMatomoConfigurationSecret) (not .Values.matomoSkipInstall) -}}
matomo: matomoConfiguration
    You are trying to use a wp-config.php file. This setup is only supported
    when skipping wizard installation (--set matomoSkipInstall=true).
{{- end -}}
{{- end -}}

{{/*
Validate values of Matomo - htaccess configuration
*/}}
{{- define "matomo.validateValues.htaccess" -}}
{{- if and .Values.customHTAccessCM .Values.allowOverrideNone -}}
matomo: customHTAccessCM
    You are trying to use custom htaccess rules but Apache was configured
    to prohibit overriding directives with htaccess files. To use this feature,
    allow overriding Apache directives (--set allowOverrideNone=false).
{{- end -}}
{{- end -}}

{{/* Validate values of Matomo - Database */}}
{{- define "matomo.validateValues.database" -}}
{{- if and (not .Values.mariadb.enabled) (or (empty .Values.externalDatabase.host) (empty .Values.externalDatabase.port) (empty .Values.externalDatabase.database)) -}}
matomo: database
   You disable the MariaDB installation but you did not provide the required parameters
   to use an external database. To use an external database, please ensure you provide
   (at least) the following values:

       externalDatabase.host=DB_SERVER_HOST
       externalDatabase.database=DB_NAME
       externalDatabase.port=DB_SERVER_PORT
{{- end -}}
{{- end -}}
