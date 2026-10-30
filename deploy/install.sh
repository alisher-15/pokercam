#!/usr/bin/env bash
# PokerCam on a fresh Ubuntu 22.04 / 24.04 server (a VPS or a mini-PC in the club), as root:
#
#   curl -fsSL https://raw.githubusercontent.com/alisher-15/pokercam/main/deploy/install.sh | bash -s -- --ref main
#
# Installs Docker, puts the code in /opt/pokercam, writes .env with fresh secrets and this server's public
# address, opens the ports and starts postgres, backend (+ admin panel) and media-server. Running it again
# updates the code to --ref and restarts; .env (secrets, passwords) is kept.
set -euo pipefail

# All of it is one function, run on the last line: piped into bash (curl | bash), the script is read while it
# runs, and a command that reads stdin (docker compose run) would swallow the rest of it.
main() {
REF=main
IP=""
TIMEZONE_NAME=Asia/Almaty
ADMIN_EMAIL_ARG=admin@pokercam.local
DIR=/opt/pokercam
REPO=https://github.com/alisher-15/pokercam.git

usage() {
  echo "usage: install.sh [--ref BRANCH] [--ip PUBLIC_IP] [--timezone Area/City] [--admin-email EMAIL] [--dir DIR]"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --timezone) TIMEZONE_NAME="$2"; shift 2 ;;
    --admin-email) ADMIN_EMAIL_ARG="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }

step() { printf '\n==> %s\n' "$*"; }

step "Docker"
# Some VPS get IPv6 addresses from DNS but have no IPv6 route: apt then fails on archive.ubuntu.com.
if [ -z "$(ip -6 route show default 2>/dev/null)" ] && [ ! -e /etc/apt/apt.conf.d/99pokercam-ipv4 ]; then
  echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99pokercam-ipv4
  echo "no IPv6 route: apt goes over IPv4"
fi
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  apt-get update -q
  apt-get install -yq ca-certificates curl git
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -yq docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
command -v git >/dev/null || apt-get install -yq git
docker --version

step "Code: $REPO $REF -> $DIR"
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" fetch --depth 1 origin "$REF"
  git -C "$DIR" checkout -q -B "$REF" FETCH_HEAD
else
  git clone -q --depth 1 --branch "$REF" "$REPO" "$DIR"
fi
cd "$DIR"
git log --oneline -1

if [ -z "$IP" ]; then
  IP=$(curl -4 -fsS --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')
fi
echo "public address: $IP"

# Sets KEY=VALUE in .env, replacing the line or adding one.
set_env() {
  if grep -q "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    echo "$1=$2" >> .env
  fi
}

FIRST_RUN=false
if [ ! -f .env ]; then
  FIRST_RUN=true
  step ".env with fresh secrets"
  cp .env.example .env
  ADMIN_PASSWORD_VALUE=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)
  set_env POSTGRES_PASSWORD "$(openssl rand -hex 24)"
  set_env TIMEZONE "$TIMEZONE_NAME"
  set_env ADMIN_EMAIL "$ADMIN_EMAIL_ARG"
  set_env ADMIN_PASSWORD "$ADMIN_PASSWORD_VALUE"
  docker compose build -q backend
  # Split at the first "=" only: base64 values end in "=", which IFS='=' read would cut off.
  docker compose run --rm --no-deps -T backend python -m app.cli gen-keys | while IFS= read -r line; do
    set_env "${line%%=*}" "${line#*=}"
  done
  # Production only now that the secrets are there: the backend refuses to start without them.
  set_env ENVIRONMENT production
  chmod 600 .env
fi
# The address can change (a new VPS, a new IP): set it on every run.
set_env RTC_ANNOUNCED_ADDRESS "$IP"
set_env PUBLIC_API_URL "http://$IP:8000"
set_env PUBLIC_MEDIA_URL "ws://$IP:3000/ws"

step "Firewall"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 22/tcp
  ufw allow 8000/tcp
  ufw allow 3000/tcp
  ufw allow 40000:40003/tcp
  ufw allow 40000:40003/udp
else
  echo "ufw is off. If the provider has its own firewall, open TCP 8000, 3000, 40000-40003 and UDP 40000-40003."
fi

step "Start"
docker compose up -d --build --wait
set -a
. ./.env
set +a
if [ "$FIRST_RUN" = true ]; then
  docker compose exec -T backend python -m app.cli create-admin "$ADMIN_EMAIL" "$ADMIN_PASSWORD" >/dev/null
fi
docker compose ps

cat <<SUMMARY

PokerCam is running.
  Admin panel:  http://$IP:8000/admin
  Login:        $ADMIN_EMAIL
SUMMARY
if [ "$FIRST_RUN" = true ]; then
  echo "  Password:     $ADMIN_PASSWORD   (shown once; it is also in $DIR/.env)"
fi
cat <<SUMMARY

Next:
  1. A client with a paid month and table 1 (prints its activation key for the PC; keep it):
       cd $DIR && docker compose exec backend python -m app.cli create-client "CLIENT NAME"
     Or in the admin panel: Brands -> create a brand, then Clients -> create a client.
  2. Pair the camera phone with the client's table: a 6-digit code for 5 minutes:
       cd $DIR && docker compose exec backend python -m app.cli pairing-code "CLIENT NAME"
     In the camera app: "Enter the code" -> server http://$IP:8000 and the code.
  3. Update later: run this script again (same --ref or a new one).
SUMMARY
}

main "$@"
