--- migration:up
CREATE TABLE repositories
(
    github_id  BIGINT PRIMARY KEY,
    owner      TEXT        NOT NULL,
    name       TEXT        NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TYPE github_state AS ENUM ('open', 'closed');
CREATE TYPE github_state_reason AS ENUM ('completed', 'reopened', 'not_planned', 'duplicate');

CREATE TABLE items
(
    repository_id BIGINT       NOT NULL REFERENCES repositories (github_id),
    number        INTEGER      NOT NULL,
    github_id     BIGINT       NOT NULL,
    item_type     TEXT         NOT NULL CHECK (item_type IN ('issue', 'discussion')),
    title         TEXT         NOT NULL,
    body          TEXT,
    state         github_state NOT NULL,
    state_reason  github_state_reason,
    created_at    TIMESTAMP  NOT NULL,
    updated_at    TIMESTAMP  NOT NULL,
    PRIMARY KEY (repository_id, number)
);

CREATE INDEX idx_items_github_id ON items (repository_id, github_id);

--- migration:down
DROP TABLE items;
DROP TABLE repositories;

--- migration:end