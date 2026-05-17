import config
import github/types
import gleam/dynamic/decode
import gleam/float
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
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
              closedAt
              author { login }
              comments(last: 10) {
                  nodes {
                      author { login }
                      body
                      createdAt
                  }
              }
              timelineItems(itemTypes: CONVERTED_TO_DISCUSSION_EVENT, last: 1) {
                  nodes {
                      ... on ConvertedToDiscussionEvent {
                          discussion { number }
                      }
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
  BackfillItem(
    item: types.Item,
    duplicate_of_number: Option(Int),
    // The login that filed this item, or None for ghost (deleted) authors.
    // Surfaced alongside the item in the dashboard so same-author refilings
    // pop visually without changing the underlying ranking.
    author_login: Option(String),
  )
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
  use item <- decode.then(types.issue_decoder())
  // Two independent signals for the canonical pointer:
  //   - ConvertedToDiscussionEvent (structured, authoritative) — fires when
  //     a maintainer used GitHub's "convert to discussion" button.
  //   - bo0tzz dupe-pattern comment near the close event (heuristic) — the
  //     manual workflow.
  // In practice these are mutually exclusive (you don't comment '#NNN' on a
  // converted issue), but if both fire, conversion wins.
  use converted_to <- decode.then(converted_to_discussion_decoder())
  use closed_at <- decode.optional_field(
    "closedAt",
    option.None,
    decode.optional(timestamp_decoder()),
  )
  use comment_ref <- decode.then(duplicate_of_decoder(closed_at))
  use author_login <- decode.then(author_login_decoder())
  let duplicate_of_number = case converted_to {
    option.Some(_) -> converted_to
    option.None -> comment_ref
  }
  decode.success(BackfillItem(item:, duplicate_of_number:, author_login:))
}

// GitHub's GraphQL author field is null for ghost (deleted) accounts. Use
// optional_field for the outer wrapper so missing/null both fall to None.
fn author_login_decoder() -> decode.Decoder(Option(String)) {
  use author <- decode.optional_field(
    "author",
    option.None,
    decode.optional(decode.at(["login"], decode.string)),
  )
  decode.success(author)
}

fn converted_to_discussion_decoder() -> decode.Decoder(Option(Int)) {
  let event_decoder = {
    use number <- decode.optional_field(
      "discussion",
      option.None,
      decode.optional(decode.at(["number"], decode.int)),
    )
    decode.success(number)
  }
  let nodes_decoder = {
    use nodes <- decode.field("nodes", decode.list(event_decoder))
    case nodes {
      [first, ..] -> decode.success(first)
      [] -> decode.success(option.None)
    }
  }
  use timeline <- decode.optional_field(
    "timelineItems",
    option.None,
    decode.optional(nodes_decoder),
  )
  decode.success(option.flatten(timeline))
}

// The dupe signal in the immich workflow is a maintainer comment near the
// close event whose body matches a known dupe-pattern ('#NNN', 'Duplicate
// of #NNN', 'Dupe of #NNN'). Anchoring to the close timestamp is what
// keeps us from picking up unrelated dupe-pattern comments left long
// before or long after the actual triage action (users sometimes reply
// to closed issues days later with questions).
//
// Open issues skip this entirely — without a close timestamp there's
// nothing to align to and a maintainer hasn't declared anything.
fn duplicate_of_decoder(
  close_at: Option(Timestamp),
) -> decode.Decoder(Option(Int)) {
  let dupe_comment_decoder = {
    use author_login <- decode.optional_field(
      "author",
      option.None,
      decode.optional(decode.at(["login"], decode.string)),
    )
    use created_at <- decode.field("createdAt", timestamp_decoder())
    use body <- decode.field("body", decode.string)
    case author_login {
      option.Some(login) if login == dupe_comment_maintainer ->
        case parse_dupe_ref(body) {
          option.Some(n) -> decode.success(option.Some(#(created_at, n)))
          option.None -> decode.success(option.None)
        }
      _ -> decode.success(option.None)
    }
  }

  let comments_decoder = {
    use nodes <- decode.field("nodes", decode.list(dupe_comment_decoder))
    let matches =
      list.filter_map(nodes, fn(x) {
        case x {
          option.Some(v) -> Ok(v)
          option.None -> Error(Nil)
        }
      })
    decode.success(pick_closest_to_close(close_at, matches))
  }

  use comments <- decode.optional_field(
    "comments",
    option.None,
    decode.optional(comments_decoder),
  )
  decode.success(option.flatten(comments))
}

// Five-minute window matches the immich maintainer workflow: comment then
// close (or vice versa) within a few seconds. Wider windows risk catching
// dupe-pattern comments from much earlier (e.g. discussion of which old
// issue might be related) that aren't authoritative.
const close_alignment_window_seconds = 300.0

fn pick_closest_to_close(
  close_at: Option(Timestamp),
  candidates: List(#(Timestamp, Int)),
) -> Option(Int) {
  case close_at {
    option.None -> option.None
    option.Some(ct) -> {
      candidates
      |> list.filter_map(fn(pair) {
        let #(t, n) = pair
        let delta =
          timestamp.difference(ct, t)
          |> duration.to_seconds
          |> float.absolute_value
        case delta <=. close_alignment_window_seconds {
          True -> Ok(#(delta, n))
          False -> Error(Nil)
        }
      })
      |> list.sort(fn(a, b) { float.compare(a.0, b.0) })
      |> list.first
      |> result.map(fn(p) { p.1 })
      |> option.from_result
    }
  }
}

fn timestamp_decoder() -> decode.Decoder(Timestamp) {
  use s <- decode.then(decode.string)
  case timestamp.parse_rfc3339(s) {
    Ok(t) -> decode.success(t)
    Error(_) -> decode.failure(timestamp.from_unix_seconds(0), "Timestamp")
  }
}

// Parse a comment body for a dupe pointer like '#NNN'. We accept the bare
// form ('#992') and a small set of known prefixes ('Duplicate of #992',
// 'Dupe of #992', 'Now tracked in #992') with optional trailing period —
// these are the phrasings the maintainer actually uses. We deliberately
// don't try to extract '#NNN' from arbitrary prose because comments often
// reference related-but-not-canonical PRs/issues ('see #123', 'fix in
// #123'), which would poison the dupe graph.
fn parse_dupe_ref(body: String) -> Option(Int) {
  let trimmed = string.trim(body)
  let core = trimmed |> strip_dupe_prefix |> string.trim
  case core {
    "#" <> rest -> {
      let digits = rest |> string.trim |> trim_trailing_period
      case int.parse(digits) {
        Ok(n) -> option.Some(n)
        Error(_) -> option.None
      }
    }
    _ -> option.None
  }
}

fn strip_dupe_prefix(text: String) -> String {
  case string.lowercase(text) {
    "duplicate of " <> _ -> string.drop_start(text, 13)
    "dupe of " <> _ -> string.drop_start(text, 8)
    "now tracked in " <> _ -> string.drop_start(text, 15)
    "closing as duplicate of " <> _ -> string.drop_start(text, 24)
    _ -> text
  }
}

fn trim_trailing_period(s: String) -> String {
  case string.ends_with(s, ".") {
    True -> string.drop_end(s, 1)
    False -> s
  }
}

// Hardcoded ID of the immich-app/immich 'Feature Request' discussion
// category. The user only cares about this category for dedupe; other
// categories (Q&A, General, etc.) are conversational and not duplicate
// candidates in the same sense.
const feature_request_category_id = "DIC_kwDOGyI-8M4CUEPD"

pub fn list_discussions(client: squall.Client, cursor: Option(String)) {
  let query =
    "
    query ListDiscussions($cursor: String, $category: ID!) {
      repository(owner: \"immich-app\", name: \"immich\") {
        discussions(first: 100, after: $cursor, categoryId: $category) {
          nodes {
              databaseId
              number
              title
              body
              closed
              stateReason
              url
              createdAt
              updatedAt
              closedAt
              author { login }
              comments(last: 10) {
                  nodes {
                      author { login }
                      body
                      createdAt
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
      json.object([
        #("cursor", json.nullable(cursor, json.string)),
        #("category", json.string(feature_request_category_id)),
      ]),
    )

  let assert Ok(response) = httpc.send(request)

  squall.parse_response(response.body, list_discussions_response_decoder())
}

fn list_discussions_response_decoder() -> decode.Decoder(ListItemsResponse) {
  let decoder = {
    use items <- decode.field("nodes", decode.list(discussion_backfill_decoder()))
    use page_info <- decode.field("pageInfo", page_info_decoder())
    decode.success(ListItemsResponse(items:, page_info:))
  }

  decode.at(["repository", "discussions"], decoder)
}

fn discussion_backfill_decoder() -> decode.Decoder(BackfillItem) {
  use item <- decode.then(types.discussion_decoder())
  use closed_at <- decode.optional_field(
    "closedAt",
    option.None,
    decode.optional(timestamp_decoder()),
  )
  use duplicate_of_number <- decode.then(duplicate_of_decoder(closed_at))
  use author_login <- decode.then(author_login_decoder())
  decode.success(BackfillItem(item:, duplicate_of_number:, author_login:))
}

pub type PageInfo {
  PageInfo(cursor: Option(String))
}

fn page_info_decoder() -> decode.Decoder(PageInfo) {
  use cursor <- decode.field("endCursor", decode.optional(decode.string))
  decode.success(PageInfo(cursor:))
}
