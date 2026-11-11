#!/usr/bin/env bash
# vps-setup.sh — bootstrap a fresh Hetzner VPS (Debian/Ubuntu)
#
# Does: packages + auto-updates, zsh/zoxide/vim config, admin + pi users,
#       Tailscale, sshd hardening, ufw (Tailscale-only inbound).
#
# Usage (from your machine):
#   scp vps-setup.sh root@<public-ip>:
#   ssh -t root@<public-ip> 'bash vps-setup.sh'
#
# Optional environment variables:
#   TS_AUTHKEY=tskey-...   join the tailnet without a prompt (otherwise you're
#                          asked to paste a key, or press Enter for browser login)
#   TS_HOSTNAME=some-hostname   tailnet/MagicDNS name (default: current hostname)
#   ADMIN_USER=admin       name of the sudo user (default: admin)
#   AGENT_USER=pi          name of the locked-down user (default: pi)
#   ADMIN_PASSWORD=...     skip the interactive password prompt
#
# Safe to re-run: every step checks or overwrites rather than appending blindly.

set -euo pipefail

ADMIN_USER="${ADMIN_USER:-admin}"
AGENT_USER="${AGENT_USER:-pi}"
TS_TAGS="${TS_TAGS:-tag:server}"
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname)}"
SSHD_CONF=/etc/ssh/sshd_config.d/00-hardening.conf
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- helpers
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

confirm() {
  local ans
  read -r -p "$1 Type 'yes' to continue: " ans </dev/tty
  [[ "$ans" == "yes" ]]
}

reload_sshd() {
  sshd -t || die "sshd config test failed — nothing reloaded"
  systemctl reload ssh 2>/dev/null || systemctl restart ssh
}

write_sshd_conf() {   # $1 = PermitRootLogin value
  cat > "$SSHD_CONF" <<EOF
# Managed by vps-setup.sh. Named 00-* so it is read before 50-cloud-init.conf
# (sshd uses the FIRST value it sees for each setting).
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin $1
DenyUsers $AGENT_USER
EOF
  # Clean up the file name used by the old manual instructions
  rm -f /etc/ssh/sshd_config.d/hardening.conf
}

# ---------------------------------------------------------------- preflight
step "Preflight checks"
[[ $EUID -eq 0 ]] || die "Run as root."
[[ -r /etc/debian_version ]] || die "This script expects Debian or Ubuntu."
[[ -s /root/.ssh/authorized_keys ]] || die "/root/.ssh/authorized_keys is empty — add your SSH key when creating the server."
[[ -t 0 || -e /dev/tty ]] || die "Needs a terminal (use ssh -t)."
ok "root, Debian-based, SSH key present"

# ---------------------------------------------------------------- packages
step "Updating system and installing packages"
apt-get update -q
apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
apt-get -y -q install curl ufw unattended-upgrades tmux vim \
  zsh zsh-autosuggestions zsh-syntax-highlighting zoxide fzf
ok "packages installed"

step "Enabling automatic security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
ok "unattended-upgrades enabled"

# ---------------------------------------------------------------- zsh defaults (before creating users)
step "Making zsh the default shell"
ZSH_BIN=$(command -v zsh)
if grep -qE '^#?DSHELL=' /etc/adduser.conf 2>/dev/null; then
  sed -i "s|^#\?DSHELL=.*|DSHELL=$ZSH_BIN|" /etc/adduser.conf
fi
if grep -qE '^#?SHELL=' /etc/default/useradd; then
  sed -i "s|^#\?SHELL=.*|SHELL=$ZSH_BIN|" /etc/default/useradd
else
  echo "SHELL=$ZSH_BIN" >> /etc/default/useradd
fi
touch /etc/skel/.zshrc     # suppresses the zsh first-run wizard for new users

# Shared config, wrapped in markers so re-running replaces rather than duplicates
ZSHRC=/etc/zsh/zshrc
sed -i '/^# >>> vps-setup >>>/,/^# <<< vps-setup <<</d' "$ZSHRC"
cat >> "$ZSHRC" <<'EOF'
# >>> vps-setup >>>
# History
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt share_history hist_ignore_dups

# Completion & prompt
autoload -Uz compinit && compinit
PROMPT='%n@%m:%~%# '

# zoxide (must come after compinit)
eval "$(zoxide init zsh)"

