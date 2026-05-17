import database/item
import database/sql
import github/types as github
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import pog
import types.{type Context}
import wisp.{type Request, type Response}

const top_pairs_limit = 50

const recent_items_limit = 50

pub fn index(ctx: Context) -> Response {
  let pairs = case sql.dashboard_top_pairs(ctx.db, top_pairs_limit) {
    Ok(pog.Returned(_, rows)) -> rows
    Error(_) -> []
  }
  let recent = case sql.dashboard_recent_items(ctx.db, recent_items_limit) {
    Ok(pog.Returned(_, rows)) -> rows
    Error(_) -> []
  }
  let stats = case sql.dashboard_stats(ctx.db) {
    Ok(pog.Returned(_, [row])) -> option.Some(row)
    _ -> option.None
  }

  let body =
    page("loopdedupe", [
      stats_block(stats),
      "<div class=\"columns\"><section><h2>Top candidate pairs</h2>",
      pairs_table(pairs),
      "</section><section><h2>Recent items</h2>",
      recent_table(recent),
      "</section></div>",
    ])

  wisp.html_response(body, 200)
}

pub fn stats_fragment(ctx: Context) -> Response {
  let stats = case sql.dashboard_stats(ctx.db) {
    Ok(pog.Returned(_, [row])) -> option.Some(row)
    _ -> option.None
  }
  wisp.html_response(stats_block(stats), 200)
}

// htmx-driven dismissal. Maintainer clicks × on a pair, we insert a
// 'not_duplicate' judgment, return empty body. The pair's <tr> has
// hx-swap='delete' which removes the row visually. The dashboard query
// filters out judged pairs so the dismissal sticks across reloads.
pub fn judgments(ctx: Context) -> Response {
  let rows = case sql.list_judgments(ctx.db) {
    Ok(pog.Returned(_, r)) -> r
    Error(_) -> []
  }
  let body =
    page("loopdedupe · judgments", [
      "<header-link><a href=\"/\">← back to dashboard</a></header-link>",
      "<h2>Dismissed pairs</h2>",
      "<p class=\"muted\">Pairs you've marked as not-a-duplicate. They're filtered out of the candidates feed and the per-item drill-in until removed from <code>pair_judgments</code>.</p>",
      judgments_table(rows),
    ])
  wisp.html_response(body, 200)
}

fn judgments_table(rows: List(sql.ListJudgmentsRow)) -> String {
  case rows {
    [] -> "<p><em>No dismissed pairs yet.</em></p>"
    _ ->
      "<table><thead><tr><th>Dismissed</th><th>Pair</th><th></th></tr></thead><tbody>"
      <> {
        list.map(rows, fn(row) {
          let src =
            PairSide(
              id: row.source_item_id,
              number: row.source_number,
              title: row.source_title,
              item_type: row.source_item_type,
              state: row.source_state,
              state_reason: row.source_state_reason,
              author: row.source_author,
              resolved_via_chain: False,
            )
          let tgt =
            PairSide(
              id: row.target_item_id,
              number: row.target_number,
              title: row.target_title,
              item_type: row.target_item_type,
              state: row.target_state,
              state_reason: row.target_state_reason,
              author: row.target_author,
              resolved_via_chain: False,
            )
          let undo_btn =
            "<button class=\"undo\" title=\"undo dismissal\""
            <> " hx-post=\"/api/judgments/undo?a="
            <> int.to_string(src.id)
            <> "&b="
            <> int.to_string(tgt.id)
            <> "\" hx-target=\"closest tr\" hx-swap=\"outerHTML swap:0.15s\">undo</button>"
          "<tr><td class=\"muted\">"
          <> escape(format_date(row.judged_at))
          <> "</td><td>"
          <> pair_side(src, "candidate")
          <> "<div class=\"pair-arrow\">↮ not a duplicate</div>"
          <> pair_side(tgt, "canonical")
          <> "</td><td class=\"dismiss-cell\">"
          <> undo_btn
          <> "</td></tr>"
        })
        |> string.concat()
      }
      <> "</tbody></table>"
  }
}

