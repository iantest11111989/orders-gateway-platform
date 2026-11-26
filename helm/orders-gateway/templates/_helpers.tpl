{{- /* Every resource is named after the app, which is the release name
     (Argo CD installs the chart as release <app>): Deployment orders-gateway,
     labelled app.kubernetes.io/name=orders-gateway, so several apps can share
     an environment's namespace. A deliberate deviation from the brief's
     Deployment "app" (docs/deviations-from-test.md). */ -}}
{{- define "orders-gateway.name" -}}{{ .Release.Name }}{{- end -}}

{{- define "orders-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "orders-gateway.labels" -}}
{{ include "orders-gateway.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: platform-demo
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
env: {{ .Values.env }}
{{- end -}}

{{- define "orders-gateway.image" -}}
{{- $tag := required "image.tag is required (a published version such as 1.2.0, or a local-<time> build)" .Values.image.tag -}}
{{- with .Values.image.digest -}}
{{ $.Values.image.repository }}@{{ . }}
{{- else -}}
{{ .Values.image.repository }}:{{ $tag }}
{{- end -}}
{{- end -}}
