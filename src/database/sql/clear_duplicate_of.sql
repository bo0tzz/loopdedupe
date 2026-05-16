UPDATE items
SET duplicate_of_number = NULL
WHERE github_id = $1;
