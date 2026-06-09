{{/*
ignoreDifferences block for apps that use autoscaling.
Usage: {{- include "taskapp.ignoreDifferences" (dict "kind" "Deployment") | nindent 2 }}
*/}}
{{- define "taskapp.ignoreDifferences" -}}
ignoreDifferences:
  - group: apps
    kind: {{ .kind }}
    jsonPointers:
      - /spec/replicas
{{- end }}
