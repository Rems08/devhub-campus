{{/*
  Helpers communs au chart annuaire.
*/}}

{{- define "annuaire.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "annuaire.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "annuaire.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "annuaire.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  Labels obligatoires (polycopié, étape 4) :
    - app.kubernetes.io/name
    - app.kubernetes.io/instance
    - app.kubernetes.io/part-of: devhub-campus
    - app.kubernetes.io/managed-by: Helm
*/}}
{{- define "annuaire.labels" -}}
helm.sh/chart: {{ include "annuaire.chart" . }}
app.kubernetes.io/name: {{ include "annuaire.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: devhub-campus
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Sélecteur minimal stable (jamais modifié après création) */}}
{{- define "annuaire.selectorLabels" -}}
app.kubernetes.io/name: {{ include "annuaire.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Image complète, tag avec fallback sur appVersion */}}
{{- define "annuaire.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}
