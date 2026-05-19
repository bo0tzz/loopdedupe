-- One-row summary of the backfill pipeline state for the /backfills page.
-- 'Recent' = jobs that finished in the last 5 minutes; gives a sense of
-- whether the chain is actively churning.
SELECT
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'backfill'            AND status = 'pending')                                                                                  AS backfill_pending,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'backfill'            AND status = 'executing')                                                                                AS backfill_executing,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'backfill'            AND status = 'succeeded' AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS backfill_recent_succeeded,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'backfill'            AND status = 'failed'    AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS backfill_recent_failed,

  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'discussion_backfill' AND status = 'pending')                                                                                  AS discussion_pending,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'discussion_backfill' AND status = 'executing')                                                                                AS discussion_executing,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'discussion_backfill' AND status = 'succeeded' AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS discussion_recent_succeeded,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'discussion_backfill' AND status = 'failed'    AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS discussion_recent_failed,

  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'embeddings'          AND status = 'pending')                                                                                  AS embeddings_pending,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'embeddings'          AND status = 'executing')                                                                                AS embeddings_executing,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'embeddings'          AND status = 'succeeded' AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS embeddings_recent_succeeded,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'embeddings'          AND status = 'failed'    AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS embeddings_recent_failed,

  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'similarity'          AND status = 'pending')                                                                                  AS similarity_pending,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'similarity'          AND status = 'executing')                                                                                AS similarity_executing,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'similarity'          AND status = 'succeeded' AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS similarity_recent_succeeded,
  (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'similarity'          AND status = 'failed'    AND finished_at >= NOW() - INTERVAL '5 minutes')                                AS similarity_recent_failed,

  (SELECT MAX(github_updated_at) FROM items WHERE item_type = 'issue')                                                                                                            AS latest_issue_update,
  (SELECT MAX(github_updated_at) FROM items WHERE item_type = 'discussion')                                                                                                       AS latest_discussion_update;
