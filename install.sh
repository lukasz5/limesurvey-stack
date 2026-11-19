#!/usr/bin/env bash
# Installer and management menu for the LimeSurvey stack (Ubuntu/Debian + Docker).
# Instalator i menu zarządzania stackiem LimeSurvey (Ubuntu/Debian + Docker).
#
#   sudo ./install.sh            # terminal menu: setup wizard on the first run,
#                                # stack management afterwards
#   sudo LS_DOMAIN=surveys.example.com ACME_EMAIL=it@example.com \
#        ADMIN_EMAIL=it@example.com ./install.sh --yes --firewall
#
# Run ./install.sh --help for the options (in English or Polish).
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

FIREWALL=0 YES=0 START=1 PLAIN=0 LANG_OPT='' HELP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --firewall) FIREWALL=1 ;;
    --yes) YES=1 ;;
    --no-start) START=0 ;;
    --plain) PLAIN=1 ;;
    --lang=*) LANG_OPT=${1#--lang=} ;;
    --lang) LANG_OPT=${2:-}; shift ;;
    -h|--help) HELP=1 ;;
    *) echo "Unknown option / Nieznana opcja: $1" >&2; exit 2 ;;
  esac
  shift
done

# =====================================================================
# Language: --lang, $LS_LANG, INSTALLER_LANG saved in .env, system locale
# =====================================================================
L=${LANG_OPT:-${LS_LANG:-}}
LANG_SAVE=0 LANG_ASK=0
[ -n "$L" ] && LANG_SAVE=1
if [ -z "$L" ] && [ -f .env ]; then
  L=$(grep -E '^INSTALLER_LANG=' .env 2>/dev/null | tail -1 | cut -d= -f2- || true)
fi
if [ -z "$L" ]; then
  case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
    pl*) L=pl ;;
    *) L=en; LANG_ASK=1 ;;
  esac
fi
case "$L" in
  pl|en) ;;
  *) echo "Unsupported language '$L' (use: en, pl) / Nieobsługiwany język '$L' (dostępne: en, pl)" >&2; exit 2 ;;
esac

t() { if [ "$L" = pl ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; } # polish english

usage() {
  if [ "$L" = pl ]; then
    cat <<'EOF'
Instalator i menu zarządzania stackiem LimeSurvey (Ubuntu/Debian + Docker).

  sudo ./install.sh            # menu w terminalu: kreator przy pierwszym
                               # uruchomieniu, potem zarządzanie stackiem
  sudo LS_DOMAIN=ankiety.example.com ACME_EMAIL=it@example.com \
       ADMIN_EMAIL=it@example.com ./install.sh --yes --firewall

Opcje:
  --yes        bez pytań (wartości z env lub istniejącego .env)
  --firewall   z --yes: skonfiguruj ufw (SSH, 80/tcp, 443/tcp)
  --no-start   przygotuj tylko konfigurację i sekrety
  --plain      zwykłe pytania w terminalu zamiast okienek
  --lang pl|en język instalatora (też zmienna LS_LANG)
EOF
  else
    cat <<'EOF'
Installer and management menu for the LimeSurvey stack (Ubuntu/Debian + Docker).

  sudo ./install.sh            # terminal menu: setup wizard on the first run,
                               # stack management afterwards
  sudo LS_DOMAIN=surveys.example.com ACME_EMAIL=it@example.com \
       ADMIN_EMAIL=it@example.com ./install.sh --yes --firewall

Options:
  --yes        no questions (values from env or an existing .env)
  --firewall   with --yes: configure ufw (SSH, 80/tcp, 443/tcp)
  --no-start   only prepare the configuration and secrets
  --plain      plain terminal prompts instead of dialogs
  --lang en|pl installer language (also the LS_LANG variable)
EOF
  fi
}
[ "$HELP" -eq 1 ] && { usage; exit 0; }

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m%s\033[0m %s\n' "$(t 'BŁĄD:' 'ERROR:')" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "$(t 'Uruchom jako root: sudo ./install.sh' 'Run as root: sudo ./install.sh')"

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
    read -r -p "$(t 'Enter, aby kontynuować… ' 'Press Enter to continue… ')" _ || true
  fi
}

ui_yesno() { # text [default: yes|no]
  if [ "$TUI" -eq 1 ]; then
    dims
    local n h flags=(); n=$(text_lines "$1"); h=$((n + 7)); [ "$h" -gt "$H" ] && h=$H
    [ "${2:-yes}" = no ] && flags=(--defaultno)
    whiptail --title "$TITLE" "${flags[@]}" --yes-button "$(t 'Tak' 'Yes')" --no-button "$(t 'Nie' 'No')" \
      --yesno "$1" "$h" "$W"
  else
    local hint ans
    if [ "${2:-yes}" = no ]; then hint=$(t 't/N' 'y/N'); else hint=$(t 'T/n' 'Y/n'); fi
    read -r -p "$1 [$hint] " ans || return 1
    ans=${ans:-$([ "${2:-yes}" = no ] && echo n || echo y)}
    case "$ans" in [TtYy]*) return 0 ;; *) return 1 ;; esac
  fi
}

