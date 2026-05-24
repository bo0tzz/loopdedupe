import database/sql
import embeddings/voyage
import github/types
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import logging
import pog
import snag

fn sql_into_state(sql: sql.ItemState) -> types.ItemState {
  case sql {
    sql.Open -> types.Open
    sql.Closed -> types.Closed
  }
}

fn state_into_sql(state: types.ItemState) -> sql.ItemState {
  case state {
    types.Open -> sql.Open
    types.Closed -> sql.Closed
  }
}

fn sql_into_state_reason(
  sql: Option(sql.ItemStateReason),
) -> Option(types.ItemStateReason) {
  option.map(sql, fn(reason) {
    case reason {
      sql.Reopened -> types.Reopened
      sql.NotPlanned -> types.NotPlanned
      sql.Duplicate -> types.Duplicate
      sql.Completed -> types.Completed
      sql.Outdated -> types.Outdated
      sql.Resolved -> types.Resolved
    }
  })
}

fn state_reason_into_sql(
  reason: Option(types.ItemStateReason),
) -> Option(sql.ItemStateReason) {
  option.map(reason, fn(reason) {
    case reason {
      types.Reopened -> sql.Reopened
      types.NotPlanned -> sql.NotPlanned
      types.Duplicate -> sql.Duplicate
      types.Completed -> sql.Completed
      types.Outdated -> sql.Outdated
      types.Resolved -> sql.Resolved
    }
  })
}

// squirrel can't express a nullable parameter, so the upsert is split:
// when state_reason is Some we use upsert_item, when None we use
// upsert_item_without_reason which omits the column from the INSERT and
// nulls it in the UPDATE branch.
//
// `kind` flags whether the row is an issue or a discussion — both share the
// same DB shape, the column just records which GitHub surface it came from.
pub fn upsert(db: pog.Connection, kind: sql.ItemType, item: types.Item) {
  let state = state_into_sql(item.state)
  case state_reason_into_sql(item.state_reason) {
    option.Some(reason) ->
      sql.upsert_item(
        db,
        item.github_id,
        item.number,
        kind,
        item.title,
        item.body,
        state,
        reason,
        item.url,
        item.created_at,
        item.updated_at,
      )
    option.None ->
      sql.upsert_item_without_reason(
        db,
        item.github_id,
        item.number,
        kind,
        item.title,
        item.body,
        state,
        item.url,
        item.created_at,
        item.updated_at,
      )
  }
}

pub fn list(db: pog.Connection) -> Result(List(types.Item), pog.QueryError) {
  sql.list_items(db) |> result.map(map_items)
}

// Backfill knows the full duplicate state of an item from the GitHub
// timeline. Some => point at canonical; None => the item is not marked as
// a duplicate of anything (clear whatever was there). Webhook doesn't call
// this — it lacks the timeline data, so it preserves whatever's stored.
pub fn apply_duplicate_of(
  db: pog.Connection,
  github_id: Int,
  target: option.Option(Int),
) -> Result(pog.Returned(Nil), pog.QueryError) {
  case target {
    option.Some(t) -> sql.set_duplicate_of(db, github_id, t)
    option.None -> sql.clear_duplicate_of(db, github_id)
  }
}

// Same shape as apply_duplicate_of for the items.author_login column.
// Author is captured at backfill time from the GraphQL response; webhook
// payloads use a different field name (user.login vs author.login) so we
// don't currently update author on webhook events.
pub fn apply_author(
  db: pog.Connection,
  github_id: Int,
  author: option.Option(String),
) -> Result(pog.Returned(Nil), pog.QueryError) {
  case author {
    option.Some(login) -> sql.set_author(db, github_id, login)
    option.None -> sql.clear_author(db, github_id)
  }
}

// Closer login, captured from the ClosedEvent timeline entry at backfill.
// Discussions always pass None (their GraphQL type has no timeline).
pub fn apply_closed_by(
  db: pog.Connection,
  github_id: Int,
  closer: option.Option(String),
) -> Result(pog.Returned(Nil), pog.QueryError) {
  case closer {
    option.Some(login) -> sql.set_closed_by(db, github_id, login)
    option.None -> sql.clear_closed_by(db, github_id)
  }
}

pub fn select(
  db: pog.Connection,
  item_id: Int,
) -> Result(types.Item, snag.Snag) {
  sql.select_item(db, item_id)
  |> map_item()
}

pub fn suggest_duplicates(db: pog.Connection, item_id: Int) {
  // Two-stage retrieval with lazy cache:
  //   1. If item_rerank_cache has rows for this source, serve from there.
  //   2. Otherwise: pull the top-50 cosine candidates (threshold 0.75 —
  //      tuned for ~94% recall on ground-truth dupes), ask Voyage
  //      rerank-2.5 to rescore them with the full text, store the scores
  //      in the cache, and return the top 10.
  //
  // Cosine on Voyage-3-large gets the right ballpark cheaply; rerank
  // catches the cases where vector similarity ranks two structurally
  // similar but semantically different reports too closely. The cache
  // means a maintainer drilling into the same issue twice pays the
  // Voyage roundtrip exactly once.
  case sql.has_rerank_cache(db, item_id) {
    Ok(pog.Returned(_, [row])) ->
      case row.cached {
        True -> read_from_cache(db, item_id)
        False -> compute_and_cache(db, item_id)
      }
    _ -> compute_and_cache(db, item_id)
  }
}

fn read_from_cache(db: pog.Connection, item_id: Int) {
  case sql.get_rerank_cache(db, item_id) {
    Ok(pog.Returned(_, rows)) -> {
      let items =
        list.map(rows, fn(row) {
          let sql.GetRerankCacheRow(
            target_item_id:,
            relevance_score:,
            title:,
            state:,
            state_reason:,
          ) = row
          types.SuggestedDuplicate(
            similarity: relevance_score,
            title:,
            github_id: target_item_id,
            state: sql_into_state(state),
            state_reason: sql_into_state_reason(state_reason),
          )
        })
      Ok(types.SuggestedDuplicates(items:))
    }
    Error(e) -> Error(e)
  }
}

