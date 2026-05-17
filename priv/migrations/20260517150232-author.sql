--- migration:up
-- Capture the GitHub login that filed the item. Useful as a signal in the
-- dedup pipeline (same-author pairs are very often intentional refilings of
-- the same bug) and as display context in the dashboard ("oh, that's me").
--
-- Nullable because GitHub accounts can be deleted, leaving issues authored
-- by a ghost user (author is null on the API).
ALTER TABLE items ADD COLUMN author_login TEXT;

--- migration:down
ALTER TABLE items DROP COLUMN author_login;

--- migration:end
