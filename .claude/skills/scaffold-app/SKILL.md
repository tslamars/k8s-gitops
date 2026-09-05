---
name: scaffold-app
description: Scaffold a new application in this Flux homelab following the repo's exact convention (ks.yaml + app/ with kustomization.yaml + app-template HelmRelease, components, postBuild). Use when the user says "add a new app", "create the manifests for X", or "set up <service> in the cluster".
---

# Scaffold a new app

Create manifests under `kubernetes/apps/<namespace>/<app-name>/` matching the established pattern. Do this on a feature branch (`git checkout -b feature/add-<app>`), 2-space YAML, and open a PR — never commit to main.

## Directory layout

```
kubernetes/apps/<namespace>/<app-name>/
├── ks.yaml                     # Flux Kustomization
└── app/
    ├── kustomization.yaml
    ├── helmrelease.yaml
    └── resources/              # only if needed (ConfigMaps, ExternalSecret)
```

Then add the app to the namespace's parent `kustomization.yaml` (the one that lists `./` entries for each app's `ks.yaml`).

## ks.yaml

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app <app-name>
  namespace: &namespace <namespace>
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  interval: 1h
  path: ./kubernetes/apps/<namespace>/<app-name>/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: *namespace
  wait: true
  # dependsOn: [{ name: <dep> }]   # add if this app needs another Kustomization first
  # components:
  #   - ../../../../components/volsync   # for apps with a PVC needing backup
  # postBuild:
  #   substitute:
  #     APP: *app
```

## helmrelease.yaml (app-template / bjw-s)

Most apps use the shared `app-template` OCIRepository (chart 5.x). Match an existing app like `default/echo-server` or `default/blog` for the current chart version. Key structure: `controllers.<app>.containers.app` (image, env, probes, resources, securityContext), `service`, and a `route` block for Gateway API HTTPRoute (parentRef `envoy-external` for public, `envoy-internal` for LAN-only).

## Conventions to honor

- Externally-facing route → `parentRefs: [{ name: envoy-external, namespace: networking }]` and hostname `<app>.pipitonelabs.com`. Internal-only → `envoy-internal`.
- Add a Gatus check via the route annotation `gatus.home-operations.com/endpoint` (the gatus-sidecar auto-discovers HTTPRoutes).
- Secrets → ExternalSecret with `ClusterSecretStore` `onepassword` (see the manage-secrets skill), never inline plaintext.
- PVC-backed apps → include the `volsync` component for Restic backups.
- Set `securityContext` (runAsNonRoot, drop ALL caps, readOnlyRootFilesystem) as the other apps do.

## Verify before opening the PR

- `flux-local` runs in CI, but sanity-check locally if possible.
- Confirm the parent namespace `kustomization.yaml` references the new `ks.yaml`, or Flux will never pick it up.
