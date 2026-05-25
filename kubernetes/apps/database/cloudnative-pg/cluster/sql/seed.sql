-- ============================================================================
-- TradeForge — seed data (prop-firm catalog)
-- ============================================================================
-- Run AFTER schema.sql. Loads the shareable, non-personal reference data:
--   * 10 prop-firm rule templates
--   *  6 payout-rule templates (matched to firms by name, so no hard-coded ids)
-- Idempotent: safe to re-run; existing rows are updated, not duplicated.
-- Contains NO personal data (no users, accounts, or trades).
-- ============================================================================

-- prop_firms ------------------------------------------------------------------
INSERT INTO public.prop_firms (name, daily_drawdown_pct, max_drawdown_pct, profit_target_pct, rules_description) VALUES
  ('Apex Trader Funding', 2.50, 6.00, 6.00, 'Trailing drawdown from peak balance. No scaling required.'),
  ('Topstep',             2.00, 4.50, 6.00, 'EOD trailing drawdown. Scaling plan available.'),
  ('FTMO',                5.00,10.00,10.00, 'Balance-based drawdown. 30-day challenge period.'),
  ('MyFundedFutures',     3.00, 5.00, 8.00, 'Trailing drawdown. Consistency rules apply.'),
  ('Earn2Trade',          2.00, 4.00, 6.00, 'EOD drawdown calculation. Gauntlet Mini available.'),
  ('TradeDay',            3.00, 6.00, 6.00, 'Real-time trailing drawdown. No time limit.'),
  ('Rithmic',             2.50, 5.00, 6.00, 'Platform-specific rules. Used by multiple prop firms.'),
  ('NinjaTrader',         2.00, 4.00, 5.00, 'Built-in risk management. Supports multiple brokers.'),
  ('LucidTrading',        2.50, 5.50, 7.00, 'Progressive scaling program. Flexible withdrawal.'),
  ('The Trading Pit',     4.00, 8.00, 8.00, 'Dynamic drawdown system. Multi-asset trading.')
ON CONFLICT (name) DO UPDATE SET
  daily_drawdown_pct = EXCLUDED.daily_drawdown_pct,
  max_drawdown_pct   = EXCLUDED.max_drawdown_pct,
  profit_target_pct  = EXCLUDED.profit_target_pct,
  rules_description  = EXCLUDED.rules_description;

-- prop_firm_payouts (keyed by firm name → resolves to the firm's generated id) -
INSERT INTO public.prop_firm_payouts
  (prop_firm_id, default_profit_split, max_profit_split, profit_split_type,
   first_payout_wait_days, payout_frequency_days, payout_window_start, payout_window_end,
   minimum_payout, maximum_payout, min_trading_days, min_winning_days,
   winning_day_threshold, consistency_rule_pct, processing_days, payment_methods, is_active, notes)
SELECT pf.id, v.default_profit_split, v.max_profit_split, v.profit_split_type,
       v.first_payout_wait_days, v.payout_frequency_days, v.payout_window_start, v.payout_window_end,
       v.minimum_payout, v.maximum_payout, v.min_trading_days, v.min_winning_days,
       v.winning_day_threshold, v.consistency_rule_pct, v.processing_days, v.payment_methods, v.is_active, v.notes
FROM (VALUES
  ('Apex Trader Funding',100.00,90.00,'tiered',  8, 15,   1,   5, NULL::numeric,25000.00,NULL::int,NULL::int,NULL::numeric,30.00, 3, ARRAY['ACH','Wire','PayPal'],             true, '100% profit on first $25K, then 90%. Payout windows: 1st-5th and 15th-19th of each month.'),
  ('Topstep',            100.00,90.00,'tiered',  NULL, 0, NULL,NULL, 125.00, NULL,    NULL,    5,       200.00,        NULL,  3, ARRAY['ACH','Wire','PayPal'],             true, '100% profit on first $10K, then 90%. Request payout after 5 winning days ($200+ profit each). No fixed schedule.'),
  ('FTMO',                80.00,90.00,'scaling', 14, 0, NULL,NULL,  20.00, NULL,    4,       NULL,    NULL,          NULL,  2, ARRAY['Bank Transfer','Skrill','Crypto'], true, '80% base split, scaling to 90% for consistent traders. First payout after 14 days, then on-demand within 14-60 day cycle.'),
  ('MyFundedFutures',     90.00,90.00,'fixed',    7, 14, NULL,NULL,  50.00, NULL,    NULL,    NULL,    NULL,          40.00, 3, ARRAY['ACH','Wire','PayPal'],             true, '90% profit split. Bi-weekly payouts after initial 7-day waiting period. 40% consistency rule.'),
  ('Earn2Trade',          80.00,80.00,'fixed',   14, 14, NULL,NULL,  50.00, NULL,    NULL,    NULL,    NULL,          NULL,  5, ARRAY['ACH','Wire'],                      true, '80% profit split. Bi-weekly payouts after 14-day waiting period.'),
  ('TradeDay',            90.00,90.00,'fixed',    7,  7, NULL,NULL, 100.00, NULL,    NULL,    NULL,    NULL,          NULL,  2, ARRAY['ACH','Wire','PayPal','Crypto'],    true, '90% profit split. Weekly payouts after 7-day waiting period.')
) AS v(firm_name, default_profit_split, max_profit_split, profit_split_type,
       first_payout_wait_days, payout_frequency_days, payout_window_start, payout_window_end,
       minimum_payout, maximum_payout, min_trading_days, min_winning_days,
       winning_day_threshold, consistency_rule_pct, processing_days, payment_methods, is_active, notes)
JOIN public.prop_firms pf ON pf.name = v.firm_name
ON CONFLICT (prop_firm_id) DO NOTHING;

-- ============================================================================
-- DONE.
-- ============================================================================
