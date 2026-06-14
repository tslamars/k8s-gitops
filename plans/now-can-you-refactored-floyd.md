# Self-host TradeForge on the home Kubernetes cluster — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Actionable steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move TradeForge off Vercel + Supabase + Clerk and run the whole stack (web, REST, realtime, reporter, Postgres, auth) on the existing Flux-managed home Kubernetes cluster, exposed publicly via Cloudflare Tunnel.

**Architecture:** A dedicated CloudNativePG cluster (`tradeforge-pg`) provides Postgres with logical replication. PostgREST replaces Supabase REST, `supabase/realtime` keeps the dashboard's `postgres_changes` subscription, a Deno container runs the existing reporter Edge Function, and an nginx container serves the built SPA. One Envoy `HTTPRoute` on `envoy-external` fans `/`, `/rest/v1`, `/realtime/v1`, `/functions/v1/ticino-reporter` to those four services. Auth moves from Clerk to the existing Authentik OIDC.

**Tech Stack:** Talos + Flux CD, CloudNativePG (PG17), Envoy Gateway + Cloudflared, External-Secrets + 1Password, Garage S3 (barman-cloud backups), Authentik OIDC, app-template Helm chart (bjw-s `5.0.1`), PostgREST `v12`, `supabase/realtime` `v2`, Deno, nginx.

---

## ⚠️ What changed since the original plan (2026-05-17 → 2026-05-25)

This plan supersedes the prior draft and the tradeforge `k8s-plan.md`. The following drift was verified in both repos and is already folded into the steps below:

**tradeforge repo (commits since 2026-05-17):**
1. **Migrations were fully restructured** (commit `37529ed`, 2026-05-23). The 17 old numbered files are gone; the set is now `0001_initial_schema.sql`, `0002_harden_rls_drop_public_read.sql`, `0003_reporter_rate_limit.sql` (+ `schema.sql`, `seed.sql`). → The old "backfill `011_ticino_user_secrets` / remove grants from `010`" task is **deleted** — `ticino_user_secrets` is fully defined in `0001`.
2. **New reporter dependency:** `0003` adds table `ticino_reporter_rate_limit` + RPC `ticino_reporter_rate_check`, which the reporter calls on failed auth. The DB bootstrap **must** include `0003` (it is **not** in `schema.sql`).
3. **Reporter health path is `GET /health`** (and `/`), **not `/healthz`**. Probes/verification updated accordingly. Reporter binds `0.0.0.0:8000` by default (bare `Deno.serve`).
4. **`REPORTER_URL` is still hardcoded** (now line ~12 of `TradeReporterSettings.tsx`) — still needs to become env-driven.
5. **New Clerk-coupled file:** `src/pages/landing/LandingPage.tsx` (public splash now at `/`). Added to the OIDC swap list. (`@clerk/themes` is not actually installed — ignore the "remove it" note.)
6. **Token injection point:** `src/services/supabase.ts` now forwards the token via the supabase-js `accessToken` callback calling `window.Clerk.session.getToken()`. The OIDC swap replaces *that callback*.
7. New low-impact features: Risk Calculator, Legal pages, Edit-Trade modal. `/` is now a public route.

**k8s-gitops repo (assumption corrections):**
8. ClusterSecretStore is named **`onepassword`**, not `onepassword-connect`.
9. Public exposure = attach the route to **`parentRef: envoy-external`** (namespace `networking`). There is **no per-route cloudflared annotation**; the wildcard tunnel (`*.pipitonelabs.com → envoy-external`) + external-dns `--gateway-name=envoy-external` filter do it automatically.
10. CNPG backups use the **barman-cloud plugin + a separate `ObjectStore` CR**, not inline `barmanObjectStore`. Garage endpoint `https://s3.pipitonelabs.com`, creds in secret `cloudnative-pg-secret` (keys `garage-aws-access-key-id` / `garage-aws-secret-access-key`).
11. Namespace dir is `networking`; app-template is `oci://ghcr.io/bjw-s-labs/helm/app-template` tag `5.0.1`; issuer `sso.pipitonelabs.com` and base domain `pipitonelabs.com` confirmed.

**Two showstoppers the original plan never addressed (now Phase 3):**
12. **RLS depends on `auth.jwt()`** (40+ uses). Supabase provides the `auth` schema + `auth.jwt()`; a bare CNPG + PostgREST stack does not. Without a compat shim, **every authenticated query and the reporter's writes fail.** Fixed by `00-supabase-compat.sql` below.
13. **`supabase/realtime` is not drop-in.** It needs a privileged DB role (REPLICATION + schema create), `wal_level=logical`, the `supabase_realtime` publication to exist, and a tenant provisioned at boot. This is the second-highest risk after the OIDC swap.

---

## Decisions captured

