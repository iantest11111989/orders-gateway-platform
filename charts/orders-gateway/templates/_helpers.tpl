{{- /* Every resource is named "app": the contract wants a Deployment named app,
     labelled app.kubernetes.io/name=app, in each environment (decision 0026). */ -}}
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
{{- $tag := required "image.tag is required (a sha-<12> tag from CI, or v1/v2/v2-bad)" .Values.image.tag -}}
{{- with .Values.image.digest -}}
{{ $.Values.image.repository }}@{{ . }}
{{- else -}}
{{ .Values.image.repository }}:{{ $tag }}
{{- end -}}
{{- end -}}