pub fn dismiss_pair(req: Request, ctx: Context) -> Response {
  let query = wisp.get_query(req)
  let a = result.try(list.key_find(query, "a"), int.parse)
  let b = result.try(list.key_find(query, "b"), int.parse)
  case a, b {
    Ok(a_id), Ok(b_id) ->
      case sql.insert_judgment(ctx.db, a_id, b_id, sql.NotDuplicate) {
        Ok(_) -> wisp.response(200) |> wisp.string_body("")
        Error(_) -> wisp.internal_server_error()
      }
    _, _ -> wisp.bad_request("expected ?a=<id>&b=<id>")
  }
}

pub fn undo_pair_judgment(req: Request, ctx: Context) -> Response {
  let query = wisp.get_query(req)
  let a = result.try(list.key_find(query, "a"), int.parse)
  let b = result.try(list.key_find(query, "b"), int.parse)
  case a, b {
    Ok(a_id), Ok(b_id) ->
      case sql.delete_judgment(ctx.db, a_id, b_id, sql.NotDuplicate) {
        Ok(_) -> wisp.response(200) |> wisp.string_body("")
        Error(_) -> wisp.internal_server_error()
      }
    _, _ -> wisp.bad_request("expected ?a=<id>&b=<id>")
  }
}

pub fn item_detail(ctx: Context, id: String) -> Response {
  case int.parse(id) {
    Error(_) -> wisp.bad_request("invalid id")
    Ok(item_id) -> {
      case item.select(ctx.db, item_id) {
        Error(_) -> wisp.not_found()
        Ok(it) -> {
          let candidates = case item.suggest_duplicates(ctx.db, item_id) {
            Ok(github.SuggestedDuplicates(items)) -> items
            Error(_) -> []
          }
          let body =
            page("#" <> int.to_string(it.number) <> " · " <> it.title, [
              item_header(it),
              "<h2>Similar candidates</h2>",
              candidates_table(candidates),
              item_body(it),
            ])
          wisp.html_response(body, 200)
        }
      }
    }
  }
}

// --- HTML helpers ------------------------------------------------------------

fn page(title: String, sections: List(String)) -> String {
  "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>"
  <> escape(title)
  <> "</title>"
  <> style_block()
  <> "<script src=\"https://unpkg.com/htmx.org@1.9.10\"></script>"
  <> "</head><body><header><a href=\"/\"><strong>loopdedupe</strong></a>"
  <> " <a href=\"/judgments\" class=\"nav-link\">judgments</a>"
  <> "</header><main>"
  <> string.concat(sections)
  <> "</main></body></html>"
}

