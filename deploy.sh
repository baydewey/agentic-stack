#!/usr/bin/env bash
# agentic stack deploy script
# services: 9router, headroom, hermes-gateway, hermes-dashboard
# location: /opt/docker/agentic (or wherever this script lives)
#
# Interactive: prompts for dashboard user/password + 9router password.
# If args are given, uses them non-interactively:
#   ./deploy.sh [--fresh] [DASHBOARD_USER] [DASHBOARD_PASS] [ROUTER_PASS]
#   --fresh : mulai data baru (backup + reset data/9router/db & data/hermes)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Agentic Stack Deploy ==="
echo "Working dir: $SCRIPT_DIR"

# ── Parse --fresh flag ──────────────────────────────────────────────────────
FRESH=""
if [[ "${1:-}" == "--fresh" ]]; then
  FRESH="1"
  shift
  echo "🧹 FRESH MODE: akan reset data (backup dulu)"
fi

# ── Interactive credential prompts ──────────────────────────────────────────
DASH_USER="${1:-}"
DASH_PASS="${2:-}"
ROUTER_PASS="${3:-}"

if [[ -z "$DASH_USER" || -z "$DASH_PASS" || -z "$ROUTER_PASS" ]]; then
  echo ""
  echo "── Credential Setup ──────────────────────────────"
  read -r -p "Hermes Dashboard username: " DASH_USER
  while [[ -z "$DASH_USER" ]]; do
    read -r -p "⚠️  Username tidak boleh kosong. Coba lagi: " DASH_USER
  done
  while true; do
    read -rs -p "Hermes Dashboard password: " DASH_PASS
    echo ""
    read -rs -p "Ulangi password: " DASH_PASS2
    echo ""
    if [[ -z "$DASH_PASS" ]]; then
      echo "⚠️  Password tidak boleh kosong."
    elif [[ "$DASH_PASS" != "$DASH_PASS2" ]]; then
      echo "❌ Password tidak sama. Ulangi."
    else
      break
    fi
  done
  while true; do
    read -rs -p "9Router (admin) password: " ROUTER_PASS
    echo ""
    read -rs -p "Ulangi password: " ROUTER_PASS2
    echo ""
    if [[ -z "$ROUTER_PASS" ]]; then
      echo "⚠️  Password tidak boleh kosong."
    elif [[ "$ROUTER_PASS" != "$ROUTER_PASS2" ]]; then
      echo "❌ Password tidak sama. Ulangi."
    else
      break
    fi
  done
  echo "────────────────────────────────────────────────"
  echo ""
fi

# ── FRESH MODE: backup + reset existing data ──────────────────────────────
if [[ -n "$FRESH" ]]; then
  echo "🧹 Fresh mode active..."
  TS=$(date +%Y%m%d-%H%M%S)
  # Backup data lama sebelum reset
  if [[ -d "data/9router" || -d "data/hermes" ]]; then
    BACKUP_DIR="backups/agentic-data-$TS"
    mkdir -p "$BACKUP_DIR"
    [[ -d "data/9router" ]] && cp -r "data/9router" "$BACKUP_DIR/" && echo "  💾 backup: $BACKUP_DIR/9router"
    [[ -d "data/hermes" ]] && cp -r "data/hermes" "$BACKUP_DIR/" && echo "  💾 backup: $BACKUP_DIR/hermes"
    echo "  📦 Backup lengkap ke: $BACKUP_DIR"
  fi

  # Hentikan stack dulu (jika jalan) sebelum hapus data
  docker compose down >/dev/null 2>&1 || true
  echo "  ⏹️  Stack dihentikan"

  # Reset: hapus DB & runtime data (config/env TIDAK dihapus)
  rm -rf data/9router/db data/9router/logs data/9router/machine-id \
         data/9router/model-catalog*.json \
         data/hermes/state.db data/hermes/sessions data/hermes/memories \
         data/hermes/cron data/hermes/gateway_state.json \
         data/hermes/runtime data/hermes/pending data/hermes/pastes
  echo "  🧹 DB & runtime data direset (env/config dipertahankan)"
fi

# ── Generate scrypt hash for Hermes dashboard (stdlib, matches Hermes format) ──
# Format: scrypt$16384$8$1$<salt_b64>$<dk_b64>
DASH_HASH=$(python3 - "$DASH_PASS" <<'PYEOF'
import base64, hashlib, secrets, sys
n, r, p, dklen = 2**14, 8, 1, 32
salt = secrets.token_bytes(16)
dk = hashlib.scrypt(sys.argv[1].encode(), salt=salt, n=n, r=r, p=p, dklen=dklen, maxmem=0)
print(f"scrypt${n}${r}${p}${base64.b64encode(salt).decode()}${base64.b64encode(dk).decode()}")
PYEOF
)

# Export untuk substitusi di compose.yml (HERMES_DASHBOARD_BASIC_AUTH_*)
export DASH_USER DASH_HASH
echo "🔐 Dashboard auth: ${DASH_USER} / **** (hash scrypt siap)"

# ── Auto-create required directories ────────────────────────────────────────
mkdir -p data/9router data/hermes config
echo "✅ Data directories ensured: data/9router, data/hermes, config"

