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
pub fn backfills(ctx: Context) -> Response {
  let status = case sql.backfill_status(ctx.db) {
    Ok(pog.Returned(_, [row])) -> option.Some(row)
    _ -> option.None
  }
  let body =
    page("loopdedupe · backfills", [
      "<header-link><a href=\"/\">← back to dashboard</a></header-link>",
      "<h2>Backfills</h2>",
      "<p class=\"muted\">Manually kick off a walk of the GitHub corpus. Incremental walks only items updated since the latest <code>github_updated_at</code> we have stored. Full walks restart from the first page.</p>",
      backfill_triggers(),
      backfill_status_block(status),
    ])
  wisp.html_response(body, 200)
}

pub fn backfills_status_fragment(ctx: Context) -> Response {
  let status = case sql.backfill_status(ctx.db) {
    Ok(pog.Returned(_, [row])) -> option.Some(row)
    _ -> option.None
  }
  wisp.html_response(backfill_status_block(status), 200)
}

// Three trigger buttons. The response from each existing endpoint is plain
// text (e.g. 'backfill started — issues since ...'); we route it into the
// flash slot so the maintainer can see what was actually triggered.
fn backfill_triggers() -> String {
  "<section class=\"backfill-triggers\">
    <button class=\"trigger\" hx-post=\"/api/backfill/incremental\" hx-target=\"#flash\" hx-swap=\"innerHTML\">incremental (since latest)</button>
    <button class=\"trigger\" hx-post=\"/api/backfill\"             hx-target=\"#flash\" hx-swap=\"innerHTML\">full issues</button>
    <button class=\"trigger\" hx-post=\"/api/backfill/discussions\" hx-target=\"#flash\" hx-swap=\"innerHTML\">full discussions</button>
    <div id=\"flash\" class=\"flash\"></div>
  </section>"
}

fn backfill_status_block(status: Option(sql.BackfillStatusRow)) -> String {
  let chains = case status {
    option.None -> ""
    option.Some(s) ->
      chain_progress(
        "issues backfill",
        s.backfill_chain_pages,
        s.backfill_chain_age_seconds,
        s.total_issues,
        s.backfill_pending + s.backfill_executing,
      )
      <> chain_progress(
        "discussions backfill",
        s.discussion_chain_pages,
        s.discussion_chain_age_seconds,
        s.total_discussions,
        s.discussion_pending + s.discussion_executing,
      )
  }
  let rows = case status {
    option.None -> "<tr><td colspan=\"5\"><em>status unavailable</em></td></tr>"
    option.Some(s) ->
      queue_row(
        "issues backfill",
        s.backfill_pending,
        s.backfill_executing,
        s.backfill_recent_succeeded,
        s.backfill_recent_failed,
      )
      <> queue_row(
        "discussions backfill",
        s.discussion_pending,
        s.discussion_executing,
        s.discussion_recent_succeeded,
        s.discussion_recent_failed,
      )
      <> queue_row(
        "embeddings",
        s.embeddings_pending,
        s.embeddings_executing,
        s.embeddings_recent_succeeded,
        s.embeddings_recent_failed,
      )
      <> queue_row(
        "similarity",
        s.similarity_pending,
        s.similarity_executing,
        s.similarity_recent_succeeded,
        s.similarity_recent_failed,
      )
  }
  let footer = case status {
    option.None -> ""
    option.Some(s) ->
      "<p class=\"muted\">Latest <code>github_updated_at</code> stored — issues: "
      <> escape(format_datetime(s.latest_issue_update))
      <> " · discussions: "
      <> escape(format_datetime(s.latest_discussion_update))
      <> ". An incremental walk would resume from these boundaries.</p>"
  }
  "<div id=\"backfill-status\" hx-get=\"/backfills/status\" hx-trigger=\"every 2s\" hx-swap=\"outerHTML\">"
  <> chains
  <> "<h3>Queue status</h3>"
  <> "<table class=\"queue-status\"><thead><tr><th>queue</th><th>pending</th><th>executing</th><th>succeeded (5m)</th><th>failed (5m)</th></tr></thead><tbody>"
  <> rows
  <> "</tbody></table>"
  <> footer
  <> "</div>"
}

