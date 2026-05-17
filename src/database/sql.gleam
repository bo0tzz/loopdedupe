//// This module contains the code to run the sql queries defined in
//// `./src/database/sql`.
//// > 🐿️ This module was generated automatically using v4.6.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}
import pog

/// Runs the `clear_duplicate_of` query
/// defined in `./src/database/sql/clear_duplicate_of.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn clear_duplicate_of(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "UPDATE items
SET duplicate_of_number = NULL
WHERE github_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `compute_edges` query
/// defined in `./src/database/sql/compute_edges.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn compute_edges(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "WITH item_embedding AS (SELECT embedding
                        FROM item_embeddings
                        WHERE item_id = $1),
     similar_items AS (SELECT e.item_id,
                              1 - (e.embedding <=> (SELECT embedding FROM item_embedding)) as similarity
                       FROM item_embeddings e
                       WHERE e.item_id != $1
                       ORDER BY e.embedding <=> (SELECT embedding FROM item_embedding)
                       LIMIT 50)
INSERT
INTO item_similarity_edges
    (source_item_id, target_item_id, similarity, edge_type)
SELECT $1,
       item_id,
       similarity,
       'computed'
FROM similar_items
WHERE similarity >= 0.7"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `dashboard_recent_items` query
/// defined in `./src/database/sql/dashboard_recent_items.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type DashboardRecentItemsRow {
  DashboardRecentItemsRow(
    github_id: Int,
    number: Int,
    item_type: ItemType,
    title: String,
    state: ItemState,
    state_reason: Option(ItemStateReason),
    url: String,
    github_created_at: Timestamp,
  )
}

/// Runs the `dashboard_recent_items` query
/// defined in `./src/database/sql/dashboard_recent_items.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn dashboard_recent_items(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(DashboardRecentItemsRow), pog.QueryError) {
  let decoder = {
    use github_id <- decode.field(0, decode.int)
    use number <- decode.field(1, decode.int)
    use item_type <- decode.field(2, item_type_decoder())
    use title <- decode.field(3, decode.string)
    use state <- decode.field(4, item_state_decoder())
    use state_reason <- decode.field(
      5,
      decode.optional(item_state_reason_decoder()),
    )
    use url <- decode.field(6, decode.string)
    use github_created_at <- decode.field(7, pog.timestamp_decoder())
    decode.success(DashboardRecentItemsRow(
      github_id:,
      number:,
      item_type:,
      title:,
      state:,
      state_reason:,
      url:,
      github_created_at:,
    ))
  }

  "SELECT github_id,
       number,
       item_type,
       title,
       state,
       state_reason,
       url,
       github_created_at
FROM items
ORDER BY github_created_at DESC
LIMIT $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `dashboard_stats` query
/// defined in `./src/database/sql/dashboard_stats.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type DashboardStatsRow {
  DashboardStatsRow(
    items_total: Int,
    items_issues: Int,
    items_discussions: Int,
    embeddings_total: Int,
    edges_total: Int,
    duplicates_total: Int,
    jobs_backfill_pending: Int,
    jobs_embeddings_pending: Int,
    jobs_similarity_pending: Int,
    jobs_failed: Int,
  )
}

