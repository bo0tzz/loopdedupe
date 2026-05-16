INSERT INTO items (github_id, number, item_type, title, body, state, url, github_created_at, github_updated_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
ON CONFLICT (github_id) DO UPDATE
    SET number            = EXCLUDED.number,
        title             = EXCLUDED.title,
        body              = EXCLUDED.body,
        state             = EXCLUDED.state,
        state_reason      = NULL,
        url               = EXCLUDED.url,
        github_updated_at = EXCLUDED.github_updated_at;
