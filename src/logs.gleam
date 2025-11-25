import gleam/string
import logging

pub fn log_errors(callback: fn() -> Result(a, e)) -> Result(a, e) {
  let result = callback()
  case result {
    Ok(_) -> Nil
    Error(e) -> logging.log(logging.Error, string.inspect(e))
  }
  result
}
