-- ============================================================================
-- TradeForge — consolidated database schema
-- ============================================================================
-- This single file creates the COMPLETE TradeForge schema on a fresh Supabase
-- project. It is the authoritative, verified consolidation of the original
-- incremental migrations PLUS the objects that had been applied directly to the
-- production database. Run this ONCE on a new project, then run `seed.sql`.
--
-- How to apply (pick one):
--   A) Supabase Dashboard → SQL Editor → paste this whole file → Run.
--      Then do the same with seed.sql.
--   B) Supabase CLI:  supabase db push   (this file is also mirrored to
--      supabase/migrations/0001_initial_schema.sql), then run seed.sql.
--
-- Auth model: this app authenticates with CLERK, not Supabase Auth. The Clerk
-- session JWT is forwarded to Supabase (see src/services/supabase.ts) via the
-- native "Third-Party Auth" integration, so RLS resolves the current user with
-- `auth.jwt() ->> 'sub'` (the Clerk user id). You MUST enable the Clerk
-- third-party auth integration in the Supabase dashboard for RLS to work — see
-- SETUP-INSTRUCTIONS.html.
--
-- The script is idempotent: it can be re-run safely.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Extensions
-- ----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;  -- uuid_generate_v4()
CREATE EXTENSION IF NOT EXISTS pgcrypto    WITH SCHEMA extensions;  -- gen_random_uuid()

-- ============================================================================
-- TABLES
-- ============================================================================

