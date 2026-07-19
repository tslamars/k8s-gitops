-- ============================================================================
-- 0005_rename_ticino_to_swappybot.sql
-- ----------------------------------------------------------------------------
-- Renames every ticino_* object to swappybot_*, and the session-config column
-- ticino_version -> algo_version, to match the SwappyBot rename in the
-- sierra-suite repo (studies/SwappyBotReporter.cpp).
--
-- PHASE 1 of 3 — zero-downtime cutover:
--   Phase 1 (this file): rename everything, then recreate the OLD names as
--                        compatibility views / a wrapper function so the
--                        currently-deployed reporter and web images keep
--                        working untouched.
--   Phase 2: update tradeforge-selfhost source to the new names, rebuild and
--            redeploy the reporter + web images.
--   Phase 3: run 0006_drop_ticino_compat.sql to remove the compat layer.
--
-- ALL RENAMES PRESERVE DATA — ALTER ... RENAME is a catalog-only operation.
-- No table is copied, no row is rewritten.
--
-- KNOWN GAP — REALTIME SUBSCRIPTIONS ARE NOT COVERED BY THE COMPAT LAYER.
-- Logical replication reports the BASE TABLE name, and views are never
-- published. src/hooks/useTicinoTradeStats.ts and useTicinoSessionConfig.ts
-- subscribe to postgres_changes on 'ticino_trades' / 'ticino_session_configs'
-- and will stop receiving events the moment this runs. REST reads and writes
-- keep working, so the dashboard still loads and the reporter still posts —
-- the numbers just stop live-updating until Phase 2 ships. Everything else
-- degrades gracefully; this one does not.
-- ============================================================================

BEGIN;

-- ─── 1. TABLES ──────────────────────────────────────────────────────────────
ALTER TABLE public.ticino_trades              RENAME TO swappybot_trades;
ALTER TABLE public.ticino_session_configs     RENAME TO swappybot_session_configs;
ALTER TABLE public.ticino_user_secrets        RENAME TO swappybot_user_secrets;
ALTER TABLE public.ticino_reporter_rate_limit RENAME TO swappybot_reporter_rate_limit;

-- ─── 2. COLUMN ──────────────────────────────────────────────────────────────
ALTER TABLE public.swappybot_session_configs
    RENAME COLUMN ticino_version TO algo_version;

-- ─── 3. CONSTRAINTS ─────────────────────────────────────────────────────────
-- RENAME CONSTRAINT also renames the backing index for PRIMARY KEY / UNIQUE,
-- so these must not be repeated in the ALTER INDEX section below.
ALTER TABLE public.swappybot_trades
    RENAME CONSTRAINT ticino_trades_pkey              TO swappybot_trades_pkey;
ALTER TABLE public.swappybot_trades
    RENAME CONSTRAINT ticino_trades_trade_id_key      TO swappybot_trades_trade_id_key;
ALTER TABLE public.swappybot_trades
    RENAME CONSTRAINT ticino_trades_user_id_fkey      TO swappybot_trades_user_id_fkey;
ALTER TABLE public.swappybot_trades
    RENAME CONSTRAINT ticino_trades_exit_reason_check TO swappybot_trades_exit_reason_check;
ALTER TABLE public.swappybot_trades
    RENAME CONSTRAINT ticino_trades_session_check     TO swappybot_trades_session_check;
ALTER TABLE public.swappybot_trades
    RENAME CONSTRAINT ticino_trades_side_check        TO swappybot_trades_side_check;

ALTER TABLE public.swappybot_session_configs
    RENAME CONSTRAINT ticino_session_configs_pkey       TO swappybot_session_configs_pkey;
ALTER TABLE public.swappybot_session_configs
    RENAME CONSTRAINT ticino_session_configs_mode_check TO swappybot_session_configs_mode_check;
ALTER TABLE public.swappybot_session_configs
    RENAME CONSTRAINT ticino_session_configs_user_id_session_id_key
                   TO swappybot_session_configs_user_id_session_id_key;

