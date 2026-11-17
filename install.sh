#!/usr/bin/env bash
# Instalator i menu zarządzania stackiem LimeSurvey (Ubuntu/Debian + Docker).
#
#   sudo ./install.sh            # menu w terminalu: kreator przy pierwszym
#                                # uruchomieniu, potem zarządzanie stackiem
#   sudo LS_DOMAIN=ankiety.example.com ACME_EMAIL=it@example.com \
#        ADMIN_EMAIL=it@example.com ./install.sh --yes --firewall
#
# Opcje:
#   --yes        bez pytań (wartości z env lub istniejącego .env)
#   --firewall   z --yes: skonfiguruj ufw (SSH, 80/tcp, 443/tcp)
#   --no-start   przygotuj tylko konfigurację i sekrety
#   --plain      zwykłe pytania w terminalu zamiast okienek
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

FIREWALL=0 YES=0 START=1 PLAIN=0
for arg in "$@"; do
  case "$arg" in
    --firewall) FIREWALL=1 ;;
    --yes) YES=1 ;;
    --no-start) START=0 ;;
    --plain) PLAIN=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "Nieznana opcja: $arg" >&2; exit 2 ;;
  esac
done

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mBŁĄD:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die 'Uruchom jako root: sudo ./install.sh'

# whiptail needs a UTF-8 locale to draw Polish characters.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*|*UTF8*|*utf-8*) ;;
  *) export LC_ALL=C.UTF-8 ;;
esac

# =====================================================================
# UI: whiptail dialogs with a plain-terminal fallback
# =====================================================================
TITLE='LimeSurvey'
TUI=0
if [ "$YES" -eq 0 ] && [ "$PLAIN" -eq 0 ] && [ -t 0 ] && [ -t 1 ] \
   && command -v whiptail >/dev/null; then
  TUI=1
fi

dims() { # sets H (max height) and W (width) for the current terminal
  local rows cols
  read -r rows cols < <(stty size 2>/dev/null || echo '24 80')
  W=$(( cols > 82 ? 78 : cols - 4 ))
  H=$(( rows > 28 ? 24 : rows - 4 ))
}
text_lines() { printf '%s\n' "$1" | fold -s -w $((W - 4)) | wc -l; }

ui_msg() { # text
  if [ "$TUI" -eq 1 ]; then
    dims
    local n h scroll=(); n=$(text_lines "$1"); h=$((n + 7))
    # --scrolltext only when needed: it moves focus off the OK button.
    [ "$h" -gt "$H" ] && { h=$H; scroll=(--scrolltext); }
    whiptail --title "$TITLE" "${scroll[@]}" --msgbox "$1" "$h" "$W"
  else
    printf '\n%s\n\n' "$1"
    read -r -p 'Enter, aby kontynuować… ' _ || true
  fi
}

ui_yesno() { # text [default: yes|no]
  if [ "$TUI" -eq 1 ]; then
    dims
    local n h flags=(); n=$(text_lines "$1"); h=$((n + 7)); [ "$h" -gt "$H" ] && h=$H
    [ "${2:-yes}" = no ] && flags=(--defaultno)
    whiptail --title "$TITLE" "${flags[@]}" --yes-button 'Tak' --no-button 'Nie' \
      --yesno "$1" "$h" "$W"
  else
    local hint='T/n' ans; [ "${2:-yes}" = no ] && hint='t/N'
    read -r -p "$1 [$hint] " ans || return 1
    ans=${ans:-$([ "${2:-yes}" = no ] && echo n || echo t)}
    case "$ans" in [TtYy]*) return 0 ;; *) return 1 ;; esac
  fi
}

ui_input() { # prompt [default] -> value on stdout; status 1 on cancel
  local out
  if [ "$TUI" -eq 1 ]; then
    dims
    out=$(whiptail --title "$TITLE" --ok-button 'Dalej' --cancel-button 'Anuluj' \
      --inputbox "$1" $(( $(text_lines "$1") + 9 )) "$W" "${2:-}" 3>&1 1>&2 2>&3) || return 1
  else
    printf '\n%s\n' "$1" >&2
    read -r -p "[${2:-}]> " out || return 1
    out=${out:-${2:-}}
  fi
  printf '%s' "$out"
}

