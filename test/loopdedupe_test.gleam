import api/dashboard
import github/graphql
import github/types as github
import gleam/option.{type Option, None, Some}
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

// --- status slugs ----------------------------------------------------------
//
// The point of the slug is that closed items keep the reason that closed
// them, so "not planned" reads differently from "closed".

pub fn status_slug_open_ignores_reason_test() {
  assert github.status_slug(github.Open, None) == "open"
  // A reopened item is just open.
  assert github.status_slug(github.Open, Some(github.Reopened)) == "open"
}

pub fn status_slug_distinguishes_closed_reasons_test() {
  assert github.status_slug(github.Closed, Some(github.Completed))
    == "completed"
  assert github.status_slug(github.Closed, Some(github.NotPlanned))
    == "not_planned"
  assert github.status_slug(github.Closed, Some(github.Outdated)) == "outdated"
  assert github.status_slug(github.Closed, Some(github.Resolved)) == "resolved"
}

pub fn status_slug_closed_without_reason_test() {
  assert github.status_slug(github.Closed, None) == "closed"
}

// --- hidden_from_shown -----------------------------------------------------

pub fn hidden_from_shown_unsubmitted_hides_nothing_test() {
  assert dashboard.hidden_from_shown(None) == []
}

pub fn hidden_from_shown_everything_checked_hides_nothing_test() {
  assert dashboard.hidden_from_shown(Some(github.filterable_statuses)) == []
}

pub fn hidden_from_shown_inverts_the_selection_test() {
  assert dashboard.hidden_from_shown(Some(["open"]))
    == ["completed", "not_planned", "resolved", "outdated"]
}

// An submitted form with no boxes ticked means "show nothing", which is
// distinct from an unsubmitted one.
pub fn hidden_from_shown_nothing_checked_hides_everything_test() {
  assert dashboard.hidden_from_shown(Some([])) == github.filterable_statuses
}

// --- reject_hidden_statuses ------------------------------------------------

fn candidate(
  number: Int,
  state: github.ItemState,
  reason: Option(github.ItemStateReason),
) -> github.SuggestedDuplicate {
  github.SuggestedDuplicate(
    similarity: 0.9,
    number: number,
    item_type: github.Issue,
    title: "t",
    state: state,
    state_reason: reason,
  )
}

pub fn reject_hidden_statuses_empty_filter_is_identity_test() {
  let items = [
    candidate(1, github.Open, None),
    candidate(2, github.Closed, Some(github.Completed)),
  ]
  assert github.reject_hidden_statuses(items, []) == items
}

pub fn reject_hidden_statuses_drops_only_the_named_test() {
  let items = [
    candidate(1, github.Open, None),
    candidate(2, github.Closed, Some(github.Completed)),
    candidate(3, github.Closed, Some(github.NotPlanned)),
  ]
  let kept = github.reject_hidden_statuses(items, ["completed"])
  assert kept
    == [
      candidate(1, github.Open, None),
      candidate(3, github.Closed, Some(github.NotPlanned)),
    ]
}

// not_planned must survive a filter aimed at plain closures — that
// separation is the whole point of the request.
pub fn reject_hidden_statuses_not_planned_is_not_completed_test() {
  let items = [candidate(3, github.Closed, Some(github.NotPlanned))]
  assert github.reject_hidden_statuses(items, ["completed"]) == items
  assert github.reject_hidden_statuses(items, ["not_planned"]) == []
}
