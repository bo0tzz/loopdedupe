UPDATE items
SET closed_by = $2
WHERE github_id = $1;
