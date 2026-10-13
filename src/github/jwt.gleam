//// Mints short-lived RS256 JWTs for GitHub App authentication. The JWT
//// itself isn't directly used against the API — it's traded for an
//// installation access token (handled in `github/auth`).
////
//// Signed with OTP's public_key directly: one fixed algorithm doesn't need a
//// JOSE library, and jose (the only one on hex) stopped compiling on OTP 29.

import gleam/bit_array
import gleam/int
import gleam/json

type PemEntry

type PrivateKey

type DigestType {
  Sha256
}

@external(erlang, "public_key", "pem_decode")
fn pem_decode(pem: BitArray) -> List(PemEntry)

@external(erlang, "public_key", "pem_entry_decode")
fn pem_entry_decode(entry: PemEntry) -> PrivateKey

/// With an RSA key this is RSASSA-PKCS1-v1_5, which is what RS256 means.
@external(erlang, "public_key", "sign")
fn sign(message: BitArray, digest: DigestType, key: PrivateKey) -> BitArray

/// Mint a fresh RS256 JWT identifying the GitHub App. GitHub allows up to
/// 10 minutes of lifetime; 9 minutes here gives us a small buffer against
/// clock skew. Iat must be a recent unix timestamp.
pub fn github_app_jwt(
  app_id app_id: Int,
  private_key_pem private_key_pem: String,
  iat iat: Int,
) -> String {
  let assert [entry, ..] = pem_decode(bit_array.from_string(private_key_pem))
  let key = pem_entry_decode(entry)
  let header =
    json.object([
      #("alg", json.string("RS256")),
      #("typ", json.string("JWT")),
    ])
  let payload =
    json.object([
      #("iat", json.int(iat)),
      #("exp", json.int(iat + 540)),
      #("iss", json.string(int.to_string(app_id))),
    ])
  let signing_input = segment(header) <> "." <> segment(payload)
  let signature = sign(bit_array.from_string(signing_input), Sha256, key)
  signing_input <> "." <> bit_array.base64_url_encode(signature, False)
}

fn segment(value: json.Json) -> String {
  json.to_string(value)
  |> bit_array.from_string
  |> bit_array.base64_url_encode(False)
}
