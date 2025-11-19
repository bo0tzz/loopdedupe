import gleam/bit_array
import gleam/crypto

pub fn validate_signature(
  body: String,
  signature: String,
  secret: String,
) -> Bool {
  case signature {
    "sha256=" <> provided_sig -> {
      let computed =
        crypto.hmac(
          bit_array.from_string(body),
          crypto.Sha256,
          bit_array.from_string(secret),
        )

      case bit_array.base16_decode(provided_sig) {
        Ok(sig) -> crypto.secure_compare(computed, sig)
        _ -> False
      }
    }
    _ -> False
  }
}
