--- migration:up
-- The login of the actor that closed the item. Captured from
-- ClosedEvent.actor.login on issue timelines (discussions have no equivalent
-- field; their column stays NULL).
--
-- Primary use: identifying bot-closures. immich's effort gate closes any
-- issue/discussion where the "I searched for duplicates" template checkbox
-- is unticked. Those closures fire as state_reason='duplicate' but represent
-- rejected submissions, not real duplicates — so they pollute the captured
-- canonical signal and shouldn't be treated as ground-truth dupes.
ALTER TABLE items ADD COLUMN closed_by TEXT;

--- migration:down
ALTER TABLE items DROP COLUMN closed_by;

--- migration:end
