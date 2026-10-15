//// One pass at startup that re-queues whatever the embed → similarity
//// pipeline left behind (see items_needing_reconcile for what counts).
//// Nothing else would: jobs only get queued by webhooks and backfills, so an
//// item whose retries ran out stays without candidates until it's next
//// edited. Running on every deploy keeps that from accumulating.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision
import gleam/string
import jobs/embeddings
import jobs/similarity
import logging
import pog
import types.{type Context}

pub fn supervised(ctx: Context) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    Ok(actor.Started(process.spawn(fn() { run(ctx) }), Nil))
  })
  |> supervision.restart(supervision.Temporary)
}

// Written against pog rather than squirrel so the query can carry its own
// timeout. It probes the edges index once per item, and on a freshly started
// pod with a cold cache that ran past pog's 5s default.
const query_timeout_ms = 60_000

type Candidate {
  Candidate(
    github_id: Int,
    title: String,
    body: String,
    has_fresh_embedding: Bool,
  )
}

/// Items the pipeline left behind:
///   - no embedding: every attempt failed (Voyage timeouts, oversized input)
///     and nothing re-queued it
///   - embedding older than the item's last update
///   - embedding but no outgoing edges: an embed attempt whose insert
///     committed but reported a timeout, so the retry skipped straight past
///     the similarity step. Incoming edges don't count: other items' jobs
///     keep adding those, and they hide that this item's own never ran.
/// Re-queueing is deduped by content-versioned unique keys, so items that are
/// legitimately edgeless (nothing within the edge threshold) or only got a
/// comment or label since their embedding cost one no-op enqueue per startup.
fn items_needing_reconcile(
  db: pog.Connection,
) -> Result(pog.Returned(Candidate), pog.QueryError) {
  let decoder = {
    use github_id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use body <- decode.field(2, decode.string)
    use has_fresh_embedding <- decode.field(3, decode.bool)
    decode.success(Candidate(github_id:, title:, body:, has_fresh_embedding:))
  }
  "SELECT i.github_id,
          i.title,
          i.body,
          e.item_id IS NOT NULL AND e.created_at >= i.github_updated_at
   FROM items i
            LEFT JOIN item_embeddings e ON e.item_id = i.github_id
   WHERE e.item_id IS NULL
      OR e.created_at < i.github_updated_at
      OR NOT EXISTS (SELECT 1 FROM item_similarity_edges s WHERE s.source_item_id = i.github_id)"
  |> pog.query
  |> pog.timeout(query_timeout_ms)
  |> pog.returning(decoder)
  |> pog.execute(db)
}

fn run(ctx: Context) -> Nil {
  case items_needing_reconcile(ctx.db) {
    Error(e) ->
      logging.log(
        logging.Warning,
        "reconcile: failed to list items: " <> string.inspect(e),
      )
    Ok(pog.Returned(_, rows)) -> {
      let failures =
        list.count(rows, fn(row) {
          let version = embeddings.content_version(row.title, row.body)
          // A fresh embedding with no edges needs only the similarity step;
          // its embedding job already succeeded for this version, so
          // queueing that again would no-op.
          let queued = case row.has_fresh_embedding {
            True -> similarity.enqueue(ctx.db, row.github_id, version)
            False ->
              embeddings.enqueue(ctx.db, row.github_id, row.title, row.body)
          }
          queued != Ok(Nil)
        })
      logging.log(
        logging.Info,
        "reconcile: "
          <> int.to_string(list.length(rows))
          <> " items checked, "
          <> int.to_string(failures)
          <> " failed to queue",
      )
    }
  }
}