// Renders an inline progress bar when a chain is active. 'In flight' is
// pending+executing — pages already enqueued but not yet done. The
// total-page estimate assumes ~100 items per page (the GraphQL page size).
// For an incremental walk this overestimates since most pages will fall
// outside the since-window; in practice the chain ends faster than the
// total predicts, which is the right kind of error to make.
fn chain_progress(
  label: String,
  pages: Int,
  age_s: Int,
  total_items: Int,
  in_flight: Int,
) -> String {
  case pages > 0 || in_flight > 0 {
    False -> ""
    True -> {
      let estimated_total = case total_items / 100 {
        n if n < 1 -> 1
        n -> n + 1
      }
      let elapsed = format_duration(age_s)
      let eta = case pages > 0, age_s > 0 {
        True, True -> {
          let remaining = estimated_total - pages
          case remaining > 0 {
            True -> {
              // age_s seconds for `pages` pages → seconds/page = age_s / pages
              let eta_s = remaining * age_s / pages
              " · ~" <> format_duration(eta_s) <> " remaining"
            }
            False -> ""
          }
        }
        _, _ -> ""
      }
      let percent = case pages * 100 / estimated_total {
        p if p > 100 -> 100
        p -> p
      }
      "<div class=\"chain\"><div class=\"chain-label\">"
      <> escape(label)
      <> ": page "
      <> int.to_string(pages)
      <> " / ~"
      <> int.to_string(estimated_total)
      <> " · "
      <> escape(elapsed)
      <> " elapsed"
      <> escape(eta)
      <> case in_flight > 0 {
        True -> " · " <> int.to_string(in_flight) <> " in flight"
        False -> ""
      }
      <> "</div><div class=\"chain-bar\"><div class=\"chain-fill\" style=\"width: "
      <> int.to_string(percent)
      <> "%\"></div></div></div>"
    }
  }
}

fn format_duration(seconds: Int) -> String {
  case seconds {
    s if s < 60 -> int.to_string(s) <> "s"
    s if s < 3600 ->
      int.to_string(s / 60) <> "m " <> int.to_string(s % 60) <> "s"
    s ->
      int.to_string(s / 3600) <> "h " <> int.to_string({ s % 3600 } / 60) <> "m"
  }
}

