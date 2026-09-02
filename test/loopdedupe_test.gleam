import github/graphql
import gleam/option.{None, Some}
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// --- resolve_duplicate_of -------------------------------------------------
//
// Precedence and the self-reference guard. The guard is what stops an item
// becoming its own canonical, which is how MarkedAsDuplicateEvent polluted
// the items table: GitHub puts that event on the canonical's timeline too,
// where its `canonical` field is the item we're reading.

pub fn resolve_takes_highest_precedence_signal_test() {
  assert graphql.resolve_duplicate_of(100, [Some(1), Some(2), Some(3)])
    == Some(1)
}

pub fn resolve_falls_through_empty_signals_test() {
  assert graphql.resolve_duplicate_of(100, [None, None, Some(3)]) == Some(3)
}

pub fn resolve_with_no_signals_test() {
  assert graphql.resolve_duplicate_of(100, []) == None
  assert graphql.resolve_duplicate_of(100, [None, None]) == None
}

pub fn resolve_drops_self_reference_test() {
  assert graphql.resolve_duplicate_of(100, [Some(100)]) == None
}

// A self-referential high-precedence signal must not veto a good lower one —
// the reverse-direction event is garbage, not a decision.
pub fn resolve_self_reference_does_not_mask_later_signal_test() {
  assert graphql.resolve_duplicate_of(100, [Some(100), Some(42)]) == Some(42)
}

pub fn resolve_drops_self_reference_anywhere_in_the_list_test() {
  assert graphql.resolve_duplicate_of(100, [None, Some(100), None, Some(7)])
    == Some(7)
}

pub fn resolve_all_signals_self_referential_test() {
  assert graphql.resolve_duplicate_of(100, [Some(100), Some(100)]) == None
}
