--- migration:up
-- Cache for per-source rerank results.
--
-- Drill-in flow: when /items/:source_id is loaded the dashboard fetches the
-- top cosine candidates and reorders them via Voyage rerank. That's a
-- ~300-500ms API call we don't want to repeat on every view. This table
-- stores the per-source reranked scores so subsequent views are instant.
--
-- Cache lifetime: until the source item's embedding changes. We don't
-- enforce that yet (no webhook re-embed plumbing); for now the cache is
-- effectively permanent and can be wiped by hand if the model or input
-- format changes.
CREATE TABLE item_rerank_cache
(
    source_item_id  BIGINT      NOT NULL,
    target_item_id  BIGINT      NOT NULL,
    relevance_score REAL        NOT NULL,
    computed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (source_item_id, target_item_id),
    FOREIGN KEY (source_item_id) REFERENCES items (github_id) ON DELETE CASCADE,
    FOREIGN KEY (target_item_id) REFERENCES items (github_id) ON DELETE CASCADE
);

CREATE INDEX ON item_rerank_cache (source_item_id, relevance_score DESC);

--- migration:down
DROP TABLE item_rerank_cache;

--- migration:end
