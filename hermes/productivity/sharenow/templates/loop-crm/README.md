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
