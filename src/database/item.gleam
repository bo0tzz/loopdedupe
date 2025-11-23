import database/sql
import github/types
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import pog
import snag

fn sql_into_state(sql: sql.GithubState) -> types.IssueState {
  case sql {
    sql.Open -> types.Open
    sql.Closed -> types.Closed
  }
}

fn state_into_sql(state: types.IssueState) -> sql.GithubState {
  case state {
    types.Open -> sql.Open
    types.Closed -> sql.Closed
  }
}

fn sql_into_state_reason(
  sql: option.Option(sql.GithubStateReason),
) -> types.IssueStateReason {
  case sql {
    // TODO (see github/types)
    option.None -> types.Completed
    option.Some(some) ->
      case some {
        sql.Reopened -> types.Reopened
        sql.NotPlanned -> types.NotPlanned
        sql.Duplicate -> types.Duplicate
        sql.Completed -> types.Completed
      }
  }
}

fn state_reason_into_sql(
  reason: types.IssueStateReason,
) -> sql.GithubStateReason {
  case reason {
    types.Reopened -> sql.Reopened
    types.NotPlanned -> sql.NotPlanned
    types.Duplicate -> sql.Duplicate
    types.Completed -> sql.Completed
  }
}

pub fn upsert(db: pog.Connection, issue: types.Issue) {
  sql.upsert_item(
    db,
    issue.github_id,
    issue.number,
    sql.Issue,
    issue.title,
    issue.body,
    issue.state |> state_into_sql(),
    issue.state_reason |> state_reason_into_sql(),
    issue.url,
  )
}

pub fn list(db: pog.Connection) -> Result(List(types.Issue), pog.QueryError) {
  sql.list_items(db) |> result.map(map_items)
}

pub fn select(
  db: pog.Connection,
  item_id: Int,
) -> Result(types.Issue, snag.Snag) {
  sql.select_item(db, item_id)
  |> map_item()
}

fn map_item(
  returned: Result(pog.Returned(sql.SelectItemRow), pog.QueryError),
) -> Result(types.Issue, snag.Snag) {
  case returned {
    Ok(pog.Returned(1, [row])) ->
      Ok(types.Issue(
        github_id: row.github_id,
        number: row.number,
        title: row.title,
        body: row.body,
        state: row.state |> sql_into_state(),
        state_reason: row.state_reason |> sql_into_state_reason(),
        url: row.url,
      ))
    Ok(pog.Returned(n, _)) ->
      snag.error("expected 1 row but got " <> int.to_string(n))
    Error(e) -> string.inspect(e) |> snag.error()
  }
}

fn map_items(returned: pog.Returned(sql.ListItemsRow)) -> List(types.Issue) {
  list.map(returned.rows, fn(row) {
    types.Issue(
      github_id: row.github_id,
      number: row.number,
      title: row.title,
      body: row.body,
      state: row.state |> sql_into_state(),
      state_reason: row.state_reason |> sql_into_state_reason(),
      url: row.url,
    )
  })
}
