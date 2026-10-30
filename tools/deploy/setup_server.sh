#!/bin/bash
# One-time setup of exokey.top on the web server (nginx, static site from the repo's docs/).
# Run: ssh root@2.31.6.223 'bash -s' < tools/deploy/setup_server.sh
set -euo pipefail
DIR=/var/www/exokey
if [ ! -d "$DIR/.git" ]; then
  git clone --depth 1 https://github.com/jandiradmin/ExoKey.git "$DIR"
else
  git -C "$DIR" pull --ff-only -q
fi

cat > /etc/nginx/sites-available/exokey <<'NGX'
server {
  listen 80;
  listen [::]:80;
  server_name exokey.top www.exokey.top;
  root /var/www/exokey/docs;
  index index.html;

  gzip on; gzip_types text/css application/javascript image/svg+xml text/plain; gzip_min_length 1024;

  # only the site: no repo internals
  location ~ /\. { deny all; }
  location ^~ /release-notes/ { deny all; }
  location ~* \.(gif|png|jpg|svg|ico|woff2)$ { expires 7d; add_header Cache-Control "public"; }
  location / { try_files $uri $uri/ =404; }
}
NGX
ln -sf /etc/nginx/sites-available/exokey /etc/nginx/sites-enabled/exokey
nginx -t
systemctl reload nginx

# pull site updates from GitHub every 5 minutes
CRON='*/5 * * * * git -C /var/www/exokey pull --ff-only -q >/dev/null 2>&1'
( crontab -l 2>/dev/null | grep -v '/var/www/exokey' ; echo "$CRON" ) | crontab -
echo OK; crontab -l | grep exokey
