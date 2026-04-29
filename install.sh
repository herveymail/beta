#!/bin/bash
# ════════════════════════════════════════════════════════════════
#  NexusDesk MSP Platform — Quick Install
#  Usage: git clone https://github.com/herveymail/beta.git /opt/nexusdesk && cd /opt/nexusdesk && sudo ./install.sh
#  Target: Ubuntu 22.04 / 24.04 LTS on DigitalOcean
# ════════════════════════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step() { echo -e "\n${BLUE}[$1/$TOTAL_STEPS]${NC} $2"; }
print_ok()   { echo -e "    ${GREEN}✓${NC} $1"; }
print_warn() { echo -e "    ${YELLOW}!${NC} $1"; }
print_err()  { echo -e "    ${RED}✗${NC} $1"; }

TOTAL_STEPS=10
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_USER="nexusdesk"
DB_NAME="nexusdesk_db"
DB_USER="nexusdesk_user"
DB_PASS="$(openssl rand -base64 24)"
REDIS_PASS="$(openssl rand -base64 16)"
JWT_SECRET="$(openssl rand -hex 32)"
SESSION_SECRET="$(openssl rand -hex 32)"
ENCRYPTION_KEY="$(openssl rand -hex 32)"

# ── Pre-checks ──
if [ "$EUID" -ne 0 ]; then
  print_err "Please run as root: sudo ./install.sh"
  exit 1
fi

if ! grep -qE "Ubuntu (22|24)\." /etc/os-release 2>/dev/null; then
  print_warn "This script is designed for Ubuntu 22.04/24.04. Proceed with caution."
fi

echo ""
echo -e "${BLUE}════════════════════════════════════════════${NC}"
echo -e "${BLUE}   NexusDesk MSP Platform — Installer${NC}"
echo -e "${BLUE}════════════════════════════════════════════${NC}"
echo ""

# Get domain from user
read -rp "Enter your domain (e.g. nexusdesk.yourdomain.com): " DOMAIN
read -rp "Enter admin email: " ADMIN_EMAIL

echo ""
echo "  Domain:     $DOMAIN"
echo "  Admin:      $ADMIN_EMAIL"
echo "  Install to: $APP_DIR"
echo ""
read -rp "Continue? (y/n) " -n 1 CONFIRM
echo ""
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then echo "Cancelled."; exit 0; fi

# ══════════════════════════════════════
# 1. SYSTEM UPDATE
# ══════════════════════════════════════
print_step 1 "Updating system packages..."
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl wget gnupg2 software-properties-common \
  build-essential git ufw fail2ban ca-certificates lsb-release \
  apt-transport-https unzip htop > /dev/null 2>&1
print_ok "System packages updated"

# ══════════════════════════════════════
# 2. CREATE APP USER
# ══════════════════════════════════════
print_step 2 "Creating application user..."
if ! id "$APP_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$APP_USER"
  print_ok "User '$APP_USER' created"
else
  print_ok "User '$APP_USER' already exists"
fi
chown -R "$APP_USER:$APP_USER" "$APP_DIR"

