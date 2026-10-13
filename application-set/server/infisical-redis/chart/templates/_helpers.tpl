{{- define "infisical-redis.fullname" -}}
{{- .Values.fullnameOverride | default .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "infisical-redis.selectorLabels" -}}
app.kubernetes.io/name: infisical-redis
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "infisical-redis.labels" -}}
{{ include "infisical-redis.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end -}}
