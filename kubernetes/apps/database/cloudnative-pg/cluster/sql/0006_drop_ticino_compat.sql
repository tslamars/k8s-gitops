-- ============================================================================
-- 0006_drop_ticino_compat.sql
-- ----------------------------------------------------------------------------
-- PHASE 3 of the ticino -> swappybot rename (see 0005).
--
-- Removes the backward-compatibility views and wrapper function created by
-- 0005. Everything here exists only to keep the PREVIOUS reporter and web
-- images working during the cutover.
--
-- DO NOT RUN THIS UNTIL PHASE 2 IS DEPLOYED:
--   - tradeforge-selfhost source updated to the swappybot_* names
--   - BOTH the reporter and web images rebuilt, pushed, and rolled out
--   - the running deployments verified against the new names
--
-- Verify nothing still reads the old names before running:
--   SELECT schemaname, relname, seq_scan, idx_scan
--     FROM pg_stat_all_tables
--    WHERE relname LIKE 'ticino%';
-- Compat views do not accumulate stats directly, so also check the reporter
-- and web logs for PGRST205 ("Could not find the table") after the rollout.
-- ============================================================================

BEGIN;

DROP VIEW IF EXISTS public.ticino_trade_stats_v;
DROP VIEW IF EXISTS public.ticino_session_configs_v;
DROP VIEW IF EXISTS public.ticino_session_configs;
DROP VIEW IF EXISTS public.ticino_user_secrets;
DROP VIEW IF EXISTS public.ticino_trades;

DROP FUNCTION IF EXISTS public.ticino_reporter_rate_check(text, integer, integer);

COMMIT;

NOTIFY pgrst, 'reload schema';
