-- ============================================================================
-- Rate limiting for the ticino-reporter edge function
-- ============================================================================
-- The reporter is a public endpoint authenticated by a per-user trade secret.
-- This adds a fixed-window counter the edge function uses to limit ONLY failed
-- authentication attempts (missing/invalid secret) per client IP, to blunt
-- secret brute-forcing. Successful authenticated requests (real trades, sim,
-- and replays) are never rate limited. The counter lives in Postgres (the edge
-- function is stateless); only the service role touches it.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.ticino_reporter_rate_limit (
  bucket_key    text        NOT NULL,
  window_start  timestamptz NOT NULL,
  request_count integer     NOT NULL DEFAULT 0,
  PRIMARY KEY (bucket_key, window_start)
);

-- No policies → only the service role (which bypasses RLS) can read/write it.
ALTER TABLE public.ticino_reporter_rate_limit ENABLE ROW LEVEL SECURITY;

-- Atomic fixed-window check. Returns true if the request is within the limit,
-- false if it should be rejected (HTTP 429). Increments the current window's
-- counter and prunes the key's stale windows to keep the table bounded.
CREATE OR REPLACE FUNCTION public.ticino_reporter_rate_check(
  p_key            text,
  p_limit          integer,
  p_window_seconds integer
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_window timestamptz := to_timestamp(
    floor(extract(epoch FROM now()) / p_window_seconds) * p_window_seconds
  );
  v_count  integer;
BEGIN
  DELETE FROM public.ticino_reporter_rate_limit
    WHERE bucket_key = p_key AND window_start < v_window;

  INSERT INTO public.ticino_reporter_rate_limit AS r (bucket_key, window_start, request_count)
  VALUES (p_key, v_window, 1)
  ON CONFLICT (bucket_key, window_start)
  DO UPDATE SET request_count = r.request_count + 1
  RETURNING r.request_count INTO v_count;

  RETURN v_count <= p_limit;
END;
$$;

-- Lock the function down: clients (anon/authenticated) must never call it
-- directly; only the edge function via the service role.
REVOKE ALL ON FUNCTION public.ticino_reporter_rate_check(text, integer, integer) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ticino_reporter_rate_check(text, integer, integer) TO service_role;
