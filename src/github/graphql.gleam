import github/types
import gleam/dynamic/decode
import gleam/float
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/regexp
import gleam/result
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import squall

// Comments by these authorAssociation values are treated as authoritative
// for dupe-pointer extraction. OWNER/MEMBER/COLLABORATOR == "actual repo
// maintainer", which is broader than hardcoding one login and avoids
// missing closures by mmomjian, danieldietzler, alextran1502, etc. Drops
// CONTRIBUTOR / NONE / FIRST_TIMER who post '#NNN' refs that often point
// at related-but-not-canonical items.
fn is_maintainer_association(assoc: String) -> Bool {
  case assoc {
    "OWNER" | "MEMBER" | "COLLABORATOR" -> True
    _ -> False
  }
}

pub fn list_items(
  client: squall.Client,
  cursor: Option(String),
  since: Option(String),
) {
  let query =
    "
    query ListItems($cursor: String, $since: DateTime) {
      repository(owner: \"immich-app\", name: \"immich\") {
        issues(first: 100, after: $cursor, filterBy: { since: $since }) {
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
                      authorAssociation
                      body
                      createdAt
                  }
              }
              duplicateOf { number }
              conversion: timelineItems(itemTypes: CONVERTED_TO_DISCUSSION_EVENT, last: 1) {
                  nodes {
                      ... on ConvertedToDiscussionEvent {
                          discussion { number }
                      }
                  }
              }
              closure: timelineItems(itemTypes: CLOSED_EVENT, last: 1) {
                  nodes {
                      ... on ClosedEvent {
                          actor { login }
                      }
                  }
              }
              markedDup: timelineItems(itemTypes: MARKED_AS_DUPLICATE_EVENT, last: 10) {
                  nodes {
                      ... on MarkedAsDuplicateEvent {
                          canonical {
                              ... on Issue { number }
                          }
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
      json.object([
        #("cursor", json.nullable(cursor, json.string)),
        #("since", json.nullable(since, json.string)),
      ]),
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
    // The login of the actor that closed the item, or None for items that
    // are open (no close event) or for items whose closer was a ghost user.
    // Captured from the ClosedEvent timeline entry — for discussions this
    // is always None because the Discussion type has no timelineItems.
    closed_by: Option(String),
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
  // Four independent signals for the canonical pointer, in precedence order:
  //   1. ConvertedToDiscussionEvent — the issue was converted to a discussion,
  //      that discussion *is* the canonical entity going forward.
  //   2. Issue.duplicateOf — GitHub's native duplicate relationship, and what
  //      the "mark as duplicate" UI actually writes. Structured, directional,
  //      and populated on closures that leave no comment at all (which is
  //      most of them: it carries the canonical for 579 of the 939
  //      duplicate-closed issues that no other signal reaches).
  //   3. MarkedAsDuplicateEvent — the older event form of the same action.
  //      Retained as a safety net, but see marked_as_duplicate_decoder: every
  //      occurrence in this repo is a reverse-direction event, so in practice
  //      it now yields nothing.
  //   4. Maintainer dupe-pattern comment near close time — the original
  //      manual workflow, parsed heuristically.
  // Structured signals beat the heuristic: where 2 and 4 disagreed, 4 was
  // wrong both times.
  use converted_to <- decode.then(converted_to_discussion_decoder())
  use duplicate_of_field <- decode.then(duplicate_of_field_decoder())
  use marked_dup <- decode.then(marked_as_duplicate_decoder(item.number))
  use closed_at <- decode.optional_field(
    "closedAt",
    option.None,
    decode.optional(timestamp_decoder()),
  )
  use comment_ref <- decode.then(duplicate_of_decoder(closed_at))
  use author_login <- decode.then(author_login_decoder())
  use closed_by <- decode.then(closed_by_decoder())
  let duplicate_of_number =
    resolve_duplicate_of(item.number, [
      converted_to,
      duplicate_of_field,
      marked_dup,
      comment_ref,
    ])
  decode.success(BackfillItem(
    item:,
    duplicate_of_number:,
    author_login:,
    closed_by:,
  ))
}

/// Pick the canonical pointer from the available signals, highest-precedence
/// first, discarding any that points back at the item itself.
///
/// The self-reference guard is the important part. A pointer equal to the
/// item's own number is never meaningful — it makes the item its own
/// canonical, which the chain walk in suggest_duplicates.sql then spins on
/// for its full ten levels before resolving back to the item. A garbage
/// signal falls through to the next one rather than vetoing it, so a bad
/// structured read can't mask a good comment ref.
@internal
pub fn resolve_duplicate_of(
  self_number: Int,
  signals: List(Option(Int)),
) -> Option(Int) {
  signals
  |> list.find_map(fn(signal) {
    case signal {
      option.Some(n) if n != self_number -> Ok(n)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

// Issue.duplicateOf — GitHub's native duplicate relationship. This is where
// the "mark as duplicate" UI records the canonical, and unlike
// MarkedAsDuplicateEvent it is a field on the issue rather than a timeline
// entry, so it is inherently directional: it always points away from this
// issue and can never resolve to itself. Discussions have no equivalent
// field, which is why the discussion path still depends on comments.
fn duplicate_of_field_decoder() -> decode.Decoder(Option(Int)) {
  use number <- decode.optional_field(
    "duplicateOf",
    option.None,
    decode.optional(decode.at(["number"], decode.int)),
  )
  decode.success(number)
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
    "conversion",
    option.None,
    decode.optional(nodes_decoder),
  )
  decode.success(option.flatten(timeline))
}

// MarkedAsDuplicateEvent.canonical — the canonical Issue (or PR) the
// maintainer pointed this item to via GitHub's UI dropdown. We only accept
// Issue canonicals because PRs aren't in our items table.
//
// GitHub records this event on BOTH timelines: the duplicate's and the
// canonical's. On the canonical's timeline the event describes some *other*
// issue being marked against it, and `canonical` is this very issue — so
// reading it unfiltered makes an item its own canonical. That is where the
// self-referential rows in `items` came from, and taking only `last: 1` made
// it worse by preferring whichever event happened most recently. We now scan
// the recent events and keep the first that points somewhere else, which
// leaves genuine forward events working and drops the reverse ones.
fn marked_as_duplicate_decoder(
  self_number: Int,
) -> decode.Decoder(Option(Int)) {
  let event_decoder = {
    use number <- decode.optional_field(
      "canonical",
      option.None,
      decode.optional(decode.at(["number"], decode.int)),
    )
    decode.success(number)
  }
  let nodes_decoder = {
    use nodes <- decode.field("nodes", decode.list(event_decoder))
    decode.success(resolve_duplicate_of(self_number, nodes))
  }
  use timeline <- decode.optional_field(
    "markedDup",
    option.None,
    decode.optional(nodes_decoder),
  )
  decode.success(option.flatten(timeline))
}

// ClosedEvent.actor.login. Returns None when the item was never closed
// (no event), or when the closer is a ghost (deleted) user (actor: null).
fn closed_by_decoder() -> decode.Decoder(Option(String)) {
  let event_decoder = {
    use actor <- decode.optional_field(
      "actor",
      option.None,
      decode.optional(decode.at(["login"], decode.string)),
    )
    decode.success(actor)
  }
  let nodes_decoder = {
    use nodes <- decode.field("nodes", decode.list(event_decoder))
    case nodes {
      [first, ..] -> decode.success(first)
      [] -> decode.success(option.None)
    }
  }
  use timeline <- decode.optional_field(
    "closure",
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
    use author_association <- decode.optional_field(
      "authorAssociation",
      "",
      decode.string,
    )
    use created_at <- decode.field("createdAt", timestamp_decoder())
    use body <- decode.field("body", decode.string)
    case is_maintainer_association(author_association) {
      True ->
        case parse_dupe_ref(body) {
          option.Some(n) -> decode.success(option.Some(#(created_at, n)))
          option.None -> decode.success(option.None)
        }
      False -> decode.success(option.None)
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

// Bot-closure detection uses a wider window than the maintainer-comment
// path. The bot is an automated workflow with queue latency: most closures
// fire within seconds but a long tail can drift to tens of minutes. 30
// minutes captures ~99% of bot closures on the existing data without risk
// of false matches (the bot only ever posts one closure comment per item).
const bot_alignment_window_seconds = 1800.0

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

// Parse a comment body for a dupe pointer like '#NNN'. Two paths, in order:
//
//   1. Bare '#NNN' as the whole comment (after strip_dupe_prefix). Kept
//      strict — the comment must BE the pointer, no surrounding prose. A
//      mid-comment '#123' (e.g. 'unrelated context #123') is too noisy.
//
//   2. A known dupe-of phrase ('duplicate of', 'dupe of', 'tracked in',
//      'covered by', 'same as') followed by '#NNN', anywhere in the body.
//      Maintainers commonly write 'I think this is a duplicate of #N' or
//      'Thanks, tracked in #N' — narrative prose around the phrase is fine.
//      Patterns picked from sampling the 598 lazy-close issues; phrasings
//      that point at PRs ('fixed by', 'merged into') or signal relates-to
//      ('blocked by', 'see also') are deliberately excluded — they'd
//      pollute the dupe graph with non-canonical references.
fn parse_dupe_ref(body: String) -> Option(Int) {
  case parse_bare_ref(body) {
    option.Some(n) -> option.Some(n)
    option.None -> parse_phrase_ref(body)
  }
}

// Match any line that consists of just '#NNN' (optional trailing period,
// optional surrounding whitespace). Maintainers commonly place the
// canonical pointer on its own line — at the start ('#NNN\n\n<lecture>'),
// at the end ('<context>\n\n#NNN'), or as the whole body. We don't pick
// up '#NNN' mid-prose because that's too prone to false positives ('this
// might be related to #123 but actually...').
fn bare_ref_regex() -> regexp.Regexp {
  let assert Ok(re) =
    regexp.compile(
      "^\\s*#(\\d+)\\.?\\s*$",
      regexp.Options(case_insensitive: False, multi_line: True),
    )
  re
}

fn parse_bare_ref(body: String) -> Option(Int) {
  case regexp.scan(bare_ref_regex(), body) {
    [regexp.Match(_, [option.Some(digits), ..]), ..] ->
      case int.parse(digits) {
        Ok(n) -> option.Some(n)
        Error(_) -> option.None
      }
    _ -> option.None
  }
}

// Compiled once at first use; the assertion is fine because the pattern is
// a constant. Captures the trigger phrase (group 1, unused) and the digit
// sequence (group 2). [^#\n]{0,30} allows short modifiers between the
// trigger and '#N' ('in favour of THE MORE ACTIVE #4747') while stopping
// at the next '#' so we capture the first reference, and at newline so we
// don't cross paragraph boundaries.
fn dupe_phrase_regex() -> regexp.Regexp {
  let assert Ok(re) =
    regexp.compile(
      "\\b(duplicate of|dupe of|tracked in|tracking in|track this in|covered by|same as|same issue as|in favou?r of|roll into|consolidate into)[^#\\n]{0,30}#(\\d+)\\b",
      regexp.Options(case_insensitive: True, multi_line: True),
    )
  re
}

fn parse_phrase_ref(body: String) -> Option(Int) {
  case regexp.scan(dupe_phrase_regex(), body) {
    [regexp.Match(_, submatches), ..] ->
      case submatches {
        [_, option.Some(digits)] ->
          case int.parse(digits) {
            Ok(n) -> option.Some(n)
            Error(_) -> option.None
          }
        _ -> option.None
      }
    _ -> option.None
  }
}

// Hardcoded ID of the immich-app/immich 'Feature Request' discussion
// category. The user only cares about this category for dedupe; other
// categories (Q&A, General, etc.) are conversational and not duplicate
// candidates in the same sense.
const feature_request_category_id = "DIC_kwDOGyI-8M4CUEPD"

pub fn list_discussions(client: squall.Client, cursor: Option(String)) {
  // Always order newest-first by updatedAt so callers doing an incremental
  // walk can stop the chain as soon as a page contains items older than
  // their boundary. (Discussions don't have GitHub's filterBy.since, so
  // sort + early-stop is the equivalent.)
  let query =
    "
    query ListDiscussions($cursor: String, $category: ID!) {
      repository(owner: \"immich-app\", name: \"immich\") {
        discussions(
          first: 100,
          after: $cursor,
          categoryId: $category,
          orderBy: { field: UPDATED_AT, direction: DESC }
        ) {
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
                      authorAssociation
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
    use items <- decode.field(
      "nodes",
      decode.list(discussion_backfill_decoder()),
    )
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
  // Discussions have neither timelineItems nor a duplicateOf field, so the
  // maintainer comment is the only signal available here. Still guarded
  // against self-reference: a comment that names its own thread's number is
  // as useless as a reverse-direction event.
  use comment_ref <- decode.then(duplicate_of_decoder(closed_at))
  let duplicate_of_number = resolve_duplicate_of(item.number, [comment_ref])
  use author_login <- decode.then(author_login_decoder())
  // Discussions have no timelineItems on the GitHub GraphQL API, so we
  // recover the closer from the bot's own closure comment instead. The
  // immich auto-dupe bot posts as `github-actions` near the close timestamp
  // with a fixed wording; matching that gives us the closer we can't read
  // off ClosedEvent.actor. Returns None when no such comment is present.
  use closed_by <- decode.then(bot_comment_closer_decoder(closed_at))
  decode.success(BackfillItem(
    item:,
    duplicate_of_number:,
    author_login:,
    closed_by:,
  ))
}

// github-actions is the bot login for the immich auto-dupe-closer. Anchored
// to close time the same way duplicate_of_decoder is, so we don't pick up
// unrelated github-actions activity (label runs, etc.) far from the close.
fn bot_comment_closer_decoder(
  close_at: Option(Timestamp),
) -> decode.Decoder(Option(String)) {
  let comment_decoder = {
    use login <- decode.optional_field(
      "author",
      option.None,
      decode.optional(decode.at(["login"], decode.string)),
    )
    use created_at <- decode.field("createdAt", timestamp_decoder())
    case login {
      option.Some("github-actions") ->
        decode.success(option.Some(#(created_at, "github-actions")))
      _ -> decode.success(option.None)
    }
  }

  let comments_decoder = {
    use nodes <- decode.field("nodes", decode.list(comment_decoder))
    let matches =
      list.filter_map(nodes, fn(x) {
        case x {
          option.Some(v) -> Ok(v)
          option.None -> Error(Nil)
        }
      })
    let picked = pick_closest_string_to_close(close_at, matches)
    decode.success(picked)
  }

  use comments <- decode.optional_field(
    "comments",
    option.None,
    decode.optional(comments_decoder),
  )
  decode.success(option.flatten(comments))
}

fn pick_closest_string_to_close(
  close_at: Option(Timestamp),
  candidates: List(#(Timestamp, String)),
) -> Option(String) {
  case close_at {
    option.None -> option.None
    option.Some(ct) -> {
      candidates
      |> list.filter_map(fn(pair) {
        let #(t, v) = pair
        let delta =
          timestamp.difference(ct, t)
          |> duration.to_seconds
          |> float.absolute_value
        case delta <=. bot_alignment_window_seconds {
          True -> Ok(#(delta, v))
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

pub type PageInfo {
  PageInfo(cursor: Option(String))
}

fn page_info_decoder() -> decode.Decoder(PageInfo) {
  use cursor <- decode.field("endCursor", decode.optional(decode.string))
  decode.success(PageInfo(cursor:))
}
