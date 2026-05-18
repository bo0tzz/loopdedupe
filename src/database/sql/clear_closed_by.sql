UPDATE items
SET closed_by = NULL
WHERE github_id = $1;
