#!/usr/bin/env bash

# ==============================================================================
# OpenClaw LXC Helper Script for Proxmox VE
# All-in-One: OpenClaw + Docker + Web UI Dashboard + Ollama Support
# ==============================================================================

# Save stdin, use /dev/tty for interactive input
exec 3<&0
exec 0</dev/tty || { echo "ERROR: Cannot open /dev/tty. Run with: bash install.sh"; exit 1; }

set -uo pipefail
trap 'echo ""; echo "ERROR at line $LINENO: command \"$BASH_COMMAND\" failed (exit $?)"' ERR

# ─── Colors ───────────────────────────────────────────────────────────────────
BL="\e[36m"; GN="\e[32m"; RD="\e[31m"; YW="\e[33m"; DIM="\e[2m"; CL="\e[0m"
BFR="\\r\\033[K"; HOLD=" "
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"; INFO="${BL}ℹ${CL}"

# ─── Defaults ─────────────────────────────────────────────────────────────────
APP="OpenClaw"
var_os="debian"; var_version="12"
var_unprivileged="1"
var_disk="8"; var_cpu="2"; var_ram="2048"
var_bridge="vmbr0"; var_net="dhcp"
var_gate=""; var_dns=""; var_mac=""; var_vlan=""
var_ssh="no"; var_docker="yes"
var_webui="yes"; var_webui_type="nginx"; var_webui_port="80"
var_dashboard="yes"; var_dashboard_port="3333"
var_ollama="no"; var_ollama_url="http://localhost:11434"
var_domain=""
CT_ID=""; HN=""; STORAGE=""
DASHBOARD_PASS=""

# ─── Helpers ──────────────────────────────────────────────────────────────────
msg_info() { echo -ne " ${HOLD} ${INFO} ${YW}${1}...${CL}"; }
msg_ok()   { echo -e "${BFR} ${CM} ${GN}${1}${CL}"; }
msg_error(){ echo -e "${BFR} ${CROSS} ${RD}${1}${CL}"; }

