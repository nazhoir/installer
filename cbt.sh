#!/bin/bash

# ==========================================
# REKOMENDASI EKSEKUSI ANTI-DISCONNECT
# apt install tmux -y && tmux new -s cbt
# ==========================================

if [ "$EUID" -ne 0 ]; then
  echo "Jalankan script ini sebagai root (gunakan sudo)."
  exit 1
fi

# ==========================================
# GLOBAL MAINTENANCE VARIABLES
# ==========================================
readonly APP_DOWNLOAD_URL="https://s3.ekstraordinary.com/extraordinarycbt/release-rosetta/4.6.3-linux+1.zip"
readonly APP_DIR="/var/www/cbt"
readonly APP_BINARY_AMD64="main-amd64"
readonly APP_BINARY_ARM64="main-arm64"
readonly APP_DUMP_SQL="exo-dump-master.sql"
readonly APP_UPDATE_SQL="update_dari_4.5.0_execute_ini.sql"

readonly STATE_FILE="/opt/.cbt_install_state"
readonly CRED_FILE="/root/cbt_credentials.txt"
readonly SYSTEMD_SERVICE="cbt.service"
readonly SYSTEMD_IDENTIFIER="cbt"
readonly NGINX_CONF_PATH="/etc/nginx/sites-available/cbt"
readonly NGINX_LINK_PATH="/etc/nginx/sites-enabled/cbt"
readonly CF_CONF_PATH="/etc/nginx/conf.d/cloudflare.conf"

# ==========================================
# STRICT MODE & TRAP SETUP
# ==========================================
set -uE
trap 'echo "[FATAL] Skrip terhenti karena error pada baris $LINENO. Silakan periksa pesan error di atas."; exit 1' ERR
trap "" HUP PIPE

die() { echo "[FATAL] $*"; exit 1; }
log_info()    { echo "[$(date '+%H:%M:%S')] [INFO]    $*"; }
log_ok()      { echo "[$(date '+%H:%M:%S')] [OK]      $*"; }
log_warn()    { echo "[$(date '+%H:%M:%S')] [WARN]    $*"; }
log_error()   { echo "[$(date '+%H:%M:%S')] [ERROR]   $*"; }
log_skip()    { echo "[$(date '+%H:%M:%S')] [SKIPPED] $*"; }
log_running() { echo "[$(date '+%H:%M:%S')] [RUNNING] $*"; }

# ==========================================
# HELPER: Deteksi dukungan IPv6 kernel
# ==========================================
kernel_has_ipv6() {
    [ -d /proc/sys/net/ipv6 ]
}

