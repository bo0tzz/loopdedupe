import gleam/erlang/process
import jobs/embeddings
import m25
import pog

pub fn supervised(db_name: process.Name(pog.Message)) {
  let assert Ok(queues) =
    pog.named_connection(db_name)
    |> m25.new()
    |> m25.add_queue(embeddings.queue_spec())

  m25.supervised(queues, 10_000)
}
