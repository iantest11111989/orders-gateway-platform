{{- /* Every resource is named after the app, which is the release name
     (Argo CD installs the chart as release <app>): Deployment hello-world,
     labelled app.kubernetes.io/name=hello-world, so several apps can share
     an environment's namespace. Named after the app on purpose,
     not "app" (docs/naming.md). */ -}}
{{- define "hello-world.name" -}}{{ .Release.Name }}{{- end -}}

{{- define "hello-world.selectorLabels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "hello-world.labels" -}}
{{ include "hello-world.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: platform-demo
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
env: {{ .Values.env }}
{{- end -}}

{{- define "hello-world.image" -}}
{{- $tag := required "image.tag is required (a published version such as 1.2.0, or a local-<time> build)" .Values.image.tag -}}
{{- with .Values.image.digest -}}
{{ $.Values.image.repository }}@{{ . }}
{{- else -}}
{{ .Values.image.repository }}:{{ $tag }}
{{- end -}}
{{- end -}}