# ==========================================
# HELPER: Bersihkan SEMUA config nginx lama
# dan tulis ulang default site IPv4-only
# ==========================================
reset_nginx_configs() {
    log_info "Membersihkan seluruh konfigurasi Nginx lama..."

    # Stop nginx dulu agar tidak ada file yang terkunci
    systemctl stop nginx 2>/dev/null || true

    # Hapus semua sites
    rm -f /etc/nginx/sites-enabled/*
    rm -f /etc/nginx/sites-available/*

    # Hapus conf.d yang mungkin berisi IPv6
    rm -f /etc/nginx/conf.d/*.conf

    # Tulis ulang default site IPv4-only
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    cat > /etc/nginx/sites-available/default <<'NGINXEOF'
server {
    listen 80 default_server;
    root /var/www/html;
    index index.html index.htm;
    server_name _;
    location / {
        try_files $uri $uri/ =404;
    }
}
NGINXEOF

    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

    log_ok "Konfigurasi Nginx direset ke default IPv4-only."
}

# ==========================================
# HELPER: Patch sisa directive [::] jika masih ada
# ==========================================
patch_nginx_ipv6() {
    if kernel_has_ipv6; then
        return
    fi
    log_info "Memastikan tidak ada directive IPv6 tersisa di config Nginx..."
    find /etc/nginx -type f -name "*.conf" 2>/dev/null | while read -r f; do
        sed -i '/listen \[::\]/d' "$f"
    done
    find /etc/nginx/sites-available /etc/nginx/sites-enabled -type f 2>/dev/null | while read -r f; do
        sed -i '/listen \[::\]/d' "$f"
    done
    log_ok "Patch IPv6 selesai."
}

# ==========================================
# 0. PENGECEKAN SPESIFIKASI SERVER
# ==========================================
check_server_specs() {
    echo "==================================================="
    echo " Melakukan Pengecekan Spesifikasi Server..."
    echo "==================================================="
    local fail=0

    local cpu_cores
    cpu_cores=$(nproc)
    if [ "$cpu_cores" -lt 1 ]; then
        log_error "CPU Cores: $cpu_cores (Minimal 1 Core)"
        fail=1
    else
        log_ok "CPU Cores : $cpu_cores"
    fi

    local total_mem
    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$total_mem" -lt 900 ]; then
        log_error "RAM Total: ${total_mem}MB (Minimal 1024MB / 1GB)"
        fail=1
    else
        log_ok "RAM Total : ${total_mem}MB"
    fi

    local disk_free
    disk_free=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "$disk_free" -lt 10 ]; then
        log_error "Disk Kosong (/): ${disk_free}GB (Minimal sisa 10GB)"
        fail=1
    else
        log_ok "Disk Kosong : ${disk_free}GB (/)"
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        local os_name=$ID
        local os_version="${VERSION_ID:-0}"
        local os_valid=0

        if [ "$os_name" = "ubuntu" ]; then
            local ubuntu_major
            ubuntu_major=$(echo "$os_version" | cut -d'.' -f1)
            if [ "$ubuntu_major" -ge 22 ] && [ "$ubuntu_major" -le 24 ]; then
                os_valid=1
            fi
        elif [ "$os_name" = "debian" ]; then
            local debian_major
            debian_major=$(echo "$os_version" | cut -d'.' -f1)
            if [ "$debian_major" -eq 11 ] || [ "$debian_major" -eq 12 ]; then
                os_valid=1
            fi
        fi

        if [ "$os_valid" -eq 0 ]; then
            log_error "OS: $PRETTY_NAME tidak didukung."
            echo "        Syarat OS: Ubuntu (22-24) atau Debian (11-12)"
            fail=1
        else
            log_ok "OS Server : $PRETTY_NAME"
        fi
    else
        log_error "Tidak dapat mendeteksi OS. Harap gunakan Ubuntu/Debian."
        fail=1
    fi

    if [ "$fail" -eq 1 ]; then
        echo "==================================================="
        die "Spesifikasi server tidak memenuhi syarat minimal! Silakan upgrade server Anda."
    fi
    echo "==================================================="
}
check_server_specs

# ==========================================
# 1. KONFIGURASI DEFAULT & VARIABEL UMUM
# ==========================================
AUTO_MODE="false"
SIMPLE_MODE="ASK"

SERVER_SECRET_LICENSE_KEY=""
INSTALL_POSTGRES="yes"
REINSTALL_POSTGRES="no"
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="cbt_db"
DB_USER="cbt_user"
DB_PASS="AUTO"
SETUP_DOMAIN="no"
DOMAIN_NAME=""
LETSENCRYPT_EMAIL=""
APP_PORT="9988"
BLOCK_DIRECT_IP="yes"

# ==========================================
# VARIABEL LANJUTAN (ENV APLIKASI)
# ==========================================
SERVER_WS_ACTIVE="true"
SERVER_ASSET_URL=""
SERVER_ASSET_CACHE_TIME_SECOND="3600"
SERVER_CACHE_IN_EXAM_ENABLE="false"
SERVER_LOG_REQ_ACTIVE="true"
SERVER_WRITE_BUFFER_SIZE="50096"
SECURITY_RATE_LIMIT_ACTIVE="false"
SECURITY_RATE_LIMIT_MAX="60"
SECURITY_RATE_LIMIT_EXP="15"
GOOGLE_DOC_ACTIVE="false"
GOOGLE_CREDENTIAL=""
OPEN_AI_MODEL="gpt-4o-mini"
OPEN_AI_ACTIVE="false"
OPEN_AI_ACCESS_KEY=""

# ==========================================
# 2. PARSING ARGUMEN CLI
# ==========================================
while [ $# -gt 0 ]; do
  case "$1" in
    --auto=*) AUTO_MODE="${1#*=}" ;;
    --simple=*) SIMPLE_MODE="${1#*=}" ;;
    --license=*) SERVER_SECRET_LICENSE_KEY="${1#*=}" ;;
    --no-db) INSTALL_POSTGRES="no" ;;
    --db-host=*) DB_HOST="${1#*=}" ;;
    --db-port=*) DB_PORT="${1#*=}" ;;
    --db-name=*) DB_NAME="${1#*=}" ;;
    --db-user=*) DB_USER="${1#*=}" ;;
    --db-pass=*) DB_PASS="${1#*=}" ;;
    --app-port=*) APP_PORT="${1#*=}" ;;
    --domain=*) DOMAIN_NAME="${1#*=}"; SETUP_DOMAIN="yes" ;;
    --email=*) LETSENCRYPT_EMAIL="${1#*=}" ;;
    --block-ip=*) BLOCK_DIRECT_IP="${1#*=}" ;;
    --ws-active=*) SERVER_WS_ACTIVE="${1#*=}" ;;
    --asset-url=*) SERVER_ASSET_URL="${1#*=}" ;;
    --asset-cache=*) SERVER_ASSET_CACHE_TIME_SECOND="${1#*=}" ;;
    --cache-exam=*) SERVER_CACHE_IN_EXAM_ENABLE="${1#*=}" ;;
    --log-req=*) SERVER_LOG_REQ_ACTIVE="${1#*=}" ;;
    --write-buffer=*) SERVER_WRITE_BUFFER_SIZE="${1#*=}" ;;
    --rate-limit-active=*) SECURITY_RATE_LIMIT_ACTIVE="${1#*=}" ;;
    --rate-limit-max=*) SECURITY_RATE_LIMIT_MAX="${1#*=}" ;;
    --rate-limit-exp=*) SECURITY_RATE_LIMIT_EXP="${1#*=}" ;;
    --gdoc-active=*) GOOGLE_DOC_ACTIVE="${1#*=}" ;;
    --gdoc-cred=*) GOOGLE_CREDENTIAL="${1#*=}" ;;
    --ai-active=*) OPEN_AI_ACTIVE="${1#*=}" ;;
    --ai-model=*) OPEN_AI_MODEL="${1#*=}" ;;
    --ai-key=*) OPEN_AI_ACCESS_KEY="${1#*=}" ;;
    --help)
      echo "Penggunaan: $0 [opsi...]"
      echo "  --auto=true/false             Jalankan tanpa wizard interaktif"
      echo "  --simple=true/false           Sembunyikan pertanyaan ENV tingkat lanjut"
      echo "  --license=KODE_LISENSI        Set license key"
      echo "  --domain=domain.com           Set domain dan aktifkan Nginx Proxy"
      echo "  --email=admin@domain.com      Email Let's Encrypt"
      echo "  --block-ip=yes/no             Blokir akses IP Publik jika domain aktif"
      exit 0
      ;;
    *) die "Argumen tidak dikenal: '$1'. Gunakan --help untuk bantuan." ;;
  esac
  shift
done

validate_domain_format() {
    local domain="$1"
    if [[ ! "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        die "Format domain tidak valid: '$domain'. Contoh: cbt.sekolah.com"
    fi
}

# ==========================================
# 3. DETEKSI INSTALASI EKSISTING & LISENSI
# ==========================================
check_existing_installation() {
    if [ -d "$APP_DIR" ] || [ -f "$STATE_FILE" ]; then
        local existing_license=""
        if [ -f "$APP_DIR/.env" ]; then
            existing_license=$(grep "^SERVER_SECRET_LICENSE_KEY=" "$APP_DIR/.env" | cut -d'=' -f2- | tr -d '"')
        fi

        echo "==================================================="
        echo "      TERDETEKSI INSTALASI SEBELUMNYA              "
        echo "==================================================="
        echo "Aplikasi CBT sudah terpasang di sistem ini."
        echo "[1] Install Ulang (WARNING: Seluruh file & database akan DIHAPUS!)"
        echo "[2] Perbaiki (Fix Permissions, Update Lisensi, Restart Service)"
        echo "[3] Batalkan eksekusi"
        read -p "Pilih tindakan operasional [1/2/3]: " action_choice

        case "$action_choice" in
            1)
                log_info "Mempersiapkan instalasi ulang..."
                if [ -n "$existing_license" ]; then
                    read -p "Lisensi terdeteksi ($existing_license). Gunakan kembali lisensi ini? (y/n) [y]: " use_exist
                    if [[ "${use_exist:-y}" =~ ^[Yy]$ ]]; then
                        SERVER_SECRET_LICENSE_KEY="$existing_license"
                        log_ok "Lisensi akan dipertahankan untuk instalasi baru."
                    fi
                fi

                log_info "Mereset instalasi eksisting..."
                systemctl stop "$SYSTEMD_IDENTIFIER" 2>/dev/null || true
                systemctl disable "$SYSTEMD_IDENTIFIER" 2>/dev/null || true
                rm -f /etc/systemd/system/"$SYSTEMD_SERVICE"
                systemctl daemon-reload
                rm -rf "$APP_DIR"
                rm -f "$STATE_FILE"

                if [ "$INSTALL_POSTGRES" = "yes" ]; then
                    sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" 2>/dev/null || true
                fi
                log_ok "Reset selesai. Memulai instalasi bersih..."
                ;;
            2)
                echo "==================================================="
                log_info "Memulai proses perbaikan (Repair)..."

                if [ -f "$APP_DIR/.env" ]; then
                    if [ -z "$existing_license" ]; then
                        read -p "License Key kosong di .env. Masukkan License Key: " input_lic
                        if [ -n "$input_lic" ]; then
                            echo "SERVER_SECRET_LICENSE_KEY=\"$input_lic\"" >> "$APP_DIR/.env"
                            log_ok "Lisensi berhasil ditambahkan ke konfigurasi."
                        fi
                    else
                        read -p "Lisensi terdeteksi ($existing_license). Ingin mengubahnya? (y/n) [n]: " change_lic
                        if [[ "${change_lic:-n}" =~ ^[Yy]$ ]]; then
                            read -p "Masukkan License Key Baru: " input_lic
                            if [ -n "$input_lic" ]; then
                                sed -i "s/^SERVER_SECRET_LICENSE_KEY=.*/SERVER_SECRET_LICENSE_KEY=\"$input_lic\"/" "$APP_DIR/.env"
                                log_ok "Lisensi berhasil diperbarui."
                            fi
                        fi
                    fi
                fi

                if [ -d "$APP_DIR" ]; then
                    mkdir -p "$APP_DIR/storage"
                    chown -R www-data:www-data "$APP_DIR"
                    chmod -R 775 "$APP_DIR/storage"
                    chmod 600 "$APP_DIR/.env" 2>/dev/null || true
                    log_ok "Hak akses direktori & file .env dikembalikan."
                fi

                local arch
                arch=$(uname -m)
                local binary_file="$APP_BINARY_AMD64"
                if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
                    binary_file="$APP_BINARY_ARM64"
                fi

                if [ ! -f "$APP_DIR/$binary_file" ]; then
                    log_warn "Binary eksekusi tidak ditemukan. Menarik ulang..."
                    wget --timeout=120 --tries=3 --progress=bar:force \
                        -O /tmp/cbt-linux.zip "$APP_DOWNLOAD_URL" \
                        || die "Gagal mengunduh binary aplikasi dari $APP_DOWNLOAD_URL."
                    unzip -o -q /tmp/cbt-linux.zip -d "$APP_DIR/" \
                        || die "Gagal mengekstrak arsip aplikasi."
                    rm -f /tmp/cbt-linux.zip
                    chown -R www-data:www-data "$APP_DIR"
                fi

                chmod +x "$APP_DIR/$binary_file"
                log_ok "Integritas binary divalidasi."

                reset_nginx_configs
                patch_nginx_ipv6

                if [ -f "/etc/systemd/system/$SYSTEMD_SERVICE" ]; then
                    systemctl daemon-reload
                    systemctl restart "$SYSTEMD_IDENTIFIER"
                    log_ok "Service CBT di-restart secara paksa."
                fi

                echo "==================================================="
                log_ok "Perbaikan Selesai. Cek status: sudo systemctl status $SYSTEMD_IDENTIFIER"
                exit 0
                ;;
            *)
                log_info "Operasi dibatalkan oleh pengguna."
                exit 0
                ;;
        esac
    fi
}
check_existing_installation

