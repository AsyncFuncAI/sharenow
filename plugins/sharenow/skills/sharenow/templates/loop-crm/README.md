# Loopdesk

A reviewed sharenow Fullstack starter for a loop-driven lead desk.

- Public lead intake over HTTP
- Queue-driven Claude enrichment
- Scheduled reconciliation every 15 minutes
- D1 state and bounded run history
- R2 result reports
- Admin and reviewer access tokens
- Daily per-source intake limits and idempotent queue processing

The deployment contract requires `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL`, and
`APP_ADMIN_TOKEN`. Put their values in a mode-600 JSON file only when the
approved plan is deployed. Never commit that file.

Runtime notes for the branded host:

- Inside the Worker, `request.url` carries the workers.dev host. Read the
  `x-forwarded-host` request header when you need the public
  `<slug>` hostname (absolute links, OAuth callbacks, QR codes).
- Responses without a `Cache-Control` header are served `no-store`, so fresh
  deploys are visible immediately. Set `Cache-Control` yourself to opt into
  caching.
- To change the schema after the first deploy, edit `schema.sql` to the new
  complete shape AND add a numbered `migrations/NNNN_name.sql` file with the
  ALTER/CREATE statements; `fullstack.sh update` applies pending migrations in
  order before swapping code.
