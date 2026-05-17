--- migration:up
CREATE TYPE item_state AS ENUM ('open', 'closed');
CREATE TYPE item_state_reason AS ENUM (
    'completed',
    'reopened',
    'not_planned',
    'duplicate',
    'outdated',
    'resolved'
);
CREATE TYPE item_type AS ENUM ('issue', 'discussion');
CREATE TYPE duplicate_source AS ENUM (
    'github_duplicate_of',
    'maintainer_comment_ref',
    'dashboard'
);

CREATE TABLE items
(
    github_id          BIGINT PRIMARY KEY,
    number             INTEGER   NOT NULL,
    item_type          item_type NOT NULL,
    title              TEXT      NOT NULL,
    body               TEXT      NOT NULL,
    state              item_state NOT NULL,
    state_reason       item_state_reason,
    url                TEXT      NOT NULL,
    -- Stored without time zone; always UTC by convention. squirrel can't
    -- handle timestamptz, and GitHub already gives us UTC, so we drop the
    -- tz tag rather than fight the codegen.
    github_created_at  TIMESTAMP NOT NULL,
    github_updated_at  TIMESTAMP NOT NULL,
    -- Per-repo number of the canonical item this one was marked as duplicate
    -- of. The signal is a maintainer comment of the form '#NNN' on the closed
    -- issue — GitHub's MarkedAsDuplicateEvent is rarely used in the immich
    -- workflow. Stored as number (not github_id) because that's all the
    -- comment gives us; resolution to github_id happens at query time via
    -- JOIN against items.number. No FK; dangling refs (typos, PRs,
    -- not-yet-ingested canonicals) drop out of the join naturally.
    duplicate_of_number INTEGER
);

CREATE INDEX ON items (duplicate_of_number) WHERE duplicate_of_number IS NOT NULL;
CREATE INDEX ON items (number);

CREATE INDEX ON items (github_created_at DESC);

CREATE EXTENSION IF NOT EXISTS vchord CASCADE;

CREATE TABLE item_embeddings
(
    item_id    BIGINT PRIMARY KEY,
    embedding  vector(2048) NOT NULL,
    model      TEXT         NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    FOREIGN KEY (item_id)
        REFERENCES items (github_id) ON DELETE CASCADE
);

CREATE INDEX ON item_embeddings USING vchordrq (embedding vector_cosine_ops);

CREATE TABLE item_similarity_edges
(
    source_item_id BIGINT      NOT NULL,
    target_item_id BIGINT      NOT NULL,
    similarity     REAL        NOT NULL,
    edge_type      TEXT        NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (source_item_id, target_item_id),
    FOREIGN KEY (source_item_id)
        REFERENCES items (github_id) ON DELETE CASCADE,
    FOREIGN KEY (target_item_id)
        REFERENCES items (github_id) ON DELETE CASCADE
);

CREATE INDEX ON item_similarity_edges (target_item_id);
-- Partial index over high-similarity edges only — the dashboard's top-N
-- query filters by similarity >= 0.80 first and benefits from an ordered
-- scan there. The rest of the table is rarely queried by ORDER BY similarity.
CREATE INDEX ON item_similarity_edges (similarity DESC) WHERE similarity >= 0.80;

CREATE TABLE item_duplicates
(
    source_item_id BIGINT           NOT NULL,
    target_item_id BIGINT           NOT NULL,
    source         duplicate_source NOT NULL,
    created_at     TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    PRIMARY KEY (source_item_id, target_item_id, source),
    FOREIGN KEY (source_item_id)
        REFERENCES items (github_id) ON DELETE CASCADE,
    FOREIGN KEY (target_item_id)
        REFERENCES items (github_id) ON DELETE CASCADE
);

CREATE INDEX ON item_duplicates (target_item_id);

--- migration:down
DROP TABLE item_duplicates;
DROP TABLE item_similarity_edges;
DROP TABLE item_embeddings;
DROP TABLE items;

DROP TYPE duplicate_source;
DROP TYPE item_state;
DROP TYPE item_state_reason;
DROP TYPE item_type;

--- migration:end
