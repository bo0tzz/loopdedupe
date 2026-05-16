import config
import github/types
import gleam/dynamic/decode
import gleam/httpc
import gleam/int
import gleam/json
import gleam/option.{type Option}
import gleam/string
import squall

// Hardcoded for now — the maintainer whose dupe-close comments we trust.
// Should become a config setting once another maintainer joins the workflow.
const dupe_comment_maintainer = "bo0tzz"

pub fn new_client() {
  let token = config.get_env(config.GithubToken)
  squall.new_with_auth("https://api.github.com/graphql", token)
}

pub fn list_items(client: squall.Client, cursor: Option(String)) {
  let query =
    "
    query ListItems($cursor: String) {
      repository(owner: \"immich-app\", name: \"immich\") {
        issues(first: 100, after: $cursor) {
          nodes {
              databaseId
              number
              title
              body
              state
              stateReason
              url
              createdAt
              updatedAt
              comments(last: 1) {
                  nodes {
                      author { login }
                      body
                  }
              }
          }
          pageInfo {
              endCursor
          }
        }
      }
    }
  "
  let assert Ok(request) =
    squall.prepare_request(
      client,
      query,
      json.object([#("cursor", json.nullable(cursor, json.string))]),
    )

  let assert Ok(response) = httpc.send(request)

  squall.parse_response(response.body, list_items_response_decoder())
}

pub type BackfillItem {
  BackfillItem(issue: types.Issue, duplicate_of_number: Option(Int))
}

pub type ListItemsResponse {
  ListItemsResponse(items: List(BackfillItem), page_info: PageInfo)
}

fn list_items_response_decoder() -> decode.Decoder(ListItemsResponse) {
  let decoder = {
    use items <- decode.field("nodes", decode.list(backfill_item_decoder()))
    use page_info <- decode.field("pageInfo", page_info_decoder())
    decode.success(ListItemsResponse(items:, page_info:))
  }

  decode.at(["repository", "issues"], decoder)
}

fn backfill_item_decoder() -> decode.Decoder(BackfillItem) {
  use issue <- decode.then(types.issue_decoder())
  use duplicate_of_number <- decode.then(duplicate_of_decoder())
  decode.success(BackfillItem(issue:, duplicate_of_number:))
}

// The dupe signal in the immich workflow is the most recent comment, by the
// maintainer, whose body is exactly '#NNN' — pointing at the canonical's
// per-repo number. We deliberately skip comments with more than the bare
// ref (e.g. "see #123, related to #456") because they're ambiguous; the
// user can revisit if it turns out to matter.
fn duplicate_of_decoder() -> decode.Decoder(Option(Int)) {
  let comment_decoder = {
    use author_login <- decode.optional_field(
      "author",
      option.None,
      decode.optional(decode.at(["login"], decode.string)),
    )
    use body <- decode.field("body", decode.string)
    case author_login {
      option.Some(login) if login == dupe_comment_maintainer ->
        decode.success(parse_dupe_ref(body))
      _ -> decode.success(option.None)
    }
  }

  let comments_decoder = {
    use nodes <- decode.field("nodes", decode.list(comment_decoder))
    case nodes {
      [first, ..] -> decode.success(first)
      [] -> decode.success(option.None)
    }
  }

  use comments <- decode.optional_field(
    "comments",
    option.None,
    decode.optional(comments_decoder),
  )
  decode.success(option.flatten(comments))
}

fn parse_dupe_ref(body: String) -> Option(Int) {
  case string.trim(body) {
    "#" <> rest ->
      case int.parse(string.trim(rest)) {
        Ok(n) -> option.Some(n)
        Error(_) -> option.None
      }
    _ -> option.None
  }
}

pub type PageInfo {
  PageInfo(cursor: Option(String))
}

fn page_info_decoder() -> decode.Decoder(PageInfo) {
  use cursor <- decode.field("endCursor", decode.optional(decode.string))
  decode.success(PageInfo(cursor:))
}