# ==========================================
# 4. WIZARD INTERAKTIF
# ==========================================
run_interactive_wizard() {
    echo "==================================================="
    echo " KONFIGURASI INSTALASI CBT"
    echo " (Tekan ENTER untuk menggunakan nilai di dalam [ ])"
    echo "==================================================="

    if [ -z "$SERVER_SECRET_LICENSE_KEY" ]; then
        while true; do
            read -p "License Key (Wajib): " input_license
            if [ -n "$input_license" ]; then
                SERVER_SECRET_LICENSE_KEY="$input_license"
                break
            fi
            echo " -> License Key tidak boleh kosong!"
        done
    fi

    read -p "Setup Nginx Reverse Proxy & SSL (Domain)? (y/n) [n]: " input_setup_domain
    if [[ "${input_setup_domain:-n}" =~ ^[Yy]$ ]]; then
        SETUP_DOMAIN="yes"
        while true; do
            read -p "  -> Nama Domain (contoh: cbt.sekolah.com): " input_domain
            DOMAIN_NAME="${input_domain:-$DOMAIN_NAME}"
            if [ -n "$DOMAIN_NAME" ]; then
                if [[ "$DOMAIN_NAME" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                    break
                else
                    echo "  -> Format domain tidak valid. Contoh: cbt.sekolah.com"
                    DOMAIN_NAME=""
                fi
            else
                echo "  -> Domain wajib diisi jika fitur aktif!"
            fi
        done

        local default_email="admin@$DOMAIN_NAME"
        read -p "  -> Email Let's Encrypt [$default_email]: " input_email
        LETSENCRYPT_EMAIL="${input_email:-$default_email}"

        read -p "  -> Blokir akses langsung via IP Publik? (y/n) [$BLOCK_DIRECT_IP]: " input_block_ip
        if [[ "${input_block_ip:-$BLOCK_DIRECT_IP}" =~ ^[Nn]$ ]]; then
            BLOCK_DIRECT_IP="no"
        else
            BLOCK_DIRECT_IP="yes"
        fi
    else
        SETUP_DOMAIN="no"
        BLOCK_DIRECT_IP="no"
    fi

    read -p "Install PostgreSQL Lokal? (y/n) [y]: " input_install_pg
    if [[ "${input_install_pg:-y}" =~ ^[Nn]$ ]]; then
        INSTALL_POSTGRES="no"
        read -p "  -> DB Host [$DB_HOST]: " input_host; DB_HOST="${input_host:-$DB_HOST}"
        read -p "  -> DB Port [$DB_PORT]: " input_port; DB_PORT="${input_port:-$DB_PORT}"
    else
        INSTALL_POSTGRES="yes"
        if command -v psql &> /dev/null; then
            echo ""
            log_warn "PostgreSQL sudah terinstall di sistem ini."
            read -p "  -> Purge & Reinstall PostgreSQL (HAPUS SELURUH DATA)? (y/n) [n]: " input_reinstall_pg
            if [[ "${input_reinstall_pg:-n}" =~ ^[Yy]$ ]]; then
                REINSTALL_POSTGRES="yes"
            else
                REINSTALL_POSTGRES="no"
            fi
        fi
    fi

    read -p "Nama Database [$DB_NAME]: " input_dbname; DB_NAME="${input_dbname:-$DB_NAME}"
    read -p "User Database [$DB_USER]: " input_dbuser; DB_USER="${input_dbuser:-$DB_USER}"
    read -p "Password DB (Kosongkan = Auto Generate) [$DB_PASS]: " input_dbpass
    DB_PASS="${input_dbpass:-$DB_PASS}"
    [ -z "$DB_PASS" ] && DB_PASS="AUTO"

    while true; do
        read -p "Port Aplikasi CBT [$APP_PORT]: " input_appport
        APP_PORT="${input_appport:-$APP_PORT}"
        if [[ "$APP_PORT" =~ ^[0-9]+$ ]] && [ "$APP_PORT" -ge 1 ] && [ "$APP_PORT" -le 65535 ]; then
            break
        else
            echo " -> Port tidak valid! Masukkan angka antara 1-65535."
            APP_PORT="9988"
        fi
    done

    if [ "$SIMPLE_MODE" = "ASK" ]; then
        echo ""
        read -p "Gunakan konfigurasi instalasi minimal (Lewati opsi lanjutan)? (y/n) [y]: " input_simple
        if [[ "${input_simple:-y}" =~ ^[Nn]$ ]]; then
            SIMPLE_MODE="false"
        else
            SIMPLE_MODE="true"
        fi
    fi

    if [ "$SIMPLE_MODE" = "false" ]; then
        echo ""
        echo "--- KONFIGURASI LANJUTAN (ENVIRONMENT APLIKASI) ---"
        read -p "SERVER_WS_ACTIVE [$SERVER_WS_ACTIVE]: " i_var; SERVER_WS_ACTIVE="${i_var:-$SERVER_WS_ACTIVE}"
        read -p "SERVER_ASSET_URL [$SERVER_ASSET_URL]: " i_var; SERVER_ASSET_URL="${i_var:-$SERVER_ASSET_URL}"
        read -p "SERVER_ASSET_CACHE_TIME_SECOND [$SERVER_ASSET_CACHE_TIME_SECOND]: " i_var; SERVER_ASSET_CACHE_TIME_SECOND="${i_var:-$SERVER_ASSET_CACHE_TIME_SECOND}"
        read -p "SERVER_CACHE_IN_EXAM_ENABLE [$SERVER_CACHE_IN_EXAM_ENABLE]: " i_var; SERVER_CACHE_IN_EXAM_ENABLE="${i_var:-$SERVER_CACHE_IN_EXAM_ENABLE}"
        read -p "SERVER_LOG_REQ_ACTIVE [$SERVER_LOG_REQ_ACTIVE]: " i_var; SERVER_LOG_REQ_ACTIVE="${i_var:-$SERVER_LOG_REQ_ACTIVE}"
        read -p "SERVER_WRITE_BUFFER_SIZE [$SERVER_WRITE_BUFFER_SIZE]: " i_var; SERVER_WRITE_BUFFER_SIZE="${i_var:-$SERVER_WRITE_BUFFER_SIZE}"
        read -p "SECURITY_RATE_LIMIT_ACTIVE [$SECURITY_RATE_LIMIT_ACTIVE]: " i_var; SECURITY_RATE_LIMIT_ACTIVE="${i_var:-$SECURITY_RATE_LIMIT_ACTIVE}"
        read -p "SECURITY_RATE_LIMIT_MAX [$SECURITY_RATE_LIMIT_MAX]: " i_var; SECURITY_RATE_LIMIT_MAX="${i_var:-$SECURITY_RATE_LIMIT_MAX}"
        read -p "SECURITY_RATE_LIMIT_EXP [$SECURITY_RATE_LIMIT_EXP]: " i_var; SECURITY_RATE_LIMIT_EXP="${i_var:-$SECURITY_RATE_LIMIT_EXP}"
        read -p "GOOGLE_DOC_ACTIVE [$GOOGLE_DOC_ACTIVE]: " i_var; GOOGLE_DOC_ACTIVE="${i_var:-$GOOGLE_DOC_ACTIVE}"
        read -p "GOOGLE_CREDENTIAL [$GOOGLE_CREDENTIAL]: " i_var; GOOGLE_CREDENTIAL="${i_var:-$GOOGLE_CREDENTIAL}"
        read -p "OPEN_AI_ACTIVE [$OPEN_AI_ACTIVE]: " i_var; OPEN_AI_ACTIVE="${i_var:-$OPEN_AI_ACTIVE}"
        read -p "OPEN_AI_MODEL [$OPEN_AI_MODEL]: " i_var; OPEN_AI_MODEL="${i_var:-$OPEN_AI_MODEL}"
        read -p "OPEN_AI_ACCESS_KEY [$OPEN_AI_ACCESS_KEY]: " i_var; OPEN_AI_ACCESS_KEY="${i_var:-$OPEN_AI_ACCESS_KEY}"
    fi

    echo "==================================================="
    echo "Konfigurasi diterima. Memulai eksekusi..."
    echo "==================================================="
}

if [ "$AUTO_MODE" != "true" ]; then
    run_interactive_wizard
else
    [ -z "$SERVER_SECRET_LICENSE_KEY" ] && \
        die "Mode --auto=true aktif. Parameter --license=KODE_LISENSI wajib dilampirkan."
    if [ "$SETUP_DOMAIN" = "yes" ]; then
        [ -n "$DOMAIN_NAME" ] && validate_domain_format "$DOMAIN_NAME"
        [ -z "$LETSENCRYPT_EMAIL" ] && LETSENCRYPT_EMAIL="admin@$DOMAIN_NAME"
    fi
    [ "$SETUP_DOMAIN" != "yes" ] && BLOCK_DIRECT_IP="no"
    [ "$SIMPLE_MODE" = "ASK" ] && SIMPLE_MODE="true"
fi

# ==========================================
# 5. STATE MANAGEMENT
# ==========================================
touch "$STATE_FILE"

restore_credentials_if_needed() {
    if [ -f "$CRED_FILE" ] && grep -q "^DB_PASS=" "$CRED_FILE"; then
        local saved_pass
        saved_pass=$(grep "^DB_PASS=" "$CRED_FILE" | cut -d'=' -f2-)
        if [ -n "$saved_pass" ]; then
            DB_PASS="$saved_pass"
            log_info "Kredensial database dipulihkan dari $CRED_FILE"
        fi
    fi
}
restore_credentials_if_needed

execute_step() {
    local step_id="$1"
    local step_desc="$2"
    local step_func="$3"

    if grep -q "^${step_id}$" "$STATE_FILE" 2>/dev/null; then
        log_skip "$step_desc"
    else
        log_running "$step_desc..."
        "$step_func" || die "Gagal pada tahap: $step_desc"
        echo "$step_id" >> "$STATE_FILE"
        log_ok "$step_desc"
        echo "---------------------------------------------------"
    fi
}

# ==========================================
# 6. PENDEFINISIAN FUNGSI-FUNGSI TAHAPAN
# ==========================================

step_check_requirements() {
    log_info "Memeriksa perangkat lunak dan port yang digunakan..."
    if ! command -v ss &> /dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq iproute2
    fi

    if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]]; then
        die "APP_PORT '$APP_PORT' bukan angka yang valid."
    fi

    if ss -tuln 2>/dev/null | grep -q ":${APP_PORT} "; then
        die "Port $APP_PORT sudah digunakan oleh proses lain. Ganti dengan --app-port=PORT_LAIN"
    fi
    log_ok "Port $APP_PORT tersedia."

    if [ "$SETUP_DOMAIN" = "yes" ]; then
        if ss -tulnp 2>/dev/null | grep -E ":(80|443) " | grep -q "apache2"; then
            die "Terdeteksi Apache2 berjalan di port 80/443. Harap matikan/hapus Apache2 terlebih dahulu."
        fi
        if command -v nslookup &>/dev/null; then
            if ! nslookup "$DOMAIN_NAME" &>/dev/null; then
                log_warn "Domain '$DOMAIN_NAME' tidak dapat di-resolve. Pastikan DNS sudah diarahkan ke server ini."
            else
                log_ok "DNS domain '$DOMAIN_NAME' berhasil di-resolve."
            fi
        fi
    fi

    if kernel_has_ipv6; then
        log_ok "Kernel mendukung IPv6."
    else
        log_warn "Kernel TIDAK mendukung IPv6 — directive [::] akan dihapus otomatis dari Nginx."
    fi
}