# ══════════════════════════════════════
# 3. NODE.JS 22 LTS
# ══════════════════════════════════════
print_step 3 "Installing Node.js 22 LTS..."
if ! command -v node &>/dev/null || [[ ! "$(node -v)" =~ ^v22 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null 2>&1
  apt install -y -qq nodejs > /dev/null 2>&1
fi
npm install -g pm2 > /dev/null 2>&1
print_ok "Node.js $(node -v), npm $(npm -v), PM2 installed"

# ══════════════════════════════════════
# 4. POSTGRESQL 16
# ══════════════════════════════════════
print_step 4 "Installing PostgreSQL 16..."
if ! command -v psql &>/dev/null; then
  # Import GPG key properly for Ubuntu 24.04+
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor --yes -o /usr/share/keyrings/postgresql-archive-keyring.gpg
  # Add repo with signed-by reference
  echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  apt update -qq
  apt install -y -qq postgresql-16 postgresql-client-16 > /dev/null 2>&1
fi
# Wait for PostgreSQL to be ready
systemctl start postgresql
systemctl enable postgresql > /dev/null 2>&1
sleep 2

sudo -u postgres psql -q <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$DB_USER') THEN
    CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';
  END IF;
END \$\$;
SELECT 'CREATE DATABASE $DB_NAME OWNER $DB_USER' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\gexec
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
EOF

# Apply schema
if [ -f "$APP_DIR/schema.sql" ]; then
  PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" -f "$APP_DIR/schema.sql" -q 2>/dev/null || true
  print_ok "Database schema applied"
fi
print_ok "PostgreSQL 16 configured — database: $DB_NAME"

# ══════════════════════════════════════
# 5. REDIS 7
# ══════════════════════════════════════
print_step 5 "Installing Redis 7..."
apt install -y -qq redis-server > /dev/null 2>&1
sed -i "s/^.*requirepass .*/requirepass $REDIS_PASS/" /etc/redis/redis.conf
sed -i 's/^bind .*/bind 127.0.0.1 ::1/' /etc/redis/redis.conf
sed -i 's/^.*maxmemory .*/maxmemory 256mb/' /etc/redis/redis.conf 2>/dev/null || true
sed -i 's/^.*maxmemory-policy .*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf 2>/dev/null || true
systemctl restart redis-server > /dev/null 2>&1 || true
systemctl enable redis-server > /dev/null 2>&1 || true
print_ok "Redis 7 installed and secured"

# ══════════════════════════════════════
# 6. NGINX
# ══════════════════════════════════════
print_step 6 "Configuring Nginx..."
apt install -y -qq nginx > /dev/null 2>&1

cat > /etc/nginx/sites-available/nexusdesk <<NGINX
limit_req_zone \$binary_remote_addr zone=api:10m rate=30r/s;
limit_req_zone \$binary_remote_addr zone=login:10m rate=5r/m;

server {
    listen 80;
    server_name $DOMAIN;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml;

    location /static/ {
        alias $APP_DIR/public/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    location /api/auth/ {
        limit_req zone=login burst=3 nodelay;
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /api/ {
        limit_req zone=api burst=20 nodelay;
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 90;
    }

    location /ws {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    location ~ /\. { deny all; }
    client_max_body_size 25M;
}
NGINX

ln -sf /etc/nginx/sites-available/nexusdesk /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t -q && systemctl restart nginx && systemctl enable nginx > /dev/null 2>&1
print_ok "Nginx configured for $DOMAIN"

# ══════════════════════════════════════
# 7. FIREWALL & SECURITY
# ══════════════════════════════════════
print_step 7 "Configuring firewall and security..."

# UFW — allow rules are idempotent
ufw default deny incoming > /dev/null 2>&1 || true
ufw default allow outgoing > /dev/null 2>&1 || true
ufw allow 22/tcp > /dev/null 2>&1 || true
ufw allow 80/tcp > /dev/null 2>&1 || true
ufw allow 443/tcp > /dev/null 2>&1 || true
echo "y" | ufw enable > /dev/null 2>&1 || true
print_ok "UFW firewall enabled"

# Fail2Ban
cat > /etc/fail2ban/jail.local <<F2B
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
maxretry = 3
bantime = 7200

[nginx-limit-req]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 10
F2B

systemctl restart fail2ban > /dev/null 2>&1 || true
systemctl enable fail2ban > /dev/null 2>&1 || true
print_ok "Fail2Ban configured"

# SSH hardening (use ssh not sshd on Ubuntu 24.04)
sed -i 's/#MaxAuthTries 6/MaxAuthTries 3/' /etc/ssh/sshd_config 2>/dev/null || true
systemctl restart ssh > /dev/null 2>&1 || true
print_ok "SSH hardened"

# Kernel hardening — only add if not already present
if ! grep -q "NexusDesk security" /etc/sysctl.conf 2>/dev/null; then
  cat >> /etc/sysctl.conf <<SYSCTL
# NexusDesk security hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
kernel.randomize_va_space = 2
SYSCTL
fi
sysctl -p > /dev/null 2>&1 || true
print_ok "Kernel security applied"

# ══════════════════════════════════════
# 8. APPLICATION SETUP
# ══════════════════════════════════════
print_step 8 "Setting up application..."
mkdir -p "$APP_DIR"/{logs,uploads,backups,public/static}

# Create .env only if it doesn't exist (don't overwrite existing config)
if [ ! -f "$APP_DIR/.env" ]; then
  cat > "$APP_DIR/.env" <<ENV
NODE_ENV=production
PORT=3000
APP_URL=https://$DOMAIN
APP_NAME=NexusDesk
ADMIN_EMAIL=$ADMIN_EMAIL

DATABASE_URL=postgresql://$DB_USER:$DB_PASS@localhost:5432/$DB_NAME
DB_POOL_MIN=2
DB_POOL_MAX=10

REDIS_URL=redis://:$REDIS_PASS@127.0.0.1:6379

JWT_SECRET=$JWT_SECRET
SESSION_SECRET=$SESSION_SECRET
ENCRYPTION_KEY=$ENCRYPTION_KEY
BCRYPT_ROUNDS=12

RATE_LIMIT_WINDOW=900000
RATE_LIMIT_MAX=100
UPLOAD_DIR=$APP_DIR/uploads
MAX_FILE_SIZE=25000000
LOG_LEVEL=info
LOG_DIR=$APP_DIR/logs

SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
SMTP_FROM=$ADMIN_EMAIL

CONNECTWISE_API_KEY=
DATTO_API_KEY=
M365_TENANT_ID=
M365_CLIENT_ID=
M365_CLIENT_SECRET=
SENTINELONE_API_KEY=
QUICKBOOKS_CLIENT_ID=
QUICKBOOKS_CLIENT_SECRET=
DUO_IKEY=
DUO_SKEY=
DUO_HOST=
ACRONIS_API_KEY=
SLACK_WEBHOOK_URL=
ENV

chmod 600 "$APP_DIR/.env"
  print_ok ".env created with auto-generated secrets"
else
  print_warn ".env already exists — skipping (won't overwrite your config)"
fi
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
print_ok "Application directory configured"

# ══════════════════════════════════════
# 9. INSTALL DEPENDENCIES & BUILD
# ══════════════════════════════════════
print_step 9 "Installing dependencies..."
cd "$APP_DIR"
sudo -u "$APP_USER" npm install --production 2>/dev/null || print_warn "npm install needs package.json — run manually after adding your code"

# PM2 ecosystem
cat > "$APP_DIR/ecosystem.config.js" <<PM2
module.exports = {
  apps: [{
    name: 'nexusdesk',
    script: './src/server.js',
    cwd: '$APP_DIR',
    instances: 'max',
    exec_mode: 'cluster',
    max_memory_restart: '512M',
    env: { NODE_ENV: 'production' },
    error_file: '$APP_DIR/logs/pm2-error.log',
    out_file: '$APP_DIR/logs/pm2-out.log',
    merge_logs: true,
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
    autorestart: true,
    max_restarts: 10,
    restart_delay: 5000
  }]
};
PM2

chown "$APP_USER:$APP_USER" "$APP_DIR/ecosystem.config.js"
pm2 startup systemd -u "$APP_USER" --hp "/home/$APP_USER" > /dev/null 2>&1 || true
print_ok "PM2 configured for auto-start"

# ══════════════════════════════════════
# 10. CRON JOBS & SSL
# ══════════════════════════════════════
print_step 10 "Setting up backups and SSL..."

cat > /etc/cron.d/nexusdesk <<CRON
# Daily database backup at 2 AM
0 2 * * * $APP_USER PGPASSWORD="$DB_PASS" pg_dump -U $DB_USER $DB_NAME | gzip > $APP_DIR/backups/db-\$(date +\%Y\%m\%d).sql.gz
# Cleanup backups older than 7 days
0 3 * * * $APP_USER find $APP_DIR/backups/ -name "*.sql.gz" -mtime +7 -delete
# Log rotation — delete logs older than 30 days
0 4 * * 0 $APP_USER find $APP_DIR/logs/ -name "*.log" -mtime +30 -delete
CRON
chmod 644 /etc/cron.d/nexusdesk

# Install certbot
apt install -y -qq certbot python3-certbot-nginx > /dev/null 2>&1 || true
print_ok "Certbot installed — run SSL setup after DNS is configured"

# ══════════════════════════════════════
# DONE
# ══════════════════════════════════════
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   NexusDesk installed successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Stack:"
echo "    Node.js $(node -v) · PostgreSQL 16 · Redis 7 · Nginx · PM2"
echo ""
echo -e "  ${YELLOW}Database credentials (SAVE THESE):${NC}"
echo "    DB Name:     $DB_NAME"
echo "    DB User:     $DB_USER"
echo "    DB Password: $DB_PASS"
echo ""
echo "  Next steps:"
echo ""
echo "    1. Point DNS A record for $DOMAIN → $SERVER_IP"
echo ""
echo "    2. Set up SSL:"
echo "       sudo certbot --nginx -d $DOMAIN -m $ADMIN_EMAIL --agree-tos"
echo ""
echo "    3. Configure integrations:"
echo "       nano $APP_DIR/.env"
echo ""
echo "    4. Start the app:"
echo "       cd $APP_DIR"
echo "       sudo -u $APP_USER pm2 start ecosystem.config.js"
echo "       sudo -u $APP_USER pm2 save"
echo ""
echo "  Config:  $APP_DIR/.env"
echo "  Logs:    $APP_DIR/logs/"
echo "  Backups: $APP_DIR/backups/ (daily 2 AM, 7-day retention)"
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