ui_input() { # prompt [default] -> value on stdout; status 1 on cancel
  local out
  if [ "$TUI" -eq 1 ]; then
    dims
    out=$(whiptail --title "$TITLE" --ok-button "$(t 'Dalej' 'Next')" --cancel-button "$(t 'Anuluj' 'Cancel')" \
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
    whiptail --title "$TITLE" --notags --ok-button "$(t 'Wybierz' 'Select')" \
      --cancel-button "${CANCEL:-$(t 'Wstecz' 'Back')}" \
      --default-item "$def" --menu "$prompt" $((pl + lh + 7)) "$W" "$lh" "$@" 3>&1 1>&2 2>&3
  else
    local -a tags=(); local i=1 n defn=1
    printf '\n%s\n' "$prompt" >&2
    while [ $# -gt 0 ]; do
      tags+=("$1"); [ "$1" = "$def" ] && defn=$i
      printf '  %d) %s\n' "$i" "$2" >&2
      i=$((i + 1)); shift 2
    done
    read -r -p "$(t 'Wybór' 'Choice') [$defn]: " n || return 1
    n=${n:-$defn}
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#tags[@]}" ] || return 1
    printf '%s' "${tags[n-1]}"
  fi
}

ui_textfile() { # title file  (long output: less, q returns to the menu)
  if [ "$TUI" -eq 1 ] && command -v less >/dev/null; then
    clear
    { printf '=== %s  (%s) ===\n\n' "$1" "$(t 'q: powrót do menu, /: szukaj' 'q: back to the menu, /: search')"; cat "$2"; } \
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
pause()   { if [ "$TUI" -eq 1 ]; then read -r -p $'\n'"$(t 'Enter, aby wrócić do menu… ' 'Press Enter to return to the menu… ')" _ || true; fi; }
abort()   { [ "$TUI" -eq 1 ] && clear; t 'Przerwano. Nic nie zostało zmienione.' 'Aborted. Nothing was changed.'; echo; exit 1; }

# First interactive run without a language hint: ask once.
if [ "$LANG_ASK" -eq 1 ] && [ "$YES" -eq 0 ] && [ -t 0 ]; then
  L=$(CANCEL='Cancel / Anuluj' ui_menu 'Language / Język' en \
    en 'English' \
    pl 'Polski') || abort
  LANG_SAVE=1
fi

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
    info "$(t 'Utworzono .env z .env.example' 'Created .env from .env.example')"
  fi
  chmod 600 .env
  set_env INSTALLER_LANG "$L"
}

# Remember an explicitly chosen language for the management menu.
[ "$LANG_SAVE" -eq 1 ] && [ -f .env ] && set_env INSTALLER_LANG "$L"

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
valid_days()   { [[ "$1" =~ ^[0-9]{1,4}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 3650 ]; }

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
  case "$ID" in ubuntu|debian) ;; *) die "$(t "Automatyczna instalacja Dockera obsługuje Ubuntu i Debiana (wykryto: $ID)." "Automatic Docker installation supports Ubuntu and Debian (detected: $ID).")" ;; esac
  console "$(t 'Instalacja Docker Engine z oficjalnego repozytorium Dockera' 'Installing Docker Engine from the official Docker repository')"
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
    if [ "$YES" -eq 0 ] && ui_yesno "$(t 'Docker nie jest zainstalowany.

Zainstalować Docker Engine i wtyczkę Compose z oficjalnego repozytorium Dockera (download.docker.com)?' 'Docker is not installed.

Install Docker Engine and the Compose plugin from the official Docker repository (download.docker.com)?')"; then
      install_docker
    else
      die "$(t 'Docker nie jest zainstalowany' 'Docker is not installed'): https://docs.docker.com/engine/install/ubuntu/"
    fi
  fi
  docker compose version >/dev/null 2>&1 || die "$(t 'Brak wtyczki Docker Compose (apt install docker-compose-plugin).' 'The Docker Compose plugin is missing (apt install docker-compose-plugin).')"
  docker info >/dev/null 2>&1 || die "$(t 'Usługa Docker nie działa (systemctl start docker).' 'The Docker service is not running (systemctl start docker).')"
  command -v openssl >/dev/null || die "$(t 'Wymagany jest openssl (apt install openssl).' 'openssl is required (apt install openssl).')"
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
    local ver; ver=$(get_env LIMESURVEY_VERSION | cut -d+ -f1)
    ui_msg "$(t "Ten kreator zainstaluje LimeSurvey na tym serwerze:

  • Traefik: HTTPS i certyfikaty Let's Encrypt,
  • LimeSurvey $ver (PHP 8.3),
  • MariaDB 11.4 dostępna tylko wewnątrz stacku,
  • codzienny backup bazy, plików i kluczy szyfrowania.

Przygotuj:
  • domenę z rekordem DNS A wskazującym na ten serwer,
  • adres e-mail dla Let's Encrypt i dla administratora.

Nic nie zostanie zmienione przed ekranem podsumowania." "This wizard will install LimeSurvey on this server:

  • Traefik: HTTPS and Let's Encrypt certificates,
  • LimeSurvey $ver (PHP 8.3),
  • MariaDB 11.4, reachable only inside the stack,
  • daily backup of the database, files and encryption keys.

You will need:
  • a domain with a DNS A record pointing at this server,
  • an e-mail address for Let's Encrypt and for the administrator.

Nothing is changed before the summary screen.")"
  fi

  local bad_email; bad_email=$(t 'To nie jest poprawny adres e-mail.' 'This is not a valid e-mail address.')

  # --- Domain + DNS check ---
  local ip dip
  while :; do
    ask C_DOMAIN "$(t 'Domena ankiet (np. ankiety.firma.pl).

Rekord DNS A tej domeny musi wskazywać na ten serwer.' 'Survey domain (e.g. surveys.example.org).

The DNS A record of this domain must point at this server.')" \
      "$(current_or_empty LS_DOMAIN)" valid_domain "$(t 'To nie jest poprawna nazwa domeny.' 'This is not a valid domain name.')"
    ip=$(public_ip); dip=$(dns_ip "$C_DOMAIN")
    if [ -z "$dip" ]; then
      ui_yesno "$(t "Domena $C_DOMAIN jeszcze się nie rozwiązuje.

Certyfikat zostanie wydany, gdy DNS zacznie wskazywać na ten serwer${ip:+ ($ip)}. Do tego czasu przeglądarka pokaże błąd certyfikatu.

Kontynuować z tą domeną?" "The domain $C_DOMAIN does not resolve yet.

The certificate will be issued once DNS points at this server${ip:+ ($ip)}. Until then browsers will show a certificate error.

Continue with this domain?")" no && break
    elif [ -n "$ip" ] && [ "$dip" != "$ip" ]; then
      ui_yesno "$(t "Domena $C_DOMAIN wskazuje na $dip, a ten serwer ma adres $ip.

Jeśli serwer jest za NAT-em lub proxy, to może być w porządku. W przeciwnym razie certyfikat nie zostanie wydany.

Kontynuować z tą domeną?" "The domain $C_DOMAIN points at $dip, but this server's address is $ip.

That may be fine if the server is behind NAT or a proxy. Otherwise the certificate will not be issued.

Continue with this domain?")" no && break
    else
      break
    fi
  done

  ask C_ACME "$(t "Adres e-mail dla Let's Encrypt (powiadomienia o wygasających certyfikatach):" "E-mail address for Let's Encrypt (certificate expiry notices):")" \
    "$(current_or_empty ACME_EMAIL)" valid_email "$bad_email"

  # --- First administrator (only before the first start) ---
  if [ "$installed" -eq 0 ]; then
    local ae; ae=$(current_or_empty ADMIN_EMAIL); ae=${ae:-$C_ACME}
    ask C_ADMIN_EMAIL "$(t 'Adres e-mail pierwszego administratora LimeSurvey:' 'E-mail address of the first LimeSurvey administrator:')" \
      "$ae" valid_email "$bad_email"
    local au; au=$(get_env ADMIN_USER)
    ask C_ADMIN_USER "$(t 'Login pierwszego administratora:' 'Login of the first administrator:')" \
      "${au:-admin}" valid_user "$(t 'Login może zawierać litery, cyfry oraz . _ - (do 64 znaków).' 'The login may contain letters, digits and . _ - (up to 64 characters).')"
  else
    C_ADMIN_EMAIL=$(get_env ADMIN_EMAIL); C_ADMIN_USER=$(get_env ADMIN_USER)
  fi

  # --- Time zone ---
  local tz; tz=$(get_env TZ)
  [ -n "$tz" ] || tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  tz=${tz:-UTC}
  ask C_TZ "$(t 'Strefa czasowa (godzina backupu, daty w LimeSurvey), np. Europe/Warsaw:' 'Time zone (backup time, dates in LimeSurvey), e.g. Europe/London:')" \
    "$tz" valid_tz "$(t 'Nieznana strefa czasowa. Przykłady: Europe/Warsaw, Europe/London, UTC.' 'Unknown time zone. Examples: Europe/London, America/New_York, UTC.')"

  # --- Admin panel access ---
  local cur me choice def=all
  cur=$(get_env ADMIN_ALLOW_CIDRS)
  [ -n "$cur" ] && [ "$cur" != '0.0.0.0/0,::/0' ] && def=custom
  me=$(ssh_client_ip)
  local -a opts=(all "$(t 'Z dowolnego adresu (domyślnie)' 'From any address (default)')")
  [ -n "$me" ] && opts+=(me "$(t "Tylko z mojego adresu ($me)" "Only from my address ($me)")")
  opts+=(custom "$(t 'Z wybranych adresów lub sieci' 'From selected addresses or networks')")
  choice=$(ui_menu "$(t 'Skąd można otwierać panel administracyjny i logowanie?

Ankiety są zawsze publiczne. Ograniczenie działa na poziomie Traefika, przed LimeSurvey.' 'Where can the admin panel and login be opened from?

Surveys are always public. The restriction is enforced by Traefik, in front of LimeSurvey.')" \
    "$def" "${opts[@]}") || abort
  case "$choice" in
    all) C_CIDRS='0.0.0.0/0,::/0' ;;
    me)  C_CIDRS=$(normalize_cidrs "$me") ;;
    custom)
      local v="$cur"; [ "$v" = '0.0.0.0/0,::/0' ] && v=${me:-}
      while :; do
        v=$(ui_input "$(t 'Adresy IP lub sieci oddzielone przecinkami, np.:
203.0.113.10, 198.51.100.0/24

Uwaga: spoza tej listy nie zalogujesz się do panelu. Listę zmienisz później w tym menu (z SSH).' 'IP addresses or networks separated by commas, e.g.:
203.0.113.10, 198.51.100.0/24

Note: you cannot log in to the panel from outside this list. You can change it later in this menu (over SSH).')" "$v") || abort
        C_CIDRS=$(normalize_cidrs "$v") && break
        ui_msg "$(t 'Niepoprawny adres lub sieć. Użyj formatu 203.0.113.10 lub 198.51.100.0/24.' 'Invalid address or network. Use the format 203.0.113.10 or 198.51.100.0/24.')"
      done ;;
  esac

  # --- Backups ---
  local bt bk
  bt=$(get_env BACKUP_TIME); bk=$(get_env BACKUP_KEEP_DAYS)
  ask C_BACKUP_TIME "$(t 'Godzina codziennego backupu (GG:MM):' 'Daily backup time (HH:MM):')" "${bt:-03:15}" valid_time \
    "$(t 'Podaj godzinę w formacie GG:MM, np. 03:15.' 'Enter the time as HH:MM, e.g. 03:15.')"
  ask C_BACKUP_KEEP "$(t 'Ile dni przechowywać kopie zapasowe na serwerze?' 'How many days should backups be kept on the server?')" "${bk:-14}" \
    valid_days "$(t 'Podaj liczbę dni od 1 do 3650.' 'Enter a number of days from 1 to 3650.')"

  # --- Certificates ---
  local cadef=prod; [ "$(get_env ACME_CA_SERVER)" = "$STAGING_CA" ] && cadef=staging
  C_CA=$(ui_menu "$(t 'Certyfikaty TLS:' 'TLS certificates:')" "$cadef" \
    prod    "$(t "Let's Encrypt — produkcyjne" "Let's Encrypt — production")" \
    staging "$(t "Let's Encrypt — testowe (przeglądarka pokaże ostrzeżenie)" "Let's Encrypt — staging (browsers will show a warning)")") || abort

  # --- Firewall ---
  C_FIREWALL=0
  if [ "$mode" = first ] || ! ufw status 2>/dev/null | grep -q 'Status: active'; then
    local sp; sp=$(ssh_ports | sed 's/ $//; s/ /, /g')
    ui_yesno "$(t "Włączyć zaporę ufw?

Zostaną otwarte tylko porty: SSH ($sp), 80 i 443. Pozostały ruch przychodzący będzie blokowany." "Enable the ufw firewall?

Only these ports will be open: SSH ($sp), 80 and 443. All other incoming traffic will be blocked.")" && C_FIREWALL=1
  fi

  # --- Summary ---
  local fw acc ca admin_line action
  fw=$(t 'bez zmian' 'unchanged'); [ "$C_FIREWALL" -eq 1 ] && fw=$(t 'włączona (SSH, 80, 443)' 'enabled (SSH, 80, 443)')
  acc=$(t 'z dowolnego adresu' 'from any address'); [ "$C_CIDRS" != '0.0.0.0/0,::/0' ] && acc=$C_CIDRS
  ca=$(t 'produkcyjne' 'production'); [ "$C_CA" = staging ] && ca=$(t 'testowe (staging)' 'staging (test)')
  admin_line="  $(t 'Administrator:    ' 'Administrator:    ') $C_ADMIN_USER <$C_ADMIN_EMAIL>"
  [ "$installed" -eq 1 ] && admin_line="  $(t 'Administrator:     bez zmian (zmienia się w panelu LimeSurvey)' 'Administrator:     unchanged (managed in the LimeSurvey panel)')"
  if [ "$installed" -eq 1 ]; then action=$(t 'zastosować zmiany' 'apply the changes'); else action=$(t 'zainstalować' 'install'); fi
  if [ "$L" = pl ]; then
    ui_yesno "Podsumowanie

  Adres ankiet:      https://$C_DOMAIN/
  Panel:             https://$C_DOMAIN/index.php/admin
$admin_line
  Let's Encrypt:     $C_ACME, certyfikaty $ca
  Dostęp do panelu:  $acc
  Strefa czasowa:    $C_TZ
  Backup:            codziennie o $C_BACKUP_TIME, przez $C_BACKUP_KEEP dni
  Zapora ufw:        $fw

Zapisać i $action?" || abort
  else
    ui_yesno "Summary

  Survey address:    https://$C_DOMAIN/
  Admin panel:       https://$C_DOMAIN/index.php/admin
$admin_line
  Let's Encrypt:     $C_ACME, $ca certificates
  Panel access:      $acc
  Time zone:         $C_TZ
  Backup:            daily at $C_BACKUP_TIME, kept for $C_BACKUP_KEEP days
  ufw firewall:      $fw

Save and $action?" || abort
  fi
}

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
    info "$(t 'Zmiana urzędu certyfikacji: usuwam zapisane certyfikaty' 'Certificate authority changed: deleting stored certificates')"
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
      info "$(t 'Wygenerowano' 'Generated') secrets/$name"
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
  info "$(t 'Konfiguracja ufw' 'Configuring ufw')"
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
  info "$(t 'Budowanie i uruchamianie (pierwsze budowanie trwa kilka minut)' 'Building and starting (the first build takes a few minutes)')"
  docker compose build --pull
  if ! docker compose up -d --remove-orphans --wait --wait-timeout 600; then
    ps_table
    docker compose logs --tail=80 limesurvey db traefik
    die "$(t 'Stack nie osiągnął stanu healthy. Logi powyżej.' 'The stack did not become healthy. See the logs above.')"
  fi
  ps_table
}

