# ── Build stage: not needed (static files only) ─────────────────────────────
FROM nginx:alpine

# Remove default nginx config
RUN rm /etc/nginx/conf.d/default.conf

# Copy all SPA static files
COPY . /usr/share/nginx/html/

# Copy the authConfig template (overwrites the local-dev hardcoded authConfig.js
# in the image; the real authConfig.js is generated at container startup)
COPY authConfig.template.js /authConfig.template.js

# nginx config that serves .html files without clean-URL rewriting
COPY nginx.conf /etc/nginx/nginx.conf

# Startup script that runs sed substitution then starts nginx
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
