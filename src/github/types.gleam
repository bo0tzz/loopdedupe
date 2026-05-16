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

pub type Issue {
  Issue(
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

pub fn issue_to_json(issue: Issue) -> json.Json {
  let Issue(
    github_id:,
    number:,
    title:,
    body:,
    state:,
    state_reason:,
    url:,
    created_at:,
    updated_at:,
  ) = issue
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
  use url <- decode.field("url", decode.string)
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

  decode.success(Issue(
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

pub type IssueWebhook {
  IssueWebhook(action: String, issue: Issue)
}

pub fn issue_webhook_decoder() {
  use action <- decode.field("action", decode.string)
  use issue <- decode.field("issue", issue_decoder())

  decode.success(IssueWebhook(action:, issue:))
}

pub type SuggestedDuplicate {
  SuggestedDuplicate(
    similarity: Float,
    github_id: Int,
    title: String,
    state: ItemState,
    state_reason: Option(ItemStateReason),
  )
}

fn suggested_duplicate_to_json(
  suggested_duplicate: SuggestedDuplicate,
) -> json.Json {
  let SuggestedDuplicate(similarity:, github_id:, title:, state:, state_reason:) =
    suggested_duplicate
  json.object([
    #("similarity", json.float(similarity)),
    #("github_id", json.int(github_id)),
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
