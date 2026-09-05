---
name: manage-secrets
description: Add or change a secret in this cluster the right way — via an ExternalSecret backed by 1Password, never inline plaintext. Use when the user needs to give an app credentials, an API key, a token, or DB access, or asks "how do secrets work here".
---

# Manage secrets (External Secrets Operator + 1Password)

Secrets are never committed as plaintext or SealedSecrets. They live in 1Password and are pulled in by External Secrets Operator (ESO) via a `ClusterSecretStore` named `onepassword`. Manifests reference 1Password items; the actual values stay in the vault.

## Pattern (match the real repo — e.g. `budget/app`)

```yaml
---
# yaml-language-server: $schema=https://kube-schemas.pages.dev/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app>-app
spec:
  refreshInterval: 5m
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: <app>-secret            # the k8s Secret ESO creates
    creationPolicy: Owner
    template:
      engineVersion: v2
      metadata:
        annotations:
          reloader.stakater.com/auto: "true"   # roll pods when the secret changes
      data:
        SOME_ENV: "{{ .field_in_1password }}"
  dataFrom:
    - extract:
        key: <1password-item-name>    # pulls all fields from the item
```

Two ways to map fields:
- **`dataFrom.extract`** (preferred when you want all/most fields of an item) — fields become `{{ .fieldName }}` in the template.
- **`data[].remoteRef`** with `key: op://<vault>/<item>/<field>` for pulling one specific field.

The HelmRelease consumes it via `envFrom: [{ secretRef: { name: <app>-secret } }]` or individual `secretKeyRef`s.

## Rules

- **1Password is the source of truth.** To add/change a value, the field must exist in the 1Password item first. Do NOT invent field names — confirm the item/field with the user.
- **Never modify unrelated 1Password fields.** Editing a field or item beyond the exact ask has caused problems here — if a change would touch anything not explicitly requested, stop and confirm (see repo memory `feedback_scope_of_changes`).
- **Non-secret config stays inline** on the HelmRelease (URLs, ports, flags); only true secrets go through ESO.
- **DB credentials** for CNPG-backed apps come from the operator-generated `<app>-pguser-secret` (via the `cnpg` component), not a hand-written ExternalSecret — reference that secret directly.
- After changing an ExternalSecret, `task kubernetes:sync-secrets` forces a refresh; `reloader` restarts the consuming pods automatically.
- Never print secret values to logs or the terminal.
