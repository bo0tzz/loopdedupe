import gleam/option
import gleam/json
import gleam/dynamic/decode

pub type IssueState {
  Open
  Closed
}

fn issue_state_to_json(issue_state: IssueState) -> json.Json {
  case issue_state {
    Open -> json.string("open")
    Closed -> json.string("closed")
  }
}

fn issue_state_decoder() {
  use string <- decode.then(decode.string)
  case string {
    "open" -> decode.success(Open)
    "closed" -> decode.success(Closed)
    _ -> decode.failure(Open, "IssueState")
  }
}

pub type IssueStateReason {
  Completed
  Duplicate
  NotPlanned
  Reopened
}

fn issue_state_reason_to_json(issue_state_reason: IssueStateReason) -> json.Json {
  case issue_state_reason {
    Completed -> json.string("completed")
    Duplicate -> json.string("duplicate")
    NotPlanned -> json.string("not_planned")
    Reopened -> json.string("reopened")
  }
}

fn issue_state_reason_decoder() -> decode.Decoder(IssueStateReason) {
  use variant <- decode.then(decode.string)
  case variant {
    "completed" -> decode.success(Completed)
    "duplicate" -> decode.success(Duplicate)
    "not_planned" -> decode.success(NotPlanned)
    "reopened" -> decode.success(Reopened)
    _ -> decode.failure(Completed, "IssueStateReason")
  }
}

pub type Issue {
  Issue(
    github_id: Int,
    number: Int,
    title: String,
    body: String,
    state: IssueState,
    state_reason: IssueStateReason,
    url: String,
  )
}

pub fn issue_to_json(issue: Issue) -> json.Json {
  let Issue(github_id:, number:, title:, body:, state:, state_reason:, url:) = issue
  json.object([
    #("github_id", json.int(github_id)),
    #("number", json.int(number)),
    #("title", json.string(title)),
    #("body", json.string(body)),
    #("state", issue_state_to_json(state)),
    #("state_reason", issue_state_reason_to_json(state_reason)),
    #("url", json.string(url)),
  ])
}

fn issue_decoder() {
  use github_id <- decode.field("id", decode.int)
  use number <- decode.field("number", decode.int)
  use title <- decode.field("title", decode.string)
  use body <- decode.field("body", decode.string)
  use state <- decode.field("state", issue_state_decoder())
  // TODO: How to propagate Option() through database
  use state_reason_opt <- decode.field("state_reason", decode.optional(issue_state_reason_decoder()))
  let state_reason = option.unwrap(state_reason_opt, Completed)
  use url <- decode.field("url", decode.string)

  decode.success(Issue(
    github_id:,
    number:,
    title:,
    body:,
    state:,
    state_reason:,
    url:,
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
