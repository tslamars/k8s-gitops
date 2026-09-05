---
name: debug-helmrelease
description: Systematically debug a failing or stuck Flux HelmRelease in this repo. Use when a HelmRelease is not Ready, Stalled, RetriesExceeded, stuck InProgress, or an app didn't update after a chart/image bump merged.
---

# Debug a HelmRelease

Work read-only first; only reconcile/rollback once you understand the cause. This repo delivers apps through the app-template OCIRepository and a nested `cluster-apps` → per-app Kustomization chain.

## 1. Get the real status message

```bash
flux get helmreleases -A --status-selector ready=false
kubectl describe helmrelease <app> -n <ns>
flux logs --kind=HelmRelease -n <ns> --name <app> --level=error
```

The `Ready` condition message almost always names the failure class. Map it:

| Message | Likely cause | Next step |
|---|---|---|
| `Running 'upgrade' action with timeout of Nm` | Still in progress (rolling upgrade) | Wait / watch — not failed |
| `timeout waiting for: [Deployment .. InProgress]` but pods are healthy | Helm "wait" hanging, not a pod problem | Check `kubectl get pods` — if healthy, it's a wait/probe issue |
| `install/upgrade retries exhausted` | Real failure, remediation gave up | Read the underlying error in the events/logs |
| `values don't meet the specifications` / schema error | Chart values incompatible after a bump | Compare chart's changed values keys |
| `chart pull error` / OCI errors | Source/registry problem | Check the OCIRepository/HelmRepository source |

## 2. Chart or image bump broke it?

A version bump is the most common cause here (see repo memory: external-dns, kromgo). Check for renamed **env vars**, **args/flags**, **values keys**, **probe paths/ports**. Compare the failing pod's actual error:

```bash
kubectl logs -n <ns> <pod> --previous     # crashloop reason
kubectl get pods -n <ns> -l app.kubernetes.io/name=<app>
```

Look for "unknown flag", "no X provided", missing-config, or probe failures. Cross-check the HelmRelease `args:`/`env:` against the new chart/app version's docs.

## 3. Did it even get delivered? (the nested-Kustomization gotcha)

If the change is merged to main but not live, reconciling `cluster-apps` alone is NOT enough — the per-app Kustomization can stay on an old revision. Force the specific one with its source:

```bash
flux reconcile kustomization <app> -n <ns> --with-source
```

## 4. Remediation (only after cause is understood, and with authorization)

- Config fix → edit the manifest on a feature branch, PR, merge (Flux applies). Never `kubectl edit` the live HelmRelease as a durable fix — it drifts from git.
- Force a retry after a fix: `flux reconcile helmrelease <app> -n <ns>`.
- Stuck upgrade needing a clean slate: check the HR's `upgrade.remediation` (some use `strategy: rollback`); suspend/resume only if you understand why.
- If a bad version needs reverting, revert in git (PR) — that's the source of truth — don't just roll back the Helm release in-cluster.

## Verify

After the fix reconciles: `flux get helmreleases -n <ns>` shows Ready=True, pods healthy, and (for external services) confirm with a direct in-cluster curl, not just the dashboard.
