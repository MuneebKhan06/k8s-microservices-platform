{{/*
Chart name, overridable so two releases of the same chart can coexist.
*/}}
{{- define "distributed-job-queue.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified release name, capped at the 63 character Kubernetes limit.
*/}}
{{- define "distributed-job-queue.fullname" -}}
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

{{- define "distributed-job-queue.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Labels shared by every object in the chart.
*/}}
{{- define "distributed-job-queue.labels" -}}
helm.sh/chart: {{ include "distributed-job-queue.chart" . }}
{{ include "distributed-job-queue.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: k8s-microservices-platform
{{- end }}

{{/*
Base selector labels. Two Deployments (api and worker) live in this chart,
so component-specific templates append app.kubernetes.io/component on top
of these rather than redefining name/instance.
*/}}
{{- define "distributed-job-queue.selectorLabels" -}}
app.kubernetes.io/name: {{ include "distributed-job-queue.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels for the API Deployment specifically.
*/}}
{{- define "distributed-job-queue.apiSelectorLabels" -}}
{{ include "distributed-job-queue.selectorLabels" . }}
app.kubernetes.io/component: api
{{- end }}

{{/*
Selector labels for the worker Deployment specifically.
*/}}
{{- define "distributed-job-queue.workerSelectorLabels" -}}
{{ include "distributed-job-queue.selectorLabels" . }}
app.kubernetes.io/component: worker
{{- end }}