ALTER TABLE public.swappybot_user_secrets
    RENAME CONSTRAINT ticino_user_secrets_pkey             TO swappybot_user_secrets_pkey;
ALTER TABLE public.swappybot_user_secrets
    RENAME CONSTRAINT ticino_user_secrets_trade_secret_key TO swappybot_user_secrets_trade_secret_key;
ALTER TABLE public.swappybot_user_secrets
    RENAME CONSTRAINT ticino_user_secrets_user_id_fkey     TO swappybot_user_secrets_user_id_fkey;

ALTER TABLE public.swappybot_reporter_rate_limit
    RENAME CONSTRAINT ticino_reporter_rate_limit_pkey TO swappybot_reporter_rate_limit_pkey;

-- ─── 4. PLAIN INDEXES ───────────────────────────────────────────────────────
ALTER INDEX public.idx_ticino_trades_entry_time
    RENAME TO idx_swappybot_trades_entry_time;
ALTER INDEX public.idx_ticino_trades_user_id_entry_time
    RENAME TO idx_swappybot_trades_user_id_entry_time;
ALTER INDEX public.idx_ticino_session_configs_user_recent
    RENAME TO idx_swappybot_session_configs_user_recent;

-- ─── 5. RLS POLICIES ────────────────────────────────────────────────────────
-- Policies follow their table automatically; only the names are cosmetic.
ALTER POLICY ticino_trades_all_own
    ON public.swappybot_trades          RENAME TO swappybot_trades_all_own;
ALTER POLICY ticino_user_secrets_all_own
    ON public.swappybot_user_secrets    RENAME TO swappybot_user_secrets_all_own;
ALTER POLICY ticino_session_configs_all_own
    ON public.swappybot_session_configs RENAME TO swappybot_session_configs_all_own;

-- ─── 6. TRIGGER + FUNCTIONS ─────────────────────────────────────────────────
ALTER TRIGGER ticino_user_secrets_set_updated_at
    ON public.swappybot_user_secrets
    RENAME TO swappybot_user_secrets_set_updated_at;
ALTER FUNCTION public.set_ticino_user_secrets_updated_at()
    RENAME TO set_swappybot_user_secrets_updated_at;

-- ticino_reporter_rate_check hardcodes its table name in the function BODY.
-- Function bodies are stored as text, not resolved OIDs, so the table rename
-- above does NOT update it — it would fail at runtime with "relation
-- public.ticino_reporter_rate_limit does not exist". Recreate it against the
-- new table rather than renaming it.
CREATE OR REPLACE FUNCTION public.swappybot_reporter_rate_check(
    p_key text, p_limit integer, p_window_seconds integer)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_window timestamptz := to_timestamp(
    floor(extract(epoch FROM now()) / p_window_seconds) * p_window_seconds
  );
  v_count  integer;
BEGIN
  DELETE FROM public.swappybot_reporter_rate_limit
    WHERE bucket_key = p_key AND window_start < v_window;

  INSERT INTO public.swappybot_reporter_rate_limit AS r (bucket_key, window_start, request_count)
  VALUES (p_key, v_window, 1)
  ON CONFLICT (bucket_key, window_start)
  DO UPDATE SET request_count = r.request_count + 1
  RETURNING r.request_count INTO v_count;

  RETURN v_count <= p_limit;
END;
$function$;

-- ─── 7. VIEWS (new names) ───────────────────────────────────────────────────
-- Dropped and recreated rather than renamed: a view's output column names are
-- fixed at creation, so renaming ticino_version on the base table would leave
-- the view still emitting a column called ticino_version.
DROP VIEW IF EXISTS public.ticino_session_configs_v;
DROP VIEW IF EXISTS public.ticino_trade_stats_v;

