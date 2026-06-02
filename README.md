# loopdedupe

Semantic dedupe assistant for the [immich-app/immich](https://github.com/immich-app/immich) repo. Embeds open issues and feature-request discussions with Voyage AI, surfaces likely duplicates to maintainers through a small dashboard, and captures their judgements so the picks get steadily better.

Built in Gleam on Wisp + Postgres (with [vchord](https://github.com/tensorchord/VectorChord) for `vector(2048)` similarity).

## Configuration

All config is via environment variables.

| Variable | Purpose |
|---|---|
| `DATABASE_URL` | Postgres connection string. The Postgres needs the `vchord` extension; migrations expect it loaded. |
| `SECRET_KEY_BASE` | Wisp session signing key. |
| `GITHUB_TOKEN` | Used for GraphQL backfill against the immich repo. A classic PAT with `public_repo` scope is enough. |
| `GITHUB_WEBHOOK_SECRET` | HMAC secret configured on the repo's webhook. Webhook delivery is rejected if this doesn't match. |
| `VOYAGE_API_KEY` | Voyage AI API key — used for both `voyage-4-large` embeddings and `rerank-2.5` reranking. |
| `ENVIRONMENT` | `dev` or `production`. Currently only changes the `is_dev()` check. |

### Webhook

Configure the repo webhook to `POST /api/webhooks/github`:

- **Payload URL**: `https://<your-host>/api/webhooks/github`
- **Content type**: `application/json` (required — `form-urlencoded` is rejected)
- **Secret**: same value as the `GITHUB_WEBHOOK_SECRET` env var (HMAC-SHA256 signature is verified on every delivery)
- **SSL verification**: enabled
- **Which events**: select **"Let me select individual events"** and tick exactly:
  - **Issues** — covers every issue action (opened / edited / closed / reopened / labeled / etc.). The handler upserts the item and re-embeds on every action; `closed` additionally triggers an incremental backfill to capture timeline-derived signals (canonical pointer, closer, MarkedAsDuplicate).
  - **Discussions** — same shape as Issues, but the handler silently no-ops for any discussion outside the `feature-request` category (other categories aren't dedupe candidates).

Don't subscribe to other events (Issue comments, Discussion comments, Pushes, etc.) — the handler returns 200 for any unknown `X-GitHub-Event` so deliveries won't error, but they're discarded. Just Issues + Discussions is enough.

## Container

A Dockerfile is in the repo root. Built and pushed by `.github/workflows/build.yml` to `ghcr.io/<owner>/loopdedupe` on every push to `main` and on `v*` tags.

```sh
docker run --rm \
  -e DATABASE_URL=... \
  -e SECRET_KEY_BASE=... \
  -e GITHUB_TOKEN=... \
  -e GITHUB_WEBHOOK_SECRET=... \
  -e VOYAGE_API_KEY=... \
  -p 8000:8000 \
  ghcr.io/<owner>/loopdedupe:latest
```

The container listens on port `8000`. Migrations run automatically on startup via cigogne — point it at an empty Postgres and it'll set itself up.

## Development

```sh
docker compose up -d             # starts the vchord-Postgres on :15432
cp secret.env.example secret.env # then fill it in
mise run dev                     # or `gleam run` with the env loaded
```

Squirrel-generated SQL bindings live in `src/database/sql.gleam`; regenerate after editing files in `src/database/sql/` with:

```sh
gleam run -m squirrel
```

## What it does

- Walks the issue + feature-request-discussion backlog via the GitHub GraphQL API, storing items in Postgres
- Embeds each item (`voyage-4-large`, 2048d) and stores symmetric edges above a cosine threshold
- A live webhook keeps the corpus current as items are opened, closed, edited, etc.
- A dashboard at `/` surfaces the strongest pairs across the corpus
- A drill-in at `/items/N` shows reranked candidates for a single item (top-200 cosine → `rerank-2.5`), chain-resolved to canonicals and deduped
- `/judgments` lists pairs the maintainer has dismissed; `/backfills` exposes manual backfill triggers and live queue status
- Pair-judgement table feeds back into ranking — dismissals stick across reloads and the chain resolution treats them as canonical-level decisions

There is no auth on the dashboard — put it behind something private in prod.
