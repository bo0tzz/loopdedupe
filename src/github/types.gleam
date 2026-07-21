import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}

pub type ItemState {
  Open
  Closed
}

fn item_state_to_json(state: ItemState) -> json.Json {
  case state {
    Open -> json.string("open")
    Closed -> json.string("closed")
  }
}

fn item_state_decoder() {
  use string <- decode.then(decode.string)
  case string |> string.lowercase() {
    "open" -> decode.success(Open)
    "closed" -> decode.success(Closed)
    _ -> decode.failure(Open, "ItemState")
  }
}

pub type ItemStateReason {
  Completed
  Duplicate
  NotPlanned
  Reopened
  Outdated
  Resolved
}

fn item_state_reason_to_json(reason: ItemStateReason) -> json.Json {
  case reason {
    Completed -> json.string("completed")
    Duplicate -> json.string("duplicate")
    NotPlanned -> json.string("not_planned")
    Reopened -> json.string("reopened")
    Outdated -> json.string("outdated")
    Resolved -> json.string("resolved")
  }
}

fn item_state_reason_decoder() -> decode.Decoder(ItemStateReason) {
  use variant <- decode.then(decode.string)
  case variant |> string.lowercase() {
    "completed" -> decode.success(Completed)
    "duplicate" -> decode.success(Duplicate)
    "not_planned" -> decode.success(NotPlanned)
    "reopened" -> decode.success(Reopened)
    "outdated" -> decode.success(Outdated)
    "resolved" -> decode.success(Resolved)
    _ -> decode.failure(Completed, "ItemStateReason")
  }
}

pub type Item {
  Item(
    github_id: Int,
    number: Int,
    title: String,
    body: String,
    state: ItemState,
    state_reason: Option(ItemStateReason),
    url: String,
    created_at: Timestamp,
    updated_at: Timestamp,
  )
}

fn timestamp_to_json(t: Timestamp) -> json.Json {
  timestamp.to_rfc3339(t, duration.seconds(0)) |> json.string
}

pub fn item_to_json(item: Item) -> json.Json {
  let Item(
    github_id:,
    number:,
    title:,
    body:,
    state:,
    state_reason:,
    url:,
    created_at:,
    updated_at:,
  ) = item
  json.object([
    #("github_id", json.int(github_id)),
    #("number", json.int(number)),
    #("title", json.string(title)),
    #("body", json.string(body)),
    #("state", item_state_to_json(state)),
    #("state_reason", json.nullable(state_reason, item_state_reason_to_json)),
    #("url", json.string(url)),
    #("created_at", timestamp_to_json(created_at)),
    #("updated_at", timestamp_to_json(updated_at)),
  ])
}

fn timestamp_decoder() -> decode.Decoder(Timestamp) {
  use s <- decode.then(decode.string)
  case timestamp.parse_rfc3339(s) {
    Ok(t) -> decode.success(t)
    Error(_) -> decode.failure(timestamp.from_unix_seconds(0), "Timestamp")
  }
}

// Postgres TEXT columns reject null bytes (0x00) with character_not_in_repertoire
// even though they're valid UTF-8. A handful of immich issue bodies contain them
// (probably copy-pasted from binary dumps), so we strip at ingest.
fn safe_string() -> decode.Decoder(String) {
  decode.string |> decode.map(string.replace(_, "\u{0000}", ""))
}

pub fn issue_decoder() {
  let id_decoder =
    decode.one_of(decode.at(["id"], decode.int), or: [
      decode.at(["databaseId"], decode.int),
    ])
  use github_id <- decode.then(id_decoder)
  use number <- decode.field("number", decode.int)
  use title <- decode.field("title", safe_string())
  use body <- decode.field("body", safe_string())
  use state <- decode.field("state", item_state_decoder())
  let state_reason_decoder =
    decode.one_of(
      decode.at(["state_reason"], decode.optional(item_state_reason_decoder())),
      or: [
        decode.at(["stateReason"], decode.optional(item_state_reason_decoder())),
      ],
    )
  use state_reason <- decode.then(state_reason_decoder)
  // REST payloads carry both `url` (the api.github.com API URL) and `html_url`
  // (the web UI URL); we want the latter. GraphQL only has `url`, and there it
  // already is the web URL, so it's the correct fallback.
  let url_decoder =
    decode.one_of(decode.at(["html_url"], decode.string), or: [
      decode.at(["url"], decode.string),
    ])
  use url <- decode.then(url_decoder)
  let created_at_decoder =
    decode.one_of(decode.at(["created_at"], timestamp_decoder()), or: [
      decode.at(["createdAt"], timestamp_decoder()),
    ])
  use created_at <- decode.then(created_at_decoder)
  let updated_at_decoder =
    decode.one_of(decode.at(["updated_at"], timestamp_decoder()), or: [
      decode.at(["updatedAt"], timestamp_decoder()),
    ])
  use updated_at <- decode.then(updated_at_decoder)

  decode.success(Item(
    github_id:,
    number:,
    title:,
    body:,
    state:,
    state_reason:,
    url:,
    created_at:,
    updated_at:,
  ))
}

// Discussion's GraphQL shape differs from Issue: there's no `state` string,
// just a `closed` boolean. Everything else lines up so we still produce an
// Item value, just deriving state from `closed`.
pub fn discussion_decoder() {
  use github_id <- decode.field("databaseId", decode.int)
  use number <- decode.field("number", decode.int)
  use title <- decode.field("title", safe_string())
  use body <- decode.field("body", safe_string())
  use closed <- decode.field("closed", decode.bool)
  let state = case closed {
    True -> Closed
    False -> Open
  }
  use state_reason <- decode.field(
    "stateReason",
    decode.optional(item_state_reason_decoder()),
  )
  use url <- decode.field("url", decode.string)
  use created_at <- decode.field("createdAt", timestamp_decoder())
  use updated_at <- decode.field("updatedAt", timestamp_decoder())
  decode.success(Item(
    github_id:,
    number:,
    title:,
    body:,
    state:,
    state_reason:,
    url:,
    created_at:,
    updated_at:,
  ))
}