step_prepare_credentials() {
    if [ -f "$CRED_FILE" ] && grep -q "^DB_PASS=" "$CRED_FILE"; then
        DB_PASS=$(grep "^DB_PASS=" "$CRED_FILE" | cut -d'=' -f2-)
        log_info "Menggunakan password database yang sudah tersimpan."
        return
    fi

    if [ "$DB_PASS" = "AUTO" ] || [ -z "$DB_PASS" ]; then
        DB_PASS=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 24)
    fi

    {
        echo "# CBT Credentials - Generated: $(date)"
        echo "DB_HOST=$DB_HOST"
        echo "DB_PORT=$DB_PORT"
        echo "DB_NAME=$DB_NAME"
        echo "DB_USER=$DB_USER"
        echo "DB_PASS=$DB_PASS"
    } > "$CRED_FILE"
    chmod 600 "$CRED_FILE"
    log_ok "Kredensial baru disimpan di $CRED_FILE"
}

step_update_system() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || die "Gagal update package list."
    apt-get install -y unzip wget postgresql-client openssl ca-certificates curl jq tzdata iproute2 \
        || die "Gagal install dependensi sistem."
    timedatectl set-timezone Asia/Jakarta || log_warn "Gagal set timezone, lanjutkan..."
    id -u www-data &>/dev/null || useradd -r -s /usr/sbin/nologin www-data
    log_ok "Sistem diperbarui dan dependensi terinstall."
}

