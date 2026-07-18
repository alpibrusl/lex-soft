-- lex-soft — data retention (GDPR-05, storage limitation, Art. 5(1)(e)).
--
-- The agent trace log and durable agent memory accumulate free-text that can
-- contain personal data (driver names, preferences, home depots) and are fed
-- back into model prompts. They currently grow unbounded. This schedules a
-- daily purge via pg_cron (runs as the job owner, so it is not affected by RLS).
--
-- On Supabase: enable pg_cron (Dashboard → Database → Extensions), then run this
-- as `postgres`. Adjust the windows to your lawful basis / DPIA.
--
--   traces:                 90 days
--   agent_memory (expired): as soon as a fact's own expires_at has passed
--   agent_memory (hard cap): 365 days regardless of expiry

CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$ BEGIN
  PERFORM cron.unschedule('lex_soft_retention');
EXCEPTION WHEN OTHERS THEN NULL; END $$;

SELECT cron.schedule('lex_soft_retention', '23 3 * * *', $job$
  DELETE FROM traces       WHERE ts <> ''         AND ts::timestamptz         < now() - interval '90 days';
  DELETE FROM agent_memory WHERE expires_at <> '' AND expires_at::timestamptz < now();
  DELETE FROM agent_memory WHERE ts <> ''         AND ts::timestamptz         < now() - interval '365 days';
$job$);

-- Note: agent_memory already carries expires_at, but the app only *filters*
-- expired facts out of recall — it never deletes them. This job actually removes
-- them, which is what the storage-limitation principle requires.
