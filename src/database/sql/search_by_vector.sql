-- Ad-hoc similarity search: cosine top-N against item_embeddings for an
-- arbitrary query vector, then chain-resolve each candidate to its
-- canonical (following items.duplicate_of_number), drop dead-ends
-- (canonicals that are themselves state_reason='duplicate' with no
-- further pointer), and dedupe multiple chain members landing on the
-- same canonical.
--
-- Same shape and semantics as suggest_duplicates.sql; the difference is
-- the input — this one takes a raw vector (as text, cast on the fly)
-- rather than an existing item_id whose stored embedding drives the
-- lookup. Used by the /api/search + /search endpoints.
WITH cosine_top AS (
    SELECT item_id,
           1.0 - (embedding <=> $1::text::vector) AS similarity
    FROM item_embeddings
    ORDER BY embedding <=> $1::text::vector ASC
    LIMIT 200
),
chain_seed AS (SELECT DISTINCT item_id AS orig_id FROM cosine_top),
chain AS (
    WITH RECURSIVE walk(orig_id, current_id, depth) AS (
        SELECT orig_id, orig_id, 0 FROM chain_seed
        UNION ALL
        SELECT w.orig_id, target.github_id, w.depth + 1
        FROM walk w
                 JOIN items source ON source.github_id = w.current_id
                 JOIN items target ON target.number = source.duplicate_of_number
        WHERE source.duplicate_of_number IS NOT NULL AND w.depth < 10
    )
    SELECT * FROM walk
),
canonical AS (
    SELECT DISTINCT ON (orig_id) orig_id, current_id AS canonical_id
    FROM chain ORDER BY orig_id, depth DESC
),
resolved AS (
    SELECT c.canonical_id AS id,
           ct.similarity   AS similarity,
           canon.number,
           canon.item_type,
           canon.title,
           canon.body,
           canon.state,
           canon.state_reason
    FROM cosine_top ct
             JOIN canonical c ON c.orig_id = ct.item_id
             JOIN items canon ON canon.github_id = c.canonical_id
    WHERE canon.state_reason IS DISTINCT FROM 'duplicate'
),
deduped AS (
    SELECT DISTINCT ON (id) id, similarity, number, item_type, title, body, state, state_reason
    FROM resolved
    ORDER BY id, similarity DESC
)
SELECT id, similarity, number, item_type, title, body, state, state_reason
FROM deduped
ORDER BY similarity DESC
LIMIT 200;
