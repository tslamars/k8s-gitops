-- ============================================================================
-- Supabase-compat shim for self-hosted PostgREST + Realtime
-- ============================================================================
-- TradeForge's schema (0001) was written for Supabase, whose platform provides
-- the `auth` schema, `auth.jwt()`, the anon/authenticated/service_role roles, an
-- `extensions` schema, and the `supabase_realtime` publication. A bare
-- CloudNativePG + PostgREST stack has none of these, so RLS (40+ policies that
-- read `auth.jwt() ->> 'sub'`) and the table GRANTs in 0001 would fail.
--
-- This file recreates exactly those primitives. It runs FIRST (before 0001) via
-- the cluster's bootstrap.initdb.postInitApplicationSQLRefs, as superuser in the
-- `tradeforge` database. It is idempotent.
-- ============================================================================

-- Schemas the app schema expects to already exist ---------------------------
CREATE SCHEMA IF NOT EXISTS extensions;   -- 0001 installs uuid-ossp/pgcrypto here
CREATE SCHEMA IF NOT EXISTS auth;

-- auth.jwt()/uid()/role(): resolve the per-request claims PostgREST injects.
-- SECURITY DEFINER so that the `authenticated` role can call these functions
-- via RLS policy inlining — without it, PostgreSQL inlines the function body
-- and then permission-checks the caller against the auth schema (which
-- authenticated has no USAGE on), causing "permission denied for schema auth".
CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(current_setting('request.jwt.claims', true), '{}')::jsonb;
$$;
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT auth.jwt() ->> 'sub';
$$;
CREATE OR REPLACE FUNCTION auth.role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT auth.jwt() ->> 'role';
$$;

-- Supabase roles -------------------------------------------------------------
-- anon/authenticated/service_role are NOLOGIN. PostgREST logs in as
-- `authenticator` and SET ROLEs to one of them based on the JWT `role` claim.
-- `authenticator` MUST stay NOINHERIT and must NOT own any table, otherwise it
-- would bypass RLS. It is created NOLOGIN here; CNPG managed.roles adopts it and
-- adds LOGIN + the password from the tradeforge-pg-authenticator secret.
-- `tradeforge_realtime` is the Realtime login role (managed.roles adds LOGIN+pw).
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
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tradeforge_realtime') THEN
    CREATE ROLE tradeforge_realtime NOLOGIN REPLICATION;
  END IF;
END $$;

GRANT anon, authenticated, service_role TO authenticator;

-- Schema usage + default privileges for the API roles ------------------------
-- (Table-level GRANTs are in 0001; these cover schema usage and the sequences
-- 0001 creates afterward, so INSERTs on serial/identity columns work.)
GRANT USAGE ON SCHEMA public     TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO anon, authenticated, service_role;

-- Realtime needs a logical replication slot + its two schemas. Supabase's
-- platform pre-creates `_realtime` (control plane) and `realtime` (per-tenant
-- data plane); recreate them here so a fresh bootstrap matches.
GRANT ALL ON DATABASE tradeforge TO tradeforge_realtime;
GRANT ALL ON SCHEMA public TO tradeforge_realtime;
CREATE SCHEMA IF NOT EXISTS _realtime AUTHORIZATION tradeforge_realtime;
CREATE SCHEMA IF NOT EXISTS realtime AUTHORIZATION tradeforge_realtime;

-- Empty publication that 0001 ALTERs ... ADD TABLE into ----------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END $$;
