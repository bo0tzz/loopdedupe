import gleam/dynamic/decode
import gleam/json

pub type IssueState {
  Open
  Closed
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

fn issue_state_reason_decoder() {
  use string <- decode.then(decode.string)
  case string {
    "COMPLETED" -> decode.success(Completed)
    "DUPLICATE" -> decode.success(Duplicate)
    "NOT_PLANNED" -> decode.success(NotPlanned)
    "REOPENED" -> decode.success(Reopened)
    _ -> decode.failure(Completed, "IssueStateReason")
  }
}

pub type Issue {
  Issue(
    number: Int,
    title: String,
    body: String,
    state: IssueState,
    state_reason: IssueStateReason,
    url: String,
  )
}

fn issue_decoder() {
  use number <- decode.field("number", decode.int)
  use title <- decode.field("title", decode.string)
  use body <- decode.field("body", decode.string)
  use state <- decode.field("state", issue_state_decoder())
  use state_reason <- decode.field("state_reason", issue_state_reason_decoder())
  use url <- decode.field("url", decode.string)

  decode.success(Issue(number:, title:, body:, state:, state_reason:, url:))
}

pub type IssueWebhook {
  IssueWebhook(action: String, issue: Issue)
}

pub fn issue_webhook_decoder() {
  use action <- decode.field("action", decode.string)
  use issue <- decode.field("issue", issue_decoder())

  decode.success(IssueWebhook(action:, issue:))
}