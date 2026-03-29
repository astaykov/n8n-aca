#!/bin/sh
# entrypoint.sh — substitutes environment variables into authConfig.js then starts nginx.
# Placeholders use __UPPER_SNAKE_CASE__ syntax to avoid conflicting with JS template literals.

set -e

# Fail fast if required vars are missing — better than a confusing AADSTS error at runtime.
: "${SPA_CLIENT_ID:?SPA_CLIENT_ID env var is required}"
: "${SPA_TENANT_ID:?SPA_TENANT_ID env var is required}"
: "${SPA_BLUEPRINT_APP_ID:?SPA_BLUEPRINT_APP_ID env var is required}"

echo "[entrypoint] Substituting environment variables into authConfig.js..."

sed \
  -e "s|__SPA_CLIENT_ID__|${SPA_CLIENT_ID}|g" \
  -e "s|__SPA_TENANT_ID__|${SPA_TENANT_ID}|g" \
  -e "s|__SPA_REDIRECT_URI__|${SPA_REDIRECT_URI:-http://localhost/redirect.html}|g" \
  -e "s|__SPA_BLUEPRINT_APP_ID__|${SPA_BLUEPRINT_APP_ID}|g" \
  -e "s|__N8N_WEBHOOK_URL__|${N8N_WEBHOOK_URL:-}|g" \
  -e "s|__N8N_WEBHOOK_TEST_URL__|${N8N_WEBHOOK_TEST_URL:-}|g" \
  /authConfig.template.js > /usr/share/nginx/html/authConfig.js

echo "[entrypoint] authConfig.js written. Starting nginx..."
exec nginx -g 'daemon off;'