# ======================================================================
# INSTALASI NGINX
# Strategi: reset semua config lama → install → patch sisa IPv6 → start
# ======================================================================
step_install_nginx_core() {
    if [ "$SETUP_DOMAIN" != "yes" ] || [ -z "$DOMAIN_NAME" ]; then
        log_info "Instalasi Nginx dilewati (SETUP_DOMAIN=no)."
        return
    fi

    export DEBIAN_FRONTEND=noninteractive

    # LANGKAH 1: Reset & bersihkan semua config nginx lama sebelum install
    # Ini mencegah dpkg mencoba start nginx dengan config IPv6 yang invalid
    reset_nginx_configs

    # LANGKAH 2: Install paket
    log_info "Menginstal Nginx dan Certbot..."
    dpkg --configure -a 2>/dev/null || true

    if ! apt-get install -y nginx certbot python3-certbot-nginx; then
        log_warn "Instalasi pertama gagal, mencoba recovery..."
        reset_nginx_configs
        dpkg --configure -a || true
        apt-get install -f -y || die "Gagal menyelesaikan instalasi Nginx."
    fi

    # LANGKAH 3: Post-install — apt bisa menulis ulang default site, reset lagi
    reset_nginx_configs

    # LANGKAH 4: Patch sisa [::] di nginx.conf utama dan conf.d
    patch_nginx_ipv6

    # LANGKAH 5: Validasi & start
    nginx -t || die "Konfigurasi Nginx tidak valid setelah reset. Periksa /etc/nginx/nginx.conf."
    systemctl enable nginx
    systemctl restart nginx || die "Gagal menjalankan Nginx setelah instalasi."
    log_ok "Nginx dan Certbot berhasil diinstal dan berjalan."
}