/// Runs the `dashboard_stats` query
/// defined in `./src/database/sql/dashboard_stats.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn dashboard_stats(
  db: pog.Connection,
) -> Result(pog.Returned(DashboardStatsRow), pog.QueryError) {
  let decoder = {
    use items_total <- decode.field(0, decode.int)
    use items_issues <- decode.field(1, decode.int)
    use items_discussions <- decode.field(2, decode.int)
    use embeddings_total <- decode.field(3, decode.int)
    use edges_total <- decode.field(4, decode.int)
    use duplicates_total <- decode.field(5, decode.int)
    use jobs_backfill_pending <- decode.field(6, decode.int)
    use jobs_embeddings_pending <- decode.field(7, decode.int)
    use jobs_similarity_pending <- decode.field(8, decode.int)
    use jobs_failed <- decode.field(9, decode.int)
    decode.success(DashboardStatsRow(
      items_total:,
      items_issues:,
      items_discussions:,
      embeddings_total:,
      edges_total:,
      duplicates_total:,
      jobs_backfill_pending:,
      jobs_embeddings_pending:,
      jobs_similarity_pending:,
      jobs_failed:,
    ))
  }

  "SELECT (SELECT COUNT(*) FROM items)                                           AS items_total,
       (SELECT COUNT(*) FROM items WHERE item_type = 'issue')                 AS items_issues,
       (SELECT COUNT(*) FROM items WHERE item_type = 'discussion')            AS items_discussions,
       (SELECT COUNT(*) FROM item_embeddings)                                 AS embeddings_total,
       (SELECT COUNT(*) FROM item_similarity_edges)                           AS edges_total,
       (SELECT COUNT(*) FROM item_duplicates)                                 AS duplicates_total,
       (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'backfill'    AND status = 'pending')   AS jobs_backfill_pending,
       (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'embeddings'  AND status = 'pending')   AS jobs_embeddings_pending,
       (SELECT COUNT(*) FROM m25.job WHERE queue_name = 'similarity'  AND status = 'pending')   AS jobs_similarity_pending,
       (SELECT COUNT(*) FROM m25.job WHERE status = 'failed')                                   AS jobs_failed;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `dashboard_top_pairs` query
/// defined in `./src/database/sql/dashboard_top_pairs.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type DashboardTopPairsRow {
  DashboardTopPairsRow(
    similarity: Float,
    source_id: Int,
    source_number: Int,
    source_title: String,
    source_item_type: ItemType,
    source_state: ItemState,
    source_state_reason: Option(ItemStateReason),
    source_original_id: Int,
    target_id: Int,
    target_number: Int,
    target_title: String,
    target_item_type: ItemType,
    target_state: ItemState,
    target_state_reason: Option(ItemStateReason),
    target_original_id: Int,
  )
}

/// Resolves each side of every similarity edge through the duplicate_of chain
/// to its canonical, then filters and deduplicates to actionable pairs.
/// 
/// Chain walk: items.duplicate_of_number (per-repo number of the canonical) →
/// items.number (lookup). Dangling refs (PRs, cross-repo, typos) drop out of
/// the join naturally because the target won't be in items.
/// 
/// A pair is actionable when:
/// - the two canonicals differ (otherwise the edge just connects two
/// instances of the same logical issue),
/// - at least one canonical is open (the maintainer can do something),
/// - the pair isn't already recorded as a known dupe in item_duplicates.
/// 
/// We still drop pairs where either side is state_reason='duplicate' WITHOUT a
/// captured duplicate_of_number — those are dupes we know about but can't
/// resolve. They reappear once the canonical is captured.
/// 
/// Deduplication: item_similarity_edges stores both directions of each pair
/// (each side gets embedded and computes its own kNN), so without a final
/// pass on the unordered pair (LEAST/GREATEST) the same suggestion shows up
/// twice in the feed.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn dashboard_top_pairs(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(DashboardTopPairsRow), pog.QueryError) {
  let decoder = {
    use similarity <- decode.field(0, decode.float)
    use source_id <- decode.field(1, decode.int)
    use source_number <- decode.field(2, decode.int)
    use source_title <- decode.field(3, decode.string)
    use source_item_type <- decode.field(4, item_type_decoder())
    use source_state <- decode.field(5, item_state_decoder())
    use source_state_reason <- decode.field(
      6,
      decode.optional(item_state_reason_decoder()),
    )
    use source_original_id <- decode.field(7, decode.int)
    use target_id <- decode.field(8, decode.int)
    use target_number <- decode.field(9, decode.int)
    use target_title <- decode.field(10, decode.string)
    use target_item_type <- decode.field(11, item_type_decoder())
    use target_state <- decode.field(12, item_state_decoder())
    use target_state_reason <- decode.field(
      13,
      decode.optional(item_state_reason_decoder()),
    )
    use target_original_id <- decode.field(14, decode.int)
    decode.success(DashboardTopPairsRow(
      similarity:,
      source_id:,
      source_number:,
      source_title:,
      source_item_type:,
      source_state:,
      source_state_reason:,
      source_original_id:,
      target_id:,
      target_number:,
      target_title:,
      target_item_type:,
      target_state:,
      target_state_reason:,
      target_original_id:,
    ))
  }

  "-- Resolves each side of every similarity edge through the duplicate_of chain