// GitHub's `issues` webhook event has a top-level `issue` field. We keep the
// IssueWebhook name to mirror that wire shape; the inner value is an Item.
pub type IssueWebhook {
  IssueWebhook(action: String, item: Item)
}

pub fn issue_webhook_decoder() {
  use action <- decode.field("action", decode.string)
  use item <- decode.field("issue", issue_decoder())

  decode.success(IssueWebhook(action:, item:))
}

// Discussion webhook payload shape. Field-for-field similar to issue
// webhooks (we reuse issue_decoder for the inner item), with the addition
// of `category.slug` so the handler can filter to feature-request only.
pub type DiscussionWebhook {
  DiscussionWebhook(action: String, item: Item, category_slug: String)
}

pub fn discussion_webhook_decoder() {
  use action <- decode.field("action", decode.string)
  use item <- decode.field("discussion", issue_decoder())
  use category_slug <- decode.field(
    "discussion",
    decode.at(["category", "slug"], decode.string),
  )
  decode.success(DiscussionWebhook(action:, item:, category_slug:))
}

// A comment-created webhook on an issue, PR conversation, or discussion,
// reduced to what the bot mention flow needs. `issue_comment` events carry
// PR conversation comments too — the payload's issue object has a
// `pull_request` key iff the thread is a PR.
pub type CommentWebhook {
  CommentWebhook(
    action: String,
    comment_id: Int,
    comment_body: String,
    author_is_bot: Bool,
    number: Int,
    title: String,
    body: String,
    is_pull_request: Bool,
    // GraphQL node id of the parent discussion; None for issues/PRs.
    // Needed because addDiscussionComment only accepts node ids.
    discussion_node_id: Option(String),
  )
}

pub fn issue_comment_webhook_decoder() -> decode.Decoder(CommentWebhook) {
  use action <- decode.field("action", decode.string)
  use comment_id <- decode.field("comment", decode.at(["id"], decode.int))
  use comment_body <- decode.field(
    "comment",
    decode.at(["body"], safe_string()),
  )
  use author_type <- decode.field(
    "comment",
    decode.at(["user", "type"], decode.string),
  )
  use number <- decode.field("issue", decode.at(["number"], decode.int))
  use title <- decode.field("issue", decode.at(["title"], safe_string()))
  use body <- decode.field(
    "issue",
    decode.optionally_at(["body"], "", safe_string()),
  )
  use pr_url <- decode.field(
    "issue",
    decode.optionally_at(
      ["pull_request", "url"],
      option.None,
      decode.optional(decode.string),
    ),
  )
  decode.success(CommentWebhook(
    action:,
    comment_id:,
    comment_body:,
    author_is_bot: author_type == "Bot",
    number:,
    title:,
    body:,
    is_pull_request: option.is_some(pr_url),
    discussion_node_id: option.None,
  ))
}

pub fn discussion_comment_webhook_decoder() -> decode.Decoder(CommentWebhook) {
  use action <- decode.field("action", decode.string)
  use comment_id <- decode.field("comment", decode.at(["id"], decode.int))
  use comment_body <- decode.field(
    "comment",
    decode.at(["body"], safe_string()),
  )
  use author_type <- decode.field(
    "comment",
    decode.at(["user", "type"], decode.string),
  )
  use number <- decode.field("discussion", decode.at(["number"], decode.int))
  use title <- decode.field("discussion", decode.at(["title"], safe_string()))
  use body <- decode.field(
    "discussion",
    decode.optionally_at(["body"], "", safe_string()),
  )
  use node_id <- decode.field(
    "discussion",
    decode.at(["node_id"], decode.string),
  )
  decode.success(CommentWebhook(
    action:,
    comment_id:,
    comment_body:,
    author_is_bot: author_type == "Bot",
    number:,
    title:,
    body:,
    is_pull_request: False,
    discussion_node_id: option.Some(node_id),
  ))
}

pub type ItemType {
  Issue
  Discussion
}

fn item_type_to_json(t: ItemType) -> json.Json {
  case t {
    Issue -> json.string("issue")
    Discussion -> json.string("discussion")
  }
}

pub type SuggestedDuplicate {
  SuggestedDuplicate(
    similarity: Float,
    number: Int,
    item_type: ItemType,
    title: String,
    state: ItemState,
    state_reason: Option(ItemStateReason),
  )
}

fn suggested_duplicate_to_json(
  suggested_duplicate: SuggestedDuplicate,
) -> json.Json {
  let SuggestedDuplicate(
    similarity:,
    number:,
    item_type:,
    title:,
    state:,
    state_reason:,
  ) = suggested_duplicate
  json.object([
    #("similarity", json.float(similarity)),
    #("number", json.int(number)),
    #("item_type", item_type_to_json(item_type)),
    #("title", json.string(title)),
    #("state", item_state_to_json(state)),
    #("state_reason", json.nullable(state_reason, item_state_reason_to_json)),
  ])
}

pub type SuggestedDuplicates {
  SuggestedDuplicates(items: List(SuggestedDuplicate))
}

pub fn suggested_duplicates_to_json(
  suggested_duplicates: SuggestedDuplicates,
) -> json.Json {
  let SuggestedDuplicates(items:) = suggested_duplicates
  json.object([
    #("items", json.array(items, suggested_duplicate_to_json)),
  ])
}
