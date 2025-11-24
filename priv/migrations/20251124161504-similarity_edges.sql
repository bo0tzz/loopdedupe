--- migration:up
CREATE INDEX ON item_embeddings USING vchordrq (embedding vector_cosine_ops);
CREATE TYPE edge_type AS ENUM ('computed', 'github_duplicate', 'manual');

CREATE TABLE item_similarity_edges
(
    source_item_id BIGINT      NOT NULL,
    target_item_id BIGINT      NOT NULL,
    similarity     FLOAT       NOT NULL CHECK (similarity >= 0 AND similarity <= 1),
    edge_type      edge_type   NOT NULL,
    computed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (source_item_id, target_item_id),
    FOREIGN KEY (source_item_id) REFERENCES items (github_id) ON DELETE CASCADE,
    FOREIGN KEY (target_item_id) REFERENCES items (github_id) ON DELETE CASCADE
);

CREATE INDEX idx_edges_source ON item_similarity_edges (source_item_id, similarity DESC);
CREATE INDEX idx_edges_target ON item_similarity_edges (target_item_id, similarity DESC);

--- migration:down
DROP TABLE item_similarity_edges;
DROP TYPE edge_type;
--- migration:end