import database/sql
import github/types
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
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

pub fn select(
  db: pog.Connection,
  item_id: Int,
) -> Result(types.Item, snag.Snag) {
  sql.select_item(db, item_id)
  |> map_item()
}

pub fn suggest_duplicates(db: pog.Connection, item_id: Int) {
  // With the title+stripped-body+EOS embed format on E5-Mistral, related
  // pairs sit around 0.85-0.92 in our small validation set while unrelated
  // pairs land at 0.70-0.80. 0.85 is the threshold that cleanly separates
  // them; revisit once we have real maintainer judgments to tune against.
  case sql.suggest_duplicates(db, item_id, 0.85) {
    Ok(pog.Returned(_, rows)) -> {
      //TODO: Resolve canonical/root items in query
      let items =
        list.map(rows, fn(row) {
          let sql.SuggestDuplicatesRow(
            target_item_id:,
            similarity:,
            title:,
            state:,
            state_reason:,
          ) = row
          types.SuggestedDuplicate(
            similarity:,
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
