import api/middleware
import config
import database/item
import database/sql
import github/types as github
import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import jobs/backfill
import jobs/bot_reply
import jobs/discussion_backfill
import jobs/embeddings
import snag
import types.{type Context}
import wisp.{type Request, type Response}

// Slug of the discussion category we care about. Other categories (Q&A,
// General, etc.) are conversational and aren't dedupe candidates, so we
// silently ignore those webhooks. Matches the categoryId-based filter
// the GraphQL discussion backfill uses.
const feature_request_slug = "feature-request"

pub fn handle(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use <- wisp.require_content_type(req, "application/json")
  use body <- wisp.require_string_body(req)
  use <- middleware.require_github_signature(req.headers, body)

  // GitHub sends the event type in the X-GitHub-Event header — same body
  // shape can mean an issue, a discussion, an issue_comment, etc., and we
  // need to know which decoder to use.
  let event = list.key_find(req.headers, "x-github-event")
  case event {
    Ok("issues") -> respond(handle_issue(body, ctx))
    Ok("discussion") -> respond(handle_discussion(body, ctx))
    Ok("issue_comment") ->
      respond(handle_comment(body, ctx, github.issue_comment_webhook_decoder()))
    Ok("discussion_comment") ->
      respond(handle_comment(
        body,
        ctx,
        github.discussion_comment_webhook_decoder(),
      ))
    _ ->
      wisp.response(200)
      |> wisp.string_body("ignored event type")
  }
}

// Bot mention flow: a human wrote a comment containing the bot handle on
// an issue, PR, or discussion. Enqueue a reply job carrying the parent's
// title+body (search query) so the worker never needs to refetch. Bot
// authors are skipped so we can't loop on our own replies.
fn handle_comment(
  body: String,
  ctx: Context,
  decoder: decode.Decoder(github.CommentWebhook),
) -> Result(String, snag.Snag) {
  use webhook <- result.try(
    json.parse(body, decoder) |> snag.map_error(string.inspect),
  )
  let handle = bot_handle()
  let mentioned =
    string.contains(
      string.lowercase(webhook.comment_body),
      string.lowercase(handle),
    )
  case webhook.action, webhook.author_is_bot, mentioned {
    "created", False, True -> {
      let kind = case webhook.discussion_node_id, webhook.is_pull_request {
        option.Some(_), _ -> "discussion"
        option.None, True -> "pr"
        option.None, False -> "issue"
      }
      let _ =
        bot_reply.enqueue(
          ctx,
          bot_reply.BotReplyJob(
            kind:,
            number: webhook.number,
            comment_id: webhook.comment_id,
            title: webhook.title,
            body: webhook.body,
            discussion_node_id: webhook.discussion_node_id,
          ),
        )
      Ok("bot reply enqueued")
    }
    _, _, _ -> Ok("ignored")
  }
}

fn bot_handle() -> String {
  config.try_env(config.BotHandle) |> result.unwrap("@loopdedupe")
}

fn respond(result: Result(String, snag.Snag)) -> Response {
  case result {
    Ok(msg) -> wisp.response(200) |> wisp.string_body(msg)
    Error(e) -> snag.line_print(e) |> wisp.bad_request
  }
}

fn handle_issue(body: String, ctx: Context) -> Result(String, snag.Snag) {
  use webhook <- result.try(
    json.parse(body, github.issue_webhook_decoder())
    |> snag.map_error(string.inspect),
  )
  use _ <- result.try(
    item.upsert(ctx.db, sql.Issue, webhook.item)
    |> snag.map_error(string.inspect),
  )
  use _ <- result.try(
    embeddings.enqueue(ctx.db, webhook.item.github_id)
    |> snag.map_error(string.inspect),
  )
  invalidate_rerank_for(ctx, webhook.item.github_id)
  refresh_canonical_on_close(ctx, webhook.action, IssueKind, webhook.item)
  Ok("OK")
}

fn handle_discussion(body: String, ctx: Context) -> Result(String, snag.Snag) {
  use webhook <- result.try(
    json.parse(body, github.discussion_webhook_decoder())
    |> snag.map_error(string.inspect),
  )
  case webhook.category_slug == feature_request_slug {
    False -> Ok("ignored — not feature-request category")
    True -> {
      use _ <- result.try(
        item.upsert(ctx.db, sql.Discussion, webhook.item)
        |> snag.map_error(string.inspect),
      )
      use _ <- result.try(
        embeddings.enqueue(ctx.db, webhook.item.github_id)
        |> snag.map_error(string.inspect),
      )
      invalidate_rerank_for(ctx, webhook.item.github_id)
      refresh_canonical_on_close(
        ctx,
        webhook.action,
        DiscussionKind,
        webhook.item,
      )
      Ok("OK")
    }
  }
}

type Kind {
  IssueKind
  DiscussionKind
}

// Drop the per-source rerank cache so the next drill-in recomputes against
// the freshly-updated content. Cheap (one DELETE), fire-and-forget — even
// if it fails the cache just stays stale, no correctness issue.
fn invalidate_rerank_for(ctx: Context, github_id: Int) -> Nil {
  let _ = sql.invalidate_rerank_cache(ctx.db, github_id)
  Nil
}

// On a close event, enqueue an incremental backfill so the duplicate_of
// pointer gets captured (via timeline / closing-comment scan). The webhook
// payload itself doesn't carry those signals — only the GraphQL backfill
// path does. Boundary is set just before the item's updated_at so this
// item is included in the filterBy.since window.
fn refresh_canonical_on_close(
  ctx: Context,
  action: String,
  kind: Kind,
  item: github.Item,
) -> Nil {
  case action {
    "closed" -> {
      // -1 second buffer so server-side timestamp resolution doesn't
      // accidentally exclude the just-closed item from the filterBy.since
      // window (GitHub stores at second precision in some places).
      let since =
        timestamp.add(item.updated_at, duration.seconds(-1))
        |> timestamp.to_rfc3339(duration.seconds(0))
      case kind {
        IssueKind -> {
          let _ = backfill.enqueue(ctx, option.None, option.Some(since))
          Nil
        }
        DiscussionKind -> {
          let _ =
            discussion_backfill.enqueue(ctx, option.None, option.Some(since))
          Nil
        }
      }
    }
    _ -> Nil
  }
}