-- to its canonical, then filters and deduplicates to actionable pairs.
--
-- Chain walk: items.duplicate_of_number (per-repo number of the canonical) →
-- items.number (lookup). Dangling refs (PRs, cross-repo, typos) drop out of
-- the join naturally because the target won't be in items.
--
-- A pair is actionable when:
--   - the two canonicals differ (otherwise the edge just connects two
--     instances of the same logical issue),
--   - at least one canonical is open (the maintainer can do something),
--   - the pair isn't already recorded as a known dupe in item_duplicates.
--
-- We still drop pairs where either side is state_reason='duplicate' WITHOUT a
-- captured duplicate_of_number — those are dupes we know about but can't
-- resolve. They reappear once the canonical is captured.
--
-- Deduplication: item_similarity_edges stores both directions of each pair
-- (each side gets embedded and computes its own kNN), so without a final
-- pass on the unordered pair (LEAST/GREATEST) the same suggestion shows up
-- twice in the feed.
WITH RECURSIVE chain(orig_id, current_id, depth) AS (
    SELECT github_id, github_id, 0
    FROM items

    UNION ALL

    SELECT c.orig_id, target.github_id, c.depth + 1
    FROM chain c
             JOIN items source ON source.github_id = c.current_id
             JOIN items target ON target.number = source.duplicate_of_number
    WHERE source.duplicate_of_number IS NOT NULL
      AND c.depth < 10
),
canonical AS (
    SELECT DISTINCT ON (orig_id) orig_id, current_id AS canonical_id
    FROM chain
    ORDER BY orig_id, depth DESC
),
resolved AS (
    SELECT e.similarity,
           src_can.canonical_id                                                AS source_id,
           src_info.number                                                     AS source_number,
           src_info.title                                                      AS source_title,
           src_info.item_type                                                  AS source_item_type,
           src_info.state                                                      AS source_state,
           src_info.state_reason                                               AS source_state_reason,
           e.source_item_id                                                    AS source_original_id,
           tgt_can.canonical_id                                                AS target_id,
           tgt_info.number                                                     AS target_number,
           tgt_info.title                                                      AS target_title,
           tgt_info.item_type                                                  AS target_item_type,
           tgt_info.state                                                      AS target_state,
           tgt_info.state_reason                                               AS target_state_reason,
           e.target_item_id                                                    AS target_original_id,
           LEAST(src_can.canonical_id, tgt_can.canonical_id)                   AS pair_lo,
           GREATEST(src_can.canonical_id, tgt_can.canonical_id)                AS pair_hi
    FROM item_similarity_edges e
             JOIN canonical src_can ON src_can.orig_id = e.source_item_id
             JOIN canonical tgt_can ON tgt_can.orig_id = e.target_item_id
             JOIN items src_info ON src_info.github_id = src_can.canonical_id
             JOIN items tgt_info ON tgt_info.github_id = tgt_can.canonical_id
    WHERE src_can.canonical_id != tgt_can.canonical_id
      AND (src_info.state = 'open' OR tgt_info.state = 'open')
      AND src_info.state_reason IS DISTINCT FROM 'duplicate'
      AND tgt_info.state_reason IS DISTINCT FROM 'duplicate'
      AND NOT EXISTS (SELECT 1
                      FROM item_duplicates d
                      WHERE (d.source_item_id = src_can.canonical_id AND d.target_item_id = tgt_can.canonical_id)
                         OR (d.source_item_id = tgt_can.canonical_id AND d.target_item_id = src_can.canonical_id))
),
deduped AS (
    SELECT DISTINCT ON (pair_lo, pair_hi) *
    FROM resolved
    ORDER BY pair_lo, pair_hi, similarity DESC
)
SELECT similarity,
       source_id, source_number, source_title, source_item_type,
       source_state, source_state_reason, source_original_id,
       target_id, target_number, target_title, target_item_type,
       target_state, target_state_reason, target_original_id
FROM deduped
ORDER BY similarity DESC
LIMIT $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `list_items` query
/// defined in `./src/database/sql/list_items.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ListItemsRow {
  ListItemsRow(
    github_id: Int,
    number: Int,
    item_type: ItemType,
    title: String,
    body: String,
    state: ItemState,
    state_reason: Option(ItemStateReason),
    url: String,
    github_created_at: Timestamp,
    github_updated_at: Timestamp,
    duplicate_of_number: Option(Int),
  )
}