fn style_block() -> String {
  "<style>
    :root { color-scheme: light dark; }
    body { font-family: system-ui, -apple-system, sans-serif; max-width: 1400px; margin: 0 auto; padding: 1em; line-height: 1.4; }
    header { padding: 0.5em 0; margin-bottom: 1em; border-bottom: 1px solid #ddd; }
    header a { color: inherit; text-decoration: none; }
    header .nav-link { margin-left: 1em; opacity: 0.6; font-size: 0.95em; }
    header .nav-link:hover { opacity: 1; }
    h2 { margin-top: 0; }
    .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 1em; padding: 1em; background: #f6f6f6; border-radius: 6px; margin-bottom: 1.5em; }
    @media (prefers-color-scheme: dark) { .stats { background: #222; } }
    .stat-label { font-size: 0.8em; opacity: 0.7; text-transform: uppercase; letter-spacing: 0.05em; }
    .stat-value { font-size: 1.4em; font-weight: 600; }
    .columns { display: grid; grid-template-columns: 1fr 1fr; gap: 2em; }
    @media (max-width: 900px) { .columns { grid-template-columns: 1fr; } }
    table { width: 100%; border-collapse: collapse; font-size: 1em; }
    th, td { text-align: left; padding: 0.55em 0.6em; border-bottom: 1px solid #eee; vertical-align: top; }
    @media (prefers-color-scheme: dark) { th, td { border-color: #333; } }
    th { font-weight: 600; opacity: 0.7; font-size: 0.9em; }
    .pair { display: block; }
    .pair-candidate { font-weight: 600; }
    .pair-canonical { opacity: 0.85; }
    .pair-arrow { font-size: 0.75em; opacity: 0.55; margin: 0.15em 0 0.15em 0.5em; font-style: italic; }
    .pair-arrow-sym { opacity: 0.45; }
    .pair-arrow-same-author { color: #b5651d; opacity: 1; font-style: normal; font-weight: 600; }
    @media (prefers-color-scheme: dark) { .pair-arrow-same-author { color: #f6c873; } }
    .same-author-row { background: rgba(255, 200, 100, 0.08); }
    @media (prefers-color-scheme: dark) { .same-author-row { background: rgba(255, 200, 100, 0.04); } }
    .deprioritized-row { opacity: 0.55; }
    .deprioritized-row:hover { opacity: 1; }
    .similarity { font-variant-numeric: tabular-nums; font-weight: 600; }
    .kind { display: inline-block; font-size: 0.7em; padding: 0.1em 0.4em; border-radius: 3px; background: #ddd; color: #333; vertical-align: middle; margin-right: 0.3em; }
    .kind-discussion { background: #c8e6c9; }
    .resolution-hint { font-size: 0.75em; opacity: 0.6; font-style: italic; margin-left: 0.5em; }
    .author { font-size: 0.75em; opacity: 0.6; margin-left: 0.5em; font-variant: tabular-nums; }
    .dismiss-cell { width: 2em; text-align: center; vertical-align: middle; }
    .dismiss, .undo { background: transparent; border: 1px solid #ccc; border-radius: 3px; padding: 0.1em 0.45em; cursor: pointer; opacity: 0.4; color: inherit; line-height: 1; }
    .dismiss { font-size: 1.1em; }
    .undo { font-size: 0.85em; }
    .undo:hover { opacity: 1; background: rgba(50, 150, 50, 0.1); border-color: rgba(50, 150, 50, 0.5); color: #393; }
    @media (prefers-color-scheme: dark) { .undo:hover { background: rgba(120, 220, 120, 0.15); border-color: #6d6; color: #8e8; } }
    .dismiss:hover { opacity: 1; background: rgba(200, 50, 50, 0.1); border-color: rgba(200, 50, 50, 0.5); color: #c33; }
    @media (prefers-color-scheme: dark) { .dismiss { border-color: #555; } .dismiss:hover { background: rgba(255, 100, 100, 0.15); border-color: #d77; color: #f88; } }
    .muted { opacity: 0.7; font-size: 0.9em; }
    header-link { display: block; margin-bottom: 1em; font-size: 0.9em; }
    header-link a { color: inherit; text-decoration: none; opacity: 0.7; }
    header-link a:hover { opacity: 1; }
    .state-closed { opacity: 0.55; }
    .state-duplicate { text-decoration: line-through; opacity: 0.55; }
    .item-body { white-space: pre-wrap; background: #f6f6f6; padding: 1em; border-radius: 6px; }
    @media (prefers-color-scheme: dark) { .item-body, .kind { background: #222; color: #eee; } .kind-discussion { background: #2e5b35; } }
    a { color: #06c; }
  </style>"
}

fn stats_block(stats: Option(sql.DashboardStatsRow)) -> String {
  let cells = case stats {
    option.None -> [#("status", "unavailable")]
    option.Some(s) -> [
      #("items", int.to_string(s.items_total)),
      #(
        "issues / discussions",
        int.to_string(s.items_issues)
          <> " / "
          <> int.to_string(s.items_discussions),
      ),
      #("embeddings", int.to_string(s.embeddings_total)),
      #("similarity edges", int.to_string(s.edges_total)),
      #("confirmed duplicates", int.to_string(s.duplicates_total)),
      #("backfill pending", int.to_string(s.jobs_backfill_pending)),
      #("embeddings pending", int.to_string(s.jobs_embeddings_pending)),
      #("similarity pending", int.to_string(s.jobs_similarity_pending)),
      #("jobs failed", int.to_string(s.jobs_failed)),
    ]
  }
  let body =
    list.map(cells, fn(c) {
      let #(label, value) = c
      "<div><div class=\"stat-label\">"
      <> escape(label)
      <> "</div><div class=\"stat-value\">"
      <> escape(value)
      <> "</div></div>"
    })
    |> string.concat()
  "<div id=\"stats\" class=\"stats\" hx-get=\"/dashboard/stats\" hx-trigger=\"every 5s\" hx-swap=\"outerHTML\">"
  <> body
  <> "</div>"
}

type PairSide {
  PairSide(
    id: Int,
    number: Int,
    title: String,
    item_type: sql.ItemType,
    state: sql.ItemState,
    state_reason: Option(sql.ItemStateReason),
    author: Option(String),
    resolved_via_chain: Bool,
  )
}

// Orient the pair into (candidate, canonical, is_symmetric).
//
// candidate = the open side; what a maintainer would act on (close as dupe).
// canonical = the "maybe a dupe of" target. Often older / closed-completed.
// is_symmetric = both sides open, so either could be the canonical. We pick
// the older one (lower number) as canonical and the newer as candidate, but
// surface that the direction isn't authoritative.
fn orient_pair(row: sql.DashboardTopPairsRow) -> #(PairSide, PairSide, Bool) {
  let src =
    PairSide(
      id: row.source_id,
      number: row.source_number,
      title: row.source_title,
      item_type: row.source_item_type,
      state: row.source_state,
      state_reason: row.source_state_reason,
      author: row.source_author,
      resolved_via_chain: row.source_id != row.source_original_id,
    )
  let tgt =
    PairSide(
      id: row.target_id,
      number: row.target_number,
      title: row.target_title,
      item_type: row.target_item_type,
      state: row.target_state,
      state_reason: row.target_state_reason,
      author: row.target_author,
      resolved_via_chain: row.target_id != row.target_original_id,
    )
  case src.state, tgt.state {
    sql.Open, sql.Closed -> #(src, tgt, False)
    sql.Closed, sql.Open -> #(tgt, src, False)
    sql.Open, sql.Open -> {
      // Both open — pick the newer (higher number) as candidate.
      case src.number > tgt.number {
        True -> #(src, tgt, True)
        False -> #(tgt, src, True)
      }
    }
    // Both-closed pairs are filtered upstream in dashboard_top_pairs.sql,
    // but if one slips through we still render it. The "candidate" label
    // is meaningless here; treat as symmetric and let the maintainer judge.
    sql.Closed, sql.Closed -> #(src, tgt, True)
  }
}

fn pairs_table(rows: List(sql.DashboardTopPairsRow)) -> String {
  case rows {
    [] -> "<p><em>No pairs yet. Run backfill to populate.</em></p>"
    _ ->
      "<table><thead><tr><th>Sim</th><th>Pair</th><th></th></tr></thead><tbody>"
      <> {
        list.map(rows, fn(row) {
          let #(candidate, canonical, symmetric) = orient_pair(row)
          let same_author = same_author(candidate.author, canonical.author)
          let separator = case symmetric, same_author {
            // Same-author pairs are ~100x more likely to be real duplicates
            // than random pairs (14.8% vs 0.15% in our ground-truth set).
            // Worth flagging visually so the maintainer can prioritize them.
            _, True ->
              "<div class=\"pair-arrow pair-arrow-same-author\">↻ same author — probably a refiling</div>"
            True, _ ->
              "<div class=\"pair-arrow pair-arrow-sym\">↔ either could be the canonical</div>"
            False, _ ->
              "<div class=\"pair-arrow\">↓ maybe a duplicate of</div>"
          }
          // Deprioritized = "closed-with-non-dupe-reason vs open" — empirically
          // 100% dismissal rate / 0% closure rate in the first triage session.
          // Sink to the bottom and grey out so they're scannable but don't
          // crowd out actionable pairs.
          let row_class = case same_author, row.deprioritized {
            _, True -> "<tr class=\"deprioritized-row\">"
            True, _ -> "<tr class=\"same-author-row\">"
            False, _ -> "<tr>"
          }
          let dismiss_btn =
            "<button class=\"dismiss\" title=\"dismiss as not a duplicate\""
            <> " hx-post=\"/api/judgments/not-duplicate?a="
            <> int.to_string(candidate.id)
            <> "&b="
            <> int.to_string(canonical.id)
            <> "\" hx-target=\"closest tr\" hx-swap=\"outerHTML swap:0.15s\">×</button>"
          row_class
          <> "<td class=\"similarity\">"
          <> format_similarity(row.similarity)
          <> "</td><td>"
          <> pair_side(candidate, "candidate")
          <> separator
          <> pair_side(canonical, "canonical")
          <> "</td><td class=\"dismiss-cell\">"
          <> dismiss_btn
          <> "</td></tr>"
        })
        |> string.concat()
      }
      <> "</tbody></table>"
  }
}

fn same_author(a: Option(String), b: Option(String)) -> Bool {
  case a, b {
    option.Some(x), option.Some(y) -> x == y
    _, _ -> False
  }
}

fn pair_side(side: PairSide, role: String) -> String {
  // The previous wording was "resolved canonical" which clashed with the
  // canonical/candidate role labels. This says the same thing — that an
  // edge endpoint was walked through items.duplicate_of_number to land
  // here — without overloading the role vocabulary.
  let resolution_hint = case side.resolved_via_chain {
    True -> " <span class=\"resolution-hint\">↪ via dupe chain</span>"
    False -> ""
  }
  let author_badge = case side.author {
    option.Some(login) ->
      " <span class=\"author\">by @" <> escape(login) <> "</span>"
    option.None -> ""
  }
  "<a class=\"pair pair-"
  <> role
  <> " "
  <> state_class(side.state, side.state_reason)
  <> "\" href=\"/items/"
  <> int.to_string(side.id)
  <> "\">"
  <> kind_badge(side.item_type)
  <> "#"
  <> int.to_string(side.number)
  <> " "
  <> escape(side.title)
  <> author_badge
  <> resolution_hint
  <> "</a>"
}

fn recent_table(rows: List(sql.DashboardRecentItemsRow)) -> String {
  case rows {
    [] -> "<p><em>No items yet.</em></p>"
    _ ->
      "<table><thead><tr><th>Created</th><th>Item</th></tr></thead><tbody>"
      <> {
        list.map(rows, fn(row) {
          "<tr><td>"
          <> escape(format_date(row.github_created_at))
          <> "</td><td><a class=\""
          <> state_class(row.state, row.state_reason)
          <> "\" href=\"/items/"
          <> int.to_string(row.github_id)
          <> "\">"
          <> kind_badge(row.item_type)
          <> "#"
          <> int.to_string(row.number)
          <> " "
          <> escape(row.title)
          <> "</a></td></tr>"
        })
        |> string.concat()
      }
      <> "</tbody></table>"
  }
}

fn item_header(it: github.Item) -> String {
  "<h2>#"
  <> int.to_string(it.number)
  <> " "
  <> escape(it.title)
  <> "</h2><p><a href=\""
  <> escape(it.url)
  <> "\">View on GitHub →</a> · "
  <> escape(format_date(it.created_at))
  <> "</p>"
}

fn item_body(it: github.Item) -> String {
  "<h2>Body</h2><div class=\"item-body\">" <> escape(it.body) <> "</div>"
}

fn candidates_table(items: List(github.SuggestedDuplicate)) -> String {
  case items {
    [] -> "<p><em>No candidates above threshold.</em></p>"
    _ ->
      "<table><thead><tr><th>Sim</th><th>Candidate</th></tr></thead><tbody>"
      <> {
        list.map(items, fn(c) {
          "<tr><td class=\"similarity\">"
          <> format_similarity(c.similarity)
          <> "</td><td><a class=\""
          <> state_class_github(c.state, c.state_reason)
          <> "\" href=\"/items/"
          <> int.to_string(c.github_id)
          <> "\">"
          <> escape(c.title)
          <> "</a></td></tr>"
        })
        |> string.concat()
      }
      <> "</tbody></table>"
  }
}

fn kind_badge(t: sql.ItemType) -> String {
  case t {
    sql.Issue -> "<span class=\"kind\">issue</span>"
    sql.Discussion -> "<span class=\"kind kind-discussion\">discussion</span>"
  }
}

fn state_class(
  state: sql.ItemState,
  reason: Option(sql.ItemStateReason),
) -> String {
  case state, reason {
    sql.Closed, option.Some(sql.Duplicate) -> "state-duplicate"
    sql.Closed, _ -> "state-closed"
    _, _ -> ""
  }
}

fn state_class_github(
  state: github.ItemState,
  reason: Option(github.ItemStateReason),
) -> String {
  case state, reason {
    github.Closed, option.Some(github.Duplicate) -> "state-duplicate"
    github.Closed, _ -> "state-closed"
    _, _ -> ""
  }
}

fn format_similarity(s: Float) -> String {
  case float.to_precision(s *. 100.0, 1) |> float.to_string() {
    str -> str <> "%"
  }
}

fn format_date(t: Timestamp) -> String {
  // YYYY-MM-DD slice of RFC3339 — good enough for a sortable, scannable list.
  timestamp.to_rfc3339(t, duration.seconds(0)) |> string.slice(0, 10)
}

fn escape(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}
