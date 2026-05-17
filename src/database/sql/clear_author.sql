UPDATE items
SET author_login = NULL
WHERE github_id = $1;