- **Exposure:** public via Cloudflare Tunnel at `tradeforge.pipitonelabs.com` (cutover host `tradeforge-new.pipitonelabs.com`).
- **Data:** start fresh. No pg_dump from Supabase. Re-generate the trade-reporter secret on the new stack.
- **Realtime:** run `supabase/realtime` so the dashboard's `postgres_changes` subscription works with zero client change.
- **Database:** a **dedicated** CloudNativePG cluster `tradeforge-pg` (see §"Database cluster prep"). Not the shared `postgres17`.
- **Auth:** Clerk → Authentik OIDC, in client code only.
- **Cutover:** side-by-side at the temporary host, verify, then swap DNS.

---

## Architecture

```
Browser ──HTTPS──▶ Cloudflare Tunnel ──▶ envoy-external (Envoy Gateway) ──▶ HTTPRoute "tradeforge"
                                                                              │
        ┌──────────────────────┬──────────────────────┬─────────────────────┤
        ▼                      ▼                      ▼                     ▼
  / → tradeforge-web    /rest/v1 → postgrest   /realtime/v1 → realtime   /functions/v1/ticino-reporter
   (nginx + dist/)       (PostgREST v12)        (supabase/realtime)        → reporter (Deno)
                              │                       │                         │
                              └───────────┬───────────┴────────────┬────────────┘
                                          ▼                        ▼
                              tradeforge-pg-rw.database.svc   (reporter also calls PostgREST
                              (dedicated CNPG, wal_level=logical, internally via SUPABASE_URL)
                               barman-cloud → Garage bucket)

        Authentik (sso.pipitonelabs.com) ◀── OIDC discovery / login redirects ── Browser
```

All app workloads live in a new `tradeforge` namespace. The **database** lives in the `database` namespace (same as `postgres17`/`outline`), reached cross-namespace at `tradeforge-pg-rw.database.svc.cluster.local`.

---

## Database cluster prep (answering "can we just create a new dedicated Postgres?")

**Short answer: yes.** The CNPG *operator* is already deployed and reconciling (`kubernetes/apps/database/cloudnative-pg`, chart `0.28.2`). You do **not** install anything new at the operator level. To get a dedicated Postgres you add one more `postgresql.cnpg.io/v1` **Cluster** CR named `tradeforge-pg` — exactly how `outline` is its own cluster today alongside `postgres17` and `immich`. The operator spins up its own pods, PVCs, and service endpoints.

**Why dedicated, not the shared `postgres17`:**
- Realtime needs **`wal_level = logical`**, which is a **cluster-wide** Postgres setting. Turning it on for `postgres17` would change WAL behavior for Authentik and every other tenant. A dedicated cluster isolates it.
- Independent backup/restore lifecycle (own Garage bucket, own retention).
- Independent sizing and blast radius.

The shared-cluster convention in this repo (`components/cnpg` + `ghcr.io/home-operations/postgres-init` initContainer) provisions a DB+role *inside* `postgres17`. We deliberately **do not** use it here; instead we own the whole cluster and bootstrap it with CNPG-native `initdb`.

### What's involved (six pieces)

1. **The Cluster CR** with `wal_level=logical` and `initdb` bootstrap.
2. **Roles + passwords** — `authenticator` (PostgREST login role) and `tradeforge_realtime` (Realtime), with passwords sourced from the shared `cloudnative-pg` 1Password item via CNPG `managed.roles`; the NOLOGIN Supabase roles (`anon`, `authenticated`, `service_role`) created in SQL. `authenticator` is deliberately **not** the table owner (the CNPG-created `tradeforge` owner role is unused by the app) so RLS is never bypassed.
3. **A Supabase-compat shim** (`00-supabase-compat.sql`) — creates the `extensions` and `auth` schemas, `auth.jwt()/uid()/role()`, the four roles + grants, and the empty `supabase_realtime` publication. **This must run before the app schema.**
4. **The app schema + data** — copies of `0001` (storage block stripped), `0002`, `0003`, and `seed.sql`, run in order via `postInitApplicationSQLRefs`.
5. **Backups** — a barman-cloud `ObjectStore` CR (Garage bucket `tradeforge-pg`) + a `ScheduledBackup`.
6. **Flux + Garage + 1Password wiring** — register the files, create the Garage bucket, populate secrets.

### Files to create (all under the existing CNPG cluster dir so Flux's `cloudnative-pg-cluster` Kustomization picks them up)