summary_text() {
  local d; d=$(get_env LS_DOMAIN)
  if [ "$L" = pl ]; then
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
  else
    cat <<EOF
LimeSurvey is running.

  Surveys:   https://$d/
  Panel:     https://$d/index.php/admin
  Login:     $(get_env ADMIN_USER)
  Password:  sudo cat $(pwd)/secrets/admin_password

Change the password after your first login. The secrets/admin_password file is
used only on the first start (do not delete it; you may overwrite it with random
characters).

Backup: daily at $(get_env BACKUP_TIME) to $(pwd)/backups.
Copy this directory off the server.

Management menu: sudo $(pwd)/install.sh
EOF
  fi
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
  if [ "$L" = pl ]; then
    ui_msg "$(ps_table)

Adres:    https://$(get_env LS_DOMAIN)/
Wersja:   LimeSurvey $(get_env LIMESURVEY_VERSION)
Backupy:  $count${last:+, ostatni $(backup_label "$last")}
Dysk:     $(df -h . | awk 'NR==2{print $4" wolne z "$2}')"
  else
    ui_msg "$(ps_table)

Address:  https://$(get_env LS_DOMAIN)/
Version:  LimeSurvey $(get_env LIMESURVEY_VERSION)
Backups:  $count${last:+, latest $(backup_label "$last")}
Disk:     $(df -h . | awk 'NR==2{print $4" free of "$2}')"
  fi
}

