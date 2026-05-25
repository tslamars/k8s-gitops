-- ============================================================================
-- Security hardening — drop world-readable RLS policies
-- ============================================================================
-- Three SELECT policies had been added ad hoc (via the Supabase dashboard) with
-- USING (true) for the anon/public role. Because the anon key ships in the
-- client bundle, these exposed every user's data to anyone:
--   * ticino_trades            — all users' trade history
--   * ticino_session_configs   — all users' bot/strategy settings
-- and a redundant duplicate public-read on the prop_firms catalog table.
--
-- RLS policies are OR'd, so these permissive policies overrode the correct
-- owner-scoped (*_all_own) policies. The owner-scoped policies remain in place;
-- the Sierra Chart reporter writes via the service role (bypasses RLS) and the
-- dashboard reads as the authenticated owner, so nothing legitimate relied on
-- these. Idempotent and safe to re-run.
-- ============================================================================

DROP POLICY IF EXISTS "Public can read ticino_trades" ON public.ticino_trades;
DROP POLICY IF EXISTS "Anon and auth can read ticino_session_configs" ON public.ticino_session_configs;
DROP POLICY IF EXISTS "Allow anon read access to prop_firms" ON public.prop_firms;