```
kubernetes/apps/database/cloudnative-pg/cluster/
├── kustomization.yaml                 # MODIFY: add the 3 new resources + sql/ configMapGenerator
├── tradeforge.yaml                    # NEW: Cluster CR (wal_level=logical, initdb, managed.roles)
├── objectstore-tradeforge.yaml        # NEW: barman-cloud ObjectStore → Garage s3://tradeforge-pg/
├── scheduledbackup.yaml               # MODIFY: add a 3rd ScheduledBackup for tradeforge-pg
└── sql/                               # NEW: bootstrap SQL (ConfigMap sources)
    ├── 00-supabase-compat.sql         # NEW (authored here)
    ├── 0001_initial_schema.sql        # COPY from tradeforge, storage block (lines ~390-412) removed
    ├── 0002_harden_rls_drop_public_read.sql   # COPY from tradeforge, verbatim
    ├── 0003_reporter_rate_limit.sql           # COPY from tradeforge, verbatim
    └── seed.sql                               # COPY from tradeforge, verbatim
```

> **Source-of-truth note:** the four copied files duplicate tradeforge's `supabase/migrations/*` + `seed.sql`. They change rarely and are not Renovate-managed; re-copy on schema change. This is the trade-off for a fully declarative GitOps bootstrap. (Alternative considered: a migration Job pulling SQL from the built image — rejected as more moving parts for a "start fresh" deploy.)

### `00-supabase-compat.sql` (authored in this repo)

```sql
-- Supabase-compat shim for self-hosted PostgREST + Realtime.
-- Runs BEFORE 0001. Provides what Supabase's platform normally creates.

-- Schemas the app schema expects to exist.
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE SCHEMA IF NOT EXISTS auth;

-- auth.jwt()/uid()/role(): read the claims PostgREST sets per request.
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT coalesce(current_setting('request.jwt.claims', true), '{}')::jsonb;
$$;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT auth.jwt() ->> 'sub';
$$;
CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT auth.jwt() ->> 'role';
$$;

-- Supabase roles. anon/authenticated/service_role are NOLOGIN; PostgREST's
-- login role (authenticator) SET ROLEs to them based on the JWT `role` claim.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
  -- authenticator: created NOLOGIN here; CNPG managed.roles adds LOGIN + password.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator NOLOGIN NOINHERIT;
  END IF;
END $$;

GRANT anon, authenticated, service_role TO authenticator;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;

-- Future objects in public are usable by the API roles (table grants are in 0001).
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO anon, authenticated, service_role;

-- Empty publication that 0001 will ALTER ... ADD TABLE into.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END $$;

-- Realtime connects as tradeforge_realtime (managed.roles supplies LOGIN + pw).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tradeforge_realtime') THEN
    CREATE ROLE tradeforge_realtime NOLOGIN REPLICATION;
  END IF;
END $$;
GRANT ALL ON DATABASE tradeforge TO tradeforge_realtime;
GRANT ALL ON SCHEMA public TO tradeforge_realtime;
```

> **Edit to the copied `0001`:** delete the entire `STORAGE` block (the `INSERT INTO storage.buckets …` through the three `storage.objects` policies, lines ~390–412). The app parses CSV client-side and never uploads; the schema's own comment marks this block "safe to remove." Leaving it in fails the bootstrap (`storage` schema/`storage.foldername` do not exist).

### `tradeforge.yaml` — the Cluster CR

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/postgresql.cnpg.io/cluster_v1.json
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: tradeforge-pg
spec:
  instances: 3                       # HA across the 3 nodes, matching postgres17/outline
  imageName: ghcr.io/cloudnative-pg/postgresql:17
  primaryUpdateStrategy: unsupervised
  primaryUpdateMethod: switchover
  storage:
    size: 20Gi
    storageClass: openebs-hostpath
  # No superuserSecret: CNPG auto-generates tradeforge-pg-superuser.
  # kubectl exec ... psql connects via local socket (no password needed).
  enableSuperuserAccess: true
  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: 256MB
      wal_level: logical              # required for supabase/realtime
      max_replication_slots: "10"
      max_wal_senders: "10"
      max_logical_replication_workers: "8"
  managed:
    roles:
      - name: authenticator           # PostgREST login role
        ensure: present
        login: true
        superuser: false
        passwordSecret:
          name: tradeforge-pg-authenticator
      - name: tradeforge_realtime      # Realtime login role
        ensure: present
        login: true
        replication: true
        passwordSecret:
          name: tradeforge-pg-realtime
  bootstrap:
    initdb:
      database: tradeforge
      owner: tradeforge               # app owner role (password via managed? see note)
      postInitApplicationSQLRefs:
        configMapRefs:
          - name: tradeforge-bootstrap-sql
            key: 00-supabase-compat.sql
          - name: tradeforge-bootstrap-sql
            key: 0001_initial_schema.sql
          - name: tradeforge-bootstrap-sql
            key: 0002_harden_rls_drop_public_read.sql
          - name: tradeforge-bootstrap-sql
            key: 0003_reporter_rate_limit.sql
          - name: tradeforge-bootstrap-sql
            key: seed.sql
  nodeMaintenanceWindow:
    inProgress: false
    reusePVC: true
  resources:
    requests:
      cpu: 250m
    limits:
      memory: 2Gi
  monitoring:
    enablePodMonitor: true
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: garage-s3-tradeforge
        serverName: tradeforge-pg-v1
