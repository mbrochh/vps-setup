#!/usr/bin/env bash
#
# install-dokku.sh — Dokku on a locked-down Debian VPS (Tailscale-only SSH,
# public traffic only via Cloudflare Tunnel, no inbound ports).
#
# Run the same script on staging and production; only the variables differ.
#
# Usage (as your sudo user, e.g. admin):
#   sudo DOKKU_DOMAIN=staging.example.com \
#        ADMIN_PUBKEY_FILE=/home/admin/.ssh/id_ed25519_dokku.pub \
#        CF_TUNNEL_TOKEN=eyJ... \
#        bash install-dokku.sh
#
# Safe to re-run: every step checks whether it has already been done.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------
DOKKU_TAG="${DOKKU_TAG:-v0.38.25}"          # pin; bump deliberately on both servers
DOKKU_DOMAIN="${DOKKU_DOMAIN:-}"             # global domain, e.g. staging.example.com
ADMIN_PUBKEY_FILE="${ADMIN_PUBKEY_FILE:-}"   # public key allowed to push/manage (optional)
ADMIN_KEY_NAME="${ADMIN_KEY_NAME:-admin}"    # name for that key inside Dokku
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"       # remotely-managed tunnel token (optional)
DOKKU_PLUGINS="${DOKKU_PLUGINS:-postgres redis}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Preflight checks
# ---------------------------------------------------------------------------
log "Preflight checks"

[[ $EUID -eq 0 ]] || die "Run with sudo/as root."

. /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "This script targets Debian (found: ${ID:-unknown})."
echo "Debian ${VERSION_ID:-?} (${VERSION_CODENAME:-?})"

[[ -n "$DOKKU_DOMAIN" ]] || die "Set DOKKU_DOMAIN (e.g. staging.example.com)."

if ! hostname -f &>/dev/null; then
  die "'hostname -f' fails. Add '127.0.1.1 $(hostname).localdomain $(hostname)' to /etc/hosts and retry."
fi

if command -v tailscale &>/dev/null && tailscale status &>/dev/null; then
  echo "Tailscale is up: $(tailscale ip -4 2>/dev/null | head -n1)"
else
  die "Tailscale is not running. Fix that first — it is your only way in."
fi

if [[ -n "$ADMIN_PUBKEY_FILE" && ! -r "$ADMIN_PUBKEY_FILE" ]]; then
  die "ADMIN_PUBKEY_FILE '$ADMIN_PUBKEY_FILE' is not readable."
fi

mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
(( mem_mb >= 1900 )) || warn "Only ${mem_mb} MB RAM. Docker builds may OOM; consider swap or building in CI."

apt-get update -qq
apt-get install -y -qq ca-certificates curl wget gnupg lsb-release debconf-utils >/dev/null

# ---------------------------------------------------------------------------
# 2. Install Dokku (pinned version, non-interactive)
# ---------------------------------------------------------------------------
if command -v dokku &>/dev/null; then
  log "Dokku already installed: $(dokku version)"
  [[ "$(dokku version)" == *"${DOKKU_TAG#v}"* ]] || \
    warn "Installed version differs from DOKKU_TAG=${DOKKU_TAG}. Upgrade deliberately (see Dokku docs)."
else
  log "Installing Dokku ${DOKKU_TAG}"

  # Preseed answers so the package install never prompts.
  debconf-set-selections <<EOF
dokku dokku/vhost_enable boolean true
dokku dokku/nginx_enable boolean true
dokku dokku/hostname string ${DOKKU_DOMAIN}
dokku dokku/skip_key_file boolean true
EOF

  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' EXIT
  wget -q -O "$workdir/bootstrap.sh" "https://dokku.com/install/${DOKKU_TAG}/bootstrap.sh"
  DOKKU_TAG="$DOKKU_TAG" bash "$workdir/bootstrap.sh"
fi

# ---------------------------------------------------------------------------
# 3. Global domain
# ---------------------------------------------------------------------------
log "Setting global domain: ${DOKKU_DOMAIN}"
dokku domains:set-global "$DOKKU_DOMAIN"

