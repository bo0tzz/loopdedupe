UPDATE items
SET duplicate_of_number = $2
WHERE github_id = $1;
