-- Resolve a (number, item_type) tuple to its internal github_id, used by
-- the human-friendly /issues/N and /discussions/N redirect routes.
SELECT github_id
FROM items
WHERE number = $1
  AND item_type = $2
LIMIT 1;