```

> `postInitApplicationSQLRefs` executes **once**, in order, as superuser in the `tradeforge` database, only on first bootstrap. Because it runs as superuser, the `CREATE ROLE`/`GRANT` statements in the shim succeed. `managed.roles` reconciles *after* the instance is up and adopts the `authenticator`/`tradeforge_realtime` roles the shim already created, adding `LOGIN` + the secret password. The `tradeforge` owner role is created by `initdb`; PostgREST does **not** use it (it uses `authenticator`).

### `objectstore-tradeforge.yaml`

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/datreeio/CRDs-catalog/refs/heads/main/barmancloud.cnpg.io/objectstore_v1.json
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: garage-s3-tradeforge
spec:
  configuration:
    data:
      compression: bzip2
    destinationPath: s3://tradeforge-pg/
    endpointURL: https://s3.pipitonelabs.com
    s3Credentials:
      accessKeyId:
        name: cloudnative-pg-secret
        key: garage-aws-access-key-id
      secretAccessKey:
        name: cloudnative-pg-secret
        key: garage-aws-secret-access-key
    wal:
      compression: bzip2
      maxParallel: 4
  retentionPolicy: 30d
```

### `scheduledbackup.yaml` — append a third block

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/postgresql.cnpg.io/scheduledbackup_v1.json
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: tradeforge-pg
spec:
  schedule: "@daily"
  immediate: true
  backupOwnerReference: self
  cluster:
    name: tradeforge-pg
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

### `kustomization.yaml` — register everything

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./cluster17.yaml
  - ./objectstore-outline.yaml
  - ./objectstore-postgres17.yaml
  - ./objectstore-tradeforge.yaml      # NEW
  - ./outline.yaml
  - ./tradeforge.yaml                  # NEW
  - ./prometheusrule.yaml
  - ./scheduledbackup.yaml
configMapGenerator:                    # NEW
  - name: tradeforge-bootstrap-sql
    files:
      - ./sql/00-supabase-compat.sql
      - ./sql/0001_initial_schema.sql
      - ./sql/0002_harden_rls_drop_public_read.sql
      - ./sql/0003_reporter_rate_limit.sql
      - ./sql/seed.sql
generatorOptions:
  disableNameSuffixHash: true          # initdb references a stable ConfigMap name
```

> The CNPG cluster reads `tradeforge-bootstrap-sql` from its own namespace (`database`) — the configMapGenerator emits it there because the cluster Kustomization targets `database`. `disableNameSuffixHash` keeps the name stable so `postInitApplicationSQLRefs` resolves it.

### Garage bucket + 1Password prerequisites (one-time, manual)

- [ ] **Create the Garage bucket** `tradeforge-pg` and grant the existing CNPG access key read/write. Suggest the user run interactively (Garage admin CLI / web UI at `garage.pipitonelabs.com`). The barman creds reused are already in `cloudnative-pg-secret`.
- [ ] **1Password — add Postgres role credentials to the existing `cloudnative-pg` item** (same item every other app's `<app>_postgres_*` creds live in). Add four fields:
  - `tradeforge_authenticator_username` = `authenticator`, `tradeforge_authenticator_password` = (random) — PostgREST login role.
  - `tradeforge_realtime_username` = `tradeforge_realtime`, `tradeforge_realtime_password` = (random) — Realtime login role.

  Two pairs (not one) because the stack needs two distinct roles: the PostgREST `authenticator` (NOINHERIT, non-owner, so RLS applies) and a `REPLICATION`-capable role for Realtime. The superuser and the `tradeforge` owner role are auto-generated by CNPG — no fields needed.
- [ ] **1Password — app secrets (Phase 4)** go in a *separate* per-app item named `tradeforge` (mirroring the `authentik` item): `JWT_SECRET`, `anon_jwt`, `service_role_jwt`, `oidc_client_id`, `oidc_client_secret`, `realtime_db_enc_key`, `realtime_secret_key_base`. Add these when you reach Phase 4.

### How the app reaches the DB

- PostgREST → `postgresql://authenticator:<pw>@tradeforge-pg-rw.database.svc.cluster.local:5432/tradeforge`
- Realtime → same host, user `tradeforge_realtime`, db `tradeforge`.
- Reporter → talks to **PostgREST** (`SUPABASE_URL=http://tradeforge-postgrest.tradeforge.svc.cluster.local`), not Postgres directly.

---

## Critical reference files (verified current)

