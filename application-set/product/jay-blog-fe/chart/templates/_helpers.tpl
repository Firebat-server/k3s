{{/* Expand the chart name. */}}
{{- define "jay-blog-fe.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Create a stable fully qualified resource name. */}}
{{- define "jay-blog-fe.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Chart label value. */}}
{{- define "jay-blog-fe.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Common labels. */}}
{{- define "jay-blog-fe.labels" -}}
helm.sh/chart: {{ include "jay-blog-fe.chart" . }}
{{ include "jay-blog-fe.selectorLabels" . }}
app.kubernetes.io/component: frontend
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Immutable selector labels. */}}
{{- define "jay-blog-fe.selectorLabels" -}}
app.kubernetes.io/name: {{ include "jay-blog-fe.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