step_install_db() {
    if [ "$INSTALL_POSTGRES" = "yes" ]; then
        export DEBIAN_FRONTEND=noninteractive

        if [ "$REINSTALL_POSTGRES" = "yes" ]; then
            log_info "Menghapus instalasi PostgreSQL eksisting secara menyeluruh..."
            systemctl stop postgresql 2>/dev/null || true
            apt-get purge -y "postgresql*" || true
            rm -rf /etc/postgresql/ /var/lib/postgresql/ /var/log/postgresql/
            userdel -r postgres 2>/dev/null || true
            groupdel postgres 2>/dev/null || true
            log_ok "PostgreSQL berhasil dihapus."
        fi

        apt-get install -y postgresql postgresql-contrib || die "Gagal install PostgreSQL."
        systemctl enable --now postgresql || die "Gagal menjalankan service PostgreSQL."

        local max_wait=30
        local waited=0
        while ! sudo -u postgres psql -c "SELECT 1;" &>/dev/null; do
            if [ "$waited" -ge "$max_wait" ]; then
                die "PostgreSQL tidak merespons setelah ${max_wait} detik."
            fi
            log_info "Menunggu PostgreSQL siap... ($waited/$max_wait detik)"
            sleep 2
            waited=$((waited + 2))
        done
        log_ok "PostgreSQL siap menerima koneksi."

        local user_exists
        user_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null | tr -d '[:space:]')
        if [ "$user_exists" != "1" ]; then
            sudo -u postgres psql -c "CREATE USER \"$DB_USER\" WITH PASSWORD \$\$$DB_PASS\$\$;" \
                || die "Gagal membuat user database '$DB_USER'."
            log_ok "User database '$DB_USER' dibuat."
        else
            log_info "User database '$DB_USER' sudah ada, memperbarui password..."
            sudo -u postgres psql -c "ALTER USER \"$DB_USER\" WITH PASSWORD \$\$$DB_PASS\$\$;" || true
        fi

        local db_exists
        db_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null | tr -d '[:space:]')
        if [ "$db_exists" != "1" ]; then
            sudo -u postgres psql -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";" \
                || die "Gagal membuat database '$DB_NAME'."
            log_ok "Database '$DB_NAME' dibuat."
        fi

        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\";" || true
    fi
}

step_setup_app() {
    mkdir -p "$APP_DIR/storage"

    local download_tmp="/tmp/cbt-linux-$$.zip"

    log_info "Mengunduh paket aplikasi CBT..."
    if ! wget --timeout=120 --tries=3 --progress=bar:force \
              -O "$download_tmp" "$APP_DOWNLOAD_URL" 2>&1; then
        rm -f "$download_tmp"
        die "Gagal mengunduh aplikasi dari $APP_DOWNLOAD_URL. Periksa koneksi internet."
    fi

    if [ ! -s "$download_tmp" ]; then
        rm -f "$download_tmp"
        die "File yang diunduh kosong atau tidak valid."
    fi

    log_info "Mengekstrak paket aplikasi..."
    unzip -o -q "$download_tmp" -d "$APP_DIR/" || die "Gagal mengekstrak arsip aplikasi."
    rm -f "$download_tmp"
    log_ok "Paket aplikasi berhasil diekstrak."

    local is_proxied="false"
    local server_bind_host="0.0.0.0"
    if [ "$SETUP_DOMAIN" = "yes" ]; then
        is_proxied="true"
        server_bind_host="127.0.0.1"
    fi

    cat > "$APP_DIR/.env" <<EOF
SERVER_HOST="${server_bind_host}"
SERVER_PORT="${APP_PORT}"
SERVER_WS_ACTIVE="${SERVER_WS_ACTIVE}"
SERVER_ASSET_URL="${SERVER_ASSET_URL}"
SERVER_ASSET_CACHE_TIME_SECOND="${SERVER_ASSET_CACHE_TIME_SECOND}"
SERVER_CACHE_IN_EXAM_ENABLE="${SERVER_CACHE_IN_EXAM_ENABLE}"
SERVER_LOG_REQ_ACTIVE="${SERVER_LOG_REQ_ACTIVE}"
SERVER_WRITE_BUFFER_SIZE="${SERVER_WRITE_BUFFER_SIZE}"
SERVER_SECRET_LICENSE_KEY="${SERVER_SECRET_LICENSE_KEY}"
SERVER_BEHIND_PROXY="${is_proxied}"
SERVER_PROXY_REAL_API_HEADER="X-Forwarded-For"

DB_HOST="${DB_HOST}"
DB_PORT="${DB_PORT}"
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
DB_TZ="Asia/Jakarta"
TZ="Asia/Jakarta"
DB_SECURE_ENCRYPT="false"
DB_CONNECTION_MAX_LIFETIME="30"
DB_CONNECTION_MAX_IDLE_TIME="5"
DB_CONNECTION_MAX_IDLE_SIZE="2"
DB_CONNECTION_MAX_OPEN_SIZE="10"

STORAGE_PATH="${APP_DIR}/storage"
SECURITY_RATE_LIMIT_ACTIVE="${SECURITY_RATE_LIMIT_ACTIVE}"
SECURITY_RATE_LIMIT_MAX="${SECURITY_RATE_LIMIT_MAX}"
SECURITY_RATE_LIMIT_EXP="${SECURITY_RATE_LIMIT_EXP}"
GOOGLE_DOC_ACTIVE="${GOOGLE_DOC_ACTIVE}"
GOOGLE_CREDENTIAL="${GOOGLE_CREDENTIAL}"
OPEN_AI_MODEL="${OPEN_AI_MODEL}"
OPEN_AI_ACTIVE="${OPEN_AI_ACTIVE}"
OPEN_AI_ACCESS_KEY="${OPEN_AI_ACCESS_KEY}"
EOF

    chown www-data:www-data "$APP_DIR/.env"
    chmod 600 "$APP_DIR/.env"

    if [ "$INSTALL_POSTGRES" = "yes" ]; then
        local table_count
        table_count=$(sudo -u postgres psql -d "$DB_NAME" -tAc \
            "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null \
            | tr -d '[:space:]')

        if [ "${table_count:-0}" -eq "0" ]; then
            if [ -f "$APP_DIR/$APP_DUMP_SQL" ]; then
                log_info "Mengimpor skema database awal..."
                sudo -u postgres psql "$DB_NAME" < "$APP_DIR/$APP_DUMP_SQL" \
                    || die "Gagal mengimpor skema database."
                sudo -u postgres psql -d "$DB_NAME" \
                    -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"$DB_USER\";" || true
                sudo -u postgres psql -d "$DB_NAME" \
                    -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"$DB_USER\";" || true
                log_ok "Skema database berhasil diimpor."
            else
                log_warn "File $APP_DUMP_SQL tidak ditemukan. Skema DB tidak diimpor."
            fi
        else
            if [ "$AUTO_MODE" = "true" ]; then
                log_info "Database sudah berisi $table_count tabel. (Auto Mode: Lewati modifikasi skema)."
            else
                echo ""
                echo "==================================================="
                echo " PERHATIAN: Database '$DB_NAME' sudah berisi $table_count tabel."
                echo " [1] Lewati (Gunakan data eksisting - Default)"
                echo " [2] Update (Import $APP_UPDATE_SQL)"
                echo " [3] Hapus Semua Tabel & Buat Ulang (Import $APP_DUMP_SQL)"
                read -p " Pilih opsi modifikasi database [1/2/3]: " db_action_choice

                case "$db_action_choice" in
                    2)
                        if [ -f "$APP_DIR/$APP_UPDATE_SQL" ]; then
                            log_info "Menjalankan skrip update database..."
                            sudo -u postgres psql "$DB_NAME" < "$APP_DIR/$APP_UPDATE_SQL" \
                                || die "Gagal menjalankan update skema."
                            log_ok "Update database selesai dieksekusi."
                        else
                            log_warn "File $APP_UPDATE_SQL tidak ditemukan. Melewati update."
                        fi
                        ;;
                    3)
                        log_warn "Menghapus seluruh tabel eksisting dan mereset skema..."
                        sudo -u postgres psql -d "$DB_NAME" \
                            -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO public; GRANT ALL ON SCHEMA public TO \"$DB_USER\";"
                        if [ -f "$APP_DIR/$APP_DUMP_SQL" ]; then
                            sudo -u postgres psql "$DB_NAME" < "$APP_DIR/$APP_DUMP_SQL" \
                                || die "Gagal mengimpor skema database baru."
                            sudo -u postgres psql -d "$DB_NAME" \
                                -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"$DB_USER\";" || true
                            log_ok "Skema database baru berhasil diimpor."
                        else
                            log_error "File $APP_DUMP_SQL tidak ditemukan! Database kosong."
                        fi
                        ;;
                    *)
                        log_info "Melewati modifikasi skema database (menggunakan data yang ada)."
                        ;;
                esac
                echo "==================================================="
            fi
        fi
    fi

    local arch
    arch=$(uname -m)
    local binary_file="$APP_BINARY_AMD64"
    if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        binary_file="$APP_BINARY_ARM64"
    fi

    if [ ! -f "$APP_DIR/$binary_file" ]; then
        die "Binary '$binary_file' tidak ditemukan setelah ekstrak. Periksa integritas file ZIP."
    fi

    chmod +x "$APP_DIR/$binary_file"
    chown -R www-data:www-data "$APP_DIR"
    chmod -R 775 "$APP_DIR/storage"
    log_ok "Hak akses file aplikasi dikonfigurasi."
}

