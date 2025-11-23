--- migration:up
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE item_embeddings
(
    item_id    BIGINT PRIMARY KEY,
    embedding  vector(2048) NOT NULL,
    model      TEXT         NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    FOREIGN KEY (item_id)
        REFERENCES items (github_id) ON DELETE CASCADE
);

--- migration:down
DROP TABLE item_embeddings;

--- migration:end