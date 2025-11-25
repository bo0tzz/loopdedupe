import gleam/erlang/process
import pog
import squall

pub type Context {
  Context(
    db_name: process.Name(pog.Message),
    db: pog.Connection,
    github_client: squall.Client,
  )
}
