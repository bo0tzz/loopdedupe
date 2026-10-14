//// One pass at startup that re-queues whatever the embed → similarity
//// pipeline left behind (see items_needing_reconcile.sql for what counts).
//// Nothing else would: jobs only get queued by webhooks and backfills, so an
//// item whose retries ran out stays without candidates until it's next
//// edited. Running on every deploy keeps that from accumulating.

import database/sql
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

fn run(ctx: Context) -> Nil {
  case sql.items_needing_reconcile(ctx.db) {
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
