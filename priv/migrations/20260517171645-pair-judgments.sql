--- migration:up
-- Per-pair maintainer judgments — for now just 'not_duplicate' so dismissed
-- pairs stop reappearing in the candidates feed. Enum so we can extend
-- later (confirmed_duplicate, related, etc.) with ALTER TYPE ADD VALUE.
--
-- Pairs are stored in canonical order (source <= target) so we only ever
-- have one row per logical pair regardless of which direction the edge
-- came from. INSERT helpers use LEAST/GREATEST to normalize on the way in.
CREATE TYPE pair_verdict AS ENUM ('not_duplicate');

CREATE TABLE pair_judgments
(
    source_item_id BIGINT       NOT NULL,
    target_item_id BIGINT       NOT NULL,
    verdict        pair_verdict NOT NULL,
    judged_at      TIMESTAMP    NOT NULL DEFAULT now(),
    PRIMARY KEY (source_item_id, target_item_id, verdict),
    CHECK (source_item_id <= target_item_id),
    FOREIGN KEY (source_item_id) REFERENCES items (github_id) ON DELETE CASCADE,
    FOREIGN KEY (target_item_id) REFERENCES items (github_id) ON DELETE CASCADE
);

--- migration:down
DROP TABLE pair_judgments;
DROP TYPE pair_verdict;

--- migration:end
