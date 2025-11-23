import gleam/erlang/process
import jobs/embeddings
import m25
import pog

pub fn supervised(db_name: process.Name(pog.Message)) {
  let conn = pog.named_connection(db_name)
  let assert Ok(queues) = m25.new(conn)
    |> m25.add_queue(embeddings.queue_spec(conn))

  m25.supervised(queues, 10_000)
}