step_setup_systemd() {
    local arch
    arch=$(uname -m)
    local binary_file="$APP_BINARY_AMD64"
    if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        binary_file="$APP_BINARY_ARM64"
    fi

    if [ ! -f "$APP_DIR/$binary_file" ]; then
        die "Binary '$APP_DIR/$binary_file' tidak ditemukan. Pastikan step_setup_app berhasil."
    fi

    cat > /etc/systemd/system/"$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=CBT Application Service
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=${APP_DIR}
Environment="TZ=Asia/Jakarta"
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/${binary_file}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SYSTEMD_IDENTIFIER}

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${APP_DIR}/storage

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SYSTEMD_SERVICE" || die "Gagal mengaktifkan service CBT."
    systemctl restart "$SYSTEMD_SERVICE" || die "Gagal menjalankan service CBT."

    local max_wait=20
    local waited=0
    while ! systemctl is-active --quiet "$SYSTEMD_IDENTIFIER"; do
        if [ "$waited" -ge "$max_wait" ]; then
            log_warn "Service CBT belum active setelah ${max_wait}s. Cek: journalctl -fu $SYSTEMD_IDENTIFIER"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if systemctl is-active --quiet "$SYSTEMD_IDENTIFIER"; then
        log_ok "Service CBT berjalan dengan normal."
    fi
}