ui_menu() { # prompt default tag desc [tag desc...] -> tag on stdout ($CANCEL: button)
  local prompt=$1 def=$2; shift 2
  if [ "$TUI" -eq 1 ]; then
    dims
    local items=$(($# / 2)) pl lh
    pl=$(text_lines "$prompt"); lh=$items
    [ $((pl + lh + 7)) -gt "$H" ] && lh=$((H - pl - 7))
    [ "$lh" -lt 3 ] && lh=3
    whiptail --title "$TITLE" --notags --ok-button 'Wybierz' --cancel-button "${CANCEL:-Wstecz}" \
      --default-item "$def" --menu "$prompt" $((pl + lh + 7)) "$W" "$lh" "$@" 3>&1 1>&2 2>&3
  else
    local -a tags=(); local i=1 n defn=1
    printf '\n%s\n' "$prompt" >&2
    while [ $# -gt 0 ]; do
      tags+=("$1"); [ "$1" = "$def" ] && defn=$i
      printf '  %d) %s\n' "$i" "$2" >&2
      i=$((i + 1)); shift 2
    done
    read -r -p "Wybór [$defn]: " n || return 1
    n=${n:-$defn}
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#tags[@]}" ] || return 1
    printf '%s' "${tags[n-1]}"
  fi
}

ui_textfile() { # title file  (long output: less, q returns to the menu)
  if [ "$TUI" -eq 1 ] && command -v less >/dev/null; then
    clear
    { printf '=== %s  (q: powrót do menu, /: szukaj) ===\n\n' "$1"; cat "$2"; } \
      | LESSSECURE=1 less -R +G -S
  elif [ "$TUI" -eq 1 ]; then
    local rows cols
    read -r rows cols < <(stty size 2>/dev/null || echo '24 80')
    whiptail --title "$1" --scrolltext --textbox "$2" $((rows - 2)) $((cols - 4))
  else
    printf '\n== %s ==\n' "$1"; cat "$2"
  fi
}

# Leave the dialogs and show raw command output (builds, restore, …).
console() { if [ "$TUI" -eq 1 ]; then clear; fi; printf '\033[1m%s\033[0m\n' "$*"; }
pause()   { if [ "$TUI" -eq 1 ]; then read -r -p $'\nEnter, aby wrócić do menu… ' _ || true; fi; }
abort()   { [ "$TUI" -eq 1 ] && clear; echo 'Przerwano. Nic nie zostało zmienione.'; exit 1; }

# =====================================================================
# .env helpers
# =====================================================================
get_env() { # reads .env, or the defaults in .env.example before it exists
  local f=.env; [ -f .env ] || f=.env.example
  grep -E "^$1=" "$f" 2>/dev/null | tail -1 | cut -d= -f2- || true
}
set_env() { # key value
  local key=$1 val=$2 esc
  esc=${val//\\/\\\\}; esc=${esc//|/\\|}; esc=${esc//&/\\&}
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${esc}|" .env
  elif grep -q "^# *${key}=" .env; then
    sed -i "s|^# *${key}=.*|${key}=${esc}|" .env
  else
    printf '%s=%s\n' "$key" "$val" >> .env
  fi
}
unset_env() { sed -i "s|^$1=|# $1=|" .env; }

ensure_env_file() {
  if [ ! -f .env ]; then
    cp .env.example .env
    info 'Utworzono .env z .env.example'
  fi
  chmod 600 .env
}

STAGING_CA='https://acme-staging-v02.api.letsencrypt.org/directory'
stack_name() { local s; s=$(get_env STACK_NAME); echo "${s:-limesurvey}"; }
is_configured() {
  [ -f .env ] && [ -s secrets/db_password ] || return 1
  local d; d=$(get_env LS_DOMAIN)
  [ -n "$d" ] && [[ "$d" != *example.com ]]
}
is_installed() { docker volume inspect "$(stack_name)_db" >/dev/null 2>&1; }

# =====================================================================
# Validation
# =====================================================================
valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }
valid_email()  { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
valid_user()   { [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }
valid_time()   { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
valid_tz()     { [ -n "$1" ] && { [ ! -d /usr/share/zoneinfo ] || [ -f "/usr/share/zoneinfo/$1" ]; }; }

normalize_cidrs() { # "1.2.3.4, 10.0.0.0/8" -> "1.2.3.4/32,10.0.0.0/8"; status 1 if invalid
  local item out=() ip
  IFS=', ' read -r -a items <<< "$1"
  for item in "${items[@]}"; do
    [ -n "$item" ] || continue
    ip=${item%/*}
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      [[ "$item" == */* ]] || item="$item/32"
      [[ "${item#*/}" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
    elif [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$ip" == *:* ]]; then
      [[ "$item" == */* ]] || item="$item/128"
      [[ "${item#*/}" =~ ^[0-9]{1,3}$ ]] && [ "${item#*/}" -le 128 ] || return 1
    else
      return 1
    fi
    out+=("$item")
  done
  [ "${#out[@]}" -gt 0 ] || return 1
  (IFS=,; echo "${out[*]}")
}

public_ip() { curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true; }
dns_ip()    { getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}' || true; }
ssh_client_ip() { set -- ${SSH_CLIENT:-${SSH_CONNECTION:-}}; echo "${1:-}"; }
ssh_ports() {
  local p
  p=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u | tr '\n' ' ')
  echo "${p:-22}"
}

# =====================================================================
# Prerequisites
# =====================================================================
install_docker() {
  . /etc/os-release
  case "$ID" in ubuntu|debian) ;; *) die "Automatyczna instalacja Dockera obsługuje Ubuntu i Debiana (wykryto: $ID)." ;; esac
  console 'Instalacja Docker Engine z oficjalnego repozytorium Dockera'
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

check_prereqs() {
  if ! command -v docker >/dev/null; then
    if [ "$YES" -eq 0 ] && ui_yesno 'Docker nie jest zainstalowany.

Zainstalować Docker Engine i wtyczkę Compose z oficjalnego repozytorium Dockera (download.docker.com)?'; then
      install_docker
    else
      die 'Docker nie jest zainstalowany: https://docs.docker.com/engine/install/ubuntu/'
    fi
  fi
  docker compose version >/dev/null 2>&1 || die 'Brak wtyczki Docker Compose (apt install docker-compose-plugin).'
  docker info >/dev/null 2>&1 || die 'Usługa Docker nie działa (systemctl start docker).'
  command -v openssl >/dev/null || die 'Wymagany jest openssl (apt install openssl).'
}

ports_busy() { # prints busy ports not held by this stack's Traefik
  local port taken=()
  for port in 80 443; do
    if ss -ltnH "sport = :$port" 2>/dev/null | grep -q . \
       && ! docker ps --format '{{.Names}}' | grep -q -- "^$(stack_name)-traefik-"; then
      taken+=("$port")
    fi
  done
  echo "${taken[*]}"
}

# =====================================================================
# Configuration wizard
# =====================================================================
ask() { # var prompt default validator error
  local var=$1 prompt=$2 def=$3 check=$4 err=$5 val
  while :; do
    val=$(ui_input "$prompt" "$def") || abort
    val=$(printf '%s' "$val" | tr -d '[:space:]')
    if "$check" "$val"; then printf -v "$var" '%s' "$val"; return; fi
    ui_msg "$err"
    def=$val
  done
}

current_or_empty() { local v; v=$(get_env "$1"); [[ "$v" == *example.com ]] && v=''; echo "$v"; }

wizard() { # sets C_* variables; $1 = first|reconfigure
  local mode=$1 installed=0
  is_installed && installed=1

  if [ "$mode" = first ]; then
    ui_msg "Ten kreator zainstaluje LimeSurvey na tym serwerze:

  • Traefik: HTTPS i certyfikaty Let's Encrypt,
  • LimeSurvey $(get_env LIMESURVEY_VERSION | cut -d+ -f1) (PHP 8.3),
  • MariaDB 11.4 dostępna tylko wewnątrz stacku,
  • codzienny backup bazy, plików i kluczy szyfrowania.

Przygotuj:
  • domenę z rekordem DNS A wskazującym na ten serwer,
  • adres e-mail dla Let's Encrypt i dla administratora.

Nic nie zostanie zmienione przed ekranem podsumowania."
  fi

  # --- Domain + DNS check ---
  local ip dip
  while :; do
    ask C_DOMAIN 'Domena ankiet (np. ankiety.firma.pl).

Rekord DNS A tej domeny musi wskazywać na ten serwer.' \
      "$(current_or_empty LS_DOMAIN)" valid_domain 'To nie jest poprawna nazwa domeny.'
    ip=$(public_ip); dip=$(dns_ip "$C_DOMAIN")
    if [ -z "$dip" ]; then
      ui_yesno "Domena $C_DOMAIN jeszcze się nie rozwiązuje.

Certyfikat zostanie wydany, gdy DNS zacznie wskazywać na ten serwer${ip:+ ($ip)}. Do tego czasu przeglądarka pokaże błąd certyfikatu.

Kontynuować z tą domeną?" no && break
    elif [ -n "$ip" ] && [ "$dip" != "$ip" ]; then
      ui_yesno "Domena $C_DOMAIN wskazuje na $dip, a ten serwer ma adres $ip.

Jeśli serwer jest za NAT-em lub proxy, to może być w porządku. W przeciwnym razie certyfikat nie zostanie wydany.

Kontynuować z tą domeną?" no && break
    else
      break
    fi
  done

  ask C_ACME 'Adres e-mail dla Let'"'"'s Encrypt (powiadomienia o wygasających certyfikatach):' \
    "$(current_or_empty ACME_EMAIL)" valid_email 'To nie jest poprawny adres e-mail.'

  # --- First administrator (only before the first start) ---
  if [ "$installed" -eq 0 ]; then
    local ae; ae=$(current_or_empty ADMIN_EMAIL); ae=${ae:-$C_ACME}
    ask C_ADMIN_EMAIL 'Adres e-mail pierwszego administratora LimeSurvey:' \
      "$ae" valid_email 'To nie jest poprawny adres e-mail.'
    local au; au=$(get_env ADMIN_USER)
    ask C_ADMIN_USER 'Login pierwszego administratora:' \
      "${au:-admin}" valid_user 'Login może zawierać litery, cyfry oraz . _ - (do 64 znaków).'
  else
    C_ADMIN_EMAIL=$(get_env ADMIN_EMAIL); C_ADMIN_USER=$(get_env ADMIN_USER)
  fi

  # --- Time zone ---
  local tz; tz=$(get_env TZ)
  [ -n "$tz" ] || tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  tz=${tz:-UTC}
  ask C_TZ 'Strefa czasowa (godzina backupu, daty w LimeSurvey), np. Europe/Warsaw:' \
    "$tz" valid_tz 'Nieznana strefa czasowa. Przykłady: Europe/Warsaw, Europe/London, UTC.'

  # --- Admin panel access ---
  local cur me choice def=all
  cur=$(get_env ADMIN_ALLOW_CIDRS)
  [ -n "$cur" ] && [ "$cur" != '0.0.0.0/0,::/0' ] && def=custom
  me=$(ssh_client_ip)
  local -a opts=(all 'Z dowolnego adresu (domyślnie)')
  [ -n "$me" ] && opts+=(me "Tylko z mojego adresu ($me)")
  opts+=(custom 'Z wybranych adresów lub sieci')
  choice=$(ui_menu 'Skąd można otwierać panel administracyjny i logowanie?

Ankiety są zawsze publiczne. Ograniczenie działa na poziomie Traefika, przed LimeSurvey.' \
    "$def" "${opts[@]}") || abort
  case "$choice" in
    all) C_CIDRS='0.0.0.0/0,::/0' ;;
    me)  C_CIDRS=$(normalize_cidrs "$me") ;;
    custom)
      local v="$cur"; [ "$v" = '0.0.0.0/0,::/0' ] && v=${me:-}
      while :; do
        v=$(ui_input 'Adresy IP lub sieci oddzielone przecinkami, np.:
203.0.113.10, 198.51.100.0/24

Uwaga: spoza tej listy nie zalogujesz się do panelu. Listę zmienisz później w tym menu (z SSH).' "$v") || abort
        C_CIDRS=$(normalize_cidrs "$v") && break
        ui_msg 'Niepoprawny adres lub sieć. Użyj formatu 203.0.113.10 lub 198.51.100.0/24.'
      done ;;
  esac

  # --- Backups ---
  local bt bk
  bt=$(get_env BACKUP_TIME); bk=$(get_env BACKUP_KEEP_DAYS)
  ask C_BACKUP_TIME 'Godzina codziennego backupu (GG:MM):' "${bt:-03:15}" valid_time \
    'Podaj godzinę w formacie GG:MM, np. 03:15.'
  ask C_BACKUP_KEEP 'Ile dni przechowywać kopie zapasowe na serwerze?' "${bk:-14}" \
    valid_days 'Podaj liczbę dni od 1 do 3650.'

  # --- Certificates ---
  local cadef=prod; [ "$(get_env ACME_CA_SERVER)" = "$STAGING_CA" ] && cadef=staging
  C_CA=$(ui_menu 'Certyfikaty TLS:' "$cadef" \
    prod    "Let's Encrypt — produkcyjne" \
    staging "Let's Encrypt — testowe (przeglądarka pokaże ostrzeżenie)") || abort

  # --- Firewall ---
  C_FIREWALL=0
  if [ "$mode" = first ] || ! ufw status 2>/dev/null | grep -q 'Status: active'; then
    ui_yesno "Włączyć zaporę ufw?

Zostaną otwarte tylko porty: SSH ($(ssh_ports | sed 's/ $//; s/ /, /g')), 80 i 443. Pozostały ruch przychodzący będzie blokowany." && C_FIREWALL=1
  fi

  # --- Summary ---
  local fw='bez zmian'; [ "$C_FIREWALL" -eq 1 ] && fw='włączona (SSH, 80, 443)'
  local acc='z dowolnego adresu'; [ "$C_CIDRS" != '0.0.0.0/0,::/0' ] && acc=$C_CIDRS
  local ca="produkcyjne"; [ "$C_CA" = staging ] && ca='testowe (staging)'
  local admin_line="  Administrator:     $C_ADMIN_USER <$C_ADMIN_EMAIL>"
  [ "$installed" -eq 1 ] && admin_line='  Administrator:     bez zmian (zmienia się w panelu LimeSurvey)'
  ui_yesno "Podsumowanie

  Adres ankiet:      https://$C_DOMAIN/
  Panel:             https://$C_DOMAIN/index.php/admin
$admin_line
  Let's Encrypt:     $C_ACME, certyfikaty $ca
  Dostęp do panelu:  $acc
  Strefa czasowa:    $C_TZ
  Backup:            codziennie o $C_BACKUP_TIME, przez $C_BACKUP_KEEP dni
  Zapora ufw:        $fw

Zapisać i $([ "$installed" -eq 1 ] && echo 'zastosować zmiany' || echo 'zainstalować')?" || abort
}
valid_days() { [[ "$1" =~ ^[0-9]{1,4}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 3650 ]; }

apply_config() {
  ensure_env_file
  local old_ca; old_ca=$(get_env ACME_CA_SERVER)
  set_env LS_DOMAIN "$C_DOMAIN"
  set_env ACME_EMAIL "$C_ACME"
  set_env ADMIN_EMAIL "$C_ADMIN_EMAIL"
  set_env ADMIN_USER "$C_ADMIN_USER"
  set_env TZ "$C_TZ"
  set_env ADMIN_ALLOW_CIDRS "$C_CIDRS"
  set_env BACKUP_TIME "$C_BACKUP_TIME"
  set_env BACKUP_KEEP_DAYS "$C_BACKUP_KEEP"
  if [ "$C_CA" = staging ]; then set_env ACME_CA_SERVER "$STAGING_CA"; else unset_env ACME_CA_SERVER; fi
  FIREWALL=$C_FIREWALL

  # Certificates from the other CA must not be reused.
  if [ "$old_ca" != "$(get_env ACME_CA_SERVER)" ] \
     && docker volume inspect "$(stack_name)_letsencrypt" >/dev/null 2>&1; then
    info 'Zmiana urzędu certyfikacji: usuwam zapisane certyfikaty'
    docker compose rm -sf traefik >/dev/null 2>&1 || true
    docker volume rm "$(stack_name)_letsencrypt" >/dev/null
  fi
}

# =====================================================================
# Secrets, firewall, start
# =====================================================================
ensure_secrets() {
  local old_umask name; old_umask=$(umask); umask 077
  install -d -m 700 secrets backups
  gen() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }
  for name in db_password db_root_password admin_password; do
    if [ ! -s "secrets/$name" ]; then
      gen > "secrets/$name"
      info "Wygenerowano secrets/$name"
    fi
  done
  # LimeSurvey runs as www-data (uid/gid 33) and reads its two secrets directly.
  chown root:root secrets/*
  chmod 600 secrets/db_root_password
  chown root:33 secrets/db_password secrets/admin_password
  chmod 640 secrets/db_password secrets/admin_password
  chmod 600 .env
  umask "$old_umask"
}

configure_firewall() {
  [ "$FIREWALL" -eq 1 ] || return 0
  command -v ufw >/dev/null || apt-get install -y ufw
  local port
  info 'Konfiguracja ufw'
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for port in $(ssh_ports); do ufw allow "$port/tcp" comment 'SSH' >/dev/null; done
  ufw allow 80/tcp comment 'HTTP (Traefik)' >/dev/null
  ufw allow 443/tcp comment 'HTTPS (Traefik)' >/dev/null
  ufw --force enable >/dev/null
  ufw status verbose
}

ps_table() { docker compose ps -a --format 'table {{.Service}}\t{{.Status}}' 2>&1; }

start_stack() {
  info 'Budowanie i uruchamianie (pierwsze budowanie trwa kilka minut)'
  docker compose build --pull
  if ! docker compose up -d --remove-orphans --wait --wait-timeout 600; then
    ps_table
    docker compose logs --tail=80 limesurvey db traefik
    die 'Stack nie osiągnął stanu healthy. Logi powyżej.'
  fi
  ps_table
}

summary_text() {
  local d; d=$(get_env LS_DOMAIN)
  cat <<EOF
LimeSurvey działa.

  Ankiety:   https://$d/
  Panel:     https://$d/index.php/admin
  Login:     $(get_env ADMIN_USER)
  Hasło:     sudo cat $(pwd)/secrets/admin_password

Zmień hasło po pierwszym logowaniu. Plik secrets/admin_password jest używany
tylko przy pierwszym starcie (nie usuwaj go, możesz nadpisać losowymi znakami).

Backup: codziennie o $(get_env BACKUP_TIME) do $(pwd)/backups.
Kopiuj ten katalog poza serwer.

Menu zarządzania: sudo $(pwd)/install.sh
EOF
}

# =====================================================================
# Management menu actions
# =====================================================================
tmpfile() { local f; f=$(mktemp); TMPFILES+=("$f"); echo "$f"; }
TMPFILES=()
trap 'rm -f "${TMPFILES[@]}"' EXIT

act_status() {
  local last count
  last=$(ls -1 backups 2>/dev/null | grep -E '^20[0-9]{6}-[0-9]{6}$' | tail -1 || true)
  count=$(find backups -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null | wc -l)
  ui_msg "$(ps_table)

Adres:    https://$(get_env LS_DOMAIN)/
Wersja:   LimeSurvey $(get_env LIMESURVEY_VERSION)
Backupy:  $count${last:+, ostatni $last}
Dysk:     $(df -h . | awk 'NR==2{print $4" wolne z "$2}')"
}

act_backup() {
  console 'Backup na żądanie'
  if docker compose exec -T backup /bin/bash /opt/backup/backup.sh now; then
    info 'Backup gotowy.'
  else
    warn 'Backup się nie udał. Sprawdź komunikaty powyżej.'
  fi
  pause
}

act_restore() {
  local -a items=(); local d
  while read -r d; do
    [ -n "$d" ] || continue
    items+=("$d" "$(backup_label "$d")  ($(du -sh "backups/$d" 2>/dev/null | cut -f1))")
  done < <(ls -1r backups 2>/dev/null | grep -E '^20[0-9]{6}-[0-9]{6}$' || true)
  if [ "${#items[@]}" -eq 0 ]; then ui_msg 'Brak kopii w katalogu backups/.'; return; fi
  d=$(ui_menu 'Którą kopię odtworzyć? (najnowsze na górze)' "${items[0]}" "${items[@]}") || return 0
  ui_yesno "Odtworzenie kopii z $(backup_label "$d") ZASTĄPI obecną bazę, pliki i klucze szyfrowania.

Wszystko, co zmieniono po $(backup_label "$d"), zostanie utracone.

Najpierw zrobić kopię obecnego stanu?" && act_backup_quiet
  ui_yesno "Na pewno odtworzyć kopię z $(backup_label "$d")?" no || return 0
  console "Odtwarzanie $d"
  RESTORE_CONFIRMED=1 ./scripts/restore.sh "backups/$d" || warn 'Odtwarzanie się nie udało.'
  pause
}
backup_label() { echo "$1" | sed -E 's/^(....)(..)(..)-(..)(..)(..)$/\3.\2.\1  \4:\5:\6/'; }
act_backup_quiet() {
  console 'Kopia obecnego stanu przed odtworzeniem'
  docker compose exec -T backup /bin/bash /opt/backup/backup.sh now || die 'Backup się nie udał, przerywam.'
}

act_logs() {
  local svc f
  svc=$(ui_menu 'Logi której usługi?' limesurvey \
    limesurvey 'LimeSurvey (Apache/PHP)' \
    traefik    'Traefik (dostęp, certyfikaty)' \
    db         'MariaDB' \
    backup     'Backup') || return 0
  f=$(tmpfile)
  docker compose logs --no-color --tail=300 "$svc" > "$f" 2>&1 || true
  ui_textfile "Logi: $svc (ostatnie 300 linii)" "$f"
}

act_password() {
  ui_msg "Początkowe hasło administratora ($(get_env ADMIN_USER)):

    $(cat secrets/admin_password)

Działa, dopóki nie zmienisz go w panelu LimeSurvey."
}

act_reconfigure() {
  # Subshell: "Anuluj" inside the wizard returns to the menu instead of exiting.
  local f; f=$(tmpfile)
  ( wizard reconfigure
    declare -p C_DOMAIN C_ACME C_ADMIN_EMAIL C_ADMIN_USER C_TZ C_CIDRS \
      C_BACKUP_TIME C_BACKUP_KEEP C_CA C_FIREWALL > "$f" ) || return 0
  # shellcheck disable=SC1090
  . "$f"
  apply_config
  ensure_secrets
  console 'Stosowanie zmian'
  configure_firewall
  docker compose up -d --remove-orphans --wait --wait-timeout 600 || warn 'Nie wszystkie usługi są healthy.'
  ps_table
  pause
}

latest_ls_tag() {
  curl -fsS --max-time 10 'https://api.github.com/repos/LimeSurvey/LimeSurvey/tags?per_page=100' 2>/dev/null \
    | grep -o '"name": *"[0-9]*\.[0-9]*\.[0-9]*+[0-9]*"' | cut -d'"' -f4 | sort -V | tail -1 || true
}

act_update() {
  local what
  what=$(ui_menu 'Co zaktualizować?' images \
    images 'Traefik, MariaDB i system bazowy obrazu (ta sama wersja LimeSurvey)' \
    ls     'LimeSurvey do nowej wersji') || return 0
  case "$what" in
    images)
      ui_yesno 'Pobrać nowe obrazy, przebudować LimeSurvey i zrestartować usługi?

Strona będzie niedostępna przez kilkadziesiąt sekund.' || return 0
      console 'Aktualizacja obrazów'
      docker compose pull traefik socket-proxy db backup
      start_stack
      pause ;;
    ls)
      local cur latest tag sha f
      cur=$(get_env LIMESURVEY_VERSION)
      latest=$(latest_ls_tag)
      tag=$(ui_input "Obecna wersja: $cur
Najnowsza na GitHubie: ${latest:-nie udało się sprawdzić}

Podaj tag wersji (z https://github.com/LimeSurvey/LimeSurvey/tags):" "${latest:-$cur}") || return 0
      [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?$ ]] || { ui_msg "Niepoprawny tag: $tag"; return 0; }
      [ "$tag" = "$cur" ] && { ui_msg 'To jest obecna wersja.'; return 0; }
      if [ "$(printf '%s\n%s\n' "$cur" "$tag" | sort -V | head -1)" = "$tag" ]; then
        ui_msg "Wersja $tag jest starsza niż $cur. Obniżenie wersji uszkodziłoby schemat bazy, więc nie jest obsługiwane."
        return 0
      fi
      console "Pobieranie LimeSurvey $tag"
      f=$(tmpfile)
      curl -fL --progress-bar -o "$f" "https://github.com/LimeSurvey/LimeSurvey/archive/refs/tags/${tag}.tar.gz" \
        || { warn 'Nie udało się pobrać tej wersji.'; pause; return 0; }
      sha=$(sha256sum "$f" | cut -d' ' -f1)
      ui_yesno "LimeSurvey $cur → $tag
SHA-256: $sha

Przed aktualizacją zostanie zrobiony backup. Migracja bazy wykona się automatycznie przy starcie. Kontynuować?" || return 0
      act_backup_quiet
      set_env LIMESURVEY_VERSION "$tag"
      set_env LIMESURVEY_SHA256 "$sha"
      start_stack
      pause ;;
  esac
}

act_restart() {
  ui_yesno 'Zrestartować wszystkie usługi?' || return 0
  console 'Restart'
  docker compose restart
  docker compose up -d --wait --wait-timeout 300 || warn 'Nie wszystkie usługi są healthy.'
  pause
}

management_menu() {
  local choice=status
  while :; do
    TITLE="LimeSurvey — $(get_env LS_DOMAIN)"
    choice=$(CANCEL='Wyjście' ui_menu 'Zarządzanie stackiem:' "$choice" \
      status   'Stan usług' \
      backup   'Zrób backup teraz' \
      restore  'Odtwórz backup' \
      logs     'Logi' \
      config   'Zmień konfigurację (domena, dostęp do panelu, backup…)' \
      update   'Aktualizacja' \
      restart  'Restart usług' \
      password 'Pokaż początkowe hasło administratora' \
      quit     'Wyjście') || break
    case "$choice" in
      status) act_status ;; backup) act_backup ;; restore) act_restore ;;
      logs) act_logs ;; config) act_reconfigure ;; update) act_update ;;
      restart) act_restart ;; password) act_password ;; quit) break ;;
    esac
  done
  [ "$TUI" -eq 1 ] && clear
  return 0
}

# =====================================================================
# Main
# =====================================================================
check_prereqs

busy=$(ports_busy)
if [ -n "$busy" ]; then
  if [ "$YES" -eq 1 ]; then
    warn "Porty zajęte na hoście: $busy. Traefik potrzebuje 80 i 443."
  else
    ui_yesno "Porty $busy są zajęte przez inny program na tym serwerze. Traefik potrzebuje portów 80 i 443.

Zatrzymaj tamten program (np. apache2 lub nginx). Kontynuować mimo to?" no || abort
  fi
fi

# ---- Non-interactive ----
if [ "$YES" -eq 1 ]; then
  ensure_env_file
  for key in LS_DOMAIN ACME_EMAIL ADMIN_EMAIL; do
    val=${!key:-}
    [ -n "$val" ] || val=$(current_or_empty "$key")
    [ -n "$val" ] || die "$key jest wymagane (w .env lub w zmiennej środowiskowej)."
    set_env "$key" "$val"
  done
  valid_domain "$(get_env LS_DOMAIN)" || die "LS_DOMAIN '$(get_env LS_DOMAIN)' nie jest poprawną domeną."
  d=$(get_env LS_DOMAIN); ip=$(public_ip); dip=$(dns_ip "$d")
  if [ -z "$dip" ]; then warn "$d jeszcze się nie rozwiązuje. Certyfikat zostanie wydany, gdy DNS wskaże ten serwer."
  elif [ -n "$ip" ] && [ "$dip" != "$ip" ]; then warn "$d wskazuje na $dip, ten serwer to $ip."; fi
  ensure_secrets
  configure_firewall
  [ "$START" -eq 1 ] || { info 'Gotowe. Uruchom: docker compose up -d --build'; exit 0; }
  start_stack
  echo; summary_text
  exit 0
fi

# ---- Interactive ----
if is_configured; then
  management_menu
  exit 0
fi

wizard first
apply_config
ensure_secrets
console 'Instalacja'
configure_firewall
[ "$START" -eq 1 ] || { info 'Gotowe. Uruchom: docker compose up -d --build'; exit 0; }
start_stack
if [ "$TUI" -eq 1 ]; then
  read -r -p $'\nEnter, aby zobaczyć podsumowanie… ' _ || true
  ui_msg "$(summary_text)"
  ui_yesno 'Pokazać teraz początkowe hasło administratora?' no && act_password
  clear
fi
summary_text
