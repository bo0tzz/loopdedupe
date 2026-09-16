//// Database-backed health endpoint for Kubernetes probes.
////
//// The check runs a trivial query through the same pog pool the rest of the
//// app uses. That specificity is the point: on 2026-09-15 the pool spent 56
//// minutes handing out connections whose sockets were dead, returning
//// QueryTimeout on every m25 operation, while the pod reported 1/1 Running
//// with zero restarts. The BEAM was alive, the listener was accepting, and
//// TCP connections to Postgres were established — so a process check, a port
//// check and a connection count would all have passed throughout. Only a
//// query that actually traverses a pooled connection distinguishes that
//// state from a healthy one.

import gleam/dynamic/decode
import pog
import types.{type Context}
import wisp.{type Response}

// Written against pog directly rather than through squirrel, which has no way
// to express a per-query timeout. pog's default is 5s; five of those would let
// a probe hold a request worker for 25s, long after the kubelet gave up on it
// and started the next one. Bounded so the whole probe finishes inside a
// sane probe timeout even when every attempt is slow.
const query_timeout_ms = 500

/// A pool recovering from a Postgres restart is poisoned *partially*, not
/// uniformly — reproducing the incident locally gave a pool where checkout
/// rotated between working and dead connections, so single probes came back
/// in runs like `..XXX.XXX.XXX........XXX`. One query per probe is therefore
/// a coin flip, and a kubelet needs *consecutive* failures before it acts: a
/// lucky draw resets the counter and the pod is never restarted, while a
/// steady fraction of real work keeps failing.
///
/// Several queries per probe samples enough of the pool to make that
/// unlikely. Any failure fails the probe, which is the honest reading —
/// a pool that serves a dead connection some of the time cannot do its job.
const probe_attempts = 5

pub fn check(ctx: Context) -> Response {
  case probe(ctx, probe_attempts) {
    Ok(Nil) ->
      wisp.response(200)
      |> wisp.string_body("ok")
    Error(failure) -> unhealthy(failure)
  }
}

fn probe(ctx: Context, remaining: Int) -> Result(Nil, String) {
  case remaining {
    0 -> Ok(Nil)
    _ ->
      case run_check(ctx) {
        Ok(pog.Returned(_, [_])) -> probe(ctx, remaining - 1)
        Ok(_) -> Error("unexpected_result")
        Error(error) -> Error(reason(error))
      }
  }
}

fn run_check(ctx: Context) -> Result(pog.Returned(Int), pog.QueryError) {
  "SELECT 1"
  |> pog.query
  |> pog.timeout(query_timeout_ms)
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(ctx.db)
}

fn unhealthy(reason: String) -> Response {
  wisp.response(503)
  |> wisp.string_body("unhealthy: " <> reason)
}

// Mapped to fixed labels rather than inspected. pog's QueryError values don't
// carry connection options today, but this incident already leaked the
// database password into pod logs via a supervisor report — the response body
// of an unauthenticated endpoint is not somewhere to risk a repeat.
fn reason(error: pog.QueryError) -> String {
  case error {
    // What a dead pooled socket reports: pog maps `{error, closed}` from the
    // socket write to QueryTimeout, so this is the wedged-pool signature
    // rather than a slow query.
    pog.QueryTimeout -> "query_timeout"
    pog.ConnectionUnavailable -> "connection_unavailable"
    pog.ConstraintViolated(_, _, _) -> "constraint_violated"
    pog.PostgresqlError(code, _, _) -> "postgresql_error:" <> code
    pog.UnexpectedArgumentCount(_, _) -> "unexpected_argument_count"
    pog.UnexpectedArgumentType(_, _) -> "unexpected_argument_type"
    pog.UnexpectedResultType(_) -> "unexpected_result_type"
  }
}