fn queue_row(
  name: String,
  pending: Int,
  executing: Int,
  succeeded: Int,
  failed: Int,
) -> String {
  "<tr><td>"
  <> escape(name)
  <> "</td><td>"
  <> int.to_string(pending)
  <> "</td><td class=\""
  <> case executing > 0 {
    True -> "live"
    False -> ""
  }
  <> "\">"
  <> int.to_string(executing)
  <> "</td><td>"
  <> int.to_string(succeeded)
  <> "</td><td class=\""
  <> case failed > 0 {
    True -> "fail"
    False -> ""
  }
  <> "\">"
  <> int.to_string(failed)
  <> "</td></tr>"
}

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
  <> " <a href=\"/backfills\" class=\"nav-link\">backfills</a>"
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
    .backfill-triggers { display: flex; flex-wrap: wrap; gap: 0.6em; align-items: center; margin: 1em 0 2em; }
    .backfill-triggers .trigger { padding: 0.5em 0.9em; font-size: 0.95em; border: 1px solid #888; background: transparent; color: inherit; border-radius: 4px; cursor: pointer; }
    .backfill-triggers .trigger:hover { background: rgba(0, 100, 200, 0.08); border-color: #06c; }
    @media (prefers-color-scheme: dark) { .backfill-triggers .trigger:hover { background: rgba(120, 180, 255, 0.12); } }
    .backfill-triggers .flash { flex-basis: 100%; font-size: 0.9em; opacity: 0.75; font-family: ui-monospace, monospace; }
    .queue-status { max-width: 700px; font-variant-numeric: tabular-nums; }
    .queue-status td:not(:first-child), .queue-status th:not(:first-child) { text-align: right; padding-right: 1.2em; }
    .queue-status td.live { color: #06c; font-weight: 600; }
    @media (prefers-color-scheme: dark) { .queue-status td.live { color: #6cf; } }
    .queue-status td.fail { color: #c33; font-weight: 600; }
    @media (prefers-color-scheme: dark) { .queue-status td.fail { color: #f88; } }
    .chain { max-width: 700px; margin: 0.6em 0; font-variant-numeric: tabular-nums; }
    .chain-label { font-size: 0.9em; margin-bottom: 0.25em; }
    .chain-bar { height: 6px; background: rgba(120, 120, 120, 0.15); border-radius: 3px; overflow: hidden; }
    .chain-fill { height: 100%; background: #06c; transition: width 0.3s ease; }
    @media (prefers-color-scheme: dark) { .chain-fill { background: #6cf; } }
    .confidence-row td { font-size: 0.85em; padding: 0.4em 0.6em; border-bottom: 1px solid #eee; }
    @media (prefers-color-scheme: dark) { .confidence-row td { border-color: #333; } }
    .confidence-label { text-transform: uppercase; font-size: 0.75em; letter-spacing: 0.05em; opacity: 0.75; margin-right: 0.3em; }
    .confidence-gap { opacity: 0.6; font-size: 0.9em; margin-left: 0.2em; }
    .confidence-strong td { color: #393; }
    @media (prefers-color-scheme: dark) { .confidence-strong td { color: #8e8; } }
    .confidence-moderate td { color: #b5651d; }
    @media (prefers-color-scheme: dark) { .confidence-moderate td { color: #f6c873; } }
    .confidence-weak td { color: #c33; }
    @media (prefers-color-scheme: dark) { .confidence-weak td { color: #f88; } }
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
            False, _ -> "<div class=\"pair-arrow\">↓ maybe a duplicate of</div>"
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
        let banner = confidence_banner(items)
        let rows =
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
        banner <> rows
      }
      <> "</tbody></table>"
  }
}

// Confidence is the gap between rank 1 and rank 2 rerank scores, not the
// absolute score. With a sparse canonical or several semantically-similar
// candidates the rerank model spreads probability and no single item gets
// a high score — but a large gap to the next candidate means the top pick
// is unambiguous. Empirically (sampled from a week of closures) a gap of
// ~0.10 = confidently the one; < 0.05 = real ambiguity worth eyeballing
// the next few.
fn confidence_banner(items: List(github.SuggestedDuplicate)) -> String {
  case items {
    [first, second, ..] -> {
      let gap = first.similarity -. second.similarity
      let #(label, css_class) = case gap {
        g if g >=. 0.1 -> #("strong", "confidence-strong")
        g if g >=. 0.05 -> #("moderate", "confidence-moderate")
        _ -> #("weak — top candidates are close", "confidence-weak")
      }
      "<tr class=\"confidence-row "
      <> css_class
      <> "\"><td colspan=\"2\"><span class=\"confidence-label\">confidence</span> "
      <> escape(label)
      <> " <span class=\"confidence-gap\">(rank 1 leads by "
      <> format_similarity(gap)
      <> ")</span></td></tr>"
    }
    _ -> ""
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

fn format_datetime(t: Timestamp) -> String {
  // YYYY-MM-DD HH:MM slice — used where minute-level resolution matters
  // (e.g. 'latest update' freshness on the backfills page).
  timestamp.to_rfc3339(t, duration.seconds(0)) |> string.slice(0, 16)
}

fn escape(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}