act_backup() {
  console "$(t 'Backup na żądanie' 'On-demand backup')"
  if docker compose exec -T backup /bin/bash /opt/backup/backup.sh now; then
    info "$(t 'Backup gotowy.' 'Backup complete.')"
  else
    warn "$(t 'Backup się nie udał. Sprawdź komunikaty powyżej.' 'Backup failed. Check the messages above.')"
  fi
  pause
}

act_restore() {
  local -a items=(); local d label
  while read -r d; do
    [ -n "$d" ] || continue
    items+=("$d" "$(backup_label "$d")  ($(du -sh "backups/$d" 2>/dev/null | cut -f1))")
  done < <(ls -1r backups 2>/dev/null | grep -E '^20[0-9]{6}-[0-9]{6}$' || true)
  if [ "${#items[@]}" -eq 0 ]; then ui_msg "$(t 'Brak kopii w katalogu backups/.' 'No backups in the backups/ directory.')"; return; fi
  d=$(ui_menu "$(t 'Którą kopię odtworzyć? (najnowsze na górze)' 'Which backup should be restored? (newest first)')" "${items[0]}" "${items[@]}") || return 0
  label=$(backup_label "$d")
  ui_yesno "$(t "Odtworzenie kopii z $label ZASTĄPI obecną bazę, pliki i klucze szyfrowania.

Wszystko, co zmieniono po $label, zostanie utracone.

Najpierw zrobić kopię obecnego stanu?" "Restoring the backup from $label will REPLACE the current database, files and encryption keys.

Everything changed after $label will be lost.

Back up the current state first?")" && act_backup_quiet
  ui_yesno "$(t "Na pewno odtworzyć kopię z $label?" "Really restore the backup from $label?")" no || return 0
  console "$(t 'Odtwarzanie' 'Restoring') $d"
  RESTORE_CONFIRMED=1 ./scripts/restore.sh "backups/$d" || warn "$(t 'Odtwarzanie się nie udało.' 'Restore failed.')"
  pause
}
backup_label() {
  if [ "$L" = pl ]; then
    echo "$1" | sed -E 's/^(....)(..)(..)-(..)(..)(..)$/\3.\2.\1  \4:\5:\6/'
  else
    echo "$1" | sed -E 's/^(....)(..)(..)-(..)(..)(..)$/\1-\2-\3  \4:\5:\6/'
  fi
}
act_backup_quiet() {
  console "$(t 'Kopia obecnego stanu przed odtworzeniem' 'Backing up the current state first')"
  docker compose exec -T backup /bin/bash /opt/backup/backup.sh now \
    || die "$(t 'Backup się nie udał, przerywam.' 'Backup failed, aborting.')"
}