- App-template HelmRelease (route block, securityContext): `kubernetes/apps/default/blog/app/helmrelease.yaml`
- App-template + `postgres-init` initContainer + pguser secret wiring: `kubernetes/apps/default/wiki/app/helmrelease.yaml`
- 1Password ExternalSecret (store name `onepassword`, `dataFrom.extract`): `kubernetes/apps/security/authentik/app/externalsecret.yaml`
- Standalone HTTPRoute on Envoy (use this multi-matcher style, not the per-release `route:` block): `kubernetes/apps/security/authentik/app/httproute.yaml`
- Top-level Flux Kustomization wiring (`dependsOn`, `components`, `postBuild.substitute`): `kubernetes/apps/security/authentik/ks.yaml`
- CNPG cluster + barman plugin: `kubernetes/apps/database/cloudnative-pg/cluster/{cluster17,outline,objectstore-outline,scheduledbackup}.yaml`
- CNPG Flux Kustomizations (`cloudnative-pg-cluster` is the one apps `dependsOn`): `kubernetes/apps/database/cloudnative-pg/ks.yaml`
- app-template OCIRepository (tag `5.0.1`): `kubernetes/flux/repositories/oci/app-template.yaml`
- Renovate custom managers: `.renovate/customManagers.json5`
- Public exposure example (envoy-external): `kubernetes/apps/default/blog/...`; cloudflared wildcard: `kubernetes/apps/networking/cloudflared/app/resources/config.yaml`

---

## tradeforge repo — files that change