/// Runs the `list_items` query
/// defined in `./src/database/sql/list_items.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn list_items(
  db: pog.Connection,
) -> Result(pog.Returned(ListItemsRow), pog.QueryError) {
  let decoder = {
    use github_id <- decode.field(0, decode.int)
    use number <- decode.field(1, decode.int)
    use item_type <- decode.field(2, item_type_decoder())
    use title <- decode.field(3, decode.string)
    use body <- decode.field(4, decode.string)
    use state <- decode.field(5, item_state_decoder())
    use state_reason <- decode.field(
      6,
      decode.optional(item_state_reason_decoder()),
    )
    use url <- decode.field(7, decode.string)
    use github_created_at <- decode.field(8, pog.timestamp_decoder())
    use github_updated_at <- decode.field(9, pog.timestamp_decoder())
    use duplicate_of_number <- decode.field(10, decode.optional(decode.int))
    decode.success(ListItemsRow(
      github_id:,
      number:,
      item_type:,
      title:,
      body:,
      state:,
      state_reason:,
      url:,
      github_created_at:,
      github_updated_at:,
      duplicate_of_number:,
    ))
  }

  "SELECT * FROM items;"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `select_item` query
/// defined in `./src/database/sql/select_item.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type SelectItemRow {
  SelectItemRow(
    github_id: Int,
    number: Int,
    title: String,
    body: String,
    state: ItemState,
    state_reason: Option(ItemStateReason),
    url: String,
    github_created_at: Timestamp,
    github_updated_at: Timestamp,
  )
}

/// Runs the `select_item` query
/// defined in `./src/database/sql/select_item.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn select_item(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(SelectItemRow), pog.QueryError) {
  let decoder = {
    use github_id <- decode.field(0, decode.int)
    use number <- decode.field(1, decode.int)
    use title <- decode.field(2, decode.string)
    use body <- decode.field(3, decode.string)
    use state <- decode.field(4, item_state_decoder())
    use state_reason <- decode.field(
      5,
      decode.optional(item_state_reason_decoder()),
    )
    use url <- decode.field(6, decode.string)
    use github_created_at <- decode.field(7, pog.timestamp_decoder())
    use github_updated_at <- decode.field(8, pog.timestamp_decoder())
    decode.success(SelectItemRow(
      github_id:,
      number:,
      title:,
      body:,
      state:,
      state_reason:,
      url:,
      github_created_at:,
      github_updated_at:,
    ))
  }

  "SELECT github_id, number, title, body, state, state_reason, url, github_created_at, github_updated_at
FROM items
WHERE github_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `set_duplicate_of` query
/// defined in `./src/database/sql/set_duplicate_of.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn set_duplicate_of(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "UPDATE items
SET duplicate_of_number = $2
WHERE github_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `suggest_duplicates` query
/// defined in `./src/database/sql/suggest_duplicates.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type SuggestDuplicatesRow {
  SuggestDuplicatesRow(
    target_item_id: Int,
    similarity: Float,
    title: String,
    state: ItemState,
    state_reason: Option(ItemStateReason),
  )
}

/// Runs the `suggest_duplicates` query
/// defined in `./src/database/sql/suggest_duplicates.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn suggest_duplicates(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Float,
) -> Result(pog.Returned(SuggestDuplicatesRow), pog.QueryError) {
  let decoder = {
    use target_item_id <- decode.field(0, decode.int)
    use similarity <- decode.field(1, decode.float)
    use title <- decode.field(2, decode.string)
    use state <- decode.field(3, item_state_decoder())
    use state_reason <- decode.field(
      4,
      decode.optional(item_state_reason_decoder()),
    )
    decode.success(SuggestDuplicatesRow(
      target_item_id:,
      similarity:,
      title:,
      state:,
      state_reason:,
    ))
  }

  "WITH all_edges AS (
    SELECT target_item_id, similarity
    FROM item_similarity_edges
    WHERE source_item_id = $1
      AND similarity >= $2

    UNION

    SELECT source_item_id, similarity
    FROM item_similarity_edges
    WHERE target_item_id = $1
      AND similarity >= $2
)
SELECT
    ae.target_item_id,
    ae.similarity,
    i.title,
    i.state,
    i.state_reason
FROM all_edges ae
         JOIN items i ON i.github_id = ae.target_item_id