-- profiles: one row per Clerk user. `id` is the Clerk user id (e.g. user_xxx).
CREATE TABLE IF NOT EXISTS public.profiles (
    id         text PRIMARY KEY,
    email      text NOT NULL,
    full_name  text,
    avatar_url text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- prop_firms: catalog of prop-firm rule templates (seeded by seed.sql).
CREATE TABLE IF NOT EXISTS public.prop_firms (
    id                 uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    name               text NOT NULL UNIQUE,
    daily_drawdown_pct numeric(5,2) NOT NULL,
    max_drawdown_pct   numeric(5,2) NOT NULL,
    profit_target_pct  numeric(5,2) NOT NULL,
    rules_description  text,
    created_at         timestamptz NOT NULL DEFAULT now()
);

-- accounts: a user's trading accounts, each tied to a prop firm.
CREATE TABLE IF NOT EXISTS public.accounts (
    id                            uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    user_id                       text NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    prop_firm_id                  uuid NOT NULL REFERENCES public.prop_firms(id),
    name                          text NOT NULL,
    starting_balance              numeric(12,2) NOT NULL,
    current_balance               numeric(12,2) NOT NULL DEFAULT 0,
    status                        text NOT NULL DEFAULT 'active'
                                    CHECK (status = ANY (ARRAY['active','inactive','blown'])),
    created_at                    timestamptz NOT NULL DEFAULT now(),
    updated_at                    timestamptz NOT NULL DEFAULT now(),
    one_r_value                   numeric,
    custom_daily_drawdown_pct     numeric,
    custom_max_drawdown_pct       numeric,
    custom_profit_target_pct      numeric,
    custom_daily_drawdown_dollars numeric,
    custom_max_drawdown_dollars   numeric,
    custom_profit_target_dollars  numeric
);
COMMENT ON COLUMN public.accounts.one_r_value IS
    'Standard risk amount (1R) per trade in dollars for R-multiple calculations';

-- trades: individual trade records (CSV-imported or manual).
CREATE TABLE IF NOT EXISTS public.trades (
    id          uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    account_id  uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    symbol      text NOT NULL,
    side        text NOT NULL CHECK (side = ANY (ARRAY['long','short'])),
    quantity    numeric(12,4) NOT NULL,
    entry_price numeric(12,4) NOT NULL,
    exit_price  numeric(12,4),
    entry_time  timestamptz NOT NULL,
    exit_time   timestamptz,
    pnl         numeric(12,2),
    fees        numeric(12,2) DEFAULT 0,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- account_performance: imported Rithmic performance summaries per account.
CREATE TABLE IF NOT EXISTS public.account_performance (
    id                  uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    account_id          uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    source_account_name text NOT NULL,
    trade_pnl           numeric(12,2) NOT NULL DEFAULT 0,
    commission_fees     numeric(12,2) NOT NULL DEFAULT 0,
    net_pnl             numeric(12,2) NOT NULL DEFAULT 0,
    trade_count         integer NOT NULL DEFAULT 0,
    winning_trades      integer NOT NULL DEFAULT 0,
    losing_trades       integer NOT NULL DEFAULT 0,
    win_pct             numeric(5,2) NOT NULL DEFAULT 0,
    lose_pct            numeric(5,2) NOT NULL DEFAULT 0,
    scratched_trades    integer NOT NULL DEFAULT 0,
    scratched_pct       numeric(5,2) NOT NULL DEFAULT 0,
    ticks_made          integer NOT NULL DEFAULT 0,
    max_drawdown        numeric(12,2),
    max_drawdown_pct    numeric(5,2),
    imported_at         timestamptz NOT NULL DEFAULT now(),
    created_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.account_performance IS
    'Stores imported Rithmic performance summary data linked to TradeForge accounts';

-- prop_firm_payouts: payout-rule templates per prop firm (seeded by seed.sql).
CREATE TABLE IF NOT EXISTS public.prop_firm_payouts (
    id                     uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    prop_firm_id           uuid NOT NULL REFERENCES public.prop_firms(id) ON DELETE CASCADE,
    default_profit_split   numeric(5,2) NOT NULL,
    max_profit_split       numeric(5,2),
    profit_split_type      text DEFAULT 'fixed',
    first_payout_wait_days integer,
    payout_frequency_days  integer,
    payout_window_start    integer,
    payout_window_end      integer,
    minimum_payout         numeric(10,2),
    maximum_payout         numeric(10,2),
    min_trading_days       integer,
    min_winning_days       integer,
    winning_day_threshold  numeric(10,2),
    consistency_rule_pct   numeric(5,2),
    processing_days        integer,
    payment_methods        text[],
    is_active              boolean DEFAULT true,
    notes                  text,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS prop_firm_payouts_firm_unique
    ON public.prop_firm_payouts(prop_firm_id);

-- ticino_trades: per-user live trade feed posted by the Sierra Chart reporter
-- (via the ticino-reporter edge function). `user_id` is stamped server-side.
CREATE TABLE IF NOT EXISTS public.ticino_trades (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    trade_id           text NOT NULL UNIQUE,
    instrument         text NOT NULL,
    side               text NOT NULL CHECK (side = ANY (ARRAY['LONG','SHORT'])),
    entry_time         timestamptz NOT NULL,
    exit_time          timestamptz NOT NULL,
    entry_price        numeric(12,4) NOT NULL,
    exit_price         numeric(12,4) NOT NULL,
    stop_price         numeric(12,4) NOT NULL,
    qty                integer NOT NULL,
    r_multiple         numeric(8,4) NOT NULL,
    duration_minutes   integer NOT NULL,
    exit_reason        text NOT NULL CHECK (exit_reason = ANY (ARRAY['target','stop','be','manual'])),
    session            text NOT NULL CHECK (session = ANY (ARRAY['rth','globex','other'])),
    is_replay          boolean NOT NULL DEFAULT false,
    is_sim             boolean NOT NULL DEFAULT false,
    user_id            text NOT NULL REFERENCES public.profiles(id),
    entry_mml_level    text,
    exit_mml_level     text,
    t1_hit             boolean,
    t2_hit             boolean,
    t3_hit             boolean,
    exit_reason_detail text,
    initial_stop_price numeric(12,4),
    final_stop_price   numeric(12,4),
    weighted_r         numeric(8,4),
    created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ticino_trades_entry_time
    ON public.ticino_trades(entry_time DESC);
CREATE INDEX IF NOT EXISTS idx_ticino_trades_live_entry_time
    ON public.ticino_trades(entry_time DESC) WHERE is_replay = false;
CREATE INDEX IF NOT EXISTS idx_ticino_trades_user_id_entry_time
    ON public.ticino_trades(user_id, entry_time DESC);

-- ticino_user_secrets: maps a per-user shared secret to a user_id. The reporter
-- sends X-Trade-Secret; the edge function looks up the owner here (service role).
CREATE TABLE IF NOT EXISTS public.ticino_user_secrets (
    user_id      text PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
    trade_secret text NOT NULL UNIQUE,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ticino_session_configs: per-user Ticino algo settings, upserted by the edge
-- function once per session so the dashboard can show active configuration.
CREATE TABLE IF NOT EXISTS public.ticino_session_configs (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                text NOT NULL,
    session_id             text NOT NULL,
    session_start          timestamptz NOT NULL,
    instrument             text NOT NULL,
    mode                   text NOT NULL CHECK (mode = ANY (ARRAY['LIVE','SIM','REPLAY'])),
    ticino_version         text,
    t1_contracts           integer,
    t1_r                   integer,
    t1_points              numeric(10,4),
    t2_contracts           integer,
    t2_r                   integer,
    t2_points              numeric(10,4),
    t3_contracts           integer,
    t3_r                   integer,
    t3_points              numeric(10,4),
    stop_mode              integer,
    enable_internal_trail  boolean,
    min_close_strength_pct integer,
    require_green_close     boolean,
    require_red_close       boolean,
    max_queue_size         integer,
    pause1_from            integer,
    created_at             timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, session_id)
);
CREATE INDEX IF NOT EXISTS idx_ticino_session_configs_user_recent
    ON public.ticino_session_configs(user_id, instrument, mode, session_start DESC);

-- ============================================================================
-- FUNCTIONS + TRIGGERS (updated_at maintenance)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.update_prop_firm_payouts_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $fn$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$fn$;

CREATE OR REPLACE FUNCTION public.set_ticino_user_secrets_updated_at()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.set_ticino_user_secrets_updated_at()
    FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS prop_firm_payouts_updated_at ON public.prop_firm_payouts;
CREATE TRIGGER prop_firm_payouts_updated_at
    BEFORE UPDATE ON public.prop_firm_payouts
    FOR EACH ROW EXECUTE FUNCTION public.update_prop_firm_payouts_updated_at();

DROP TRIGGER IF EXISTS ticino_user_secrets_set_updated_at ON public.ticino_user_secrets;
CREATE TRIGGER ticino_user_secrets_set_updated_at
    BEFORE UPDATE ON public.ticino_user_secrets
    FOR EACH ROW EXECUTE FUNCTION public.set_ticino_user_secrets_updated_at();

-- ============================================================================
-- VIEWS (security_invoker = on → RLS of the querying user applies)
-- ============================================================================
CREATE OR REPLACE VIEW public.ticino_trade_stats_v WITH (security_invoker = on) AS
 SELECT id,
    (date_trunc('day', entry_time))::date AS trade_date,
    instrument, user_id, side, qty, r_multiple, weighted_r, duration_minutes,
    exit_reason, exit_reason_detail, t1_hit, t2_hit, t3_hit, session,
    is_replay, is_sim, entry_mml_level, exit_mml_level, entry_time, exit_time
   FROM public.ticino_trades;

CREATE OR REPLACE VIEW public.ticino_session_configs_v WITH (security_invoker = on) AS
 SELECT id, user_id, session_id, session_start, instrument, mode, ticino_version,
    t1_contracts, t1_r, t1_points, t2_contracts, t2_r, t2_points,
    t3_contracts, t3_r, t3_points, stop_mode, enable_internal_trail,
    min_close_strength_pct, require_green_close, require_red_close,
    max_queue_size, pause1_from, created_at
   FROM public.ticino_session_configs;

-- ============================================================================
-- ROW LEVEL SECURITY
-- All per-user policies scope rows to the Clerk user id via auth.uid().
-- Use (SELECT auth.uid()) so PostgreSQL evaluates it once as an InitPlan
-- rather than re-evaluating per row.
-- For tables accessed via a FK join (trades, account_performance), use an
-- IN subquery so the auth call stays at the outer query level and is not
-- buried inside a correlated EXISTS.
-- ============================================================================
ALTER TABLE public.profiles               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prop_firms             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.accounts               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trades                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_performance    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prop_firm_payouts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ticino_trades          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ticino_user_secrets    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ticino_session_configs ENABLE ROW LEVEL SECURITY;

-- profiles --------------------------------------------------------------------
DROP POLICY IF EXISTS profiles_select_own ON public.profiles;
CREATE POLICY profiles_select_own ON public.profiles FOR SELECT TO authenticated
    USING (id = (SELECT auth.uid()));
DROP POLICY IF EXISTS profiles_insert_own ON public.profiles;
CREATE POLICY profiles_insert_own ON public.profiles FOR INSERT TO authenticated
    WITH CHECK (id = (SELECT auth.uid()));
DROP POLICY IF EXISTS profiles_update_own ON public.profiles;
CREATE POLICY profiles_update_own ON public.profiles FOR UPDATE TO authenticated
    USING (id = (SELECT auth.uid())) WITH CHECK (id = (SELECT auth.uid()));

-- prop_firms (public reference data — readable by everyone) --------------------
DROP POLICY IF EXISTS "Public can view prop firms" ON public.prop_firms;
CREATE POLICY "Public can view prop firms" ON public.prop_firms FOR SELECT
    TO anon, authenticated USING (true);

-- accounts --------------------------------------------------------------------
DROP POLICY IF EXISTS accounts_all_own ON public.accounts;
CREATE POLICY accounts_all_own ON public.accounts FOR ALL TO authenticated
    USING (user_id = (SELECT auth.uid()))
    WITH CHECK (user_id = (SELECT auth.uid()));

-- trades (scoped through the owning account) -----------------------------------
-- IN subquery keeps auth.uid() at the outer query level for InitPlan caching.
DROP POLICY IF EXISTS trades_all_own ON public.trades;
CREATE POLICY trades_all_own ON public.trades FOR ALL TO authenticated
    USING (account_id IN (SELECT id FROM public.accounts WHERE user_id = (SELECT auth.uid())))
    WITH CHECK (account_id IN (SELECT id FROM public.accounts WHERE user_id = (SELECT auth.uid())));

-- account_performance (scoped through the owning account) ----------------------
DROP POLICY IF EXISTS account_performance_all_own ON public.account_performance;
CREATE POLICY account_performance_all_own ON public.account_performance FOR ALL TO authenticated
    USING (account_id IN (SELECT id FROM public.accounts WHERE user_id = (SELECT auth.uid())))
    WITH CHECK (account_id IN (SELECT id FROM public.accounts WHERE user_id = (SELECT auth.uid())));

-- prop_firm_payouts (public reference data — readable by everyone) -------------
DROP POLICY IF EXISTS prop_firm_payouts_read_all ON public.prop_firm_payouts;
CREATE POLICY prop_firm_payouts_read_all ON public.prop_firm_payouts FOR SELECT
    TO anon, authenticated USING (true);

-- ticino_trades ---------------------------------------------------------------
DROP POLICY IF EXISTS ticino_trades_all_own ON public.ticino_trades;
CREATE POLICY ticino_trades_all_own ON public.ticino_trades FOR ALL TO authenticated
    USING (user_id = (SELECT auth.uid()))
    WITH CHECK (user_id = (SELECT auth.uid()));

-- ticino_user_secrets ---------------------------------------------------------
DROP POLICY IF EXISTS ticino_user_secrets_all_own ON public.ticino_user_secrets;
CREATE POLICY ticino_user_secrets_all_own ON public.ticino_user_secrets FOR ALL TO authenticated
    USING (user_id = (SELECT auth.uid()))
    WITH CHECK (user_id = (SELECT auth.uid()));

-- ticino_session_configs ------------------------------------------------------
DROP POLICY IF EXISTS ticino_session_configs_all_own ON public.ticino_session_configs;
CREATE POLICY ticino_session_configs_all_own ON public.ticino_session_configs FOR ALL TO authenticated
    USING (user_id = (SELECT auth.uid()))
    WITH CHECK (user_id = (SELECT auth.uid()));

-- ============================================================================
-- DATA API GRANTS
-- PostgREST requires table-level GRANTs in addition to RLS policies. RLS still
-- enforces row access; these grants only permit a role to attempt the operation.
-- ============================================================================
GRANT SELECT, INSERT, UPDATE         ON public.profiles            TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles            TO service_role;
GRANT SELECT                         ON public.prop_firms          TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.prop_firms          TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.accounts            TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.trades              TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.account_performance TO authenticated, service_role;
GRANT SELECT                         ON public.prop_firm_payouts   TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.prop_firm_payouts   TO authenticated, service_role;
GRANT SELECT                         ON public.ticino_trades       TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ticino_trades       TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ticino_user_secrets TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ticino_session_configs TO authenticated, service_role;
GRANT SELECT ON public.ticino_trade_stats_v       TO authenticated;
GRANT SELECT ON public.ticino_session_configs_v   TO authenticated;

-- ============================================================================
-- REALTIME PUBLICATION
-- The realtime stats dashboard subscribes to these tables. Membership is added
-- idempotently (the supabase_realtime publication exists by default).
-- ============================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname = 'supabase_realtime'
                   AND schemaname = 'public' AND tablename = 'ticino_trades') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.ticino_trades;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname = 'supabase_realtime'
                   AND schemaname = 'public' AND tablename = 'ticino_session_configs') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.ticino_session_configs;
  END IF;
END $$;

-- ============================================================================
-- STORAGE  (REMOVED for self-hosting)
-- The upstream schema created a private 'csv-imports' bucket + per-user
-- storage.objects policies. That depends on Supabase Storage's `storage` schema
-- (storage.buckets / storage.objects / storage.foldername), which does NOT exist
-- on a bare CloudNativePG + PostgREST stack and would fail this bootstrap.
-- The app parses CSVs client-side and never uploads, so the block is omitted.
-- If Storage is ever self-hosted, re-add it from tradeforge 0001 lines ~390-412.
-- ============================================================================

-- ============================================================================
-- DONE. Next: run seed.sql to load the prop-firm catalog.
-- ============================================================================