type Candidate {
  Candidate(suggested: types.SuggestedDuplicate, body: String)
}

fn compute_and_cache(db: pog.Connection, item_id: Int) {
  // Threshold 0.65 for voyage-4-large + input_type=document. Noise p95 is
  // 0.68 so 0.65 sits just below — caught dupes get reranked, the
  // borderline noise gets filtered out by the rerank's heavier model.
  case sql.suggest_duplicates(db, item_id, 0.65) {
    Ok(pog.Returned(_, rows)) -> {
      let candidates = list.map(rows, suggest_row_to_candidate)
      let reranked = rerank_candidates(db, item_id, candidates)
      // Persist the full reranked list so subsequent drill-ins are instant.
      // Failures here aren't fatal — the user got their result, we just
      // didn't manage to cache it for next time.
      list.each(reranked, fn(s) {
        case sql.insert_rerank_score(db, item_id, s.github_id, s.similarity) {
          Ok(_) -> Nil
          Error(e) ->
            logging.log(
              logging.Warning,
              "failed to cache rerank score: " <> string.inspect(e),
            )
        }
      })
      Ok(types.SuggestedDuplicates(items: list.take(reranked, 10)))
    }
    Error(e) -> Error(e)
  }
}

fn suggest_row_to_candidate(row: sql.SuggestDuplicatesRow) -> Candidate {
  let sql.SuggestDuplicatesRow(
    target_item_id:,
    similarity:,
    title:,
    body:,
    state:,
    state_reason:,
  ) = row
  Candidate(
    suggested: types.SuggestedDuplicate(
      similarity:,
      title:,
      github_id: target_item_id,
      state: sql_into_state(state),
      state_reason: sql_into_state_reason(state_reason),
    ),
    body: body,
  )
}

fn rerank_candidates(
  db: pog.Connection,
  item_id: Int,
  candidates: List(Candidate),
) -> List(types.SuggestedDuplicate) {
  case candidates {
    [] -> []
    [single] -> [single.suggested]
    _ -> {
      case sql.select_item(db, item_id) {
        Ok(pog.Returned(1, [source])) -> {
          let query_text = build_text(source.title, source.body)
          let docs =
            list.map(candidates, fn(c) {
              build_text(c.suggested.title, c.body)
            })
          case voyage.rerank(query_text, docs) {
            Ok(scored) -> apply_rerank(candidates, scored)
            Error(e) -> {
              logging.log(
                logging.Warning,
                "rerank fell back to cosine: " <> snag.line_print(e),
              )
              list.map(candidates, fn(c) { c.suggested })
            }
          }
        }
        _ -> list.map(candidates, fn(c) { c.suggested })
      }
    }
  }
}

// Rerank gets raw body (template scaffolding included). Counter-intuitive
// but benched (N=81 on captured ground truth): leaving the template in
// gains ~4pp rank-1 hit rate, ~5pp top-3, and ~5pp absolute score
// (median 0.832 vs 0.781) over stripping. rerank-2.5 apparently uses the
// template structure as a 'these are both feature-request forms' signal
// rather than being distracted by it. The cosine-retrieval step still
// strips because cosine over template-noisy text inflates structural
// similarity between unrelated items — a different problem with the
// opposite right answer.
fn build_text(title: String, body: String) -> String {
  title <> "\n\n" <> body
}

fn apply_rerank(
  candidates: List(Candidate),
  scored: List(voyage.RerankResult),
) -> List(types.SuggestedDuplicate) {
  let indexed = list.index_map(candidates, fn(c, i) { #(i, c) })
  let by_index = fn(i: Int) {
    list.find_map(indexed, fn(p) {
      case p.0 == i {
        True -> {
          // Replace the cosine score with the rerank score so the cache
          // (and downstream callers) display rerank relevance.
          let updated =
            types.SuggestedDuplicate(..p.1.suggested, similarity: 0.0)
          Ok(updated)
        }
        False -> Error(Nil)
      }
    })
  }
  list.index_map(scored, fn(r, _) { r })
  |> list.filter_map(fn(r) {
    case by_index(r.index) {
      Ok(s) ->
        Ok(types.SuggestedDuplicate(..s, similarity: r.score))
      Error(_) -> Error(Nil)
    }
  })
}

fn map_item(
  returned: Result(pog.Returned(sql.SelectItemRow), pog.QueryError),
) -> Result(types.Item, snag.Snag) {
  case returned {
    Ok(pog.Returned(1, [row])) ->
      Ok(types.Item(
        github_id: row.github_id,
        number: row.number,
        title: row.title,
        body: row.body,
        state: row.state |> sql_into_state(),
        state_reason: row.state_reason |> sql_into_state_reason(),
        url: row.url,
        created_at: row.github_created_at,
        updated_at: row.github_updated_at,
      ))
    Ok(pog.Returned(n, _)) ->
      snag.error("expected 1 row but got " <> int.to_string(n))
    Error(e) -> string.inspect(e) |> snag.error()
  }
}

fn map_items(returned: pog.Returned(sql.ListItemsRow)) -> List(types.Item) {
  list.map(returned.rows, fn(row) {
    types.Item(
      github_id: row.github_id,
      number: row.number,
      title: row.title,
      body: row.body,
      state: row.state |> sql_into_state(),
      state_reason: row.state_reason |> sql_into_state_reason(),
      url: row.url,
      created_at: row.github_created_at,
      updated_at: row.github_updated_at,
    )
  })
}