ORDER BY ae.similarity DESC
LIMIT 10;"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.float(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `upsert_item` query
/// defined in `./src/database/sql/upsert_item.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn upsert_item(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: ItemType,
  arg_4: String,
  arg_5: String,
  arg_6: ItemState,
  arg_7: ItemStateReason,
  arg_8: String,
  arg_9: Timestamp,
  arg_10: Timestamp,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "INSERT INTO items (github_id, number, item_type, title, body, state, state_reason, url, github_created_at, github_updated_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
ON CONFLICT (github_id) DO UPDATE
    SET number            = EXCLUDED.number,
        title             = EXCLUDED.title,
        body              = EXCLUDED.body,
        state             = EXCLUDED.state,
        state_reason      = EXCLUDED.state_reason,
        url               = EXCLUDED.url,
        github_updated_at = EXCLUDED.github_updated_at;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(item_type_encoder(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(item_state_encoder(arg_6))
  |> pog.parameter(item_state_reason_encoder(arg_7))
  |> pog.parameter(pog.text(arg_8))
  |> pog.parameter(pog.timestamp(arg_9))
  |> pog.parameter(pog.timestamp(arg_10))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `upsert_item_without_reason` query
/// defined in `./src/database/sql/upsert_item_without_reason.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn upsert_item_without_reason(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: ItemType,
  arg_4: String,
  arg_5: String,
  arg_6: ItemState,
  arg_7: String,
  arg_8: Timestamp,
  arg_9: Timestamp,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "INSERT INTO items (github_id, number, item_type, title, body, state, url, github_created_at, github_updated_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
ON CONFLICT (github_id) DO UPDATE
    SET number            = EXCLUDED.number,
        title             = EXCLUDED.title,
        body              = EXCLUDED.body,
        state             = EXCLUDED.state,
        state_reason      = NULL,
        url               = EXCLUDED.url,
        github_updated_at = EXCLUDED.github_updated_at;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(item_type_encoder(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(item_state_encoder(arg_6))
  |> pog.parameter(pog.text(arg_7))
  |> pog.parameter(pog.timestamp(arg_8))
  |> pog.parameter(pog.timestamp(arg_9))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

// --- Enums -------------------------------------------------------------------

/// Corresponds to the Postgres `item_state` enum.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ItemState {
  Closed
  Open
}

fn item_state_decoder() -> decode.Decoder(ItemState) {
  use item_state <- decode.then(decode.string)
  case item_state {
    "closed" -> decode.success(Closed)
    "open" -> decode.success(Open)
    _ -> decode.failure(Closed, "ItemState")
  }
}

fn item_state_encoder(item_state) -> pog.Value {
  case item_state {
    Closed -> "closed"
    Open -> "open"
  }
  |> pog.text
}/// Corresponds to the Postgres `item_state_reason` enum.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ItemStateReason {
  Resolved
  Outdated
  Duplicate
  NotPlanned
  Reopened
  Completed
}

fn item_state_reason_decoder() -> decode.Decoder(ItemStateReason) {
  use item_state_reason <- decode.then(decode.string)
  case item_state_reason {
    "resolved" -> decode.success(Resolved)
    "outdated" -> decode.success(Outdated)
    "duplicate" -> decode.success(Duplicate)
    "not_planned" -> decode.success(NotPlanned)
    "reopened" -> decode.success(Reopened)
    "completed" -> decode.success(Completed)
    _ -> decode.failure(Resolved, "ItemStateReason")
  }
}

fn item_state_reason_encoder(item_state_reason) -> pog.Value {
  case item_state_reason {
    Resolved -> "resolved"
    Outdated -> "outdated"
    Duplicate -> "duplicate"
    NotPlanned -> "not_planned"
    Reopened -> "reopened"
    Completed -> "completed"
  }
  |> pog.text
}/// Corresponds to the Postgres `item_type` enum.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ItemType {
  Discussion
  Issue
}

fn item_type_decoder() -> decode.Decoder(ItemType) {
  use item_type <- decode.then(decode.string)
  case item_type {
    "discussion" -> decode.success(Discussion)
    "issue" -> decode.success(Issue)
    _ -> decode.failure(Discussion, "ItemType")
  }
}

fn item_type_encoder(item_type) -> pog.Value {
  case item_type {
    Discussion -> "discussion"
    Issue -> "issue"
  }
  |> pog.text
}