# =================================================================
# KONFIGURASI NGINX REVERSE PROXY
# =================================================================
step_setup_nginx_proxy() {
    if [ "$SETUP_DOMAIN" != "yes" ] || [ -z "$DOMAIN_NAME" ]; then
        return
    fi

    log_info "Mengkonfigurasi Nginx Reverse Proxy..."

    # Hapus default site, kita pakai config CBT saja
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-available/default

    # Cloudflare Real IP
    log_info "Menerapkan dukungan Cloudflare Real IP..."
    {
        echo "# Cloudflare IPs - $(date)"
        for i in $(curl -s --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null); do
            echo "set_real_ip_from $i;"
        done
        if kernel_has_ipv6; then
            for i in $(curl -s --max-time 10 https://www.cloudflare.com/ips-v6 2>/dev/null); do
                echo "set_real_ip_from $i;"
            done
        fi
        echo "real_ip_header CF-Connecting-IP;"
    } > "$CF_CONF_PATH"

    # Backup config lama jika ada
    if [ -f "$NGINX_CONF_PATH" ]; then
        mv "$NGINX_CONF_PATH" "${NGINX_CONF_PATH}.backup.$(date '+%Y%m%d_%H%M%S')"
        log_info "Konfigurasi Nginx lama di-backup."
    fi

    # Tulis config CBT baru
    {
        echo "server {"
        echo "    listen 80;"
        if kernel_has_ipv6; then
            echo "    listen [::]:80;"
        fi
        echo "    server_name ${DOMAIN_NAME};"
        echo ""
        if [ "$BLOCK_DIRECT_IP" = "yes" ]; then
            echo "    if (\$host != \"${DOMAIN_NAME}\") {"
            echo "        return 444;"
            echo "    }"
            echo ""
        fi
        echo "    location / {"
        echo "        proxy_pass http://127.0.0.1:${APP_PORT};"
        echo "        proxy_http_version 1.1;"
        echo "        proxy_set_header Upgrade \$http_upgrade;"
        echo "        proxy_set_header Connection 'upgrade';"
        echo "        proxy_set_header Host \$host;"
        echo "        proxy_cache_bypass \$http_upgrade;"
        echo "        proxy_set_header X-Real-IP \$remote_addr;"
        echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
        echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
        echo "        proxy_read_timeout 300s;"
        echo "        proxy_connect_timeout 10s;"
        echo "        client_max_body_size 50M;"
        echo "    }"
        echo "}"
    } > "$NGINX_CONF_PATH"

    ln -sf "$NGINX_CONF_PATH" "$NGINX_LINK_PATH"

    # Patch sekali lagi untuk memastikan tidak ada sisa IPv6
    patch_nginx_ipv6

    nginx -t || die "Konfigurasi Nginx tidak valid. Periksa file di $NGINX_CONF_PATH"
    systemctl restart nginx || die "Gagal merestart Nginx."
    log_ok "Konfigurasi proxy berhasil disimpan dan Nginx berjalan."

    # SSL
    local cert_exists=0
    if certbot certificates 2>/dev/null | grep -q "^  Certificate Name: ${DOMAIN_NAME}$"; then
        cert_exists=1
    fi

    if [ "$cert_exists" -eq 0 ]; then
        log_info "Mendaftarkan sertifikat SSL untuk domain: $DOMAIN_NAME ..."
        certbot --nginx -d "$DOMAIN_NAME" \
            --non-interactive --agree-tos \
            -m "$LETSENCRYPT_EMAIL" --redirect \
            || log_warn "Certbot gagal. Pastikan Proxy Cloudflare (Awan Oranye) DIMATIKAN saat instalasi SSL."
    else
        log_info "Sertifikat SSL untuk $DOMAIN_NAME sudah ada, melewati pendaftaran."
        certbot renew --dry-run &>/dev/null || true
    fi
}

# ==========================================
# 7. EKSEKUSI TAHAPAN (RUNNER)
# ==========================================
execute_step "01_CHECK_SOFTWARE"      "Pengecekan Konflik Port & Software"       step_check_requirements
execute_step "02_PREPARE_CREDENTIALS" "Menyiapkan Kredensial Database"           step_prepare_credentials
execute_step "03_UPDATE_SYSTEM"       "Update Sistem dan Install Dependensi"     step_update_system
execute_step "04_INSTALL_NGINX_CORE"  "Instalasi Core Nginx & Bypass Error IPv6" step_install_nginx_core
execute_step "05_INSTALL_DB"          "Instalasi dan Penyiapan PostgreSQL"       step_install_db
execute_step "06_SETUP_APP"           "Download Aplikasi, Konfigurasi & Skema"   step_setup_app
execute_step "07_SETUP_SYSTEMD"       "Registrasi dan Jalankan Systemd Service"  step_setup_systemd
execute_step "08_SETUP_NGINX_PROXY"   "Konfigurasi Domain, Cloudflare & SSL"     step_setup_nginx_proxy

# ==========================================
# 8. SUMMARY OUTPUT
# ==========================================
PUBLIC_IP=""
if PUBLIC_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null) && [ -n "$PUBLIC_IP" ]; then
    :
elif PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null) && [ -n "$PUBLIC_IP" ]; then
    :
elif PUBLIC_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}') && [ -n "$PUBLIC_IP" ]; then
    :
else
    PUBLIC_IP="(tidak terdeteksi - lihat IP server Anda)"
fi

echo ""
echo "==================================================="
echo "       INSTALASI CBT BERHASIL DISELESAIKAN!        "
echo "==================================================="
echo "[ Kredensial Database ]"
echo "  DB Host     : $DB_HOST"
echo "  DB Port     : $DB_PORT"
echo "  DB Name     : $DB_NAME"
echo "  DB User     : $DB_USER"
echo "  DB Password : $DB_PASS"
if [ -f "$CRED_FILE" ]; then
    echo "  *(Kredensial juga tersimpan di $CRED_FILE)*"
fi
echo ""
echo "[ Informasi Akses Aplikasi ]"
if [ "$SETUP_DOMAIN" = "yes" ] && [ -n "$DOMAIN_NAME" ]; then
    echo "  Mode        : Nginx Reverse Proxy (HTTPS / Let's Encrypt)"
    echo "  URL Akses   : https://$DOMAIN_NAME"
    if [ "$BLOCK_DIRECT_IP" = "yes" ]; then
        echo "  Catatan     : Akses langsung via IP ($PUBLIC_IP) telah diblokir."
    else
        echo "  Catatan     : Aplikasi juga dapat diakses via http://$PUBLIC_IP:$APP_PORT"
    fi
    echo "==================================================="
    echo "  [ ! ] PANDUAN WAJIB CLOUDFLARE:"
    echo "  1. Pastikan mode SSL/TLS di Dashboard Cloudflare"
    echo "     berada pada mode 'Full' atau 'Full (Strict)'."
    echo "  2. Jika Error 521/522, matikan Proxy (Awan Oranye) di DNS,"
    echo "     jalankan: sudo certbot --nginx -d $DOMAIN_NAME --redirect"
    echo "     lalu hidupkan proxy kembali."
else
    echo "  Mode        : Direct Port Access"
    echo "  URL Akses   : http://$PUBLIC_IP:$APP_PORT"
    echo "  *(Pastikan port $APP_PORT terbuka di Firewall VPS Anda)*"
fi
echo ""
echo "[ Manajemen Service ]"
echo "  Cek Status  : sudo systemctl status $SYSTEMD_IDENTIFIER"
echo "  Cek Log     : sudo journalctl -fu $SYSTEMD_IDENTIFIER"
echo "  Restart     : sudo systemctl restart $SYSTEMD_IDENTIFIER"
echo "==================================================="