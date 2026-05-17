SELECT MAX(github_updated_at) AS latest
FROM items
WHERE item_type = 'discussion';
