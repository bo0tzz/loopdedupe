import config
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/list
import wisp

pub fn require_github_signature(
  headers: List(#(String, String)),
  body: String,
  handler: fn() -> wisp.Response,
) -> wisp.Response {
  use <- bool.guard(when: config.is_dev(), return: handler())

  let is_valid = case list.key_find(headers, "x-hub-signature-256") {
    Ok(signature) -> validate_signature(body, signature)
    Error(_) -> False
  }
  wisp.log_info(bool.to_string(is_valid))

  case is_valid {
    True -> handler()
    False -> wisp.response(401) |> wisp.string_body("invalid signature")
  }
}

pub fn validate_signature(body: String, signature: String) -> Bool {
  case signature {
    "sha256=" <> provided_sig -> {
      let secret = config.get_env(config.GithubWebhookSecret) |> bit_array.from_string()
      let computed =
        crypto.hmac(bit_array.from_string(body), crypto.Sha256, secret)

      case bit_array.base16_decode(provided_sig) {
        Ok(sig) -> crypto.secure_compare(computed, sig)
        _ -> False
      }
    }
    _ -> False
  }
}
