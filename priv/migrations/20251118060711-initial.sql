--- migration:up
CREATE TYPE github_state AS ENUM ('open', 'closed');
CREATE TYPE github_state_reason AS ENUM ('completed', 'reopened', 'not_planned', 'duplicate');
CREATE TYPE item_type AS ENUM ('issue', 'discussion');

CREATE TABLE items
(
    github_id    BIGINT PRIMARY KEY,
    number       INTEGER      NOT NULL,
    item_type    item_type    NOT NULL,
    title        TEXT         NOT NULL,
    body         TEXT         NOT NULL,
    state        github_state NOT NULL,
    state_reason github_state_reason,
    url          TEXT         NOT NULL
);

--- migration:down
DROP TABLE items;

DROP TYPE github_state;
DROP TYPE github_state_reason;
DROP TYPE item_type;

--- migration:end