header() {
    clear 2>/dev/null || true
    cat << "EOF"
   ____                   _____ _
  / __ \                 / ____| |
 | |  | |_ __   ___ _ _| |    | | __ ___      __
 | |  | | '_ \ / _ \ '_ \ |   | |/ _` \ \ /\ / /
 | |__| | |_) |  __/ | | | |___| | (_| |\ V  V /
  \____/| .__/ \___|_| |_|\____|_|\__,_| \_/\_/
        | |
        |_|     LXC Installer for Proxmox VE
          Docker + Web UI + Ollama Edition
EOF
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_error "Must run as root on Proxmox host."
        exit 1
    fi
    msg_ok "Running as root"
}

check_proxmox() {
    if ! command -v pveversion &>/dev/null; then
        msg_error "Must run on Proxmox VE host (pveversion not found)."
        exit 1
    fi
    msg_ok "Proxmox VE detected: $(pveversion | cut -d'/' -f2)"
}

next_id() {
    local id
    id=$(pvesh get /cluster/nextid 2>/dev/null) || id=100
    echo "$id"
}

select_storage() {
    local storages
    storages=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}' || true)
    if [[ -z "$storages" ]]; then
        msg_error "No storage with 'rootdir' content type found."
        echo ""
        echo "  Tip: Make sure you have storage configured for containers."
        echo "  Check: Datacenter > Storage > Content should include 'rootdir'"
        exit 1
    fi
    local count
    count=$(echo "$storages" | wc -l)
    if [[ $count -eq 1 ]]; then
        STORAGE=$(echo "$storages" | head -1)
    else
        echo -e "\n${BL}Available storage pools:${CL}"
        local i=1
        while IFS= read -r s; do
            echo "  $i) $s"
            ((i++))
        done <<< "$storages"
        echo ""
        read -rp "Select storage (1-$count) [1]: " choice
        STORAGE=$(echo "$storages" | sed -n "${choice:-1}p")
    fi
    msg_ok "Storage: ${STORAGE}"
}

# ─── Configuration ────────────────────────────────────────────────────────────
configure() {
    echo -e "\n${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    echo -e "${BL}  ${APP} LXC Configuration${CL}"
    echo -e "${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}\n"

    local default_id
    default_id=$(next_id)
    read -rp "  Container ID [$default_id]: " i; CT_ID=${i:-$default_id}
    read -rp "  Hostname [openclaw]: " i; HN=${i:-openclaw}
    read -rp "  CPU Cores [$var_cpu]: " i; var_cpu=${i:-$var_cpu}
    read -rp "  RAM in MB [$var_ram]: " i; var_ram=${i:-$var_ram}
    read -rp "  Disk Size in GB [$var_disk]: " i; var_disk=${i:-$var_disk}
    read -rp "  Bridge [$var_bridge]: " i; var_bridge=${i:-$var_bridge}
    read -rp "  IP (dhcp or x.x.x.x/xx) [$var_net]: " i; var_net=${i:-$var_net}
    [[ "$var_net" != "dhcp" ]] && { read -rp "  Gateway IP: " var_gate; }
    read -rp "  DNS Server (blank=host): " var_dns

    echo -e "\n  ${BL}-- Features --${CL}"
    read -rp "  Install Docker? (yes/no) [$var_docker]: " i; var_docker=${i:-$var_docker}

    echo -e "\n  ${BL}-- Ollama (Local AI) --${CL}"
    read -rp "  Install Ollama inside LXC? (yes/no) [$var_ollama]: " i; var_ollama=${i:-$var_ollama}
    if [[ "$var_ollama" != "yes" ]]; then
        read -rp "  External Ollama URL (blank=none): " i
        [[ -n "$i" ]] && var_ollama_url="$i" || var_ollama_url=""
    fi

    echo -e "\n  ${BL}-- Web Access --${CL}"
    read -rp "  Reverse proxy for Control UI? (yes/no) [$var_webui]: " i; var_webui=${i:-$var_webui}
    if [[ "$var_webui" == "yes" ]]; then
        echo -e "  ${DIM}  1) nginx - lightweight, manual SSL${CL}"
        echo -e "  ${DIM}  2) caddy - auto HTTPS with Let's Encrypt${CL}"
        read -rp "  Web server (nginx/caddy) [$var_webui_type]: " i; var_webui_type=${i:-$var_webui_type}
        read -rp "  Proxy port [$var_webui_port]: " i; var_webui_port=${i:-$var_webui_port}
        if [[ "$var_webui_type" == "caddy" ]]; then
            read -rp "  Domain (for auto-HTTPS, blank=skip): " var_domain
        fi
    fi

    read -rp "  Install Management Dashboard? (yes/no) [$var_dashboard]: " i; var_dashboard=${i:-$var_dashboard}
    if [[ "$var_dashboard" == "yes" ]]; then
        read -rp "  Dashboard port [$var_dashboard_port]: " i; var_dashboard_port=${i:-$var_dashboard_port}
    fi

    read -rp "  Enable SSH? (yes/no) [$var_ssh]: " i; var_ssh=${i:-$var_ssh}

    # Docker/Ollama require privileged
    [[ "$var_docker" == "yes" || "$var_ollama" == "yes" ]] && var_unprivileged="0"

    # Ollama needs more resources
    if [[ "$var_ollama" == "yes" ]]; then
        [[ "$var_ram" -lt 4096 ]] && { echo -e "\n  ${YW}Warning: Ollama needs >=4GB RAM. Bumping to 4096 MB.${CL}"; var_ram=4096; }
        [[ "$var_disk" -lt 16 ]] && { echo -e "  ${YW}Warning: Ollama models need space. Bumping disk to 16 GB.${CL}"; var_disk=16; }
    fi

    # Summary
    echo -e "\n${BL}--- Configuration Summary ---${CL}"
    echo -e "  Container:   ${GN}${CT_ID}${CL} / ${GN}${HN}${CL}"
    echo -e "  OS:          ${GN}Debian ${var_version}${CL} ($([ "$var_unprivileged" == "0" ] && echo "privileged" || echo "unprivileged"))"
    echo -e "  Resources:   ${GN}${var_cpu} CPU / ${var_ram} MB RAM / ${var_disk} GB disk${CL}"
    echo -e "  Network:     ${GN}${var_net}${CL} on ${GN}${var_bridge}${CL}"
    echo -e "  Docker:      ${GN}${var_docker}${CL}"
    echo -e "  Ollama:      ${GN}$([ "$var_ollama" == "yes" ] && echo "install locally" || echo "${var_ollama_url:-none}")${CL}"
    echo -e "  Control UI:  ${GN}${var_webui} (${var_webui_type}:${var_webui_port})${CL}"
    echo -e "  Dashboard:   ${GN}${var_dashboard} (:${var_dashboard_port})${CL}"
    echo -e "  SSH:         ${GN}${var_ssh}${CL}"
    echo ""
    read -rp "  Create container? (y/n) [y]: " confirm
    [[ "${confirm:-y}" != "y" && "${confirm:-y}" != "Y" ]] && { echo "Aborted."; exit 0; }
}

# ─── Download Template ────────────────────────────────────────────────────────
download_template() {
    msg_info "Checking for Debian ${var_version} template"
    local template
    template=$(pveam available --section system 2>/dev/null | grep "debian-${var_version}" | sort -t- -k2 -V | tail -1 | awk '{print $2}' || true)
    if [[ -z "$template" ]]; then
        msg_error "Debian ${var_version} template not found"
        exit 1
    fi
    if ! pveam list local 2>/dev/null | grep -q "$template"; then
        msg_info "Downloading ${template}"
        pveam download local "$template" &>/dev/null || { msg_error "Failed to download template"; exit 1; }
    fi
    msg_ok "Template: ${template}"
    TEMPLATE="local:vztmpl/${template}"
}

# ─── Create Container ─────────────────────────────────────────────────────────
create_container() {
    msg_info "Creating LXC container ${CT_ID}"
    local net="name=eth0,bridge=${var_bridge}"
    if [[ "$var_net" == "dhcp" ]]; then
        net+=",ip=dhcp"
    else
        net+=",ip=${var_net}"
        [[ -n "$var_gate" ]] && net+=",gw=${var_gate}"
    fi
    [[ -n "$var_mac" ]] && net+=",hwaddr=${var_mac}"
    [[ -n "$var_vlan" ]] && net+=",tag=${var_vlan}"

    local -a extra_args=()
    [[ -n "$var_dns" ]] && extra_args+=(--nameserver "$var_dns")

    pct create "$CT_ID" "$TEMPLATE" \
        --hostname "$HN" --cores "$var_cpu" --memory "$var_ram" \
        --rootfs "${STORAGE}:${var_disk}" --net0 "$net" \
        --unprivileged "$var_unprivileged" --features nesting=1,keyctl=1 \
        --onboot 1 --ostype "$var_os" --start 0 \
        "${extra_args[@]}" || { msg_error "Failed to create container"; exit 1; }

    if [[ "$var_unprivileged" == "0" ]]; then
        cat >> "/etc/pve/lxc/${CT_ID}.conf" << 'DCONF'

# Docker/Ollama support
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
DCONF
    fi
    msg_ok "Container ${CT_ID} created"
}

start_container() {
    msg_info "Starting container ${CT_ID}"
    pct start "$CT_ID" || { msg_error "Failed to start container"; exit 1; }
    sleep 3
    local r=15
    while [[ $r -gt 0 ]]; do
        pct exec "$CT_ID" -- ping -c1 -W2 deb.debian.org &>/dev/null && break
        sleep 2; ((r--))
    done
    msg_ok "Container ${CT_ID} started"
}

# ─── Install Docker ──────────────────────────────────────────────────────────
install_docker() {
    [[ "$var_docker" != "yes" ]] && return 0
    msg_info "Installing Docker CE (this takes a few minutes)"
    pct exec "$CT_ID" -- bash -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq ca-certificates curl gnupg lsb-release >/dev/null 2>&1
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
        systemctl enable docker >/dev/null 2>&1
        systemctl start docker
    ' || { msg_error "Docker installation failed"; return 1; }
    msg_ok "Docker: $(pct exec "$CT_ID" -- docker --version 2>/dev/null || echo 'installed')"
}

# ─── Install Ollama ──────────────────────────────────────────────────────────
install_ollama() {
    [[ "$var_ollama" != "yes" ]] && return 0
    msg_info "Installing Ollama (this takes a few minutes)"
    pct exec "$CT_ID" -- bash -c '
        curl -fsSL https://ollama.com/install.sh | sh >/dev/null 2>&1
        systemctl enable ollama >/dev/null 2>&1
        systemctl start ollama
        for i in $(seq 1 15); do
            curl -sf http://localhost:11434/api/version >/dev/null 2>&1 && break
            sleep 2
        done
    ' || { msg_error "Ollama installation failed"; return 1; }
    msg_ok "Ollama installed"
    var_ollama_url="http://localhost:11434"
}

# ─── Install Nginx ───────────────────────────────────────────────────────────
install_nginx() {
    msg_info "Installing Nginx reverse proxy"
    pct exec "$CT_ID" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq nginx >/dev/null 2>&1
        cat > /etc/nginx/sites-available/openclaw << 'NGINX'
upstream openclaw_gw { server 127.0.0.1:18789; }
server {
    listen ${var_webui_port} default_server;
    listen [::]:${var_webui_port} default_server;
    server_name _;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    location / {
        proxy_pass http://openclaw_gw;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }
}
NGINX
        rm -f /etc/nginx/sites-enabled/default
        ln -sf /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/openclaw
        nginx -t >/dev/null 2>&1
        systemctl enable nginx >/dev/null 2>&1
        systemctl restart nginx
    " || { msg_error "Nginx installation failed"; return 1; }
    msg_ok "Nginx configured (port ${var_webui_port})"
}

install_caddy() {
    msg_info "Installing Caddy"
    pct exec "$CT_ID" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null 2>&1
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq caddy >/dev/null 2>&1
    " || { msg_error "Caddy installation failed"; return 1; }
    local listen="${var_domain:-:${var_webui_port}}"
    pct exec "$CT_ID" -- bash -c "
        mkdir -p /var/log/caddy
        cat > /etc/caddy/Caddyfile << CADDYEOF
${listen} {
    reverse_proxy 127.0.0.1:18789
    header {
        X-Frame-Options SAMEORIGIN
        X-Content-Type-Options nosniff
    }
    log { output file /var/log/caddy/openclaw.log }
}
CADDYEOF
        systemctl enable caddy >/dev/null 2>&1
        systemctl restart caddy
    "
    msg_ok "Caddy configured (${listen})"
}

install_webui() {
    [[ "$var_webui" != "yes" ]] && return 0
    case "$var_webui_type" in
        nginx) install_nginx ;; caddy) install_caddy ;;
    esac
}

# ─── Install Dashboard ──────────────────────────────────────────────────────
install_dashboard() {
    [[ "$var_dashboard" != "yes" ]] && return 0
    msg_info "Installing OpenClaw Management Dashboard"

    DASHBOARD_PASS=$(openssl rand -hex 16)

    # Create dashboard files inside the container
    pct exec "$CT_ID" -- bash -c "
        mkdir -p /opt/openclaw-webui

        cat > /opt/openclaw-webui/.env << ENVFILE
WEBUI_PASSWORD=${DASHBOARD_PASS}
WEBUI_PORT=${var_dashboard_port}
OPENCLAW_CONFIG=/home/openclaw/.openclaw/openclaw.json
OLLAMA_URL=${var_ollama_url}
ENVFILE

        cat > /opt/openclaw-webui/package.json << 'PKGFILE'
{
  \"name\": \"openclaw-webui\",
  \"version\": \"1.0.0\",
  \"description\": \"Web management dashboard for OpenClaw\",
  \"main\": \"server.js\",
  \"scripts\": { \"start\": \"node server.js\" },
  \"license\": \"MIT\"
}
PKGFILE

        cat > /etc/systemd/system/openclaw-webui.service << 'SVCFILE'
[Unit]
Description=OpenClaw Management Dashboard
After=network.target openclaw.service

[Service]
Type=simple
WorkingDirectory=/opt/openclaw-webui
EnvironmentFile=/opt/openclaw-webui/.env
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCFILE

        systemctl daemon-reload
        systemctl enable openclaw-webui >/dev/null 2>&1
    " || { msg_error "Dashboard setup failed"; return 1; }

    # Transfer server.js via base64
    msg_info "Transferring dashboard files"
    local server_b64
    server_b64=$(cat << 'B64END'
IyEvdXNyL2Jpbi9lbnYgbm9kZQovLyBPcGVuQ2xhdyBXZWIgTWFuYWdlbWVudCBEYXNoYm9hcmQKLy8gU2luZ2xlLWZpbGUgTm9kZS5qcyB3ZWIgYXBwIOKAlCBubyBidWlsZCBzdGVwLCBubyBleHRlcm5hbCBkZXBzCgpjb25zdCBodHRwID0gcmVxdWlyZSgnaHR0cCcpOwpjb25zdCBmcyA9IHJlcXVpcmUoJ2ZzJyk7CmNvbnN0IHsgZXhlY1N5bmMsIGV4ZWMsIHNwYXduIH0gPSByZXF1aXJlKCdjaGlsZF9wcm9jZXNzJyk7CmNvbnN0IGNyeXB0byA9IHJlcXVpcmUoJ2NyeXB0bycpOwpjb25zdCBwYXRoID0gcmVxdWlyZSgncGF0aCcpOwoKLy8g4pSA4pSA4pSAIENvbmZpZyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKY29uc3QgUE9SVCA9IHBhcnNlSW50KHByb2Nlc3MuZW52LldFQlVJX1BPUlQgfHwgJzMzMzMnKTsKY29uc3QgUEFTU1dPUkQgPSBwcm9jZXNzLmVudi5XRUJVSV9QQVNTV09SRCB8fCAnb3BlbmNsYXcnOwpjb25zdCBDT05GSUdfUEFUSCA9IHByb2Nlc3MuZW52Lk9QRU5DTEFXX0NPTkZJRyB8fCAnL2hvbWUvb3BlbmNsYXcvLm9wZW5jbGF3L29wZW5jbGF3Lmpzb24nOwpjb25zdCBPTExBTUFfVVJMID0gcHJvY2Vzcy5lbnYuT0xMQU1BX1VSTCB8fCAnaHR0cDovL2xvY2FsaG9zdDoxMTQzNCc7CmNvbnN0IFNFU1NJT05fU0VDUkVUID0gY3J5cHRvLnJhbmRvbUJ5dGVzKDMyKS50b1N0cmluZygnaGV4Jyk7CmNvbnN0IHNlc3Npb25zID0gbmV3IE1hcCgpOwoKLy8g4pSA4pSA4pSAIEhlbHBlcnMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmZ1bmN0aW9uIHBhcnNlQm9keShyZXEpIHsKICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUsIHJlamVjdCkgPT4gewogICAgbGV0IGJvZHkgPSAnJzsKICAgIHJlcS5vbignZGF0YScsIGMgPT4geyBib2R5ICs9IGM7IGlmIChib2R5Lmxlbmd0aCA+IDFlNikgcmVxLmRlc3Ryb3koKTsgfSk7CiAgICByZXEub24oJ2VuZCcsICgpID0+IHsgdHJ5IHsgcmVzb2x2ZShKU09OLnBhcnNlKGJvZHkgfHwgJ3t9JykpOyB9IGNhdGNoIHsgcmVzb2x2ZSh7fSk7IH0gfSk7CiAgICByZXEub24oJ2Vycm9yJywgcmVqZWN0KTsKICB9KTsKfQoKZnVuY3Rpb24ganNvbihyZXMsIGRhdGEsIHN0YXR1cyA9IDIwMCkgewogIHJlcy53cml0ZUhlYWQoc3RhdHVzLCB7ICdDb250ZW50LVR5cGUnOiAnYXBwbGljYXRpb24vanNvbicgfSk7CiAgcmVzLmVuZChKU09OLnN0cmluZ2lmeShkYXRhKSk7Cn0KCmZ1bmN0aW9uIGdldENvb2tpZShyZXEsIG5hbWUpIHsKICBjb25zdCBjID0gKHJlcS5oZWFkZXJzLmNvb2tpZSB8fCAnJykuc3BsaXQoJzsnKS5maW5kKGMgPT4gYy50cmltKCkuc3RhcnRzV2l0aChuYW1lICsgJz0nKSk7CiAgcmV0dXJuIGMgPyBjLnNwbGl0KCc9JylbMV0udHJpbSgpIDogbnVsbDsKfQoKZnVuY3Rpb24gaXNBdXRoZWQocmVxKSB7CiAgY29uc3Qgc2lkID0gZ2V0Q29va2llKHJlcSwgJ29jX3Nlc3Npb24nKTsKICByZXR1cm4gc2lkICYmIHNlc3Npb25zLmhhcyhzaWQpOwp9CgpmdW5jdGlvbiBydW4oY21kLCB0aW1lb3V0ID0gMTAwMDApIHsKICB0cnkgeyByZXR1cm4gZXhlY1N5bmMoY21kLCB7IHRpbWVvdXQsIGVuY29kaW5nOiAndXRmOCcsIHN0ZGlvOiBbJ3BpcGUnLCdwaXBlJywncGlwZSddIH0pLnRyaW0oKTsgfQogIGNhdGNoIChlKSB7IHJldHVybiBlLnN0ZGVyciA/IGUuc3RkZXJyLnRyaW0oKSA6IGUubWVzc2FnZTsgfQp9Cgphc3luYyBmdW5jdGlvbiBvbGxhbWFGZXRjaChwYXRoLCBvcHRzID0ge30pIHsKICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUsIHJlamVjdCkgPT4gewogICAgY29uc3QgdXJsID0gbmV3IFVSTChwYXRoLCBPTExBTUFfVVJMKTsKICAgIGNvbnN0IG9wdGlvbnMgPSB7IGhvc3RuYW1lOiB1cmwuaG9zdG5hbWUsIHBvcnQ6IHVybC5wb3J0LCBwYXRoOiB1cmwucGF0aG5hbWUsIG1ldGhvZDogb3B0cy5tZXRob2QgfHwgJ0dFVCcsIGhlYWRlcnM6IHsgJ0NvbnRlbnQtVHlwZSc6ICdhcHBsaWNhdGlvbi9qc29uJyB9IH07CiAgICBjb25zdCByZXEgPSBodHRwLnJlcXVlc3Qob3B0aW9ucywgcmVzID0+IHsKICAgICAgbGV0IGRhdGEgPSAnJzsKICAgICAgcmVzLm9uKCdkYXRhJywgYyA9PiBkYXRhICs9IGMpOwogICAgICByZXMub24oJ2VuZCcsICgpID0+IHsgdHJ5IHsgcmVzb2x2ZShKU09OLnBhcnNlKGRhdGEpKTsgfSBjYXRjaCB7IHJlc29sdmUoeyByYXc6IGRhdGEgfSk7IH0gfSk7CiAgICB9KTsKICAgIHJlcS5vbignZXJyb3InLCBlID0+IHJlc29sdmUoeyBlcnJvcjogZS5tZXNzYWdlIH0pKTsKICAgIGlmIChvcHRzLmJvZHkpIHJlcS53cml0ZShKU09OLnN0cmluZ2lmeShvcHRzLmJvZHkpKTsKICAgIHJlcS5lbmQoKTsKICB9KTsKfQoKZnVuY3Rpb24gcmVhZENvbmZpZygpIHsKICB0cnkgeyByZXR1cm4gSlNPTi5wYXJzZShmcy5yZWFkRmlsZVN5bmMoQ09ORklHX1BBVEgsICd1dGY4JykpOyB9CiAgY2F0Y2ggeyByZXR1cm4ge307IH0KfQoKZnVuY3Rpb24gd3JpdGVDb25maWcoZGF0YSkgewogIGNvbnN0IGRpciA9IHBhdGguZGlybmFtZShDT05GSUdfUEFUSCk7CiAgaWYgKCFmcy5leGlzdHNTeW5jKGRpcikpIGZzLm1rZGlyU3luYyhkaXIsIHsgcmVjdXJzaXZlOiB0cnVlIH0pOwogIGZzLndyaXRlRmlsZVN5bmMoQ09ORklHX1BBVEgsIEpTT04uc3RyaW5naWZ5KGRhdGEsIG51bGwsIDIpKTsKfQoKLy8g4pSA4pSA4pSAIEFQSSBSb3V0ZXMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmFzeW5jIGZ1bmN0aW9uIGhhbmRsZUFQSShyZXEsIHJlcywgcGF0aG5hbWUpIHsKICAvLyBBdXRoIGVuZHBvaW50cwogIGlmIChwYXRobmFtZSA9PT0gJy9hcGkvbG9naW4nICYmIHJlcS5tZXRob2QgPT09ICdQT1NUJykgewogICAgY29uc3QgeyBwYXNzd29yZCB9ID0gYXdhaXQgcGFyc2VCb2R5KHJlcSk7CiAgICBpZiAocGFzc3dvcmQgPT09IFBBU1NXT1JEKSB7CiAgICAgIGNvbnN0IHNpZCA9IGNyeXB0by5yYW5kb21CeXRlcygyNCkudG9TdHJpbmcoJ2hleCcpOwogICAgICBzZXNzaW9ucy5zZXQoc2lkLCB7IGNyZWF0ZWQ6IERhdGUubm93KCkgfSk7CiAgICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7ICdDb250ZW50LVR5cGUnOiAnYXBwbGljYXRpb24vanNvbicsICdTZXQtQ29va2llJzogYG9jX3Nlc3Npb249JHtzaWR9OyBQYXRoPS87IEh0dHBPbmx5OyBTYW1lU2l0ZT1TdHJpY3Q7IE1heC1BZ2U9ODY0MDBgIH0pOwogICAgICByZXR1cm4gcmVzLmVuZChKU09OLnN0cmluZ2lmeSh7IG9rOiB0cnVlIH0pKTsKICAgIH0KICAgIHJldHVybiBqc29uKHJlcywgeyBlcnJvcjogJ0ludmFsaWQgcGFzc3dvcmQnIH0sIDQwMSk7CiAgfQogIGlmIChwYXRobmFtZSA9PT0gJy9hcGkvbG9nb3V0JykgewogICAgY29uc3Qgc2lkID0gZ2V0Q29va2llKHJlcSwgJ29jX3Nlc3Npb24nKTsKICAgIGlmIChzaWQpIHNlc3Npb25zLmRlbGV0ZShzaWQpOwogICAgcmVzLndyaXRlSGVhZCgyMDAsIHsgJ1NldC1Db29raWUnOiAnb2Nfc2Vzc2lvbj07IFBhdGg9LzsgTWF4LUFnZT0wJyB9KTsKICAgIHJldHVybiByZXMuZW5kKCd7fScpOwogIH0KCiAgLy8gRXZlcnl0aGluZyBlbHNlIHJlcXVpcmVzIGF1dGgKICBpZiAoIWlzQXV0aGVkKHJlcSkpIHJldHVybiBqc29uKHJlcywgeyBlcnJvcjogJ1VuYXV0aG9yaXplZCcgfSwgNDAxKTsKCiAgLy8gRGFzaGJvYXJkIHN0YXR1cwogIGlmIChwYXRobmFtZSA9PT0gJy9hcGkvc3RhdHVzJykgewogICAgY29uc3QgZ2F0ZXdheSA9IHJ1bignc3lzdGVtY3RsIGlzLWFjdGl2ZSBvcGVuY2xhdy1nYXRld2F5IDI+L2Rldi9udWxsIHx8IG9wZW5jbGF3IGdhdGV3YXkgc3RhdHVzIDI+L2Rldi9udWxsIHx8IGVjaG8gdW5rbm93bicpOwogICAgY29uc3QgZG9ja2VyID0gcnVuKCdzeXN0ZW1jdGwgaXMtYWN0aXZlIGRvY2tlciAyPi9kZXYvbnVsbCB8fCBlY2hvIGluYWN0aXZlJyk7CiAgICBjb25zdCBvbGxhbWEgPSBydW4oYGN1cmwgLXNmICR7T0xMQU1BX1VSTH0vYXBpL3ZlcnNpb24gLS1tYXgtdGltZSAyIDI+L2Rldi9udWxsIHx8IGVjaG8gb2ZmbGluZWApOwogICAgY29uc3QgdXB0aW1lID0gcnVuKCd1cHRpbWUgLXAnKTsKICAgIGNvbnN0IGhvc3RuYW1lID0gcnVuKCdob3N0bmFtZScpOwogICAgY29uc3QgbWVtID0gcnVuKCJmcmVlIC1oIHwgYXdrICcvTWVtOi97cHJpbnQgJDNcIi9cIiQyfSciKTsKICAgIGNvbnN0IGRpc2sgPSBydW4oImRmIC1oIC8gfCBhd2sgJ05SPT0ye3ByaW50ICQzXCIvXCIkMlwiIChcIiQ1XCIpXCJ9JyIpOwogICAgY29uc3QgY3B1ID0gcnVuKCJncmVwIC1jIF5wcm9jZXNzb3IgL3Byb2MvY3B1aW5mbyIpOwogICAgY29uc3QgbG9hZCA9IHJ1bigiY2F0IC9wcm9jL2xvYWRhdmcgfCBhd2sgJ3twcmludCAkMSwgJDIsICQzfSciKTsKICAgIHJldHVybiBqc29uKHJlcywgeyBnYXRld2F5LCBkb2NrZXIsIG9sbGFtYSwgdXB0aW1lLCBob3N0bmFtZSwgbWVtLCBkaXNrLCBjcHUsIGxvYWQgfSk7CiAgfQoKICAvLyBDb25maWcgQ1JVRAogIGlmIChwYXRobmFtZSA9PT0gJy9hcGkvY29uZmlnJyAmJiByZXEubWV0aG9kID09PSAnR0VUJykgewogICAgcmV0dXJuIGpzb24ocmVzLCByZWFkQ29uZmlnKCkpOwogIH0KICBpZiAocGF0aG5hbWUgPT09ICcvYXBpL2NvbmZpZycgJiYgcmVxLm1ldGhvZCA9PT0gJ1BVVCcpIHsKICAgIGNvbnN0IGJvZHkgPSBhd2FpdCBwYXJzZUJvZHkocmVxKTsKICAgIHdyaXRlQ29uZmlnKGJvZHkpOwogICAgcmV0dXJuIGpzb24ocmVzLCB7IG9rOiB0cnVlIH0pOwogIH0KCiAgLy8gU2VydmljZSBjb250cm9scwogIGlmIChwYXRobmFtZSA9PT0gJy9hcGkvc2VydmljZScgJiYgcmVxLm1ldGhvZCA9PT0gJ1BPU1QnKSB7CiAgICBjb25zdCB7IGFjdGlvbiB9ID0gYXdhaXQgcGFyc2VCb2R5KHJlcSk7CiAgICBpZiAoIVsnc3RhcnQnLCAnc3RvcCcsICdyZXN0YXJ0JywgJ3N0YXR1cyddLmluY2x1ZGVzKGFjdGlvbikpIHJldHVybiBqc29uKHJlcywgeyBlcnJvcjogJ0ludmFsaWQgYWN0aW9uJyB9LCA0MDApOwogICAgLy8gVHJ5IG9wZW5jbGF3IENMSSBmaXJzdCwgZmFsbGJhY2sgdG8gc3lzdGVtY3RsCiAgICBsZXQgcmVzdWx0OwogICAgaWYgKGFjdGlvbiA9PT0gJ3N0YXR1cycpIHsKICAgICAgcmVzdWx0ID0gcnVuKCdvcGVuY2xhdyBnYXRld2F5IHN0YXR1cyAyPiYxIHx8IHN5c3RlbWN0bCBzdGF0dXMgb3BlbmNsYXctZ2F0ZXdheSAyPiYxIHx8IGVjaG8gIlNlcnZpY2Ugbm90IGZvdW5kIicsIDE1MDAwKTsKICAgIH0gZWxzZSB7CiAgICAgIHJlc3VsdCA9IHJ1bihgb3BlbmNsYXcgZ2F0ZXdheSAke2FjdGlvbn0gMj4mMSB8fCBzeXN0ZW1jdGwgJHthY3Rpb259IG9wZW5jbGF3LWdhdGV3YXkgMj4mMWAsIDE1MDAwKTsKICAgIH0KICAgIHJldHVybiBqc29uKHJlcywgeyByZXN1bHQgfSk7CiAgfQoKICAvLyBMb2dzCiAgaWYgKHBhdGhuYW1lID09PSAnL2FwaS9sb2dzJykgewogICAgY29uc3QgbGluZXMgPSBwYXJzZUludChuZXcgVVJMKHJlcS51cmwsICdodHRwOi8veCcpLnNlYXJjaFBhcmFtcy5nZXQoJ2xpbmVzJykgfHwgJzEwMCcpOwogICAgY29uc3QgcmVzdWx0ID0gcnVuKGBqb3VybmFsY3RsIC11IG9wZW5jbGF3LWdhdGV3YXkgLS1uby1wYWdlciAtbiAke01hdGgubWluKGxpbmVzLCA1MDApfSAyPi9kZXYvbnVsbCB8fCBqb3VybmFsY3RsIC0tbm8tcGFnZXIgLW4gJHtNYXRoLm1pbihsaW5lcywgNTAwKX0gLXQgb3BlbmNsYXcgMj4vZGV2L251bGwgfHwgZWNobyAiTm8gbG9ncyBhdmFpbGFibGUiYCwgMTUwMDApOwogICAgcmV0dXJuIGpzb24ocmVzLCB7IGxvZ3M6IHJlc3VsdCB9KTsKICB9CgogIC8vIE9sbGFtYSBlbmRwb2ludHMKICBpZiAocGF0aG5hbWUgPT09ICcvYXBpL29sbGFtYS9tb2RlbHMnKSB7CiAgICBjb25zdCBkYXRhID0gYXdhaXQgb2xsYW1hRmV0Y2goJy9hcGkvdGFncycpOwogICAgcmV0dXJuIGpzb24ocmVzLCBkYXRhKTsKICB9CiAgaWYgKHBhdGhuYW1lID09PSAnL2FwaS9vbGxhbWEvcnVubmluZycpIHsKICAgIGNvbnN0IGRhdGEgPSBhd2FpdCBvbGxhbWFGZXRjaCgnL2FwaS9wcycpOwogICAgcmV0dXJuIGpzb24ocmVzLCBkYXRhKTsKICB9CiAgaWYgKHBhdGhuYW1lID09PSAnL2FwaS9vbGxhbWEvcHVsbCcgJiYgcmVxLm1ldGhvZCA9PT0gJ1BPU1QnKSB7CiAgICBjb25zdCB7IG1vZGVsIH0gPSBhd2FpdCBwYXJzZUJvZHkocmVxKTsKICAgIGlmICghbW9kZWwpIHJldHVybiBqc29uKHJlcywgeyBlcnJvcjogJ01vZGVsIG5hbWUgcmVxdWlyZWQnIH0sIDQwMCk7CiAgICAvLyBTdHJlYW0gcHVsbCBwcm9ncmVzcyB2aWEgU1NFCiAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAnQ29udGVudC1UeXBlJzogJ3RleHQvZXZlbnQtc3RyZWFtJywgJ0NhY2hlLUNvbnRyb2wnOiAnbm8tY2FjaGUnLCAnQ29ubmVjdGlvbic6ICdrZWVwLWFsaXZlJyB9KTsKICAgIGNvbnN0IHVybCA9IG5ldyBVUkwoJy9hcGkvcHVsbCcsIE9MTEFNQV9VUkwpOwogICAgY29uc3QgcHVsbFJlcSA9IGh0dHAucmVxdWVzdCh7IGhvc3RuYW1lOiB1cmwuaG9zdG5hbWUsIHBvcnQ6IHVybC5wb3J0LCBwYXRoOiB1cmwucGF0aG5hbWUsIG1ldGhvZDogJ1BPU1QnLCBoZWFkZXJzOiB7ICdDb250ZW50LVR5cGUnOiAnYXBwbGljYXRpb24vanNvbicgfSB9LCBwdWxsUmVzID0+IHsKICAgICAgcHVsbFJlcy5vbignZGF0YScsIGNodW5rID0+IHsKICAgICAgICBjb25zdCBsaW5lcyA9IGNodW5rLnRvU3RyaW5nKCkuc3BsaXQoJ1xuJykuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgIGxpbmVzLmZvckVhY2gobCA9PiByZXMud3JpdGUoYGRhdGE6ICR7bH1cblxuYCkpOwogICAgICB9KTsKICAgICAgcHVsbFJlcy5vbignZW5kJywgKCkgPT4geyByZXMud3JpdGUoJ2RhdGE6IHsiZG9uZSI6dHJ1ZX1cblxuJyk7IHJlcy5lbmQoKTsgfSk7CiAgICB9KTsKICAgIHB1bGxSZXEub24oJ2Vycm9yJywgZSA9PiB7IHJlcy53cml0ZShgZGF0YTogeyJlcnJvciI6IiR7ZS5tZXNzYWdlfSJ9XG5cbmApOyByZXMuZW5kKCk7IH0pOwogICAgcHVsbFJlcS53cml0ZShKU09OLnN0cmluZ2lmeSh7IG5hbWU6IG1vZGVsLCBzdHJlYW06IHRydWUgfSkpOwogICAgcHVsbFJlcS5lbmQoKTsKICAgIHJldHVybjsKICB9CiAgaWYgKHBhdGhuYW1lID09PSAnL2FwaS9vbGxhbWEvZGVsZXRlJyAmJiByZXEubWV0aG9kID09PSAnUE9TVCcpIHsKICAgIGNvbnN0IHsgbW9kZWwgfSA9IGF3YWl0IHBhcnNlQm9keShyZXEpOwogICAgY29uc3QgZGF0YSA9IGF3YWl0IG9sbGFtYUZldGNoKCcvYXBpL2RlbGV0ZScsIHsgbWV0aG9kOiAnREVMRVRFJywgYm9keTogeyBuYW1lOiBtb2RlbCB9IH0pOwogICAgcmV0dXJuIGpzb24ocmVzLCBkYXRhLmVycm9yID8gZGF0YSA6IHsgb2s6IHRydWUgfSk7CiAgfQoKICByZXR1cm4ganNvbihyZXMsIHsgZXJyb3I6ICdOb3QgZm91bmQnIH0sIDQwNCk7Cn0KCi8vIOKUgOKUgOKUgCBGcm9udGVuZCBIVE1MIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApmdW5jdGlvbiBnZXRIVE1MKCkgewogIHJldHVybiBgPCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij48bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLGluaXRpYWwtc2NhbGU9MSI+Cjx0aXRsZT5PcGVuQ2xhdyBEYXNoYm9hcmQ8L3RpdGxlPgo8c3R5bGU+Cip7bWFyZ2luOjA7cGFkZGluZzowO2JveC1zaXppbmc6Ym9yZGVyLWJveH0KOnJvb3R7LS1iZzojMGYxMTE3Oy0tc3VyZmFjZTojMWExZDI3Oy0tc3VyZmFjZTI6IzI0MjgzNjstLWJvcmRlcjojMmQzMTQ4Oy0tYWNjZW50OiM2YzVjZTc7LS1hY2NlbnQyOiNhMjliZmU7LS10ZXh0OiNlNGU2ZjA7LS10ZXh0MjojOGI4ZmE4Oy0tZ3JlZW46IzAwYjg5NDstLXJlZDojZmY2YjZiOy0tb3JhbmdlOiNmZGNiNmU7LS1ibHVlOiM3NGI5ZmY7LS1yYWRpdXM6MTBweDstLXNoYWRvdzowIDRweCAyNHB4IHJnYmEoMCwwLDAsLjMpfQpib2R5e2ZvbnQtZmFtaWx5Oi1hcHBsZS1zeXN0ZW0sQmxpbmtNYWNTeXN0ZW1Gb250LCdTZWdvZSBVSScsUm9ib3RvLHNhbnMtc2VyaWY7YmFja2dyb3VuZDp2YXIoLS1iZyk7Y29sb3I6dmFyKC0tdGV4dCk7bWluLWhlaWdodDoxMDB2aDtkaXNwbGF5OmZsZXh9CmF7Y29sb3I6dmFyKC0tYWNjZW50Mik7dGV4dC1kZWNvcmF0aW9uOm5vbmV9CmJ1dHRvbntjdXJzb3I6cG9pbnRlcjtib3JkZXI6bm9uZTtmb250OmluaGVyaXQ7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMpO3BhZGRpbmc6OHB4IDE4cHg7YmFja2dyb3VuZDp2YXIoLS1hY2NlbnQpO2NvbG9yOiNmZmY7dHJhbnNpdGlvbjouMnN9CmJ1dHRvbjpob3ZlcntiYWNrZ3JvdW5kOnZhcigtLWFjY2VudDIpO2NvbG9yOiMxMTF9CmJ1dHRvbi5kYW5nZXJ7YmFja2dyb3VuZDp2YXIoLS1yZWQpfWJ1dHRvbi5kYW5nZXI6aG92ZXJ7YmFja2dyb3VuZDojZTA1NTU1fQpidXR0b24uc2Vjb25kYXJ5e2JhY2tncm91bmQ6dmFyKC0tc3VyZmFjZTIpO2NvbG9yOnZhcigtLXRleHQpfWJ1dHRvbi5zZWNvbmRhcnk6aG92ZXJ7YmFja2dyb3VuZDp2YXIoLS1ib3JkZXIpfQppbnB1dCx0ZXh0YXJlYSxzZWxlY3R7YmFja2dyb3VuZDp2YXIoLS1zdXJmYWNlMik7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2NvbG9yOnZhcigtLXRleHQpO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6dmFyKC0tcmFkaXVzKTtmb250OmluaGVyaXQ7d2lkdGg6MTAwJTtvdXRsaW5lOm5vbmU7dHJhbnNpdGlvbjouMnN9CmlucHV0OmZvY3VzLHRleHRhcmVhOmZvY3VzLHNlbGVjdDpmb2N1c3tib3JkZXItY29sb3I6dmFyKC0tYWNjZW50KX0KdGV4dGFyZWF7cmVzaXplOnZlcnRpY2FsO2ZvbnQtZmFtaWx5OidTRiBNb25vJyxNb25hY28sQ29uc29sYXMsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxM3B4fQouYmFkZ2V7ZGlzcGxheTppbmxpbmUtYmxvY2s7cGFkZGluZzozcHggMTBweDtib3JkZXItcmFkaXVzOjIwcHg7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NjAwfQouYmFkZ2UuZ3JlZW57YmFja2dyb3VuZDpyZ2JhKDAsMTg0LDE0OCwuMTUpO2NvbG9yOnZhcigtLWdyZWVuKX0KLmJhZGdlLnJlZHtiYWNrZ3JvdW5kOnJnYmEoMjU1LDEwNywxMDcsLjE1KTtjb2xvcjp2YXIoLS1yZWQpfQouYmFkZ2Uub3Jhbmdle2JhY2tncm91bmQ6cmdiYSgyNTMsMjAzLDExMCwuMTUpO2NvbG9yOnZhcigtLW9yYW5nZSl9Ci5iYWRnZS5ibHVle2JhY2tncm91bmQ6cmdiYSgxMTYsMTg1LDI1NSwuMTUpO2NvbG9yOnZhcigtLWJsdWUpfQoKLyogTG9naW4gKi8KI2xvZ2luLXBhZ2V7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO3dpZHRoOjEwMCU7bWluLWhlaWdodDoxMDB2aDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOjI0cHh9CiNsb2dpbi1wYWdlIC5sb2dve2ZvbnQtc2l6ZTo0MnB4O2ZvbnQtd2VpZ2h0OjgwMDtsZXR0ZXItc3BhY2luZzotMXB4fQojbG9naW4tcGFnZSAubG9nbyBzcGFue2NvbG9yOnZhcigtLWFjY2VudCl9CiNsb2dpbi1wYWdlIGZvcm17YmFja2dyb3VuZDp2YXIoLS1zdXJmYWNlKTtwYWRkaW5nOjMycHg7Ym9yZGVyLXJhZGl1czoxNnB4O3dpZHRoOjM2MHB4O21heC13aWR0aDo5MHZ3O2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOjE2cHg7Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpfQojbG9naW4tcGFnZSBmb3JtIGgye3RleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxOHB4O2NvbG9yOnZhcigtLXRleHQyKX0KCi8qIExheW91dCAqLwojYXBwe2Rpc3BsYXk6bm9uZTt3aWR0aDoxMDAlO21pbi1oZWlnaHQ6MTAwdmh9Ci5zaWRlYmFye3dpZHRoOjI0MHB4O2JhY2tncm91bmQ6dmFyKC0tc3VyZmFjZSk7Ym9yZGVyLXJpZ2h0OjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47cG9zaXRpb246Zml4ZWQ7dG9wOjA7bGVmdDowO2JvdHRvbTowO3otaW5kZXg6MTB9Ci5zaWRlYmFyIC5sb2dve3BhZGRpbmc6MjRweCAyMHB4O2ZvbnQtc2l6ZToyMnB4O2ZvbnQtd2VpZ2h0OjgwMDtsZXR0ZXItc3BhY2luZzotMXB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcil9Ci5zaWRlYmFyIC5sb2dvIHNwYW57Y29sb3I6dmFyKC0tYWNjZW50KX0KLnNpZGViYXIgbmF2e2ZsZXg6MTtwYWRkaW5nOjEycHh9Ci5zaWRlYmFyIG5hdiBhe2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEycHg7cGFkZGluZzoxMXB4IDE2cHg7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMpO2NvbG9yOnZhcigtLXRleHQyKTt0cmFuc2l0aW9uOi4yczttYXJnaW4tYm90dG9tOjJweDtmb250LXNpemU6MTRweDtmb250LXdlaWdodDo1MDB9Ci5zaWRlYmFyIG5hdiBhOmhvdmVye2JhY2tncm91bmQ6dmFyKC0tc3VyZmFjZTIpO2NvbG9yOnZhcigtLXRleHQpfQouc2lkZWJhciBuYXYgYS5hY3RpdmV7YmFja2dyb3VuZDpyZ2JhKDEwOCw5MiwyMzEsLjE1KTtjb2xvcjp2YXIoLS1hY2NlbnQyKX0KLnNpZGViYXIgbmF2IGEgLmljb257Zm9udC1zaXplOjE4cHg7d2lkdGg6MjRweDt0ZXh0LWFsaWduOmNlbnRlcn0KLnNpZGViYXIgLmJvdHRvbXtwYWRkaW5nOjE2cHggMjBweDtib3JkZXItdG9wOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLXRleHQyKX0KLm1haW57bWFyZ2luLWxlZnQ6MjQwcHg7ZmxleDoxO3BhZGRpbmc6MzJweDttYXgtd2lkdGg6MTEwMHB4fQoubWFpbiBoMXtmb250LXNpemU6MjZweDttYXJnaW4tYm90dG9tOjI0cHg7Zm9udC13ZWlnaHQ6NzAwfQoucGFnZXtkaXNwbGF5Om5vbmV9LnBhZ2UuYWN0aXZle2Rpc3BsYXk6YmxvY2t9CgovKiBDYXJkcyAqLwouY2FyZHN7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczpyZXBlYXQoYXV0by1maWxsLG1pbm1heCgyMjBweCwxZnIpKTtnYXA6MTZweDttYXJnaW4tYm90dG9tOjMycHh9Ci5jYXJke2JhY2tncm91bmQ6dmFyKC0tc3VyZmFjZSk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6dmFyKC0tcmFkaXVzKTtwYWRkaW5nOjIwcHh9Ci5jYXJkIC5sYWJlbHtmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS10ZXh0Mik7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOjFweDttYXJnaW4tYm90dG9tOjhweH0KLmNhcmQgLnZhbHVle2ZvbnQtc2l6ZToyMHB4O2ZvbnQtd2VpZ2h0OjcwMH0KCi8qIEZvcm1zICovCi5mb3JtLWdyb3Vwe21hcmdpbi1ib3R0b206MThweH0KLmZvcm0tZ3JvdXAgbGFiZWx7ZGlzcGxheTpibG9jaztmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdGV4dDIpO21hcmdpbi1ib3R0b206NnB4O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtsZXR0ZXItc3BhY2luZzouNXB4fQouZm9ybS1yb3d7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxNnB4fQouYnRuLXJvd3tkaXNwbGF5OmZsZXg7Z2FwOjEwcHg7bWFyZ2luLXRvcDoyMHB4O2ZsZXgtd3JhcDp3cmFwfQoKLyogTG9nIHZpZXdlciAqLwoubG9nLXZpZXdlcntiYWNrZ3JvdW5kOiMwYTBjMTA7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6dmFyKC0tcmFkaXVzKTtwYWRkaW5nOjE2cHg7Zm9udC1mYW1pbHk6J1NGIE1vbm8nLE1vbmFjbyxDb25zb2xhcyxtb25vc3BhY2U7Zm9udC1zaXplOjEycHg7bGluZS1oZWlnaHQ6MS43O21heC1oZWlnaHQ6NTAwcHg7b3ZlcmZsb3c6YXV0bzt3aGl0ZS1zcGFjZTpwcmUtd3JhcDt3b3JkLWJyZWFrOmJyZWFrLWFsbDtjb2xvcjojYTBhOGMwfQoKLyogVGFibGVzICovCnRhYmxle3dpZHRoOjEwMCU7Ym9yZGVyLWNvbGxhcHNlOmNvbGxhcHNlO2JhY2tncm91bmQ6dmFyKC0tc3VyZmFjZSk7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMpO292ZXJmbG93OmhpZGRlbjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcil9CnRoLHRke3BhZGRpbmc6MTJweCAxNnB4O3RleHQtYWxpZ246bGVmdDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2ZvbnQtc2l6ZToxNHB4fQp0aHtiYWNrZ3JvdW5kOnZhcigtLXN1cmZhY2UyKTtjb2xvcjp2YXIoLS10ZXh0Mik7Zm9udC1zaXplOjEycHg7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi41cHg7Zm9udC13ZWlnaHQ6NjAwfQp0cjpsYXN0LWNoaWxkIHRke2JvcmRlci1ib3R0b206bm9uZX0KCi8qIFRhYnMgKi8KLnRhYnN7ZGlzcGxheTpmbGV4O2dhcDo0cHg7bWFyZ2luLWJvdHRvbToyNHB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7cGFkZGluZy1ib3R0b206MH0KLnRhYnMgYnV0dG9ue2JhY2tncm91bmQ6bm9uZTtjb2xvcjp2YXIoLS10ZXh0Mik7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMpIHZhcigtLXJhZGl1cykgMCAwO3BhZGRpbmc6MTBweCAyMHB4O2JvcmRlci1ib3R0b206MnB4IHNvbGlkIHRyYW5zcGFyZW50fQoudGFicyBidXR0b24uYWN0aXZle2NvbG9yOnZhcigtLWFjY2VudDIpO2JvcmRlci1ib3R0b20tY29sb3I6dmFyKC0tYWNjZW50KTtiYWNrZ3JvdW5kOnJnYmEoMTA4LDkyLDIzMSwuMDgpfQoKLyogUHJvZ3Jlc3MgKi8KLnByb2dyZXNzLWJhcnt3aWR0aDoxMDAlO2hlaWdodDo2cHg7YmFja2dyb3VuZDp2YXIoLS1zdXJmYWNlMik7Ym9yZGVyLXJhZGl1czozcHg7b3ZlcmZsb3c6aGlkZGVuO21hcmdpbi10b3A6OHB4fQoucHJvZ3Jlc3MtYmFyIC5maWxse2hlaWdodDoxMDAlO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLWFjY2VudCksdmFyKC0tYWNjZW50MikpO3RyYW5zaXRpb246d2lkdGggLjNzO2JvcmRlci1yYWRpdXM6M3B4fQoKLyogVG9hc3QgKi8KLnRvYXN0e3Bvc2l0aW9uOmZpeGVkO2JvdHRvbToyNHB4O3JpZ2h0OjI0cHg7YmFja2dyb3VuZDp2YXIoLS1zdXJmYWNlKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7cGFkZGluZzoxNHB4IDI0cHg7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMpO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt6LWluZGV4Ojk5OTthbmltYXRpb246c2xpZGVJbiAuM3M7Zm9udC1zaXplOjE0cHh9Ci50b2FzdC5lcnJvcntib3JkZXItY29sb3I6dmFyKC0tcmVkKTtjb2xvcjp2YXIoLS1yZWQpfQoudG9hc3Quc3VjY2Vzc3tib3JkZXItY29sb3I6dmFyKC0tZ3JlZW4pO2NvbG9yOnZhcigtLWdyZWVuKX0KQGtleWZyYW1lcyBzbGlkZUlue2Zyb217dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMjBweCk7b3BhY2l0eTowfXRve3RyYW5zZm9ybTp0cmFuc2xhdGVZKDApO29wYWNpdHk6MX19CgovKiBNb2JpbGUgKi8KQG1lZGlhKG1heC13aWR0aDo3NjhweCl7CiAgLnNpZGViYXJ7d2lkdGg6NjBweH0uc2lkZWJhciAubG9nb3twYWRkaW5nOjE2cHg7Zm9udC1zaXplOjB9LnNpZGViYXIgLmxvZ286OmFmdGVye2NvbnRlbnQ6J/CfkL4nO2ZvbnQtc2l6ZToyNHB4fQogIC5zaWRlYmFyIG5hdiBhIHNwYW57ZGlzcGxheTpub25lfS5zaWRlYmFyIG5hdiBhe2p1c3RpZnktY29udGVudDpjZW50ZXI7cGFkZGluZzoxNHB4fQogIC5zaWRlYmFyIC5ib3R0b217ZGlzcGxheTpub25lfS5tYWlue21hcmdpbi1sZWZ0OjYwcHg7cGFkZGluZzoyMHB4fQogIC5mb3JtLXJvd3tncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfS5jYXJkc3tncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfQp9Cjwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+Cgo8IS0tIExvZ2luIC0tPgo8ZGl2IGlkPSJsb2dpbi1wYWdlIj4KICA8ZGl2IGNsYXNzPSJsb2dvIj5PcGVuPHNwYW4+Q2xhdzwvc3Bhbj4g8J+QvjwvZGl2PgogIDxmb3JtIG9uc3VibWl0PSJkb0xvZ2luKGV2ZW50KSI+CiAgICA8aDI+RGFzaGJvYXJkIExvZ2luPC9oMj4KICAgIDxpbnB1dCB0eXBlPSJwYXNzd29yZCIgaWQ9ImxvZ2luLXBhc3MiIHBsYWNlaG9sZGVyPSJQYXNzd29yZCIgYXV0b2ZvY3VzPgogICAgPGJ1dHRvbiB0eXBlPSJzdWJtaXQiIHN0eWxlPSJ3aWR0aDoxMDAlIj5TaWduIEluPC9idXR0b24+CiAgICA8ZGl2IGlkPSJsb2dpbi1lcnJvciIgc3R5bGU9ImNvbG9yOnZhcigtLXJlZCk7dGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEzcHgiPjwvZGl2PgogIDwvZm9ybT4KPC9kaXY+Cgo8IS0tIEFwcCAtLT4KPGRpdiBpZD0iYXBwIj4KICA8YXNpZGUgY2xhc3M9InNpZGViYXIiPgogICAgPGRpdiBjbGFzcz0ibG9nbyI+T3BlbjxzcGFuPkNsYXc8L3NwYW4+PC9kaXY+CiAgICA8bmF2PgogICAgICA8YSBocmVmPSIjIiBkYXRhLXBhZ2U9ImRhc2hib2FyZCIgY2xhc3M9ImFjdGl2ZSI+PHNwYW4gY2xhc3M9Imljb24iPvCfk4o8L3NwYW4+PHNwYW4+RGFzaGJvYXJkPC9zcGFuPjwvYT4KICAgICAgPGEgaHJlZj0iIyIgZGF0YS1wYWdlPSJwcm92aWRlcnMiPjxzcGFuIGNsYXNzPSJpY29uIj7wn6SWPC9zcGFuPjxzcGFuPlByb3ZpZGVyczwvc3Bhbj48L2E+CiAgICAgIDxhIGhyZWY9IiMiIGRhdGEtcGFnZT0ib2xsYW1hIj48c3BhbiBjbGFzcz0iaWNvbiI+8J+mmTwvc3Bhbj48c3Bhbj5PbGxhbWE8L3NwYW4+PC9hPgogICAgICA8YSBocmVmPSIjIiBkYXRhLXBhZ2U9ImNvbmZpZyI+PHNwYW4gY2xhc3M9Imljb24iPuKame+4jzwvc3Bhbj48c3Bhbj5Db25maWc8L3NwYW4+PC9hPgogICAgICA8YSBocmVmPSIjIiBkYXRhLXBhZ2U9InNlcnZpY2VzIj48c3BhbiBjbGFzcz0iaWNvbiI+8J+Upzwvc3Bhbj48c3Bhbj5TZXJ2aWNlczwvc3Bhbj48L2E+CiAgICAgIDxhIGhyZWY9IiMiIGRhdGEtcGFnZT0iY2hhbm5lbHMiPjxzcGFuIGNsYXNzPSJpY29uIj7wn5KsPC9zcGFuPjxzcGFuPkNoYW5uZWxzPC9zcGFuPjwvYT4KICAgIDwvbmF2PgogICAgPGRpdiBjbGFzcz0iYm90dG9tIj4KICAgICAgPGEgaHJlZj0iIyIgb25jbGljaz0iZG9Mb2dvdXQoKSIgc3R5bGU9ImNvbG9yOnZhcigtLXRleHQyKTtmb250LXNpemU6MTNweCI+8J+aqiBMb2dvdXQ8L2E+CiAgICA8L2Rpdj4KICA8L2FzaWRlPgoKICA8ZGl2IGNsYXNzPSJtYWluIj4KICAgIDwhLS0gRGFzaGJvYXJkIC0tPgogICAgPGRpdiBjbGFzcz0icGFnZSBhY3RpdmUiIGlkPSJwYWdlLWRhc2hib2FyZCI+CiAgICAgIDxoMT5EYXNoYm9hcmQ8L2gxPgogICAgICA8ZGl2IGNsYXNzPSJjYXJkcyIgaWQ9InN0YXR1cy1jYXJkcyI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImJ0bi1yb3ciPjxidXR0b24gb25jbGljaz0ibG9hZERhc2hib2FyZCgpIj7wn5SEIFJlZnJlc2g8L2J1dHRvbj48L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0gUHJvdmlkZXJzIC0tPgogICAgPGRpdiBjbGFzcz0icGFnZSIgaWQ9InBhZ2UtcHJvdmlkZXJzIj4KICAgICAgPGgxPkFJIFByb3ZpZGVyIENvbmZpZ3VyYXRpb248L2gxPgogICAgICA8ZGl2IGNsYXNzPSJ0YWJzIiBpZD0icHJvdmlkZXItdGFicyI+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYWN0aXZlIiBkYXRhLXByb3ZpZGVyPSJvbGxhbWEiPk9sbGFtYTwvYnV0dG9uPgogICAgICAgIDxidXR0b24gZGF0YS1wcm92aWRlcj0iYW50aHJvcGljIj5BbnRocm9waWM8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGRhdGEtcHJvdmlkZXI9Im9wZW5haSI+T3BlbkFJPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBkYXRhLXByb3ZpZGVyPSJjdXN0b20iPkN1c3RvbTwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBpZD0icHJvdmlkZXItZm9ybXMiPgogICAgICAgIDxkaXYgY2xhc3M9InByb3ZpZGVyLWZvcm0gYWN0aXZlIiBkYXRhLXByb3ZpZGVyPSJvbGxhbWEiPgogICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncm91cCI+PGxhYmVsPk9sbGFtYSBVUkw8L2xhYmVsPjxpbnB1dCBpZD0icC1vbGxhbWEtdXJsIiBwbGFjZWhvbGRlcj0iaHR0cDovL2xvY2FsaG9zdDoxMTQzNCI+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+TW9kZWw8L2xhYmVsPjxzZWxlY3QgaWQ9InAtb2xsYW1hLW1vZGVsIj48b3B0aW9uPkxvYWRpbmcuLi48L29wdGlvbj48L3NlbGVjdD4gPGJ1dHRvbiBjbGFzcz0ic2Vjb25kYXJ5IiBvbmNsaWNrPSJyZWZyZXNoT2xsYW1hTW9kZWxzKCkiIHN0eWxlPSJtYXJnaW4tdG9wOjhweCI+UmVmcmVzaCBNb2RlbHM8L2J1dHRvbj48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwcm92aWRlci1mb3JtIiBkYXRhLXByb3ZpZGVyPSJhbnRocm9waWMiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncm91cCI+PGxhYmVsPkFQSSBLZXk8L2xhYmVsPjxpbnB1dCBpZD0icC1hbnRocm9waWMta2V5IiB0eXBlPSJwYXNzd29yZCIgcGxhY2Vob2xkZXI9InNrLWFudC0uLi4iPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncm91cCI+PGxhYmVsPk1vZGVsPC9sYWJlbD48c2VsZWN0IGlkPSJwLWFudGhyb3BpYy1tb2RlbCI+CiAgICAgICAgICAgIDxvcHRpb24+Y2xhdWRlLW9wdXMtNC0yMDI1MDUxNDwvb3B0aW9uPjxvcHRpb24+Y2xhdWRlLXNvbm5ldC00LTIwMjUwNTE0PC9vcHRpb24+PG9wdGlvbj5jbGF1ZGUtMy01LWhhaWt1LTIwMjQxMDIyPC9vcHRpb24+PG9wdGlvbj5jbGF1ZGUtMy01LXNvbm5ldC0yMDI0MTAyMjwvb3B0aW9uPgogICAgICAgICAgPC9zZWxlY3Q+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icHJvdmlkZXItZm9ybSIgZGF0YS1wcm92aWRlcj0ib3BlbmFpIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5BUEkgS2V5PC9sYWJlbD48aW5wdXQgaWQ9InAtb3BlbmFpLWtleSIgdHlwZT0icGFzc3dvcmQiIHBsYWNlaG9sZGVyPSJzay0uLi4iPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncm91cCI+PGxhYmVsPk1vZGVsPC9sYWJlbD48c2VsZWN0IGlkPSJwLW9wZW5haS1tb2RlbCI+CiAgICAgICAgICAgIDxvcHRpb24+Z3B0LTRvPC9vcHRpb24+PG9wdGlvbj5ncHQtNG8tbWluaTwvb3B0aW9uPjxvcHRpb24+Z3B0LTQtdHVyYm88L29wdGlvbj48b3B0aW9uPm8xPC9vcHRpb24+PG9wdGlvbj5vMS1taW5pPC9vcHRpb24+PG9wdGlvbj5vMy1taW5pPC9vcHRpb24+CiAgICAgICAgICA8L3NlbGVjdD48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwcm92aWRlci1mb3JtIiBkYXRhLXByb3ZpZGVyPSJjdXN0b20iIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncm91cCI+PGxhYmVsPkJhc2UgVVJMPC9sYWJlbD48aW5wdXQgaWQ9InAtY3VzdG9tLXVybCIgcGxhY2Vob2xkZXI9Imh0dHBzOi8vYXBpLmV4YW1wbGUuY29tL3YxIj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5BUEkgS2V5PC9sYWJlbD48aW5wdXQgaWQ9InAtY3VzdG9tLWtleSIgdHlwZT0icGFzc3dvcmQiIHBsYWNlaG9sZGVyPSJBUEkga2V5Ij48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5Nb2RlbCBOYW1lPC9sYWJlbD48aW5wdXQgaWQ9InAtY3VzdG9tLW1vZGVsIiBwbGFjZWhvbGRlcj0ibW9kZWwtbmFtZSI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJidG4tcm93Ij48YnV0dG9uIG9uY2xpY2s9InNhdmVQcm92aWRlcigpIj7wn5K+IFNhdmUgUHJvdmlkZXIgQ29uZmlnPC9idXR0b24+PC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIE9sbGFtYSAtLT4KICAgIDxkaXYgY2xhc3M9InBhZ2UiIGlkPSJwYWdlLW9sbGFtYSI+CiAgICAgIDxoMT5PbGxhbWEgTWFuYWdlbWVudDwvaDE+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tcm93IiBzdHlsZT0ibWFyZ2luLWJvdHRvbToyNHB4Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+UHVsbCBOZXcgTW9kZWw8L2xhYmVsPgogICAgICAgICAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2dhcDo4cHgiPjxpbnB1dCBpZD0ib2xsYW1hLXB1bGwtbmFtZSIgcGxhY2Vob2xkZXI9ImxsYW1hMzo4YiI+PGJ1dHRvbiBvbmNsaWNrPSJwdWxsTW9kZWwoKSI+4qyH77iPIFB1bGw8L2J1dHRvbj48L2Rpdj4KICAgICAgICAgIDxkaXYgaWQ9InB1bGwtcHJvZ3Jlc3MiIHN0eWxlPSJtYXJnaW4tdG9wOjEycHgiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGgyIHN0eWxlPSJmb250LXNpemU6MThweDttYXJnaW4tYm90dG9tOjEycHgiPkluc3RhbGxlZCBNb2RlbHM8L2gyPgogICAgICA8dGFibGU+PHRoZWFkPjx0cj48dGg+TW9kZWw8L3RoPjx0aD5TaXplPC90aD48dGg+TW9kaWZpZWQ8L3RoPjx0aD5BY3Rpb25zPC90aD48L3RyPjwvdGhlYWQ+PHRib2R5IGlkPSJvbGxhbWEtbW9kZWxzLWxpc3QiPjx0cj48dGQgY29sc3Bhbj0iNCI+TG9hZGluZy4uLjwvdGQ+PC90cj48L3Rib2R5PjwvdGFibGU+CiAgICAgIDxoMiBzdHlsZT0iZm9udC1zaXplOjE4cHg7bWFyZ2luOjI0cHggMCAxMnB4Ij5SdW5uaW5nIE1vZGVsczwvaDI+CiAgICAgIDx0YWJsZT48dGhlYWQ+PHRyPjx0aD5Nb2RlbDwvdGg+PHRoPlNpemU8L3RoPjx0aD5Qcm9jZXNzb3I8L3RoPjx0aD5VbnRpbDwvdGg+PC90cj48L3RoZWFkPjx0Ym9keSBpZD0ib2xsYW1hLXJ1bm5pbmctbGlzdCI+PHRyPjx0ZCBjb2xzcGFuPSI0Ij5Mb2FkaW5nLi4uPC90ZD48L3RyPjwvdGJvZHk+PC90YWJsZT4KICAgICAgPGRpdiBjbGFzcz0iYnRuLXJvdyIgc3R5bGU9Im1hcmdpbi10b3A6MTZweCI+PGJ1dHRvbiBvbmNsaWNrPSJsb2FkT2xsYW1hKCkiPvCflIQgUmVmcmVzaDwvYnV0dG9uPjwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSBDb25maWcgLS0+CiAgICA8ZGl2IGNsYXNzPSJwYWdlIiBpZD0icGFnZS1jb25maWciPgogICAgICA8aDE+T3BlbkNsYXcgQ29uZmlndXJhdGlvbjwvaDE+CiAgICAgIDxkaXYgY2xhc3M9InRhYnMiIGlkPSJjb25maWctdGFicyI+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYWN0aXZlIiBkYXRhLXRhYj0iZm9ybSI+Rm9ybSBFZGl0b3I8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGRhdGEtdGFiPSJqc29uIj5SYXcgSlNPTjwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBpZD0iY29uZmlnLWZvcm0tdmlldyI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1yb3ciPgogICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncm91cCI+PGxhYmVsPkdhdGV3YXkgUG9ydDwvbGFiZWw+PGlucHV0IGlkPSJjZmctcG9ydCIgdHlwZT0ibnVtYmVyIiBwbGFjZWhvbGRlcj0iMzAwMCI+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+QmluZCBBZGRyZXNzPC9sYWJlbD48aW5wdXQgaWQ9ImNmZy1iaW5kIiBwbGFjZWhvbGRlcj0iMC4wLjAuMCI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1yb3ciPgogICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncm91cCI+PGxhYmVsPkRlZmF1bHQgTW9kZWw8L2xhYmVsPjxpbnB1dCBpZD0iY2ZnLW1vZGVsIiBwbGFjZWhvbGRlcj0iYW50aHJvcGljL2NsYXVkZS1zb25uZXQtNC0yMDI1MDUxNCI+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+TG9nIExldmVsPC9sYWJlbD48c2VsZWN0IGlkPSJjZmctbG9nbGV2ZWwiPjxvcHRpb24+ZGVidWc8L29wdGlvbj48b3B0aW9uPmluZm88L29wdGlvbj48b3B0aW9uPndhcm48L29wdGlvbj48b3B0aW9uPmVycm9yPC9vcHRpb24+PC9zZWxlY3Q+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncm91cCI+PGxhYmVsPkFsbG93ZWQgT3JpZ2lucyAoY29tbWEtc2VwYXJhdGVkKTwvbGFiZWw+PGlucHV0IGlkPSJjZmctb3JpZ2lucyIgcGxhY2Vob2xkZXI9IioiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBpZD0iY29uZmlnLWpzb24tdmlldyIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncm91cCI+PHRleHRhcmVhIGlkPSJjZmctcmF3IiByb3dzPSIyMCIgcGxhY2Vob2xkZXI9IkxvYWRpbmcuLi4iPjwvdGV4dGFyZWE+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJidG4tcm93Ij4KICAgICAgICA8YnV0dG9uIG9uY2xpY2s9InNhdmVDb25maWcoKSI+8J+SviBTYXZlIENvbmZpZ3VyYXRpb248L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJzZWNvbmRhcnkiIG9uY2xpY2s9ImxvYWRDb25maWcoKSI+8J+UhCBSZWxvYWQ8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNlcnZpY2VzIC0tPgogICAgPGRpdiBjbGFzcz0icGFnZSIgaWQ9InBhZ2Utc2VydmljZXMiPgogICAgICA8aDE+U2VydmljZSBDb250cm9sczwvaDE+CiAgICAgIDxkaXYgY2xhc3M9ImNhcmQiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjI0cHgiPgogICAgICAgIDxkaXYgY2xhc3M9ImxhYmVsIj5PcGVuQ2xhdyBHYXRld2F5PC9kaXY+CiAgICAgICAgPGRpdiBpZD0ic3ZjLXN0YXR1cyIgY2xhc3M9InZhbHVlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbToxNnB4Ij5DaGVja2luZy4uLjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImJ0bi1yb3ciPgogICAgICAgICAgPGJ1dHRvbiBvbmNsaWNrPSJzdmNBY3Rpb24oJ3N0YXJ0JykiIHN0eWxlPSJiYWNrZ3JvdW5kOnZhcigtLWdyZWVuKSI+4pa2IFN0YXJ0PC9idXR0b24+CiAgICAgICAgICA8YnV0dG9uIG9uY2xpY2s9InN2Y0FjdGlvbignc3RvcCcpIiBjbGFzcz0iZGFuZ2VyIj7ij7kgU3RvcDwvYnV0dG9uPgogICAgICAgICAgPGJ1dHRvbiBvbmNsaWNrPSJzdmNBY3Rpb24oJ3Jlc3RhcnQnKSIgc3R5bGU9ImJhY2tncm91bmQ6dmFyKC0tb3JhbmdlKTtjb2xvcjojMTExIj7wn5SEIFJlc3RhcnQ8L2J1dHRvbj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9InNlY29uZGFyeSIgb25jbGljaz0ic3ZjQWN0aW9uKCdzdGF0dXMnKSI+8J+TiiBTdGF0dXM8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxoMiBzdHlsZT0iZm9udC1zaXplOjE4cHg7bWFyZ2luLWJvdHRvbToxMnB4Ij5SZWNlbnQgTG9nczwvaDI+CiAgICAgIDxkaXYgc3R5bGU9Im1hcmdpbi1ib3R0b206MTJweCI+CiAgICAgICAgPHNlbGVjdCBpZD0ibG9nLWxpbmVzIiBvbmNoYW5nZT0ibG9hZExvZ3MoKSIgc3R5bGU9IndpZHRoOmF1dG87ZGlzcGxheTppbmxpbmUtYmxvY2siPgogICAgICAgICAgPG9wdGlvbiB2YWx1ZT0iNTAiPjUwIGxpbmVzPC9vcHRpb24+PG9wdGlvbiB2YWx1ZT0iMTAwIiBzZWxlY3RlZD4xMDAgbGluZXM8L29wdGlvbj48b3B0aW9uIHZhbHVlPSIyMDAiPjIwMCBsaW5lczwvb3B0aW9uPjxvcHRpb24gdmFsdWU9IjUwMCI+NTAwIGxpbmVzPC9vcHRpb24+CiAgICAgICAgPC9zZWxlY3Q+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0ic2Vjb25kYXJ5IiBvbmNsaWNrPSJsb2FkTG9ncygpIiBzdHlsZT0ibWFyZ2luLWxlZnQ6OHB4Ij7wn5SEIFJlZnJlc2g8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImxvZy12aWV3ZXIiIGlkPSJsb2ctb3V0cHV0Ij5Mb2FkaW5nLi4uPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIENoYW5uZWxzIC0tPgogICAgPGRpdiBjbGFzcz0icGFnZSIgaWQ9InBhZ2UtY2hhbm5lbHMiPgogICAgICA8aDE+Q2hhbm5lbCBDb25maWd1cmF0aW9uPC9oMT4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi1ib3R0b206MjRweCI+CiAgICAgICAgPGgzIHN0eWxlPSJtYXJnaW4tYm90dG9tOjE2cHgiPlRlbGVncmFtPC9oMz4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+Qm90IFRva2VuPC9sYWJlbD48aW5wdXQgaWQ9ImNoLXRnLXRva2VuIiB0eXBlPSJwYXNzd29yZCIgcGxhY2Vob2xkZXI9IjEyMzQ1NjpBQkMtLi4uIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+QWxsb3dlZCBDaGF0IElEcyAoY29tbWEtc2VwYXJhdGVkKTwvbGFiZWw+PGlucHV0IGlkPSJjaC10Zy1jaGF0cyIgcGxhY2Vob2xkZXI9Ii0xMDAxMjM0NTY3ODkiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5XZWJob29rIFVSTCAob3B0aW9uYWwpPC9sYWJlbD48aW5wdXQgaWQ9ImNoLXRnLXdlYmhvb2siIHBsYWNlaG9sZGVyPSJodHRwczovL3lvdXItZG9tYWluLmNvbS93ZWJob29rL3RlbGVncmFtIj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImNhcmQiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjI0cHgiPgogICAgICAgIDxoMyBzdHlsZT0ibWFyZ2luLWJvdHRvbToxNnB4Ij5EaXNjb3JkPC9oMz4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+Qm90IFRva2VuPC9sYWJlbD48aW5wdXQgaWQ9ImNoLWRjLXRva2VuIiB0eXBlPSJwYXNzd29yZCIgcGxhY2Vob2xkZXI9IkRpc2NvcmQgYm90IHRva2VuIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+R3VpbGQgSUQ8L2xhYmVsPjxpbnB1dCBpZD0iY2gtZGMtZ3VpbGQiIHBsYWNlaG9sZGVyPSJTZXJ2ZXIgSUQiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYnRuLXJvdyI+PGJ1dHRvbiBvbmNsaWNrPSJzYXZlQ2hhbm5lbHMoKSI+8J+SviBTYXZlIENoYW5uZWwgQ29uZmlnPC9idXR0b24+PC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9kaXY+Cgo8c2NyaXB0Pgpjb25zdCBBUEkgPSAnJzsKbGV0IGN1cnJlbnRDb25maWcgPSB7fTsKCi8vIOKUgOKUgCBBdXRoIOKUgOKUgAphc3luYyBmdW5jdGlvbiBkb0xvZ2luKGUpIHsKICBlLnByZXZlbnREZWZhdWx0KCk7CiAgY29uc3QgcmVzID0gYXdhaXQgZmV0Y2goQVBJKycvYXBpL2xvZ2luJywgeyBtZXRob2Q6J1BPU1QnLCBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LCBib2R5OiBKU09OLnN0cmluZ2lmeSh7cGFzc3dvcmQ6IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsb2dpbi1wYXNzJykudmFsdWV9KSB9KTsKICBpZiAocmVzLm9rKSB7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsb2dpbi1wYWdlJykuc3R5bGUuZGlzcGxheT0nbm9uZSc7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAnKS5zdHlsZS5kaXNwbGF5PSdmbGV4JzsgaW5pdCgpOyB9CiAgZWxzZSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9naW4tZXJyb3InKS50ZXh0Q29udGVudCA9ICdJbnZhbGlkIHBhc3N3b3JkJzsKfQphc3luYyBmdW5jdGlvbiBkb0xvZ291dCgpIHsgYXdhaXQgZmV0Y2goQVBJKycvYXBpL2xvZ291dCcpOyBsb2NhdGlvbi5yZWxvYWQoKTsgfQoKLy8g4pSA4pSAIFRvYXN0IOKUgOKUgApmdW5jdGlvbiB0b2FzdChtc2csIHR5cGU9J3N1Y2Nlc3MnKSB7CiAgY29uc3QgdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOyB0LmNsYXNzTmFtZT0ndG9hc3QgJyt0eXBlOyB0LnRleHRDb250ZW50PW1zZzsgZG9jdW1lbnQuYm9keS5hcHBlbmRDaGlsZCh0KTsKICBzZXRUaW1lb3V0KCgpPT50LnJlbW92ZSgpLCAzMDAwKTsKfQoKLy8g4pSA4pSAIE5hdmlnYXRpb24g4pSA4pSACmRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5zaWRlYmFyIG5hdiBhJykuZm9yRWFjaChhID0+IGEuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICBlLnByZXZlbnREZWZhdWx0KCk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnNpZGViYXIgbmF2IGEnKS5mb3JFYWNoKHg9PnguY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGEuY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnBhZ2UnKS5mb3JFYWNoKHA9PnAuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYWdlLScrYS5kYXRhc2V0LnBhZ2UpLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGlmIChhLmRhdGFzZXQucGFnZT09PSdkYXNoYm9hcmQnKSBsb2FkRGFzaGJvYXJkKCk7CiAgaWYgKGEuZGF0YXNldC5wYWdlPT09J29sbGFtYScpIGxvYWRPbGxhbWEoKTsKICBpZiAoYS5kYXRhc2V0LnBhZ2U9PT0nY29uZmlnJykgbG9hZENvbmZpZygpOwogIGlmIChhLmRhdGFzZXQucGFnZT09PSdzZXJ2aWNlcycpIHsgc3ZjQWN0aW9uKCdzdGF0dXMnKTsgbG9hZExvZ3MoKTsgfQogIGlmIChhLmRhdGFzZXQucGFnZT09PSdwcm92aWRlcnMnKSBsb2FkUHJvdmlkZXJzKCk7CiAgaWYgKGEuZGF0YXNldC5wYWdlPT09J2NoYW5uZWxzJykgbG9hZENoYW5uZWxzKCk7Cn0pKTsKCi8vIFByb3ZpZGVyIHRhYnMKZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnI3Byb3ZpZGVyLXRhYnMgYnV0dG9uJykuZm9yRWFjaChiID0+IGIuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9PiB7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnI3Byb3ZpZGVyLXRhYnMgYnV0dG9uJykuZm9yRWFjaCh4PT54LmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBiLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5wcm92aWRlci1mb3JtJykuZm9yRWFjaChmPT57Zi5zdHlsZS5kaXNwbGF5PWYuZGF0YXNldC5wcm92aWRlcj09PWIuZGF0YXNldC5wcm92aWRlcj8nYmxvY2snOidub25lJ30pOwp9KSk7CgovLyBDb25maWcgdGFicwpkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcjY29uZmlnLXRhYnMgYnV0dG9uJykuZm9yRWFjaChiID0+IGIuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9PiB7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnI2NvbmZpZy10YWJzIGJ1dHRvbicpLmZvckVhY2goeD0+eC5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgYi5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY29uZmlnLWZvcm0tdmlldycpLnN0eWxlLmRpc3BsYXkgPSBiLmRhdGFzZXQudGFiPT09J2Zvcm0nPydibG9jayc6J25vbmUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjb25maWctanNvbi12aWV3Jykuc3R5bGUuZGlzcGxheSA9IGIuZGF0YXNldC50YWI9PT0nanNvbic/J2Jsb2NrJzonbm9uZSc7CiAgaWYgKGIuZGF0YXNldC50YWI9PT0nanNvbicpIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctcmF3JykudmFsdWUgPSBKU09OLnN0cmluZ2lmeShjdXJyZW50Q29uZmlnLCBudWxsLCAyKTsKfSkpOwoKLy8g4pSA4pSAIERhc2hib2FyZCDilIDilIAKYXN5bmMgZnVuY3Rpb24gbG9hZERhc2hib2FyZCgpIHsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2FwaS9zdGF0dXMnKTsgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpOwogICAgY29uc3QgaXNBY3RpdmUgPSBzID0+IHMgJiYgKHMuaW5jbHVkZXMoJ2FjdGl2ZScpIHx8IHMuaW5jbHVkZXMoJ3J1bm5pbmcnKSk7CiAgICBjb25zdCBiYWRnZSA9IChzLCBsYWJlbCkgPT4gewogICAgICBpZiAoIWxhYmVsKSBsYWJlbCA9IHM7CiAgICAgIHJldHVybiBpc0FjdGl2ZShzKSA/ICc8c3BhbiBjbGFzcz0iYmFkZ2UgZ3JlZW4iPicrbGFiZWwrJzwvc3Bhbj4nIDogcz09PSdvZmZsaW5lJ3x8cz09PSdpbmFjdGl2ZSc/JzxzcGFuIGNsYXNzPSJiYWRnZSByZWQiPicrbGFiZWwrJzwvc3Bhbj4nOic8c3BhbiBjbGFzcz0iYmFkZ2Ugb3JhbmdlIj4nK2xhYmVsKyc8L3NwYW4+JzsKICAgIH07CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3RhdHVzLWNhcmRzJykuaW5uZXJIVE1MID0gWwogICAgICB7bGFiZWw6J0dhdGV3YXknLCB2YWx1ZTogYmFkZ2UoZC5nYXRld2F5LCBkLmdhdGV3YXkpfSwKICAgICAge2xhYmVsOidEb2NrZXInLCB2YWx1ZTogYmFkZ2UoZC5kb2NrZXIsIGQuZG9ja2VyKX0sCiAgICAgIHtsYWJlbDonT2xsYW1hJywgdmFsdWU6IGQub2xsYW1hPT09J29mZmxpbmUnPyc8c3BhbiBjbGFzcz0iYmFkZ2UgcmVkIj5PZmZsaW5lPC9zcGFuPic6JzxzcGFuIGNsYXNzPSJiYWRnZSBncmVlbiI+JytkLm9sbGFtYSsnPC9zcGFuPid9LAogICAgICB7bGFiZWw6J0hvc3RuYW1lJywgdmFsdWU6IGQuaG9zdG5hbWV9LAogICAgICB7bGFiZWw6J1VwdGltZScsIHZhbHVlOiBkLnVwdGltZX0sCiAgICAgIHtsYWJlbDonTWVtb3J5JywgdmFsdWU6IGQubWVtfSwKICAgICAge2xhYmVsOidEaXNrJywgdmFsdWU6IGQuZGlza30sCiAgICAgIHtsYWJlbDonQ1BVIENvcmVzIC8gTG9hZCcsIHZhbHVlOiBkLmNwdSsnIC8gJytkLmxvYWR9LAogICAgXS5tYXAoYz0+JzxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9ImxhYmVsIj4nK2MubGFiZWwrJzwvZGl2PjxkaXYgY2xhc3M9InZhbHVlIiBzdHlsZT0iZm9udC1zaXplOjE2cHgiPicrYy52YWx1ZSsnPC9kaXY+PC9kaXY+Jykuam9pbignJyk7CiAgfSBjYXRjaChlKSB7IHRvYXN0KCdGYWlsZWQgdG8gbG9hZCBzdGF0dXMnLCdlcnJvcicpOyB9Cn0KCi8vIOKUgOKUgCBPbGxhbWEg4pSA4pSACmFzeW5jIGZ1bmN0aW9uIGxvYWRPbGxhbWEoKSB7CiAgdHJ5IHsKICAgIGNvbnN0IFttb2RlbHMsIHJ1bm5pbmddID0gYXdhaXQgUHJvbWlzZS5hbGwoW2ZldGNoKEFQSSsnL2FwaS9vbGxhbWEvbW9kZWxzJykudGhlbihyPT5yLmpzb24oKSksIGZldGNoKEFQSSsnL2FwaS9vbGxhbWEvcnVubmluZycpLnRoZW4ocj0+ci5qc29uKCkpXSk7CiAgICBjb25zdCBtbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbGxhbWEtbW9kZWxzLWxpc3QnKTsKICAgIGlmIChtb2RlbHMubW9kZWxzICYmIG1vZGVscy5tb2RlbHMubGVuZ3RoKSB7CiAgICAgIG1sLmlubmVySFRNTCA9IG1vZGVscy5tb2RlbHMubWFwKG0gPT4gJzx0cj48dGQ+PHN0cm9uZz4nK20ubmFtZSsnPC9zdHJvbmc+PC90ZD48dGQ+JysobS5zaXplPyhtLnNpemUvMWU5KS50b0ZpeGVkKDEpKydHQic6Jz8nKSsnPC90ZD48dGQ+JysobS5tb2RpZmllZF9hdHx8JycpLnNsaWNlKDAsMTApKyc8L3RkPjx0ZD48YnV0dG9uIGNsYXNzPSJkYW5nZXIiIG9uY2xpY2s9ImRlbGV0ZU1vZGVsKFxcJycrbS5uYW1lKydcXCcpIj7wn5eRPC9idXR0b24+PC90ZD48L3RyPicpLmpvaW4oJycpOwogICAgfSBlbHNlIG1sLmlubmVySFRNTD0nPHRyPjx0ZCBjb2xzcGFuPSI0Ij5ObyBtb2RlbHMgZm91bmQuIElzIE9sbGFtYSBydW5uaW5nPzwvdGQ+PC90cj4nOwoKICAgIGNvbnN0IHJsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29sbGFtYS1ydW5uaW5nLWxpc3QnKTsKICAgIGlmIChydW5uaW5nLm1vZGVscyAmJiBydW5uaW5nLm1vZGVscy5sZW5ndGgpIHsKICAgICAgcmwuaW5uZXJIVE1MID0gcnVubmluZy5tb2RlbHMubWFwKG09Pic8dHI+PHRkPicrbS5uYW1lKyc8L3RkPjx0ZD4nKyhtLnNpemU/KG0uc2l6ZS8xZTkpLnRvRml4ZWQoMSkrJ0dCJzonPycpKyc8L3RkPjx0ZD4nKyhtLnNpemVfdnJhbT8nR1BVJzonQ1BVJykrJzwvdGQ+PHRkPicrKG0uZXhwaXJlc19hdHx8JycpKyc8L3RkPjwvdHI+Jykuam9pbignJyk7CiAgICB9IGVsc2UgcmwuaW5uZXJIVE1MPSc8dHI+PHRkIGNvbHNwYW49IjQiPk5vIHJ1bm5pbmcgbW9kZWxzPC90ZD48L3RyPic7CiAgfSBjYXRjaChlKSB7IHRvYXN0KCdGYWlsZWQgdG8gbG9hZCBPbGxhbWEgZGF0YScsJ2Vycm9yJyk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZGVsZXRlTW9kZWwobmFtZSkgewogIGlmICghY29uZmlybSgnRGVsZXRlIG1vZGVsICcrbmFtZSsnPycpKSByZXR1cm47CiAgYXdhaXQgZmV0Y2goQVBJKycvYXBpL29sbGFtYS9kZWxldGUnLHttZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sYm9keTpKU09OLnN0cmluZ2lmeSh7bW9kZWw6bmFtZX0pfSk7CiAgdG9hc3QoJ01vZGVsIGRlbGV0ZWQnKTsgbG9hZE9sbGFtYSgpOwp9CgpmdW5jdGlvbiBwdWxsTW9kZWwoKSB7CiAgY29uc3QgbmFtZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbGxhbWEtcHVsbC1uYW1lJykudmFsdWUudHJpbSgpOwogIGlmICghbmFtZSkgcmV0dXJuOwogIGNvbnN0IHByb2cgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHVsbC1wcm9ncmVzcycpOwogIHByb2cuaW5uZXJIVE1MID0gJzxkaXY+UHVsbGluZyAnK25hbWUrJy4uLjwvZGl2PjxkaXYgY2xhc3M9InByb2dyZXNzLWJhciI+PGRpdiBjbGFzcz0iZmlsbCIgaWQ9InB1bGwtZmlsbCIgc3R5bGU9IndpZHRoOjAlIj48L2Rpdj48L2Rpdj48ZGl2IGlkPSJwdWxsLXN0YXR1cyIgc3R5bGU9Im1hcmdpbi10b3A6OHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXRleHQyKSI+PC9kaXY+JzsKICBjb25zdCBlcyA9IG5ldyBFdmVudFNvdXJjZShBUEkrJy9hcGkvb2xsYW1hL3B1bGw/bW9kZWw9JytlbmNvZGVVUklDb21wb25lbnQobmFtZSkpOwogIC8vIEZhbGxiYWNrOiB1c2UgZmV0Y2ggd2l0aCBQT1NUCiAgZmV0Y2goQVBJKycvYXBpL29sbGFtYS9wdWxsJyx7bWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LGJvZHk6SlNPTi5zdHJpbmdpZnkoe21vZGVsOm5hbWV9KX0pLnRoZW4oYXN5bmMgcmVzPT57CiAgICBjb25zdCByZWFkZXIgPSByZXMuYm9keS5nZXRSZWFkZXIoKTsgY29uc3QgZGVjb2RlciA9IG5ldyBUZXh0RGVjb2RlcigpOwogICAgd2hpbGUodHJ1ZSkgewogICAgICBjb25zdCB7ZG9uZSwgdmFsdWV9ID0gYXdhaXQgcmVhZGVyLnJlYWQoKTsKICAgICAgaWYgKGRvbmUpIGJyZWFrOwogICAgICBjb25zdCB0ZXh0ID0gZGVjb2Rlci5kZWNvZGUodmFsdWUpOwogICAgICB0ZXh0LnNwbGl0KCdcXG4nKS5maWx0ZXIobD0+bC5zdGFydHNXaXRoKCdkYXRhOiAnKSkuZm9yRWFjaChsPT57CiAgICAgICAgdHJ5IHsKICAgICAgICAgIGNvbnN0IGQgPSBKU09OLnBhcnNlKGwuc2xpY2UoNikpOwogICAgICAgICAgaWYgKGQuZG9uZSkgeyBwcm9nLmlubmVySFRNTD0nPHNwYW4gY2xhc3M9ImJhZGdlIGdyZWVuIj7inIUgUHVsbCBjb21wbGV0ZSE8L3NwYW4+JzsgbG9hZE9sbGFtYSgpOyByZXR1cm47IH0KICAgICAgICAgIGlmIChkLmVycm9yKSB7IHByb2cuaW5uZXJIVE1MPSc8c3BhbiBjbGFzcz0iYmFkZ2UgcmVkIj5FcnJvcjogJytkLmVycm9yKyc8L3NwYW4+JzsgcmV0dXJuOyB9CiAgICAgICAgICBjb25zdCBwY3QgPSBkLnRvdGFsID8gTWF0aC5yb3VuZCgoZC5jb21wbGV0ZWR8fDApL2QudG90YWwqMTAwKSA6IDA7CiAgICAgICAgICBjb25zdCBmaWxsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3B1bGwtZmlsbCcpOyBpZihmaWxsKSBmaWxsLnN0eWxlLndpZHRoPXBjdCsnJSc7CiAgICAgICAgICBjb25zdCBzdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdWxsLXN0YXR1cycpOyBpZihzdCkgc3QudGV4dENvbnRlbnQ9KGQuc3RhdHVzfHwnJykrJyAnK3BjdCsnJSc7CiAgICAgICAgfSBjYXRjaHt9CiAgICAgIH0pOwogICAgfQogIH0pLmNhdGNoKGU9PnsgcHJvZy5pbm5lckhUTUw9JzxzcGFuIGNsYXNzPSJiYWRnZSByZWQiPkVycm9yOiAnK2UubWVzc2FnZSsnPC9zcGFuPic7IH0pOwp9Cgphc3luYyBmdW5jdGlvbiByZWZyZXNoT2xsYW1hTW9kZWxzKCkgewogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9hcGkvb2xsYW1hL21vZGVscycpOyBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgY29uc3Qgc2VsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Atb2xsYW1hLW1vZGVsJyk7CiAgc2VsLmlubmVySFRNTCA9IChkLm1vZGVsc3x8W10pLm1hcChtPT4nPG9wdGlvbj4nK20ubmFtZSsnPC9vcHRpb24+Jykuam9pbignJykgfHwgJzxvcHRpb24+Tm8gbW9kZWxzPC9vcHRpb24+JzsKfQoKLy8g4pSA4pSAIENvbmZpZyDilIDilIAKYXN5bmMgZnVuY3Rpb24gbG9hZENvbmZpZygpIHsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvYXBpL2NvbmZpZycpOyBjdXJyZW50Q29uZmlnID0gYXdhaXQgci5qc29uKCk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1wb3J0JykudmFsdWUgPSBjdXJyZW50Q29uZmlnLmdhdGV3YXk/LnBvcnQgfHwgY3VycmVudENvbmZpZy5wb3J0IHx8ICcnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctYmluZCcpLnZhbHVlID0gY3VycmVudENvbmZpZy5nYXRld2F5Py5iaW5kIHx8IGN1cnJlbnRDb25maWcuYmluZCB8fCAnJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLW1vZGVsJykudmFsdWUgPSBjdXJyZW50Q29uZmlnLmRlZmF1bHRfbW9kZWwgfHwgY3VycmVudENvbmZpZy5tb2RlbCB8fCAnJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLWxvZ2xldmVsJykudmFsdWUgPSBjdXJyZW50Q29uZmlnLmxvZ19sZXZlbCB8fCBjdXJyZW50Q29uZmlnLmxvZ0xldmVsIHx8ICdpbmZvJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLW9yaWdpbnMnKS52YWx1ZSA9IChjdXJyZW50Q29uZmlnLmFsbG93ZWRfb3JpZ2lucyB8fCBjdXJyZW50Q29uZmlnLmFsbG93ZWRPcmlnaW5zIHx8IFtdKS5qb2luKCcsICcpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctcmF3JykudmFsdWUgPSBKU09OLnN0cmluZ2lmeShjdXJyZW50Q29uZmlnLCBudWxsLCAyKTsKfQoKYXN5bmMgZnVuY3Rpb24gc2F2ZUNvbmZpZygpIHsKICBjb25zdCBqc29uVGFiID0gZG9jdW1lbnQucXVlcnlTZWxlY3RvcignI2NvbmZpZy10YWJzIGJ1dHRvbltkYXRhLXRhYj0ianNvbiJdJykuY2xhc3NMaXN0LmNvbnRhaW5zKCdhY3RpdmUnKTsKICBsZXQgZGF0YTsKICBpZiAoanNvblRhYikgewogICAgdHJ5IHsgZGF0YSA9IEpTT04ucGFyc2UoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1yYXcnKS52YWx1ZSk7IH0gY2F0Y2ggeyByZXR1cm4gdG9hc3QoJ0ludmFsaWQgSlNPTicsJ2Vycm9yJyk7IH0KICB9IGVsc2UgewogICAgZGF0YSA9IHsgLi4uY3VycmVudENvbmZpZyB9OwogICAgY29uc3QgcG9ydCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctcG9ydCcpLnZhbHVlOwogICAgY29uc3QgYmluZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctYmluZCcpLnZhbHVlOwogICAgaWYgKGRhdGEuZ2F0ZXdheSkgeyBpZihwb3J0KSBkYXRhLmdhdGV3YXkucG9ydD1wYXJzZUludChwb3J0KTsgaWYoYmluZCkgZGF0YS5nYXRld2F5LmJpbmQ9YmluZDsgfQogICAgZWxzZSB7IGlmKHBvcnQpIGRhdGEucG9ydD1wYXJzZUludChwb3J0KTsgaWYoYmluZCkgZGF0YS5iaW5kPWJpbmQ7IH0KICAgIGNvbnN0IG1vZGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1tb2RlbCcpLnZhbHVlOyBpZihtb2RlbCkgZGF0YS5kZWZhdWx0X21vZGVsPW1vZGVsOwogICAgZGF0YS5sb2dfbGV2ZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLWxvZ2xldmVsJykudmFsdWU7CiAgICBjb25zdCBvcmlnaW5zID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1vcmlnaW5zJykudmFsdWU7IGlmKG9yaWdpbnMpIGRhdGEuYWxsb3dlZF9vcmlnaW5zPW9yaWdpbnMuc3BsaXQoJywnKS5tYXAocz0+cy50cmltKCkpOwogIH0KICBhd2FpdCBmZXRjaChBUEkrJy9hcGkvY29uZmlnJyx7bWV0aG9kOidQVVQnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sYm9keTpKU09OLnN0cmluZ2lmeShkYXRhKX0pOwogIHRvYXN0KCdDb25maWd1cmF0aW9uIHNhdmVkIScpOyBjdXJyZW50Q29uZmlnPWRhdGE7Cn0KCi8vIOKUgOKUgCBQcm92aWRlcnMg4pSA4pSACmFzeW5jIGZ1bmN0aW9uIGxvYWRQcm92aWRlcnMoKSB7CiAgYXdhaXQgbG9hZENvbmZpZygpOwogIGNvbnN0IGMgPSBjdXJyZW50Q29uZmlnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwLW9sbGFtYS11cmwnKS52YWx1ZSA9IGMub2xsYW1hPy51cmwgfHwgYy5vbGxhbWFVcmwgfHwgJ2h0dHA6Ly9sb2NhbGhvc3Q6MTE0MzQnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwLWFudGhyb3BpYy1rZXknKS52YWx1ZSA9IGMuYW50aHJvcGljPy5hcGlLZXkgfHwgYy5hbnRocm9waWNLZXkgfHwgJyc7CiAgaWYgKGMuYW50aHJvcGljPy5tb2RlbCkgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3AtYW50aHJvcGljLW1vZGVsJykudmFsdWUgPSBjLmFudGhyb3BpYy5tb2RlbDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncC1vcGVuYWkta2V5JykudmFsdWUgPSBjLm9wZW5haT8uYXBpS2V5IHx8IGMub3BlbmFpS2V5IHx8ICcnOwogIGlmIChjLm9wZW5haT8ubW9kZWwpIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwLW9wZW5haS1tb2RlbCcpLnZhbHVlID0gYy5vcGVuYWkubW9kZWw7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3AtY3VzdG9tLXVybCcpLnZhbHVlID0gYy5jdXN0b20/LmJhc2VVcmwgfHwgJyc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3AtY3VzdG9tLWtleScpLnZhbHVlID0gYy5jdXN0b20/LmFwaUtleSB8fCAnJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncC1jdXN0b20tbW9kZWwnKS52YWx1ZSA9IGMuY3VzdG9tPy5tb2RlbCB8fCAnJzsKICByZWZyZXNoT2xsYW1hTW9kZWxzKCk7Cn0KCmFzeW5jIGZ1bmN0aW9uIHNhdmVQcm92aWRlcigpIHsKICBjb25zdCBhY3RpdmUgPSBkb2N1bWVudC5xdWVyeVNlbGVjdG9yKCcjcHJvdmlkZXItdGFicyBidXR0b24uYWN0aXZlJykuZGF0YXNldC5wcm92aWRlcjsKICBjb25zdCBjID0geyAuLi5jdXJyZW50Q29uZmlnIH07CiAgaWYgKGFjdGl2ZT09PSdvbGxhbWEnKSB7IGMub2xsYW1hID0geyB1cmw6IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwLW9sbGFtYS11cmwnKS52YWx1ZSwgbW9kZWw6IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwLW9sbGFtYS1tb2RlbCcpLnZhbHVlIH07IH0KICBpZiAoYWN0aXZlPT09J2FudGhyb3BpYycpIHsgYy5hbnRocm9waWMgPSB7IGFwaUtleTogZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3AtYW50aHJvcGljLWtleScpLnZhbHVlLCBtb2RlbDogZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3AtYW50aHJvcGljLW1vZGVsJykudmFsdWUgfTsgfQogIGlmIChhY3RpdmU9PT0nb3BlbmFpJykgeyBjLm9wZW5haSA9IHsgYXBpS2V5OiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncC1vcGVuYWkta2V5JykudmFsdWUsIG1vZGVsOiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncC1vcGVuYWktbW9kZWwnKS52YWx1ZSB9OyB9CiAgaWYgKGFjdGl2ZT09PSdjdXN0b20nKSB7IGMuY3VzdG9tID0geyBiYXNlVXJsOiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncC1jdXN0b20tdXJsJykudmFsdWUsIGFwaUtleTogZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3AtY3VzdG9tLWtleScpLnZhbHVlLCBtb2RlbDogZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3AtY3VzdG9tLW1vZGVsJykudmFsdWUgfTsgfQogIGMuYWN0aXZlUHJvdmlkZXIgPSBhY3RpdmU7CiAgYXdhaXQgZmV0Y2goQVBJKycvYXBpL2NvbmZpZycse21ldGhvZDonUFVUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LGJvZHk6SlNPTi5zdHJpbmdpZnkoYyl9KTsKICBjdXJyZW50Q29uZmlnID0gYzsgdG9hc3QoJ1Byb3ZpZGVyIGNvbmZpZyBzYXZlZCEnKTsKfQoKLy8g4pSA4pSAIFNlcnZpY2VzIOKUgOKUgAphc3luYyBmdW5jdGlvbiBzdmNBY3Rpb24oYWN0aW9uKSB7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2FwaS9zZXJ2aWNlJyx7bWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LGJvZHk6SlNPTi5zdHJpbmdpZnkoe2FjdGlvbn0pfSk7CiAgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpOwogIGlmIChhY3Rpb249PT0nc3RhdHVzJykgewogICAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLXN0YXR1cycpOwogICAgY29uc3QgYWN0aXZlID0gZC5yZXN1bHQgJiYgKGQucmVzdWx0LmluY2x1ZGVzKCdhY3RpdmUnKSB8fCBkLnJlc3VsdC5pbmNsdWRlcygncnVubmluZycpKTsKICAgIGVsLmlubmVySFRNTCA9IGFjdGl2ZSA/ICc8c3BhbiBjbGFzcz0iYmFkZ2UgZ3JlZW4iPlJ1bm5pbmc8L3NwYW4+JyA6ICc8c3BhbiBjbGFzcz0iYmFkZ2UgcmVkIj5TdG9wcGVkPC9zcGFuPic7CiAgfSBlbHNlIHRvYXN0KGFjdGlvbisnOiAnKygoZC5yZXN1bHR8fCcnKS5zbGljZSgwLDEwMCl8fCdPSycpKTsKfQoKYXN5bmMgZnVuY3Rpb24gbG9hZExvZ3MoKSB7CiAgY29uc3QgbGluZXMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9nLWxpbmVzJykudmFsdWU7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2FwaS9sb2dzP2xpbmVzPScrbGluZXMpOyBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvZy1vdXRwdXQnKS50ZXh0Q29udGVudCA9IGQubG9ncyB8fCAnTm8gbG9ncyc7Cn0KCi8vIOKUgOKUgCBDaGFubmVscyDilIDilIAKYXN5bmMgZnVuY3Rpb24gbG9hZENoYW5uZWxzKCkgewogIGF3YWl0IGxvYWRDb25maWcoKTsKICBjb25zdCBjID0gY3VycmVudENvbmZpZzsKICBjb25zdCB0ZyA9IGMuY2hhbm5lbHM/LnRlbGVncmFtIHx8IGMudGVsZWdyYW0gfHwge307CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NoLXRnLXRva2VuJykudmFsdWUgPSB0Zy5ib3RUb2tlbiB8fCB0Zy50b2tlbiB8fCAnJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2gtdGctY2hhdHMnKS52YWx1ZSA9ICh0Zy5hbGxvd2VkQ2hhdHMgfHwgdGcuY2hhdElkcyB8fCBbXSkuam9pbignLCAnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2gtdGctd2ViaG9vaycpLnZhbHVlID0gdGcud2ViaG9va1VybCB8fCAnJzsKICBjb25zdCBkYyA9IGMuY2hhbm5lbHM/LmRpc2NvcmQgfHwgYy5kaXNjb3JkIHx8IHt9OwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaC1kYy10b2tlbicpLnZhbHVlID0gZGMuYm90VG9rZW4gfHwgZGMudG9rZW4gfHwgJyc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NoLWRjLWd1aWxkJykudmFsdWUgPSBkYy5ndWlsZElkIHx8ICcnOwp9Cgphc3luYyBmdW5jdGlvbiBzYXZlQ2hhbm5lbHMoKSB7CiAgY29uc3QgYyA9IHsgLi4uY3VycmVudENvbmZpZyB9OwogIGlmICghYy5jaGFubmVscykgYy5jaGFubmVscyA9IHt9OwogIGMuY2hhbm5lbHMudGVsZWdyYW0gPSB7CiAgICBib3RUb2tlbjogZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NoLXRnLXRva2VuJykudmFsdWUsCiAgICBhbGxvd2VkQ2hhdHM6IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaC10Zy1jaGF0cycpLnZhbHVlLnNwbGl0KCcsJykubWFwKHM9PnMudHJpbSgpKS5maWx0ZXIoQm9vbGVhbiksCiAgICB3ZWJob29rVXJsOiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2gtdGctd2ViaG9vaycpLnZhbHVlCiAgfTsKICBjLmNoYW5uZWxzLmRpc2NvcmQgPSB7CiAgICBib3RUb2tlbjogZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NoLWRjLXRva2VuJykudmFsdWUsCiAgICBndWlsZElkOiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2gtZGMtZ3VpbGQnKS52YWx1ZQogIH07CiAgYXdhaXQgZmV0Y2goQVBJKycvYXBpL2NvbmZpZycse21ldGhvZDonUFVUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LGJvZHk6SlNPTi5zdHJpbmdpZnkoYyl9KTsKICBjdXJyZW50Q29uZmlnID0gYzsgdG9hc3QoJ0NoYW5uZWwgY29uZmlnIHNhdmVkIScpOwp9CgovLyDilIDilIAgSW5pdCDilIDilIAKYXN5bmMgZnVuY3Rpb24gaW5pdCgpIHsgbG9hZERhc2hib2FyZCgpOyB9CgovLyBDaGVjayBpZiBhbHJlYWR5IGF1dGhlZApmZXRjaChBUEkrJy9hcGkvc3RhdHVzJykudGhlbihyPT57CiAgaWYoci5vayl7ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvZ2luLXBhZ2UnKS5zdHlsZS5kaXNwbGF5PSdub25lJztkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXBwJykuc3R5bGUuZGlzcGxheT0nZmxleCc7aW5pdCgpO30KfSk7Cjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD5gOwp9CgovLyDilIDilIDilIAgU2VydmVyIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApjb25zdCBzZXJ2ZXIgPSBodHRwLmNyZWF0ZVNlcnZlcihhc3luYyAocmVxLCByZXMpID0+IHsKICBjb25zdCB1cmwgPSBuZXcgVVJMKHJlcS51cmwsIGBodHRwOi8vJHtyZXEuaGVhZGVycy5ob3N0fWApOwogIGNvbnN0IHBhdGhuYW1lID0gdXJsLnBhdGhuYW1lOwoKICAvLyBDT1JTIGZvciBsb2NhbCBkZXYKICByZXMuc2V0SGVhZGVyKCdYLUNvbnRlbnQtVHlwZS1PcHRpb25zJywgJ25vc25pZmYnKTsKCiAgaWYgKHBhdGhuYW1lLnN0YXJ0c1dpdGgoJy9hcGkvJykpIHsKICAgIHJldHVybiBoYW5kbGVBUEkocmVxLCByZXMsIHBhdGhuYW1lKTsKICB9CgogIC8vIFNlcnZlIGZyb250ZW5kCiAgcmVzLndyaXRlSGVhZCgyMDAsIHsgJ0NvbnRlbnQtVHlwZSc6ICd0ZXh0L2h0bWw7IGNoYXJzZXQ9dXRmLTgnIH0pOwogIHJlcy5lbmQoZ2V0SFRNTCgpKTsKfSk7CgpzZXJ2ZXIubGlzdGVuKFBPUlQsICcwLjAuMC4wJywgKCkgPT4gewogIGNvbnNvbGUubG9nKGBcbiAg8J+QviBPcGVuQ2xhdyBXZWJVSSBydW5uaW5nIGF0IGh0dHA6Ly8wLjAuMC4wOiR7UE9SVH1gKTsKICBjb25zb2xlLmxvZyhgICBQYXNzd29yZDogJHtQQVNTV09SRCA9PT0gJ29wZW5jbGF3JyA/ICdvcGVuY2xhdyAoZGVmYXVsdCDigJQgY2hhbmdlIHZpYSBXRUJVSV9QQVNTV09SRCBlbnYpJyA6ICcoY29uZmlndXJlZCknfVxuYCk7Cn0pOwo=
B64END
)
    echo "$server_b64" | pct exec "$CT_ID" -- bash -c "base64 -d > /opt/openclaw-webui/server.js"
    pct exec "$CT_ID" -- systemctl start openclaw-webui 2>/dev/null || true

    msg_ok "Dashboard installed (port ${var_dashboard_port}, password: ${DASHBOARD_PASS})"
}

# ─── Install OpenClaw ─────────────────────────────────────────────────────────
install_openclaw() {
    msg_info "Updating container OS"
    pct exec "$CT_ID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null 2>&1 && apt-get upgrade -y -qq >/dev/null 2>&1" || true
    msg_ok "OS updated"

    msg_info "Installing dependencies"
    pct exec "$CT_ID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq curl git sudo ca-certificates gnupg openssl >/dev/null 2>&1"
    msg_ok "Dependencies installed"

    install_docker
    install_ollama

    msg_info "Installing Node.js 22.x"
    pct exec "$CT_ID" -- bash -c "
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq nodejs >/dev/null 2>&1
    "
    msg_ok "Node.js $(pct exec "$CT_ID" -- node -v 2>/dev/null || echo '22.x')"

    msg_info "Installing pnpm"
    pct exec "$CT_ID" -- bash -c "npm install -g pnpm@latest >/dev/null 2>&1"
    msg_ok "pnpm installed"

    msg_info "Installing OpenClaw (this takes a few minutes)"
    pct exec "$CT_ID" -- bash -c "npm install -g openclaw@latest >/dev/null 2>&1"
    msg_ok "OpenClaw installed"

    msg_info "Creating openclaw user"
    pct exec "$CT_ID" -- bash -c "
        useradd -r -m -s /bin/bash openclaw 2>/dev/null || true
        mkdir -p /home/openclaw/.openclaw/workspace
        chown -R openclaw:openclaw /home/openclaw
    "
    [[ "$var_docker" == "yes" ]] && pct exec "$CT_ID" -- bash -c "usermod -aG docker openclaw 2>/dev/null || true"
    msg_ok "User 'openclaw' created"

    # Build OpenClaw config
    msg_info "Configuring OpenClaw"
    local provider_env model_primary
    if [[ "$var_ollama" == "yes" || -n "${var_ollama_url:-}" ]]; then
        provider_env="\"OPENAI_API_KEY\": \"ollama\", \"OPENAI_BASE_URL\": \"${var_ollama_url}/v1\""
        model_primary="openai/llama3"
    else
        provider_env="\"ANTHROPIC_API_KEY\": \"CHANGE_ME\""
        model_primary="anthropic/claude-sonnet-4-20250514"
    fi

    local sandbox_cfg="" controlui_cfg=""
    [[ "$var_docker" == "yes" ]] && sandbox_cfg=', "sandbox": {"mode": "all"}'
    [[ "$var_webui" == "yes" ]] && controlui_cfg=', "controlUi": {"enabled": true, "allowedOrigins": ["*"]}'

    pct exec "$CT_ID" -- su - openclaw -c "cat > /home/openclaw/.openclaw/openclaw.json << 'OCEOF'
{
  \"gateway\": {
    \"port\": 18789,
    \"mode\": \"local\",
    \"bind\": \"loopback\"${controlui_cfg}
  },
  \"env\": {
    ${provider_env}
  },
  \"agents\": {
    \"defaults\": {
      \"model\": {
        \"primary\": \"${model_primary}\"
      }${sandbox_cfg}
    }
  }
}
OCEOF"
    msg_ok "OpenClaw configured"

    # Systemd service
    msg_info "Creating OpenClaw service"
    local after="network-online.target"
    [[ "$var_docker" == "yes" ]] && after+=" docker.service"
    [[ "$var_ollama" == "yes" ]] && after+=" ollama.service"

    pct exec "$CT_ID" -- bash -c "cat > /etc/systemd/system/openclaw.service << SVCEOF
[Unit]
Description=OpenClaw AI Gateway
After=${after}
Wants=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
WorkingDirectory=/home/openclaw
ExecStart=/usr/bin/openclaw gateway start --foreground
Restart=on-failure
RestartSec=10
Environment=NODE_ENV=production
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable openclaw >/dev/null 2>&1
"
    msg_ok "OpenClaw service created"

    install_webui
    install_dashboard

    if [[ "$var_ssh" == "yes" ]]; then
        msg_info "Enabling SSH"
        pct exec "$CT_ID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq openssh-server >/dev/null 2>&1; systemctl enable ssh >/dev/null 2>&1; systemctl start ssh"
        msg_ok "SSH enabled"
    fi
}

# ─── Completion ──────────────────────────────────────────────────────────────
show_completion() {
    local ip
    ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "<unknown>")

    echo ""
    echo -e "${GN}========================================================${CL}"
    echo -e "${GN}  OpenClaw LXC Installation Complete!${CL}"
    echo -e "${GN}========================================================${CL}"
    echo ""
    echo -e "  Container:   ${CT_ID} / ${HN}"
    echo -e "  IP Address:  ${ip}"
    echo ""
    echo -e "  ${BL}-- Installed --${CL}"
    echo -e "  * OpenClaw AI Gateway (port 18789)"
    [[ "$var_docker" == "yes" ]]    && echo -e "  * Docker CE"
    [[ "$var_ollama" == "yes" ]]    && echo -e "  * Ollama (port 11434)"
    [[ "$var_webui" == "yes" ]]     && echo -e "  * ${var_webui_type^} reverse proxy (port ${var_webui_port})"
    [[ "$var_dashboard" == "yes" ]] && echo -e "  * Management Dashboard (port ${var_dashboard_port})"
    [[ "$var_ssh" == "yes" ]]       && echo -e "  * SSH (port 22)"

    echo ""
    echo -e "  ${BL}-- Access URLs --${CL}"
    [[ "$var_webui" == "yes" ]] && echo -e "  Control UI:   http://${ip}:${var_webui_port}"
    [[ "$var_dashboard" == "yes" ]] && echo -e "  Dashboard:    http://${ip}:${var_dashboard_port}"
    [[ "$var_ollama" == "yes" ]] && echo -e "  Ollama API:   http://${ip}:11434"

    if [[ "$var_dashboard" == "yes" && -n "${DASHBOARD_PASS}" ]]; then
        echo ""
        echo -e "  ${YW}Dashboard Password: ${DASHBOARD_PASS}${CL}"
        echo -e "  ${DIM}(saved in /opt/openclaw-webui/.env)${CL}"
    fi

    echo ""
    echo -e "  ${YW}-- Next Steps --${CL}"
    echo "  1. pct enter ${CT_ID}"
    echo "  2. su - openclaw"
    echo "  3. openclaw setup"
    [[ "$var_ollama" == "yes" ]] && echo "  4. ollama pull llama3"
    echo "  5. openclaw channels login"
    echo "  6. sudo systemctl start openclaw"
    echo ""
    echo -e "  Docs: https://docs.openclaw.ai"
    echo -e "${GN}========================================================${CL}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    header
    check_root
    check_proxmox
    select_storage
    configure
    download_template
    create_container
    start_container
    install_openclaw
    show_completion
}

main "$@"