act_logs() {
  local svc f
  svc=$(ui_menu "$(t 'Logi której usługi?' 'Logs of which service?')" limesurvey \
    limesurvey 'LimeSurvey (Apache/PHP)' \
    traefik    "$(t 'Traefik (dostęp, certyfikaty)' 'Traefik (access, certificates)')" \
    db         'MariaDB' \
    backup     'Backup') || return 0
  f=$(tmpfile)
  docker compose logs --no-color --tail=300 "$svc" > "$f" 2>&1 || true
  ui_textfile "$(t "Logi: $svc (ostatnie 300 linii)" "Logs: $svc (last 300 lines)")" "$f"
}

act_password() {
  ui_msg "$(t "Początkowe hasło administratora ($(get_env ADMIN_USER)):" "Initial administrator password ($(get_env ADMIN_USER)):")

    $(cat secrets/admin_password)

$(t 'Działa, dopóki nie zmienisz go w panelu LimeSurvey.' 'It works until you change it in the LimeSurvey panel.')"
}

act_reconfigure() {
  # Subshell: "Cancel" inside the wizard returns to the menu instead of exiting.
  local f; f=$(tmpfile)
  ( wizard reconfigure
    declare -p C_DOMAIN C_ACME C_ADMIN_EMAIL C_ADMIN_USER C_TZ C_CIDRS \
      C_BACKUP_TIME C_BACKUP_KEEP C_CA C_FIREWALL > "$f" ) || return 0
  # shellcheck disable=SC1090
  . "$f"
  apply_config
  ensure_secrets
  console "$(t 'Stosowanie zmian' 'Applying changes')"
  configure_firewall
  docker compose up -d --remove-orphans --wait --wait-timeout 600 \
    || warn "$(t 'Nie wszystkie usługi są healthy.' 'Not all services are healthy.')"
  ps_table
  pause
}