CREATE VIEW public.swappybot_session_configs_v WITH (security_invoker = on) AS
 SELECT id, user_id, session_id, session_start, instrument, mode, algo_version,
        t1_contracts, t1_r, t1_points,
        t2_contracts, t2_r, t2_points,
        t3_contracts, t3_r, t3_points,
        stop_mode, enable_internal_trail, min_close_strength_pct,
        require_green_close, require_red_close, max_queue_size,
        pause1_from, created_at
   FROM public.swappybot_session_configs;

CREATE VIEW public.swappybot_trade_stats_v WITH (security_invoker = on) AS
 SELECT id,
        (date_trunc('day'::text, entry_time))::date AS trade_date,
        instrument, user_id, side, qty, r_multiple, weighted_r,
        duration_minutes, exit_reason, exit_reason_detail,
        t1_hit, t2_hit, t3_hit, session, is_replay, is_sim,
        entry_mml_level, exit_mml_level,
        entry_time, exit_time, entry_price, exit_price, stop_price
   FROM public.swappybot_trades;

GRANT SELECT ON public.swappybot_session_configs_v TO authenticated;
GRANT SELECT ON public.swappybot_trade_stats_v     TO authenticated;

-- ─── 8. COMPATIBILITY LAYER (old names) ─────────────────────────────────────
-- Everything below exists only so the currently-deployed reporter and web
-- images keep working until Phase 2. Dropped by 0006.
--
-- security_invoker = on is REQUIRED: without it these views run with the
-- owner's rights and would bypass the base tables' RLS, exposing every user's
-- trades to every authenticated caller.
--
-- Simple SELECT views over a single table are auto-updatable, and INSERT ...
-- ON CONFLICT resolves against the base table's unique constraint, so the
-- reporter's upsert path (on_conflict=user_id,session_id) works unchanged.
-- Verified empirically on this cluster before writing this migration.

CREATE VIEW public.ticino_trades WITH (security_invoker = on) AS
    SELECT * FROM public.swappybot_trades;

-- Aliases algo_version back to its old name for the deployed images.
CREATE VIEW public.ticino_session_configs WITH (security_invoker = on) AS
 SELECT id, user_id, session_id, session_start, instrument, mode,
        algo_version AS ticino_version,
        t1_contracts, t1_r, t1_points,
        t2_contracts, t2_r, t2_points,
        t3_contracts, t3_r, t3_points,
        stop_mode, enable_internal_trail, min_close_strength_pct,
        require_green_close, require_red_close, max_queue_size,
        pause1_from, created_at
   FROM public.swappybot_session_configs;

CREATE VIEW public.ticino_user_secrets WITH (security_invoker = on) AS
    SELECT * FROM public.swappybot_user_secrets;

CREATE VIEW public.ticino_session_configs_v WITH (security_invoker = on) AS
 SELECT id, user_id, session_id, session_start, instrument, mode,
        algo_version AS ticino_version,
        t1_contracts, t1_r, t1_points,
        t2_contracts, t2_r, t2_points,
        t3_contracts, t3_r, t3_points,
        stop_mode, enable_internal_trail, min_close_strength_pct,
        require_green_close, require_red_close, max_queue_size,
        pause1_from, created_at
   FROM public.swappybot_session_configs;

CREATE VIEW public.ticino_trade_stats_v WITH (security_invoker = on) AS
    SELECT * FROM public.swappybot_trade_stats_v;

-- Wrapper so the deployed edge function's rpc/ticino_reporter_rate_check
-- keeps resolving.
CREATE OR REPLACE FUNCTION public.ticino_reporter_rate_check(
    p_key text, p_limit integer, p_window_seconds integer)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.swappybot_reporter_rate_check(p_key, p_limit, p_window_seconds);
$function$;

-- Compat grants mirror what the renamed objects carried before this migration.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ticino_trades          TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ticino_session_configs TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ticino_user_secrets    TO authenticated, service_role;
GRANT SELECT                         ON public.ticino_session_configs_v TO authenticated;
GRANT SELECT                         ON public.ticino_trade_stats_v     TO authenticated;

COMMIT;

-- PostgREST caches the schema; without this it keeps serving the old shape.
NOTIFY pgrst, 'reload schema';
