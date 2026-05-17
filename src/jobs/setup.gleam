import jobs/backfill
import jobs/discussion_backfill
import jobs/embeddings
import jobs/similarity
import m25
import types.{type Context}

pub fn supervised(ctx: Context) {
  let queues = m25.new(ctx.db)
  let assert Ok(queues) = m25.add_queue(queues, embeddings.queue_spec(ctx.db))
  let assert Ok(queues) = m25.add_queue(queues, similarity.queue_spec(ctx.db))
  let assert Ok(queues) = m25.add_queue(queues, backfill.queue_spec(ctx))
  let assert Ok(queues) =
    m25.add_queue(queues, discussion_backfill.queue_spec(ctx))

  m25.supervised(queues, 10_000)
}
