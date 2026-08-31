{{/*
Chart name, overridable so two releases of the same chart can coexist.
*/}}
{{- define "event-ingestion-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified release name. Kubernetes object names cap at 63 characters,
so everything gets truncated. When the release name already contains the
chart name, prefixing it again just produces event-ingestion-api-event-ingestion-api.
*/}}
{{- define "event-ingestion-api.fullname" -}}
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

{{- define "event-ingestion-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Labels applied to every object the chart creates. app.kubernetes.io/version
and helm.sh/chart change on upgrade, which is why they are kept out of the
selector below.
*/}}
{{- define "event-ingestion-api.labels" -}}
helm.sh/chart: {{ include "event-ingestion-api.chart" . }}
{{ include "event-ingestion-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: k8s-microservices-platform
{{- end }}

{{/*
Selector labels only. A Deployment's selector is immutable after creation,
so these two labels must never change for the life of the release.
*/}}
{{- define "event-ingestion-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "event-ingestion-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
