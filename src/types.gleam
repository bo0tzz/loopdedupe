import github/auth
import gleam/erlang/process
import pog

pub type Context {
  Context(
    db_name: process.Name(pog.Message),
    db: pog.Connection,
    auth: process.Name(auth.Msg),
  )
}
