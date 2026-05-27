-- ============================================================================
-- Performance indexes for unindexed foreign keys + cleanup
-- ============================================================================
-- Adds covering indexes on FK columns that Supabase Performance Advisor flagged
-- as missing. Without these, any JOIN or WHERE clause on these columns performs
-- a sequential scan. Each index is IF NOT EXISTS so the file is idempotent.
--
-- Also drops a duplicate index (idx_ticino_trades_live_entry_time) whose key
-- set is identical to the already-present idx_ticino_trades_entry_time.
--
-- pg_stat_statements is enabled here; it requires shared_preload_libraries to
-- include 'pg_stat_statements' (set in the CNPG Cluster postgresql.parameters).
-- ============================================================================

-- Foreign-key indexes
CREATE INDEX IF NOT EXISTS idx_accounts_user_id             ON public.accounts(user_id);
CREATE INDEX IF NOT EXISTS idx_accounts_prop_firm_id        ON public.accounts(prop_firm_id);
CREATE INDEX IF NOT EXISTS idx_trades_account_id            ON public.trades(account_id);
CREATE INDEX IF NOT EXISTS idx_account_performance_account_id ON public.account_performance(account_id);

-- Remove duplicate index (same key set as idx_ticino_trades_entry_time)
DROP INDEX IF EXISTS public.idx_ticino_trades_live_entry_time;

-- Query-performance statistics (requires shared_preload_libraries = 'pg_stat_statements')
CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA extensions;
