{{- /* Every resource is named "app": the platform expects a Deployment named app,
     labelled app.kubernetes.io/name=app, in each environment. */ -}}
{{- define "orders-gateway.name" -}}app{{- end -}}

{{- define "orders-gateway.selectorLabels" -}}
app.kubernetes.io/name: app
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "orders-gateway.labels" -}}
{{ include "orders-gateway.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: orders-gateway-platform
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