# ---------------------------------------------------------------------------
# 4. SSH key for deploys / remote management (restricted to Dokku commands)
# ---------------------------------------------------------------------------
if [[ -n "$ADMIN_PUBKEY_FILE" ]]; then
  if dokku ssh-keys:list 2>/dev/null | grep -q "NAME=\"${ADMIN_KEY_NAME}\""; then
    log "Dokku key '${ADMIN_KEY_NAME}' already present"
  else
    log "Adding Dokku key '${ADMIN_KEY_NAME}'"
    dokku ssh-keys:add "$ADMIN_KEY_NAME" "$ADMIN_PUBKEY_FILE"
  fi
else
  warn "No ADMIN_PUBKEY_FILE given — add one later: sudo dokku ssh-keys:add <name> <file.pub>"
fi

# ---------------------------------------------------------------------------
# 5. Plugins (Postgres, Redis)
# ---------------------------------------------------------------------------
for p in $DOKKU_PLUGINS; do
  if dokku plugin:installed "$p"; then
    log "Plugin '$p' already installed"
  else
    log "Installing plugin '$p'"
    dokku plugin:install "https://github.com/dokku/dokku-${p}.git" --name "$p"
  fi
done

# ---------------------------------------------------------------------------
# 6. cloudflared (Cloudflare Tunnel) — outbound-only, no inbound ports
# ---------------------------------------------------------------------------
if ! command -v cloudflared &>/dev/null; then
  log "Installing cloudflared from Cloudflare's apt repo"
  mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
    -o /usr/share/keyrings/cloudflare-public-v2.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -qq
  apt-get install -y -qq cloudflared >/dev/null
else
  log "cloudflared already installed: $(cloudflared --version | head -n1)"
fi

if [[ -n "$CF_TUNNEL_TOKEN" ]]; then
  if systemctl list-unit-files | grep -q '^cloudflared.service'; then
    log "cloudflared service already installed"
  else
    log "Installing cloudflared as a systemd service"
    cloudflared service install "$CF_TUNNEL_TOKEN"
  fi
  systemctl enable --now cloudflared
else
  warn "No CF_TUNNEL_TOKEN given — tunnel not started. Re-run with it, or: sudo cloudflared service install <token>"
fi

# ---------------------------------------------------------------------------
# 7. Verification
# ---------------------------------------------------------------------------
log "Verification"

echo "-- Dokku:        $(dokku version)"
echo "-- Plugins:      $(dokku plugin:list | awk '/enabled/ {print $1}' | grep -E "^($(echo "$DOKKU_PLUGINS" | tr ' ' '|'))$" | xargs)"
echo "-- Global domain: $(dokku domains:report --global 2>/dev/null | awk -F: '/Domains global vhosts/ {gsub(/^ +/,"",$2); print $2}')"
echo "-- cloudflared:  $(systemctl is-active cloudflared 2>/dev/null || echo 'not running')"
echo "-- ufw:          $(ufw status 2>/dev/null | head -n1 || echo 'ufw not installed')"

echo "-- Ports published by Docker to the host (should be none):"
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E '0\.0\.0\.0|\[::\]' || echo "   none"

echo "-- Listening TCP sockets on non-loopback, non-Tailscale addresses:"
ss -Htlnp | awk '{print $4, $6}' \
  | grep -vE '^(127\.|\[::1\]|100\.|\[fd7a:)' || echo "   none"
echo "   (nginx on 0.0.0.0:80 is expected; ufw + Hetzner firewall block it from outside.)"

# Secrets should not be readable by other Unix users (e.g. a future 'pi' user).
leaky=$(find /home/dokku /var/lib/dokku -xdev \( -name ENV -o -path '*/config/*' \) \
          -type f -perm -o+r 2>/dev/null | head -n 5 || true)
if [[ -n "$leaky" ]]; then
  warn "World-readable config files found (check before adding other users):"
  echo "$leaky"
else
  echo "-- No world-readable Dokku config files found."
fi

cat <<EOF

Done. Next steps:
  1. In Cloudflare Zero Trust → Tunnels → this tunnel → Public Hostnames,
     route each app hostname (e.g. api-${DOKKU_DOMAIN}) to  http://localhost:8000
  2. On the VPS (as admin):
       sudo dokku apps:list
EOF
