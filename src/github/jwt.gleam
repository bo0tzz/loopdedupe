//// Thin wrapper around the `jose` Erlang library to mint short-lived RS256
//// JWTs for GitHub App authentication. The JWT itself isn't directly used
//// against the API — it's traded for an installation access token (handled
//// in `github/auth`).

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/json

/// Opaque handles to jose's internal record types. We don't inspect them,
/// just pass through.
pub type Jwk

pub type Signed

@external(erlang, "jose_jwk", "from_pem")
fn jwk_from_pem(pem: BitArray) -> Jwk

/// jose_jwt:sign(JWK, ProtectedHeader, Payload). Payload accepts a JSON
/// binary which jose deserialises internally; we use that so we don't have
/// to build a heterogeneous Erlang map from Gleam.
@external(erlang, "jose_jwt", "sign")
fn jwt_sign(
  jwk: Jwk,
  protected: Dict(BitArray, BitArray),
  payload: BitArray,
) -> Signed

/// jose_jws:compact/1 returns {Modules, CompactBinary}. We ignore the
/// Modules tuple element.
@external(erlang, "jose_jws", "compact")
fn jws_compact(signed: Signed) -> #(Dynamic, BitArray)

/// Mint a fresh RS256 JWT identifying the GitHub App. GitHub allows up to
/// 10 minutes of lifetime; 9 minutes here gives us a small buffer against
/// clock skew. Iat must be a recent unix timestamp.
pub fn github_app_jwt(
  app_id app_id: Int,
  private_key_pem private_key_pem: String,
  iat iat: Int,
) -> String {
  let jwk = jwk_from_pem(bit_array.from_string(private_key_pem))
  let protected = dict.from_list([#(<<"alg":utf8>>, <<"RS256":utf8>>)])
  let payload =
    json.object([
      #("iat", json.int(iat)),
      #("exp", json.int(iat + 540)),
      #("iss", json.string(int.to_string(app_id))),
    ])
    |> json.to_string
    |> bit_array.from_string
  let #(_, compact) = jws_compact(jwt_sign(jwk, protected, payload))
  let assert Ok(s) = bit_array.to_string(compact)
  s
}