**New files:**
- `Dockerfile` — multi-stage: `node:20-alpine` build → `nginx:alpine` serve. `VITE_*` passed as build args (Vite inlines at build time).
- `nginx.conf` — SPA fallback excluding `assets/` (mirror `vercel.json`'s `/((?!assets/).*) → /index.html`), plus the 5 security headers from `vercel.json` (HSTS, X-Content-Type-Options nosniff, X-Frame-Options DENY, Referrer-Policy strict-origin-when-cross-origin, Permissions-Policy).
- `.dockerignore` — exclude `node_modules`, `.env`, `dist`, `supabase/`, `.vercel/`, `.git`.
- `supabase/functions/ticino-reporter/Dockerfile` — `FROM denoland/deno:alpine`, `CMD ["run","--allow-net","--allow-env","/app/index.ts"]`, listens `0.0.0.0:8000`, health at `/health`.
- `.github/workflows/docker.yaml` — build + push `ghcr.io/pipitonelabs/tradeforge-web` and `…/tradeforge-reporter` on push to main.

**Modified (auth swap, Phase 2):**
- `src/main.tsx`, `src/providers/ClerkProvider.tsx` — replace `<ClerkProvider>` with `react-oidc-context` `<AuthProvider>`.
- `src/services/supabase.ts` — `accessToken` callback returns the OIDC access token instead of `window.Clerk.session.getToken()`.
- `src/hooks/useClerkUser.ts` → `useAuthUser.ts` — return `{ id, email, fullName, avatar, publicMetadata }` from `auth.user.profile`.
- `src/hooks/useEnsureProfile.ts` — upsert `profiles` from OIDC `sub`.
- `src/hooks/useTicinoTradeStats.ts`, `useTicinoUserSecret.ts`, `useTicinoSessionConfig.ts`, `useSupabaseRealtimeAuth.ts` — swap Clerk hooks for `useAuthUser()`.
- `src/routes/ProtectedRoute.tsx` — OIDC `isAuthenticated` instead of Clerk `isSignedIn`.
- `src/components/layout/Header.tsx` — dropdown using `auth.signoutRedirect()`.
- `src/pages/auth/LoginPage.tsx`, `RegisterPage.tsx`, `ResetPasswordPage.tsx` — redirect to Authentik (`auth.signinRedirect()`).
- `src/pages/settings/SettingsPage.tsx` — external link to `https://sso.pipitonelabs.com/if/user/`.
- `src/pages/landing/LandingPage.tsx`, `src/pages/import/ImportPage.tsx`, `src/pages/payouts/PayoutTrackerPage.tsx` — replace remaining Clerk hooks.
- `src/components/realtime-stats/TradeReporterSettings.tsx:~12` — `const REPORTER_URL = import.meta.env.VITE_REPORTER_URL ?? 'https://pagzlfemkfqpsliddhdk.supabase.co/functions/v1/ticino-reporter'`.
- `package.json` — add `react-oidc-context`, `oidc-client-ts`; remove `@clerk/clerk-react`.
- `.env.example` — add `VITE_OIDC_AUTHORITY`, `VITE_OIDC_CLIENT_ID`, `VITE_REPORTER_URL`; keep `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`.

**Not changed:** `supabase/migrations/*` (no migration backfill needed — already consolidated).

---

## Implementation phases

### Phase 0 — Prerequisites (~30 min, manual)

- [x] **Authentik — DONE via Blueprint (not Terraform).** Terraform was used *only* for Authentik and its Garage S3 state was lost in the MinIO→Garage migration, so we pivoted to Authentik **blueprints** (GitOps-native, no external state). `kubernetes/apps/security/authentik/app/blueprint-tradeforge.yaml` (ConfigMap mounted via `blueprints.configMaps`) defines: an **HS256** OAuth2 provider (no `signing_key` → signs with `client_secret` = `JWT_SECRET`), public PKCE client, `sub_mode = user_uuid`, a `tradeforge-role` scope mapping injecting `role: authenticated`, and both redirect URIs. `TRADEFORGE_JWT_SECRET`/`TRADEFORGE_OIDC_CLIENT_ID` flow from the `tradeforge` 1Password item into `authentik-secret` and are read via `!Env`. **Verified live in Authentik's DB** (provider client_secret=64=JWT_SECRET, signing_key=None, 4 mappings, app linked). Issuer: `https://sso.pipitonelabs.com/application/o/tradeforge/`. Client ID = the `oidc_client_id` field.
  - Not yet bound to a group → currently any authenticated Authentik user can access; add a `authentik_policies.policybinding` to the `Self Hosted` group if you want to restrict.
  - Remaining Authentik apps (grafana/outline/etc.) still have stale Terraform config in `terraform/` — migrate them to blueprints incrementally, then delete `terraform/authentik`.
  - **SPA scopes must be `openid email profile tradeforge`** (the extra `tradeforge` scope carries the `role` claim PostgREST reads). Run `terraform apply` in `terraform/authentik/` to create it.
  - **Post-apply validation:** sign in once, decode the access token, confirm `alg=HS256` + `role:authenticated` + `sub` present, and that PostgREST accepts it (the public-client HS256-signing and v13 `kid` behavior are the two things to verify live).
- [ ] **Garage bucket** `tradeforge-pg` created + access granted to the CNPG key (see Database prep).
- [ ] **1Password** `tradeforge` item created with all DB + app fields (see Database prep + Phase 3).
- [ ] Decide the JWT signing secret (HS256). The same secret signs the anon/service_role JWTs and is configured in PostgREST + Realtime. Generate `openssl rand -base64 48` and store as `JWT_SECRET` in 1Password.

### Phase 1 — TradeForge repo prep (PR1, ~2 hr) — *migration backfill removed*

- [ ] Add `Dockerfile`, `nginx.conf`, `.dockerignore` (web).
- [ ] Add `supabase/functions/ticino-reporter/Dockerfile` (reporter).
- [ ] Make `REPORTER_URL` env-driven in `TradeReporterSettings.tsx` (line ~12).
- [ ] Smoke build both images locally with mock env; confirm `GET /health` on the reporter returns `{"ok":true,...}` and the web image serves a valid `index.html`.
- [ ] Commit + open PR1.

### Phase 2 — Auth swap to Authentik OIDC (PR2, ~5 hr, highest client risk)

- [ ] `npm i react-oidc-context oidc-client-ts && npm rm @clerk/clerk-react`.
- [ ] Replace `ClerkProvider` in `main.tsx` with `<AuthProvider authority={VITE_OIDC_AUTHORITY} client_id={VITE_OIDC_CLIENT_ID} redirect_uri=".../auth/callback" scope="openid email profile" />`.
- [ ] Build `useAuthUser()` returning `{ id, email, fullName, avatar, publicMetadata }` from the OIDC profile (`sub`, `email`, `name`, custom `groups` for admin). Replace every Clerk `useUser()` import (incl. `LandingPage.tsx`).
- [ ] Point the supabase-js `accessToken` callback at the OIDC access token.
- [ ] Swap `useAuth()` shape (`isAuthenticated` vs `isSignedIn`) behind a thin compat wrapper.
- [ ] `LoginPage`/`RegisterPage`/`ResetPasswordPage` → `auth.signinRedirect()` (Authentik renders the UI; invite-only register message if desired).
- [ ] `SettingsPage` → external link to `sso.pipitonelabs.com/if/user/`.
- [ ] Run locally against the Authentik provider; sign in; verify `useEnsureProfile` upserts a `profiles` row with `id = OIDC sub`.
- [ ] Commit + open PR2.

### Phase 3 — Database cluster (PR3a against k8s-gitops, ~2 hr)

Implements the entire **Database cluster prep** section above.

- [ ] Create `kubernetes/apps/database/cloudnative-pg/cluster/sql/` and add `00-supabase-compat.sql` (authored) + copies of `0001` (storage block stripped), `0002`, `0003`, `seed.sql`.
- [ ] Create `tradeforge.yaml`, `objectstore-tradeforge.yaml`; append the `tradeforge-pg` `ScheduledBackup`; update `kustomization.yaml` (resources + configMapGenerator).
- [ ] Add the two CNPG role ExternalSecrets (`tradeforge-pg-authenticator`, `tradeforge-pg-realtime`) as `kubernetes.io/basic-auth` secrets (`username` + `password`), store `onepassword`, `dataFrom.extract.key: cloudnative-pg`. (Superuser is auto-generated.)
- [ ] Commit on a branch; let `flux-local` validate in PR CI.
- [ ] After merge, watch `kubectl -n database get cluster tradeforge-pg -w` until `Cluster in healthy state`. Confirm bootstrap ran: `kubectl -n database exec -it tradeforge-pg-1 -- psql -d tradeforge -c '\dt'` shows the tables; `\dn` shows `auth` + `extensions`; `\du` shows `authenticator`, `tradeforge_realtime`, `anon`, `authenticated`, `service_role`.
- [ ] Validate the shim: `psql -d tradeforge -c "select auth.jwt();"` returns `{}` (not an error).

### Phase 4 — gitops app manifests (PR3b, ~4 hr)

Path: `kubernetes/apps/default/tradeforge/`.

```
tradeforge/
├── ks.yaml                  # Flux Kustomization: dependsOn cloudnative-pg-cluster + onepassword-store
└── app/
    ├── kustomization.yaml
    ├── externalsecret.yaml      # store onepassword → tradeforge-secrets (JWT_SECRET, anon/service JWTs,
    │                            #   OIDC client secret, REALTIME secrets, DB URIs)
    ├── helmrelease-web.yaml      # app-template, ghcr tradeforge-web, route on envoy-external (cutover host)
    ├── helmrelease-postgrest.yaml
    ├── helmrelease-realtime.yaml
    ├── helmrelease-reporter.yaml
    └── httproute.yaml           # ONE HTTPRoute, four path matchers (standalone, not per-release route:)
```

- [ ] `ks.yaml`: `dependsOn` `cloudnative-pg-cluster` (ns database) + `onepassword-store` (ns external-secrets); `targetNamespace: tradeforge`; add a `namespace` component if used elsewhere, else include a Namespace.
- [ ] **PostgREST** env: `PGRST_DB_URI` (authenticator), `PGRST_JWT_SECRET=$JWT_SECRET`, `PGRST_DB_ANON_ROLE=anon`, `PGRST_DB_SCHEMAS=public`, `PGRST_DB_USE_LEGACY_GUCS=false`.
- [ ] **Realtime** env: `DB_HOST=tradeforge-pg-rw.database.svc.cluster.local`, `DB_NAME=tradeforge`, `DB_USER=tradeforge_realtime`, `DB_PASSWORD` (from the `tradeforge-pg-realtime` secret), `DB_ENC_KEY` (16 chars), `API_JWT_SECRET=$JWT_SECRET`, `SECRET_KEY_BASE` (64 chars), `APP_NAME=realtime`, `RUN_JANITOR=true`, `RLIMIT_NOFILE=10000`, `ERL_AFLAGS=-proto_dist inet_tcp`. Provision the default tenant on boot (env `SELF_HOST`/seed, or a one-shot `POST /api/tenants`). **Validate this live — it is the riskiest manifest.**
- [ ] **Reporter** env: `SUPABASE_URL=http://tradeforge-postgrest.tradeforge.svc.cluster.local`, `SUPABASE_SERVICE_ROLE_KEY=<service_role JWT signed with JWT_SECRET>`. Probe `GET /health`.
- [ ] **Web** build-time vars baked into the image (Phase 5 CI): `VITE_SUPABASE_URL=https://tradeforge-new.pipitonelabs.com`, `VITE_SUPABASE_ANON_KEY=<anon JWT>`, `VITE_OIDC_AUTHORITY`, `VITE_OIDC_CLIENT_ID`, `VITE_REPORTER_URL=https://tradeforge-new.pipitonelabs.com/functions/v1/ticino-reporter`.
- [ ] **HTTPRoute** (mirror authentik's standalone style), hostname `tradeforge-new.pipitonelabs.com`, `parentRef: envoy-external` (ns networking), four rules: `/` → web, `/rest/v1` → postgrest:3000, `/realtime/v1` → realtime:4000, `/functions/v1/ticino-reporter` → reporter:8000. (No cloudflared edit — wildcard tunnel handles `*.pipitonelabs.com`.)
- [ ] **Renovate** `# renovate:` annotations on all four image refs.

### Phase 5 — Container builds (CI, ~1 hr)

- [ ] `.github/workflows/docker.yaml` in tradeforge: build + push `tradeforge-web` (with `VITE_*` build args) and `tradeforge-reporter` to GHCR on push to main. Renovate then bumps the gitops image digests.

### Phase 6 — Side-by-side cutover + verify (~1 hr)

- [ ] Flux reconciles `tradeforge`; wait for web/postgrest/realtime/reporter Deployments Ready.
- [ ] Run the **Verification** checklist below at `tradeforge-new.pipitonelabs.com`.
- [ ] Repoint the Sierra Chart study URL to `.../functions/v1/ticino-reporter`, paste the new secret, fire a replay trade; confirm it pushes to the dashboard within ~1s.
- [ ] **Swap DNS:** change the HTTPRoute hostname `tradeforge-new` → `tradeforge.pipitonelabs.com`; update the study URL.
- [ ] Decommission Vercel + Supabase (or pause a week).

---

## Difficulty estimate (revised)

| Phase | Effort | Risk |
|-------|--------|------|
| 0 — Prereqs (Authentik app, Garage bucket, 1Password) | 0.5 hr | Low |
| 1 — Repo prep (Dockerfiles, env URL) — *backfill removed* | 2 hr | Low |
| 2 — Clerk → Authentik OIDC | 5 hr | Medium (≥12 files; redirect flow) |
| 3 — DB cluster (compat shim, roles, bootstrap, backups) | 2 hr | **Medium** (auth.jwt shim + role/password reconcile) |
| 4 — gitops app manifests | 4 hr | Medium (Realtime tenant/role the hot spot) |
| 5 — CI image builds | 1 hr | Low |
| 6 — Cutover + verify | 1 hr | Low (side-by-side rollback trivial) |
| **Total** | **~15.5 hr** | Medium |

Risk has shifted: the migration backfill is gone, but a new **Supabase-compat DB shim** and **Realtime self-hosting** now sit alongside the **OIDC swap** as the three things most likely to surprise. Still ~a weekend.

---

## Verification (before flipping DNS)

1. **DB schema:** `kubectl -n database exec -it tradeforge-pg-1 -- psql -d tradeforge -c '\dt'` shows profiles, accounts, trades, ticino_trades, ticino_user_secrets, ticino_session_configs, ticino_reporter_rate_limit. `\df auth.*` shows `jwt/uid/role`.
2. **Compat shim:** `psql -d tradeforge -c "select auth.uid();"` returns NULL (not error). `\du` lists `authenticator` (LOGIN), `tradeforge_realtime` (LOGIN, Replication), `anon`/`authenticated`/`service_role` (NOLOGIN).
3. **PostgREST (anon):** `curl -H 'apikey: <ANON_JWT>' -H 'Authorization: Bearer <ANON_JWT>' https://tradeforge-new.pipitonelabs.com/rest/v1/prop_firms` returns JSON.
4. **PostgREST (RLS works):** an authenticated request for `ticino_trades` returns only the caller's rows; an anon request returns none — proving `auth.jwt() ->> 'sub'` resolves.
5. **Realtime:** dashboard devtools → WS open to `/realtime/v1/websocket`; insert a `ticino_trades` row via psql and watch it push.
6. **Reporter:** `curl -X POST https://tradeforge-new.pipitonelabs.com/functions/v1/ticino-reporter -H 'X-Trade-Secret: <new>' -H 'content-type: application/json' -d '<full trade payload>'` → `{"ok":true,"trade":{...}}`. Health: `curl .../functions/v1/ticino-reporter/health` → `{"ok":true}`. (Confirm the rate-limit RPC exists: a bad-secret POST does not 500.)
7. **Auth flow:** `/` → redirect to `sso.pipitonelabs.com`, log in, redirected back, `profiles` row created with `id` = OIDC sub.
8. **End-to-end chart trade:** Sierra Chart replay trade (study V2.2 — cancel-first SWAP, OCO matching, quantity-weighted R) appears in the dashboard ~1s; then `psql -d tradeforge -c "SELECT r_multiple, weighted_r, exit_reason_detail, t1_hit, t2_hit, t3_hit FROM ticino_trades ORDER BY id DESC LIMIT 1"` confirms rich columns. For a T1+T2 trade, `weighted_r` differs from `r_multiple`.
9. **Mobile smoke-check:** narrow viewport — 4-section breakdown collapses to Tabs, PLCalendar week strip + bottom-sheet, trade cards, EquityCurve scrolls without hijacking touch.
10. **Backups:** `kubectl -n database get backup` shows a completed base backup to Garage within 24 h; run one restore-test before decommissioning Supabase.

---

## Self-review notes

- **Obsolete tasks removed:** migration `011` backfill and `010` grant edit (schema is consolidated into `0001`).
- **Spec coverage:** every drift item (1–13) maps to a phase — migrations (Phase 3 copies `0003`), `/health` (Phases 1/6/verify), Landing/Clerk files (Phase 2), `onepassword`/`envoy-external`/ObjectStore (Phases 3/4), `auth.jwt()` shim + Realtime role (Phase 3/4).
- **Open validation points (flagged inline):** Realtime tenant provisioning + `tradeforge_realtime` privileges; CNPG `managed.roles` adopting the shim-created roles; exact PostgREST/Realtime container ports for the HTTPRoute backendRefs (confirm against the chosen image tags during Phase 4).
