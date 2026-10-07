{{- define "odoo-dr.labels" -}}
app.kubernetes.io/part-of: odoo-dr
validatedpatterns.io/pattern: {{ .Values.global.pattern | default "sleeping-through-disasters" }}
{{- end }}

{{/* Data-plane protection: Argo CD must never delete or prune these, not on
     prune and not when the Application itself is deleted. They hold
     customer data. */}}
{{- define "odoo-dr.protect" -}}
argocd.argoproj.io/sync-options: Prune=false,Delete=false
{{- end }}
