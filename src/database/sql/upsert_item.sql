INSERT INTO items (github_id, number, item_type, title, body, state, state_reason, url, github_created_at, github_updated_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
ON CONFLICT (github_id) DO UPDATE
    SET number            = EXCLUDED.number,
        title             = EXCLUDED.title,
        body              = EXCLUDED.body,
        state             = EXCLUDED.state,
        state_reason      = EXCLUDED.state_reason,
        url               = EXCLUDED.url,
        github_updated_at = EXCLUDED.github_updated_at;