# Ensure correct ownership (root UID 0 for containers running as root)
chown -R 0:0 data/ config/ 2>/dev/null || true
chown 0:0 .env .env.hermes .env.9router compose.yml deploy.sh 2>/dev/null || true
echo "✅ Ownership set to root (0:0) for data/, config/, env files"

# ── Auto-create required env files if missing ────────────────────────────────
# .env (UID/GID for docker-compose substitution)
if [[ ! -f .env ]]; then
  cat > .env << 'EOF'
# Dipakai untuk variable substitution di docker-compose.yml (bukan diinject ke container)
# User host adalah root (UID:GID = 0:0)
HERMES_UID=0
HERMES_GID=0
EOF
  echo "✅ Created .env with HERMES_UID=0 HERMES_GID=0"
else
  echo "✅ .env already exists"
fi

# .env.hermes (optional - can stay empty for 9Router-only mode)
if [[ ! -f .env.hermes ]]; then
  cat > .env.hermes << 'EOF'
# Hermes Agent environment — diinject ke container hermes-gateway
# Kosong = semua model lewat 9Router saja
# Isi jika mau provider langsung (bypass 9Router)

# GOOGLE_API_KEY=
# ANTHROPIC_API_KEY=
# OPENROUTER_API_KEY=
# OLLAMA_API_KEY=
EOF
  echo "✅ Created .env.hermes (empty - 9Router only mode)"
else
  echo "✅ .env.hermes already exists"
fi

# .env.9router (REQUIRED - generates secrets if missing, or ALWAYS in fresh mode)
if [[ ! -f .env.9router || -n "$FRESH" ]]; then
  echo "🔐 Generating secrets for .env.9router..."
  JWT_SECRET=$(openssl rand -hex 32)
  API_KEY_SECRET=$(openssl rand -hex 32)
  MACHINE_ID_SALT=$(openssl rand -hex 32)

  cat > .env.9router << EOF
# 9Router environment — diinject ke container 9router
# AUTO-GENERATED - ganti jika perlu
JWT_SECRET=${JWT_SECRET}
INITIAL_PASSWORD=${ROUTER_PASS}
API_KEY_SECRET=${API_KEY_SECRET}
MACHINE_ID_SALT=${MACHINE_ID_SALT}

# Recommended runtime variables
NODE_ENV=production

# Recommended security and ops variables
ENABLE_REQUEST_LOGS=false
OBSERVABILITY_ENABLED=true
AUTH_COOKIE_SECURE=true
REQUIRE_API_KEY=false

# Cloud sync variables
BASE_URL=http://localhost:20128
CLOUD_URL=https://9router.com
NEXT_PUBLIC_BASE_URL=http://localhost:20128
NEXT_PUBLIC_CLOUD_URL=https://9router.com

# Optional outbound proxy untuk request ke provider upstream
# HTTP_PROXY=http://127.0.0.1:7890
# HTTPS_PROXY=http://127.0.0.1:7890
EOF
  echo "✅ Created .env.9router with generated secrets"
else
  echo "✅ .env.9router already exists (keeping existing secrets)"
fi

# ── Dashboard auth via ENV (HERMES_DASHBOARD_BASIC_AUTH_*) ───────────────
# Auth di-set melalui environment variable di compose.yml (DASH_USER/DASH_HASH),
# bukan file config — supaya config.yaml Hermes tidak tertimpa.

# ── Validate compose ────────────────────────────────────────────────────────
docker compose config -q >/dev/null 2>&1 || { echo "❌ Compose config invalid"; exit 1; }
echo "✅ Compose config valid"

# ── Deploy ──────────────────────────────────────────────────────────────────
echo "🚀 Starting stack..."
docker compose up -d

# Wait for health
echo "⏳ Waiting for containers to stabilize..."
sleep 10

# ── Enable dashboard basic auth plugin ──────────────────────────────────────
echo "🔐 Enabling dashboard_auth/basic plugin..."
docker exec hermes-dashboard hermes plugins enable basic >/dev/null 2>&1 \
  && echo "✅ Plugin enabled — restarting dashboard" \
  && docker compose restart hermes-dashboard >/dev/null 2>&1 \
  && sleep 5 \
  || echo "⚠️  Plugin enable skipped (already enabled or container not ready)"

docker compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'

echo ""
echo "=== Credentials ==="
echo "9Router login:  admin / ${ROUTER_PASS}"
echo "Hermes Dashboard: ${DASH_USER} / ${DASH_PASS}"
echo ""

echo "=== Endpoints (internal) ==="
echo "9router:         http://9router:20128"
echo "headroom:        http://headroom:8787"
echo "hermes-gateway:  http://hermes-gateway:8000"
echo "hermes-dashboard: http://hermes-dashboard:9119"
echo ""
echo "=== Next Steps ==="
echo "1. 9Router: login at http://9router:20128 (or via Cloudflare Tunnel)"
echo "2. Hermes Dashboard: basic auth configured (${DASH_USER} / ${DASH_PASS})"
echo "3. Add Public Hostnames in Cloudflare Zero Trust Dashboard:"
echo "   - 9router.terowongan.my.id -> 9router:20128"
echo "   - hermes-dashboard.terowongan.my.id -> hermes-dashboard:9119"