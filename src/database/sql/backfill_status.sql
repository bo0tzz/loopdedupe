-- One-row summary of the backfill pipeline state for the /backfills page.
--
-- For the paginated backfill queues, the headline 'how far along is it'
-- signal isn't pending-count (that's just the next-page job) but the
-- length of the current cursor chain. A chain starts at a job with
-- input->>'cursor' IS NULL (= a freshly-triggered backfill) and continues
-- via job-enqueues-job until the cursor returns null again. We treat any
-- chain-start within the last hour as 'current'; older chains are dormant
-- and we report no active chain.
WITH
  backfill_chain_start AS (
    SELECT created_at FROM m25.job
    WHERE queue_name = 'backfill'
      AND input->>'cursor' IS NULL
      AND created_at >= NOW() - INTERVAL '1 hour'
    ORDER BY created_at DESC LIMIT 1
  ),
  discussion_chain_start AS (
    SELECT created_at FROM m25.job
    WHERE queue_name = 'discussion_backfill'
      AND input->>'cursor' IS NULL
      AND created_at >= NOW() - INTERVAL '1 hour'
    ORDER BY created_at DESC LIMIT 1
  )
SELECT
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'backfill'            AND status = 'pending')                                                                                  AS backfill_pending,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'backfill'            AND status = 'executing')                                                                                AS backfill_executing,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'backfill'            AND status = 'succeeded' AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS backfill_recent_succeeded,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'backfill'            AND status = 'failed'    AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS backfill_recent_failed,
  -- Pages completed in the current backfill chain (0 if no chain is active)
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'backfill'            AND status = 'succeeded'
                                  AND created_at >= COALESCE((SELECT created_at FROM backfill_chain_start), NOW() + INTERVAL '1 day'))                                            AS backfill_chain_pages,
  -- Seconds since the chain start (0 / NULL if no active chain). Squirrel
  -- can't decode timestamptz, so we surface elapsed-seconds and let the UI
  -- format it.
  COALESCE(EXTRACT(EPOCH FROM (NOW() - (SELECT created_at FROM backfill_chain_start)))::int, 0)                                                                                   AS backfill_chain_age_seconds,

  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'discussion_backfill' AND status = 'pending')                                                                                  AS discussion_pending,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'discussion_backfill' AND status = 'executing')                                                                                AS discussion_executing,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'discussion_backfill' AND status = 'succeeded' AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS discussion_recent_succeeded,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'discussion_backfill' AND status = 'failed'    AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS discussion_recent_failed,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'discussion_backfill' AND status = 'succeeded'
                                  AND created_at >= COALESCE((SELECT created_at FROM discussion_chain_start), NOW() + INTERVAL '1 day'))                                          AS discussion_chain_pages,
  COALESCE(EXTRACT(EPOCH FROM (NOW() - (SELECT created_at FROM discussion_chain_start)))::int, 0)                                                                                 AS discussion_chain_age_seconds,

  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'embeddings'          AND status = 'pending')                                                                                  AS embeddings_pending,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'embeddings'          AND status = 'executing')                                                                                AS embeddings_executing,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'embeddings'          AND status = 'succeeded' AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS embeddings_recent_succeeded,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'embeddings'          AND status = 'failed'    AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS embeddings_recent_failed,

  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'similarity'          AND status = 'pending')                                                                                  AS similarity_pending,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'similarity'          AND status = 'executing')                                                                                AS similarity_executing,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'similarity'          AND status = 'succeeded' AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS similarity_recent_succeeded,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'similarity'          AND status = 'failed'    AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS similarity_recent_failed,

  -- For ETA on a full backfill: total items / 100 ≈ total pages
  (SELECT COUNT(*) FROM items WHERE item_type = 'issue')                                                                                                                          AS total_issues,
  (SELECT COUNT(*) FROM items WHERE item_type = 'discussion')                                                                                                                     AS total_discussions,

  (SELECT MAX(github_updated_at) FROM items WHERE item_type = 'issue')                                                                                                            AS latest_issue_update,
  (SELECT MAX(github_updated_at) FROM items WHERE item_type = 'discussion')                                                                                                       AS latest_discussion_update;