# Prefix history search on up/down arrows
autoload -U up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[OA' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search
bindkey '^[OB' down-line-or-beginning-search

# Plugins
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
# <<< vps-setup <<<
EOF
ok "shared zsh config written to $ZSHRC"

step "Global vim settings"
mkdir -p /etc/vim
cat > /etc/vim/vimrc.local <<'EOF'
" Load Debian's defaults, then stop them from loading again later
runtime! defaults.vim
let g:skip_defaults_vim = 1

" Leave the mouse to the terminal so Cmd+C works
set mouse=
EOF
ok "/etc/vim/vimrc.local written"

# ---------------------------------------------------------------- admin user
step "Setting up '$ADMIN_USER' (sudo user)"
if ! id "$ADMIN_USER" &>/dev/null; then
  useradd -m -s "$ZSH_BIN" "$ADMIN_USER"
  ok "user created"
fi
usermod -aG sudo "$ADMIN_USER"
chsh -s "$ZSH_BIN" "$ADMIN_USER"

if passwd -S "$ADMIN_USER" | awk '{exit !($2=="P")}'; then
  ok "password already set"
elif [[ -n "${ADMIN_PASSWORD:-}" ]]; then
  echo "$ADMIN_USER:$ADMIN_PASSWORD" | chpasswd
  ok "password set from ADMIN_PASSWORD"
else
  echo "  Set a strong password for $ADMIN_USER (needed for sudo and the Hetzner console):"
  until passwd "$ADMIN_USER" </dev/tty; do warn "try again"; done
fi

install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" /root/.ssh/authorized_keys "/home/$ADMIN_USER/.ssh/authorized_keys"
sudo -u "$ADMIN_USER" touch "/home/$ADMIN_USER/.zshrc"
chmod 700 "/home/$ADMIN_USER"
echo "$ADMIN_USER ALL=($AGENT_USER) NOPASSWD: ALL" > /etc/sudoers.d/admin-as-agent
chmod 440 /etc/sudoers.d/admin-as-agent
visudo -cf /etc/sudoers.d/admin-as-agent || die "sudoers syntax error"
ok "SSH keys copied from root, sudo granted"

# ---------------------------------------------------------------- agent user
step "Setting up '$AGENT_USER' (no password, no sudo, no SSH)"
if ! id "$AGENT_USER" &>/dev/null; then
  useradd -m -s "$ZSH_BIN" "$AGENT_USER"   # useradd leaves the password locked
  ok "user created"
fi
passwd -l "$AGENT_USER" >/dev/null
chsh -s "$ZSH_BIN" "$AGENT_USER"
chmod 700 "/home/$AGENT_USER"
sudo -u "$AGENT_USER" touch "/home/$AGENT_USER/.zshrc"
chsh -s "$ZSH_BIN" root
touch /root/.zshrc
ok "$AGENT_USER locked down; home is private"

# ---------------------------------------------------------------- tailscale
step "Installing Tailscale"
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if tailscale status &>/dev/null; then
  ok "already connected to tailnet"
else
  if [[ -z "${TS_AUTHKEY:-}" ]]; then
    echo "  Paste a Tailscale auth key (Settings → Keys, tagged with $TS_TAGS),"
    echo "  or press Enter to log in via the browser instead."
    read -r -s -p "  Auth key: " TS_AUTHKEY </dev/tty
    echo
  fi
  if [[ -n "${TS_AUTHKEY:-}" ]]; then
    tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" --advertise-tags="$TS_TAGS"
  else
    echo "  Open the login URL below to add this server to your tailnet:"
    tailscale up --hostname="$TS_HOSTNAME" --advertise-tags="$TS_TAGS"
  fi
fi
tailscale set --operator="$ADMIN_USER"
TS_IP=$(tailscale ip -4 | head -n1)
[[ -n "$TS_IP" ]] || die "No Tailscale IP — is tailscale up?"
ok "Tailscale IP: $TS_IP  (MagicDNS name: $TS_HOSTNAME)"

# ---------------------------------------------------------------- sshd, phase 1
step "Hardening sshd (root keys still allowed for now)"
write_sshd_conf prohibit-password
reload_sshd
ok "password logins off, $AGENT_USER denied"

# ---------------------------------------------------------------- checkpoint
cat <<EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │  CHECKPOINT — keep this session open.                            │
  │  In a NEW terminal on your machine (also on Tailscale), run:     │
  │                                                                  │
  │     ssh $ADMIN_USER@$TS_IP
  │     sudo whoami        # should print: root                      │
  │                                                                  │
  │  Optional: also log in once via the Hetzner web Console with     │
  │  $ADMIN_USER + password, so you know the fallback works.
  └──────────────────────────────────────────────────────────────────┘

EOF
if ! confirm "Did SSH as $ADMIN_USER over Tailscale AND sudo work?"; then
  warn "Stopping here. Firewall NOT enabled, root SSH still works."
  warn "Fix the problem, then re-run this script."
  exit 1
fi

# ---------------------------------------------------------------- firewall
step "Enabling ufw (inbound only via tailscale0)"
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
ufw --force enable
ok "ufw enabled"

# ---------------------------------------------------------------- sshd, phase 2
step "Disabling root SSH login"
write_sshd_conf no
reload_sshd
ok "root login disabled"

# ---------------------------------------------------------------- verification
step "Verification"
sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|denyusers) '
echo
echo "  id $AGENT_USER:  $(id "$AGENT_USER")"
sudo -l -U "$AGENT_USER" 2>&1 | sed 's/^/  /' | tail -n1
echo
ufw status verbose | sed 's/^/  /'

printf '\n\033[1;32mDone.\033[0m'
cat <<EOF
 Remaining manual steps:

  1. Hetzner Cloud Firewall (blocks traffic before it reaches the VPS and
     covers Docker-published ports that bypass ufw). Console → Firewalls →
     create one with NO inbound rules → apply to this server. Or locally:
       hcloud firewall create --name deny-inbound
       hcloud firewall apply-to-resource deny-inbound --type server --server <name>

  2. From a machine OUTSIDE your tailnet:   nmap -Pn <public-ip>
     → should show no open ports.

  3. In a new terminal:
       ssh root@$TS_IP          → should be refused
       ssh $ADMIN_USER@$TS_IP   → should work
     Then you can close this root session.

  Lockout fallback: the "Console" button on the server page in Hetzner.
EOF