latest_ls_tag() {
  curl -fsS --max-time 10 'https://api.github.com/repos/LimeSurvey/LimeSurvey/tags?per_page=100' 2>/dev/null \
    | grep -o '"name": *"[0-9]*\.[0-9]*\.[0-9]*+[0-9]*"' | cut -d'"' -f4 | sort -V | tail -1 || true
}

act_update() {
  local what
  what=$(ui_menu "$(t 'Co zaktualizować?' 'What should be updated?')" images \
    images "$(t 'Traefik, MariaDB i system bazowy obrazu (ta sama wersja LimeSurvey)' 'Traefik, MariaDB and the base image (same LimeSurvey version)')" \
    ls     "$(t 'LimeSurvey do nowej wersji' 'LimeSurvey to a new version')") || return 0
  case "$what" in
    images)
      ui_yesno "$(t 'Pobrać nowe obrazy, przebudować LimeSurvey i zrestartować usługi?

Strona będzie niedostępna przez kilkadziesiąt sekund.' 'Pull new images, rebuild LimeSurvey and restart the services?

The site will be unavailable for up to a minute or so.')" || return 0
      console "$(t 'Aktualizacja obrazów' 'Updating images')"
      docker compose pull traefik socket-proxy db backup
      start_stack
      pause ;;
    ls)
      local cur latest tag sha f
      cur=$(get_env LIMESURVEY_VERSION)
      latest=$(latest_ls_tag)
      tag=$(ui_input "$(t "Obecna wersja: $cur
Najnowsza na GitHubie: ${latest:-nie udało się sprawdzić}

Podaj tag wersji (z https://github.com/LimeSurvey/LimeSurvey/tags):" "Current version: $cur
Latest on GitHub: ${latest:-could not check}

Enter the version tag (from https://github.com/LimeSurvey/LimeSurvey/tags):")" "${latest:-$cur}") || return 0
      [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?$ ]] || { ui_msg "$(t 'Niepoprawny tag' 'Invalid tag'): $tag"; return 0; }
      [ "$tag" = "$cur" ] && { ui_msg "$(t 'To jest obecna wersja.' 'This is the current version.')"; return 0; }
      if [ "$(printf '%s\n%s\n' "$cur" "$tag" | sort -V | head -1)" = "$tag" ]; then
        ui_msg "$(t "Wersja $tag jest starsza niż $cur. Obniżenie wersji uszkodziłoby schemat bazy, więc nie jest obsługiwane." "Version $tag is older than $cur. A downgrade would break the database schema, so it is not supported.")"
        return 0
      fi
      console "$(t 'Pobieranie' 'Downloading') LimeSurvey $tag"
      f=$(tmpfile)
      curl -fL --progress-bar -o "$f" "https://github.com/LimeSurvey/LimeSurvey/archive/refs/tags/${tag}.tar.gz" \
        || { warn "$(t 'Nie udało się pobrać tej wersji.' 'Could not download this version.')"; pause; return 0; }
      sha=$(sha256sum "$f" | cut -d' ' -f1)
      ui_yesno "LimeSurvey $cur → $tag
SHA-256: $sha

$(t 'Przed aktualizacją zostanie zrobiony backup. Migracja bazy wykona się automatycznie przy starcie. Kontynuować?' 'A backup is made before the update. The database is migrated automatically on start. Continue?')" || return 0
      act_backup_quiet
      set_env LIMESURVEY_VERSION "$tag"
      set_env LIMESURVEY_SHA256 "$sha"
      start_stack
      pause ;;
  esac
}

act_restart() {
  ui_yesno "$(t 'Zrestartować wszystkie usługi?' 'Restart all services?')" || return 0
  console 'Restart'
  docker compose restart
  docker compose up -d --wait --wait-timeout 300 || warn "$(t 'Nie wszystkie usługi są healthy.' 'Not all services are healthy.')"
  pause
}

act_language() {
  local new
  new=$(ui_menu 'Language / Język' "$L" en 'English' pl 'Polski') || return 0
  L=$new
  set_env INSTALLER_LANG "$L"
}

management_menu() {
  local choice=status
  while :; do
    TITLE="LimeSurvey — $(get_env LS_DOMAIN)"
    choice=$(CANCEL="$(t 'Wyjście' 'Exit')" ui_menu "$(t 'Zarządzanie stackiem:' 'Stack management:')" "$choice" \
      status   "$(t 'Stan usług' 'Service status')" \
      backup   "$(t 'Zrób backup teraz' 'Back up now')" \
      restore  "$(t 'Odtwórz backup' 'Restore a backup')" \
      logs     "$(t 'Logi' 'Logs')" \
      config   "$(t 'Zmień konfigurację (domena, dostęp do panelu, backup…)' 'Change configuration (domain, panel access, backup…)')" \
      update   "$(t 'Aktualizacja' 'Update')" \
      restart  "$(t 'Restart usług' 'Restart services')" \
      password "$(t 'Pokaż początkowe hasło administratora' 'Show the initial administrator password')" \
      language 'Language / Język' \
      quit     "$(t 'Wyjście' 'Exit')") || break
    case "$choice" in
      status) act_status ;; backup) act_backup ;; restore) act_restore ;;
      logs) act_logs ;; config) act_reconfigure ;; update) act_update ;;
      restart) act_restart ;; password) act_password ;; language) act_language ;;
      quit) break ;;
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
    warn "$(t "Porty zajęte na hoście: $busy. Traefik potrzebuje 80 i 443." "Ports in use on the host: $busy. Traefik needs 80 and 443.")"
  else
    ui_yesno "$(t "Porty $busy są zajęte przez inny program na tym serwerze. Traefik potrzebuje portów 80 i 443.

