import api/dashboard
import api/items
import api/webhook
import config
import database/sql
import gleam/http.{Get, Post}
import gleam/option
import gleam/time/duration
import gleam/time/timestamp
import jobs/backfill
import jobs/discussion_backfill
import mist
import pog
import types.{type Context}
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub fn supervised(ctx: Context) {
  let secret = config.get_env(config.SecretKey)

  let handler = handle_request(_, ctx)

  wisp_mist.handler(handler, secret)
  |> mist.new
  |> mist.port(8000)
  |> mist.supervised
}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use <- wisp.log_request(req)

  case req.method, wisp.path_segments(req) {
    Post, ["api", "webhooks", "github"] -> webhook.handle(req, ctx)
    Get, ["api", "items"] -> items.list(ctx)
    Get, ["api", "items", id] -> items.get(ctx, id)
    Get, ["api", "items", id, "similar"] -> items.get_similar(ctx, id)
    Post, ["api", "backfill"] -> start_backfill(ctx)
    Post, ["api", "backfill", "discussions"] -> start_discussion_backfill(ctx)
    Post, ["api", "backfill", "incremental"] -> start_incremental_backfill(ctx)
    Post, ["api", "judgments", "not-duplicate"] ->
      dashboard.dismiss_pair(req, ctx)
    Post, ["api", "judgments", "undo"] -> dashboard.undo_pair_judgment(req, ctx)
    Get, ["judgments"] -> dashboard.judgments(ctx)
    Get, ["backfills"] -> dashboard.backfills(ctx)
    Get, ["backfills", "status"] -> dashboard.backfills_status_fragment(ctx)
    Get, [] -> dashboard.index(ctx)
    Get, ["dashboard", "stats"] -> dashboard.stats_fragment(ctx)
    Get, ["items", id] -> dashboard.item_detail(ctx, id)
    _, _ -> wisp.not_found()
  }
}

fn start_backfill(ctx: Context) -> Response {
  case backfill.enqueue(ctx, option.None, option.None) {
    Ok(_) -> wisp.response(200) |> wisp.string_body("backfill started")
    Error(_) -> wisp.internal_server_error()
  }
}

fn start_discussion_backfill(ctx: Context) -> Response {
  case discussion_backfill.enqueue(ctx, option.None, option.None) {
    Ok(_) ->
      wisp.response(200) |> wisp.string_body("discussion backfill started")
    Error(_) -> wisp.internal_server_error()
  }
}

// Walks only items updated since the latest github_updated_at we have stored
// (per-kind, since issues and discussions track separately). Issues use
// GitHub's filterBy.since; discussions sort by UPDATED_AT DESC and stop
// chaining as soon as a page contains anything older than the boundary.
fn start_incremental_backfill(ctx: Context) -> Response {
  let issue_since = latest_issue_iso(ctx.db)
  let discussion_since = latest_discussion_iso(ctx.db)
  let _ = backfill.enqueue(ctx, option.None, issue_since)
  let _ = discussion_backfill.enqueue(ctx, option.None, discussion_since)
  wisp.response(200)
  |> wisp.string_body(
    "incremental backfill started — issues since "
    <> option.unwrap(issue_since, "<empty corpus>")
    <> ", discussions since "
    <> option.unwrap(discussion_since, "<empty corpus>"),
  )
}

// On an empty corpus MAX(github_updated_at) returns NULL and squirrel's
// non-nullable decode fails, which the outer case folds into None. That
// flows back to enqueue(... since=None), which means a full walk — the
// right behaviour when there's nothing to be incremental against.
fn latest_issue_iso(db: pog.Connection) -> option.Option(String) {
  case sql.latest_issue_update(db) {
    Ok(pog.Returned(_, [row])) ->
      option.Some(timestamp.to_rfc3339(row.latest, duration.seconds(0)))
    _ -> option.None
  }
}

fn latest_discussion_iso(db: pog.Connection) -> option.Option(String) {
  case sql.latest_discussion_update(db) {
    Ok(pog.Returned(_, [row])) ->
      option.Some(timestamp.to_rfc3339(row.latest, duration.seconds(0)))
    _ -> option.None
  }
}
