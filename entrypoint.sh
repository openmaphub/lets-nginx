#!/bin/sh

set -euo pipefail

# Validate environment variables

MISSING=""

[ -z "${DOMAIN}" ] && MISSING="${MISSING} DOMAIN"
[ -z "${EMAIL}" ] && MISSING="${MISSING} EMAIL"

if [ "${MISSING}" != "" ]; then
  echo "Missing required environment variables:" >&2
  echo " ${MISSING}" >&2
  exit 1
fi

# Default other parameters

SERVER=""
[ -n "${STAGING:-}" ] && SERVER="--server https://acme-staging.api.letsencrypt.org/directory"

# Generate strong DH parameters for nginx, if they don't already exist.
if [ ! -f /etc/ssl/dhparams.pem ]; then
  if [ -f /cache/dhparams.pem ]; then
    cp /cache/dhparams.pem /etc/ssl/dhparams.pem
  else
    openssl dhparam -out /etc/ssl/dhparams.pem 2048
    # Cache to a volume for next time?
    if [ -d /cache ]; then
      cp /etc/ssl/dhparams.pem /cache/dhparams.pem
    fi
  fi
fi

#create temp file storage
mkdir -p /var/cache/nginx
chown nginx:nginx /var/cache/nginx

mkdir -p /var/tmp/nginx
chown nginx:nginx /var/tmp/nginx


mkdir -p /var/cache/nginx
chown nginx:nginx /var/cache/nginx

mkdir -p /var/tmp/nginx
chown nginx:nginx /var/tmp/nginx

# Template an nginx.conf
cat <<EOF >/etc/nginx/nginx.conf
user nginx;
worker_processes 2;

events {
  worker_connections 1024;
}

http {
  include mime.types;
  default_type application/octet-stream;

  proxy_cache_path /var/cache/nginx keys_zone=anonymous:10m;
  proxy_temp_path /var/tmp/nginx;
  client_body_temp_path /var/tmp/nginx/client_body_temp;
  proxy_request_buffering off;

  client_max_body_size 300M;

  sendfile on;
  tcp_nopush on;
  keepalive_timeout 65;

  access_log /var/log/nginx/access.log;
  error_log /var/log/nginx/error.log;

  gzip on;
  gzip_types text/plain image/png image/jpg application/javascript text/css text/html;


  upstream maphubs {
    server ${MAPHUBS_1_PORT_4000_TCP_ADDR}:4000;
    server ${MAPHUBS_2_PORT_4000_TCP_ADDR}:4000;
  }

  upstream tiles {
    server ${TILES_1_PORT_4001_TCP_ADDR}:4001;
    server ${TILES_2_PORT_4001_TCP_ADDR}:4001;
  }

  upstream raster {
    server ${RASTER_1_PORT_8081_TCP_ADDR}:8081;
  }

  upstream assets {
    server ${ASSETS_1_PORT_80_TCP_ADDR}:80;
  }

  server {
    listen 443 ssl http2;
    server_name "${DOMAIN}";

    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_dhparam /etc/ssl/dhparams.pem;

    ssl_ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256';
    ssl_protocols TLSv1.2;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:50m;
    add_header Strict-Transport-Security "max-age=63072000; includeSubdomains; preload";
    #add_header X-Frame-Options DENY;
    #add_header X-Content-Type-Options nosniff;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

    root /etc/letsencrypt/webrootauth;

    location / {
      proxy_pass http://maphubs;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$remote_addr;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_cache   off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      gzip off;
    }

    location /tiles {
      proxy_pass http://tiles;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$remote_addr;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_cache   off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      gzip off;
    }

    location /raster {
      rewrite /raster(.*) \$1  break;
      proxy_pass http://raster;
      proxy_redirect off;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$remote_addr;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_cache   off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    }

    location /assets {
      proxy_pass http://assets;
    }

    location /public {
      proxy_pass http://assets;
    }

    location /edit {
      proxy_pass http://assets;
    }

    location /.well-known/acme-challenge {
      alias /etc/letsencrypt/webrootauth/.well-known/acme-challenge;
      location ~ /.well-known/acme-challenge/(.*) {
        add_header Content-Type application/jose+json;
      }
    }
  }

  # Redirect from port 80 to port 443
  server {
    listen 80;
    server_name "${DOMAIN}";
    return 301 https://${DOMAIN}\$request_uri;
  }
}
EOF
TERM=xterm
# Initial certificate request, but skip if cached
if [ ! -f /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ]; then
  letsencrypt certonly \
    --domain ${DOMAIN} \
    --authenticator standalone \
    ${SERVER} \
    --email "${EMAIL}" --agree-tos --text --non-interactive
fi

# Template a cronjob to reissue the certificate with the webroot authenticator
cat <<EOF >/etc/periodic/monthly/reissue
#!/bin/sh

set -euo pipefail
TERM=xterm

# Certificate reissue
letsencrypt certonly --renew-by-default \
  --domain "${DOMAIN}" \
  --authenticator webroot \
  --webroot-path /etc/letsencrypt/webrootauth/ ${SERVER} \
  --email "${EMAIL}" --agree-tos --text --non-interactive

# Reload nginx configuration to pick up the reissued certificates
/usr/sbin/nginx -s reload
EOF
chmod +x /etc/periodic/monthly/reissue

# Kick off cron to reissue certificates as required
# Background the process and log to stderr
/usr/sbin/crond -f -d 8 &

echo Ready
# Launch nginx in the foreground
/usr/sbin/nginx -g "daemon off;"