Zatrzymaj tamten program (np. apache2 lub nginx). Kontynuować mimo to?" "Ports $busy are used by another program on this server. Traefik needs ports 80 and 443.

Stop that program (e.g. apache2 or nginx). Continue anyway?")" no || abort
  fi
fi

# ---- Non-interactive ----
if [ "$YES" -eq 1 ]; then
  ensure_env_file
  for key in LS_DOMAIN ACME_EMAIL ADMIN_EMAIL; do
    val=${!key:-}
    [ -n "$val" ] || val=$(current_or_empty "$key")
    [ -n "$val" ] || die "$(t "$key jest wymagane (w .env lub w zmiennej środowiskowej)." "$key is required (in .env or as an environment variable).")"
    set_env "$key" "$val"
  done
  valid_domain "$(get_env LS_DOMAIN)" || die "$(t "LS_DOMAIN '$(get_env LS_DOMAIN)' nie jest poprawną domeną." "LS_DOMAIN '$(get_env LS_DOMAIN)' is not a valid domain.")"
  d=$(get_env LS_DOMAIN); ip=$(public_ip); dip=$(dns_ip "$d")
  if [ -z "$dip" ]; then warn "$(t "$d jeszcze się nie rozwiązuje. Certyfikat zostanie wydany, gdy DNS wskaże ten serwer." "$d does not resolve yet. The certificate will be issued once DNS points at this server.")"
  elif [ -n "$ip" ] && [ "$dip" != "$ip" ]; then warn "$(t "$d wskazuje na $dip, ten serwer to $ip." "$d points at $dip, this server is $ip.")"; fi
  ensure_secrets
  configure_firewall
  [ "$START" -eq 1 ] || { info "$(t 'Gotowe. Uruchom: docker compose up -d --build' 'Done. Start with: docker compose up -d --build')"; exit 0; }
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
console "$(t 'Instalacja' 'Installation')"
configure_firewall
[ "$START" -eq 1 ] || { info "$(t 'Gotowe. Uruchom: docker compose up -d --build' 'Done. Start with: docker compose up -d --build')"; exit 0; }
start_stack
if [ "$TUI" -eq 1 ]; then
  read -r -p $'\n'"$(t 'Enter, aby zobaczyć podsumowanie… ' 'Press Enter to see the summary… ')" _ || true
  ui_msg "$(summary_text)"
  ui_yesno "$(t 'Pokazać teraz początkowe hasło administratora?' 'Show the initial administrator password now?')" no && act_password
  clear
fi
summary_text
