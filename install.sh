#!/usr/bin/env bash

# ==============================================================================
# OpenClaw LXC Helper Script for Proxmox VE
# All-in-One: OpenClaw + Docker + Web UI Dashboard + Ollama Support
# ==============================================================================

# Restore stdin for interactive input (needed when piped via wget/curl)
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
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/dev/null

[Install]
WantedBy=multi-user.target
SVCFILE

        systemctl daemon-reload
        systemctl enable openclaw-webui >/dev/null 2>&1
    " || { msg_error "Dashboard setup failed"; return 1; }

    # Transfer server.js (embedded)
    msg_info "Transferring dashboard files"
    echo 'IyEvdXNyL2Jpbi9lbnYgbm9kZQovLyBPcGVuQ2xhdyBXZWIgTWFuYWdlbWVudCBEYXNoYm9hcmQgdjIuMAovLyBTaW5nbGUtZmlsZSBOb2RlLmpzIHdlYiBhcHAg4oCUIG5vIGJ1aWxkIHN0ZXAsIG5vIGV4dGVybmFsIGRlcHMKLy8gV3JpdGVzIHByb3BlciBPcGVuQ2xhdyBjb25maWcgZm9ybWF0IChlbnYsIGFnZW50cywgbW9kZWxzLnByb3ZpZGVycykKCmNvbnN0IGh0dHAgPSByZXF1aXJlKCdodHRwJyk7CmNvbnN0IGh0dHBzID0gcmVxdWlyZSgnaHR0cHMnKTsKY29uc3QgZnMgPSByZXF1aXJlKCdmcycpOwpjb25zdCB7IGV4ZWNTeW5jIH0gPSByZXF1aXJlKCdjaGlsZF9wcm9jZXNzJyk7CmNvbnN0IGNyeXB0byA9IHJlcXVpcmUoJ2NyeXB0bycpOwpjb25zdCBwYXRoID0gcmVxdWlyZSgncGF0aCcpOwoKLy8g4pSA4pSA4pSAIENvbmZpZyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKY29uc3QgUE9SVCA9IHBhcnNlSW50KHByb2Nlc3MuZW52LldFQlVJX1BPUlQgfHwgJzMzMzMnKTsKY29uc3QgUEFTU1dPUkQgPSBwcm9jZXNzLmVudi5XRUJVSV9QQVNTV09SRCB8fCAnb3BlbmNsYXcnOwpjb25zdCBDT05GSUdfUEFUSCA9IHByb2Nlc3MuZW52Lk9QRU5DTEFXX0NPTkZJRyB8fCAnL2hvbWUvb3BlbmNsYXcvLm9wZW5jbGF3L29wZW5jbGF3Lmpzb24nOwpjb25zdCBPTExBTUFfVVJMID0gcHJvY2Vzcy5lbnYuT0xMQU1BX1VSTCB8fCAnaHR0cDovL2xvY2FsaG9zdDoxMTQzNCc7CmNvbnN0IFNFUlZJQ0VfTkFNRSA9ICdvcGVuY2xhdyc7CmNvbnN0IHNlc3Npb25zID0gbmV3IE1hcCgpOwoKLy8g4pSA4pSA4pSAIEhlbHBlcnMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmZ1bmN0aW9uIHBhcnNlQm9keShyZXEpIHsKICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUsIHJlamVjdCkgPT4gewogICAgbGV0IGJvZHkgPSAnJzsKICAgIHJlcS5vbignZGF0YScsIGMgPT4geyBib2R5ICs9IGM7IGlmIChib2R5Lmxlbmd0aCA+IDFlNikgcmVxLmRlc3Ryb3koKTsgfSk7CiAgICByZXEub24oJ2VuZCcsICgpID0+IHsgdHJ5IHsgcmVzb2x2ZShKU09OLnBhcnNlKGJvZHkgfHwgJ3t9JykpOyB9IGNhdGNoIHsgcmVzb2x2ZSh7fSk7IH0gfSk7CiAgICByZXEub24oJ2Vycm9yJywgcmVqZWN0KTsKICB9KTsKfQoKZnVuY3Rpb24ganNvbihyZXMsIGRhdGEsIHN0YXR1cyA9IDIwMCkgewogIHJlcy53cml0ZUhlYWQoc3RhdHVzLCB7ICdDb250ZW50LVR5cGUnOiAnYXBwbGljYXRpb24vanNvbicgfSk7CiAgcmVzLmVuZChKU09OLnN0cmluZ2lmeShkYXRhKSk7Cn0KCmZ1bmN0aW9uIGdldENvb2tpZShyZXEsIG5hbWUpIHsKICBjb25zdCBjID0gKHJlcS5oZWFkZXJzLmNvb2tpZSB8fCAnJykuc3BsaXQoJzsnKS5maW5kKGMgPT4gYy50cmltKCkuc3RhcnRzV2l0aChuYW1lICsgJz0nKSk7CiAgcmV0dXJuIGMgPyBjLnNwbGl0KCc9JylbMV0udHJpbSgpIDogbnVsbDsKfQoKZnVuY3Rpb24gaXNBdXRoZWQocmVxKSB7CiAgY29uc3Qgc2lkID0gZ2V0Q29va2llKHJlcSwgJ29jX3Nlc3Npb24nKTsKICByZXR1cm4gc2lkICYmIHNlc3Npb25zLmhhcyhzaWQpOwp9CgpmdW5jdGlvbiBydW4oY21kLCB0aW1lb3V0ID0gMTAwMDApIHsKICB0cnkgeyByZXR1cm4gZXhlY1N5bmMoY21kLCB7IHRpbWVvdXQsIGVuY29kaW5nOiAndXRmOCcsIHN0ZGlvOiBbJ3BpcGUnLCdwaXBlJywncGlwZSddIH0pLnRyaW0oKTsgfQogIGNhdGNoIChlKSB7IHJldHVybiBlLnN0ZGVyciA/IGUuc3RkZXJyLnRyaW0oKSA6IGUubWVzc2FnZTsgfQp9CgpmdW5jdGlvbiBodHRwRmV0Y2godXJsU3RyLCBvcHRzID0ge30pIHsKICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUpID0+IHsKICAgIHRyeSB7CiAgICAgIGNvbnN0IHVybCA9IG5ldyBVUkwodXJsU3RyKTsKICAgICAgY29uc3QgbGliID0gdXJsLnByb3RvY29sID09PSAnaHR0cHM6JyA/IGh0dHBzIDogaHR0cDsKICAgICAgY29uc3Qgb3B0aW9ucyA9IHsKICAgICAgICBob3N0bmFtZTogdXJsLmhvc3RuYW1lLCBwb3J0OiB1cmwucG9ydCB8fCAodXJsLnByb3RvY29sID09PSAnaHR0cHM6JyA/IDQ0MyA6IDgwKSwKICAgICAgICBwYXRoOiB1cmwucGF0aG5hbWUgKyB1cmwuc2VhcmNoLCBtZXRob2Q6IG9wdHMubWV0aG9kIHx8ICdHRVQnLAogICAgICAgIGhlYWRlcnM6IHsgJ0NvbnRlbnQtVHlwZSc6ICdhcHBsaWNhdGlvbi9qc29uJywgLi4uKG9wdHMuaGVhZGVycyB8fCB7fSkgfSwKICAgICAgICB0aW1lb3V0OiBvcHRzLnRpbWVvdXQgfHwgNTAwMAogICAgICB9OwogICAgICBjb25zdCByZXEgPSBsaWIucmVxdWVzdChvcHRpb25zLCByZXMgPT4gewogICAgICAgIGxldCBkYXRhID0gJyc7CiAgICAgICAgcmVzLm9uKCdkYXRhJywgYyA9PiBkYXRhICs9IGMpOwogICAgICAgIHJlcy5vbignZW5kJywgKCkgPT4geyB0cnkgeyByZXNvbHZlKEpTT04ucGFyc2UoZGF0YSkpOyB9IGNhdGNoIHsgcmVzb2x2ZSh7IHJhdzogZGF0YSB9KTsgfSB9KTsKICAgICAgfSk7CiAgICAgIHJlcS5vbignZXJyb3InLCBlID0+IHJlc29sdmUoeyBlcnJvcjogZS5tZXNzYWdlIH0pKTsKICAgICAgcmVxLm9uKCd0aW1lb3V0JywgKCkgPT4geyByZXEuZGVzdHJveSgpOyByZXNvbHZlKHsgZXJyb3I6ICd0aW1lb3V0JyB9KTsgfSk7CiAgICAgIGlmIChvcHRzLmJvZHkpIHJlcS53cml0ZSh0eXBlb2Ygb3B0cy5ib2R5ID09PSAnc3RyaW5nJyA/IG9wdHMuYm9keSA6IEpTT04uc3RyaW5naWZ5KG9wdHMuYm9keSkpOwogICAgICByZXEuZW5kKCk7CiAgICB9IGNhdGNoKGUpIHsgcmVzb2x2ZSh7IGVycm9yOiBlLm1lc3NhZ2UgfSk7IH0KICB9KTsKfQoKZnVuY3Rpb24gcmVhZENvbmZpZygpIHsKICB0cnkgeyByZXR1cm4gSlNPTi5wYXJzZShmcy5yZWFkRmlsZVN5bmMoQ09ORklHX1BBVEgsICd1dGY4JykpOyB9CiAgY2F0Y2ggeyByZXR1cm4ge307IH0KfQoKZnVuY3Rpb24gd3JpdGVDb25maWcoZGF0YSkgewogIGNvbnN0IGRpciA9IHBhdGguZGlybmFtZShDT05GSUdfUEFUSCk7CiAgaWYgKCFmcy5leGlzdHNTeW5jKGRpcikpIGZzLm1rZGlyU3luYyhkaXIsIHsgcmVjdXJzaXZlOiB0cnVlIH0pOwogIGZzLndyaXRlRmlsZVN5bmMoQ09ORklHX1BBVEgsIEpTT04uc3RyaW5naWZ5KGRhdGEsIG51bGwsIDIpKTsKfQoKZnVuY3Rpb24gZGVlcFNldChvYmosIHBhdGgsIHZhbHVlKSB7CiAgY29uc3Qga2V5cyA9IHBhdGguc3BsaXQoJy4nKTsKICBsZXQgY3VyID0gb2JqOwogIGZvciAobGV0IGkgPSAwOyBpIDwga2V5cy5sZW5ndGggLSAxOyBpKyspIHsKICAgIGlmICghY3VyW2tleXNbaV1dIHx8IHR5cGVvZiBjdXJba2V5c1tpXV0gIT09ICdvYmplY3QnKSBjdXJba2V5c1tpXV0gPSB7fTsKICAgIGN1ciA9IGN1cltrZXlzW2ldXTsKICB9CiAgY3VyW2tleXNba2V5cy5sZW5ndGggLSAxXV0gPSB2YWx1ZTsKfQoKZnVuY3Rpb24gZGVlcEdldChvYmosIHBhdGgsIGRlZikgewogIGNvbnN0IGtleXMgPSBwYXRoLnNwbGl0KCcuJyk7CiAgbGV0IGN1ciA9IG9iajsKICBmb3IgKGNvbnN0IGsgb2Yga2V5cykgewogICAgaWYgKCFjdXIgfHwgdHlwZW9mIGN1ciAhPT0gJ29iamVjdCcpIHJldHVybiBkZWY7CiAgICBjdXIgPSBjdXJba107CiAgfQogIHJldHVybiBjdXIgIT09IHVuZGVmaW5lZCA/IGN1ciA6IGRlZjsKfQoKZnVuY3Rpb24gZGVlcERlbGV0ZShvYmosIHBhdGgpIHsKICBjb25zdCBrZXlzID0gcGF0aC5zcGxpdCgnLicpOwogIGxldCBjdXIgPSBvYmo7CiAgZm9yIChsZXQgaSA9IDA7IGkgPCBrZXlzLmxlbmd0aCAtIDE7IGkrKykgewogICAgaWYgKCFjdXIgfHwgdHlwZW9mIGN1ciAhPT0gJ29iamVjdCcpIHJldHVybjsKICAgIGN1ciA9IGN1cltrZXlzW2ldXTsKICB9CiAgaWYgKGN1ciAmJiB0eXBlb2YgY3VyID09PSAnb2JqZWN0JykgZGVsZXRlIGN1cltrZXlzW2tleXMubGVuZ3RoIC0gMV1dOwp9CgpmdW5jdGlvbiBnZXRPbGxhbWFVcmwoKSB7CiAgY29uc3QgY2ZnID0gcmVhZENvbmZpZygpOwogIGNvbnN0IGZyb21DZmcgPSBkZWVwR2V0KGNmZywgJ21vZGVscy5wcm92aWRlcnMub2xsYW1hLmJhc2VVcmwnLCAnJyk7CiAgaWYgKGZyb21DZmcpIHJldHVybiBmcm9tQ2ZnLnJlcGxhY2UoL1wvdjFcLz8kLywgJycpOwogIHJldHVybiBPTExBTUFfVVJMOwp9CgpmdW5jdGlvbiByZXN0YXJ0U2VydmljZSgpIHsKICBydW4oYHN5c3RlbWN0bCByZXN0YXJ0ICR7U0VSVklDRV9OQU1FfSAyPiYxYCwgMTUwMDApOwp9CgpmdW5jdGlvbiBidWlsZE1vZGVsRW50cnkobmFtZSkgewogIHJldHVybiB7CiAgICBpZDogbmFtZSwgbmFtZTogbmFtZSwgcmVhc29uaW5nOiBmYWxzZSwKICAgIGlucHV0OiBbJ3RleHQnXSwKICAgIGNvc3Q6IHsgaW5wdXQ6IDAsIG91dHB1dDogMCwgY2FjaGVSZWFkOiAwLCBjYWNoZVdyaXRlOiAwIH0sCiAgICBjb250ZXh0V2luZG93OiAzMjc2OCwgbWF4VG9rZW5zOiA4MTkyCiAgfTsKfQoKLy8g4pSA4pSA4pSAIEFQSSBSb3V0ZXMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmFzeW5jIGZ1bmN0aW9uIGhhbmRsZUFQSShyZXEsIHJlcywgcGF0aG5hbWUpIHsKICAvLyBBdXRoCiAgaWYgKHBhdGhuYW1lID09PSAnL2FwaS9sb2dpbicgJiYgcmVxLm1ldGhvZCA9PT0gJ1BPU1QnKSB7CiAgICBjb25zdCB7IHBhc3N3b3JkIH0gPSBhd2FpdCBwYXJzZUJvZHkocmVxKTsKICAgIGlmIChwYXNzd29yZCA9PT0gUEFTU1dPUkQpIHsKICAgICAgY29uc3Qgc2lkID0gY3J5cHRvLnJhbmRvbUJ5dGVzKDI0KS50b1N0cmluZygnaGV4Jyk7CiAgICAgIHNlc3Npb25zLnNldChzaWQsIHsgY3JlYXRlZDogRGF0ZS5ub3coKSB9KTsKICAgICAgcmVzLndyaXRlSGVhZCgyMDAsIHsgJ0NvbnRlbnQtVHlwZSc6ICdhcHBsaWNhdGlvbi9qc29uJywgJ1NldC1Db29raWUnOiBgb2Nfc2Vzc2lvbj0ke3NpZH07IFBhdGg9LzsgSHR0cE9ubHk7IFNhbWVTaXRlPVN0cmljdDsgTWF4LUFnZT04NjQwMGAgfSk7CiAgICAgIHJldHVybiByZXMuZW5kKEpTT04uc3RyaW5naWZ5KHsgb2s6IHRydWUgfSkpOwogICAgfQogICAgcmV0dXJuIGpzb24ocmVzLCB7IGVycm9yOiAnSW52YWxpZCBwYXNzd29yZCcgfSwgNDAxKTsKICB9CiAgaWYgKHBhdGhuYW1lID09PSAnL2FwaS9sb2dvdXQnKSB7CiAgICBjb25zdCBzaWQgPSBnZXRDb29raWUocmVxLCAnb2Nfc2Vzc2lvbicpOwogICAgaWYgKHNpZCkgc2Vzc2lvbnMuZGVsZXRlKHNpZCk7CiAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAnU2V0LUNvb2tpZSc6ICdvY19zZXNzaW9uPTsgUGF0aD0vOyBNYXgtQWdlPTAnIH0pOwogICAgcmV0dXJuIHJlcy5lbmQoJ3t9Jyk7CiAgfQoKICBpZiAoIWlzQXV0aGVkKHJlcSkpIHJldHVybiBqc29uKHJlcywgeyBlcnJvcjogJ1VuYXV0aG9yaXplZCcgfSwgNDAxKTsKCiAgLy8gU3RhdHVzCiAgaWYgKHBhdGhuYW1lID09PSAnL2FwaS9zdGF0dXMnKSB7CiAgICBjb25zdCBnYXRld2F5ID0gcnVuKGBzeXN0ZW1jdGwgaXMtYWN0aXZlICR7U0VSVklDRV9OQU1FfSAyPi9kZXYvbnVsbCB8fCBlY2hvIHVua25vd25gKTsKICAgIGNvbnN0IGRvY2tlciA9IHJ1bignc3lzdGVtY3RsIGlzLWFjdGl2ZSBkb2NrZXIgMj4vZGV2L251bGwgfHwgZWNobyBpbmFjdGl2ZScpOwogICAgY29uc3Qgb2xsYW1hVXJsID0gZ2V0T2xsYW1hVXJsKCk7CiAgICBjb25zdCBvbGxhbWEgPSBydW4oYGN1cmwgLXNmICR7b2xsYW1hVXJsfS9hcGkvdmVyc2lvbiAtLW1heC10aW1lIDIgMj4vZGV2L251bGwgfHwgZWNobyBvZmZsaW5lYCk7CiAgICBjb25zdCB1cHRpbWUgPSBydW4oJ3VwdGltZSAtcCcpOwogICAgY29uc3QgaG9zdG5hbWUgPSBydW4oJ2hvc3RuYW1lJyk7CiAgICBjb25zdCBtZW0gPSBydW4oImZyZWUgLWggfCBhd2sgJy9NZW06L3twcmludCAkM1wiL1wiJDJ9JyIpOwogICAgY29uc3QgZGlzayA9IHJ1bigiZGYgLWggLyB8IGF3ayAnTlI9PTJ7cHJpbnQgJDNcIi9cIiQyXCIgKFwiJDVcIilcIn0nIik7CiAgICBjb25zdCBjcHUgPSBydW4oImdyZXAgLWMgXnByb2Nlc3NvciAvcHJvYy9jcHVpbmZvIik7CiAgICBjb25zdCBsb2FkID0gcnVuKCJjYXQgL3Byb2MvbG9hZGF2ZyB8IGF3ayAne3ByaW50ICQxLCAkMiwgJDN9JyIpOwogICAgcmV0dXJuIGpzb24ocmVzLCB7IGdhdGV3YXksIGRvY2tlciwgb2xsYW1hLCB1cHRpbWUsIGhvc3RuYW1lLCBtZW0sIGRpc2ssIGNwdSwgbG9hZCB9KTsKICB9CgogIC8vIENvbmZpZyBDUlVECiAgaWYgKHBhdGhuYW1lID09PSAnL2FwaS9jb25maWcnICYmIHJlcS5tZXRob2QgPT09ICdHRVQnKSByZXR1cm4ganNvbihyZXMsIHJlYWRDb25maWcoKSk7CiAgaWYgKHBhdGhuYW1lID09PSAnL2FwaS9jb25maWcnICYmIHJlcS5tZXRob2QgPT09ICdQVVQnKSB7CiAgICBjb25zdCBib2R5ID0gYXdhaXQgcGFyc2VCb2R5KHJlcSk7CiAgICB3cml0ZUNvbmZpZyhib2R5KTsKICAgIHJldHVybiBqc29uKHJlcywgeyBvazogdHJ1ZSB9KTsKICB9CgogIC8vIFByb3ZpZGVyIHNhdmUg4oCUIHdyaXRlcyBwcm9wZXIgT3BlbkNsYXcgY29uZmlnIGZvcm1hdAogIGlmIChwYXRobmFtZSA9PT0gJy9hcGkvcHJvdmlkZXInICYmIHJlcS5tZXRob2QgPT09ICdQT1NUJykgewogICAgY29uc3QgYm9keSA9IGF3YWl0IHBhcnNlQm9keShyZXEpOwogICAgY29uc3QgeyBwcm92aWRlciwgb2xsYW1hVXJsLCBvbGxhbWFNb2RlbCwgYW50aHJvcGljS2V5LCBhbnRocm9waWNNb2RlbCwgb3BlbmFpS2V5LCBvcGVuYWlNb2RlbCwgY3VzdG9tVXJsLCBjdXN0b21LZXksIGN1c3RvbU1vZGVsIH0gPSBib2R5OwogICAgbGV0IGNmZyA9IHJlYWRDb25maWcoKTsKCiAgICBpZiAocHJvdmlkZXIgPT09ICdvbGxhbWEnKSB7CiAgICAgIGNvbnN0IHVybCA9IG9sbGFtYVVybCB8fCBPTExBTUFfVVJMOwogICAgICAvLyBTZXQgZW52CiAgICAgIGlmICghY2ZnLmVudikgY2ZnLmVudiA9IHt9OwogICAgICBjZmcuZW52Lk9MTEFNQV9BUElfS0VZID0gJ29sbGFtYS1sb2NhbCc7CiAgICAgIGRlbGV0ZSBjZmcuZW52LkFOVEhST1BJQ19BUElfS0VZOwogICAgICBkZWxldGUgY2ZnLmVudi5PUEVOQUlfQVBJX0tFWTsKCiAgICAgIC8vIFF1ZXJ5IE9sbGFtYSBmb3IgYWxsIG1vZGVscwogICAgICBsZXQgbW9kZWxzID0gW107CiAgICAgIGNvbnN0IGRhdGEgPSBhd2FpdCBodHRwRmV0Y2goYCR7dXJsfS9hcGkvdGFnc2ApOwogICAgICBpZiAoZGF0YS5tb2RlbHMgJiYgZGF0YS5tb2RlbHMubGVuZ3RoKSB7CiAgICAgICAgbW9kZWxzID0gZGF0YS5tb2RlbHMubWFwKG0gPT4gYnVpbGRNb2RlbEVudHJ5KG0ubmFtZSkpOwogICAgICB9CiAgICAgIGlmICghbW9kZWxzLmxlbmd0aCkgbW9kZWxzID0gW2J1aWxkTW9kZWxFbnRyeShvbGxhbWFNb2RlbCB8fCAnbGxhbWEzOmxhdGVzdCcpXTsKCiAgICAgIGNvbnN0IHNlbGVjdGVkTW9kZWwgPSBvbGxhbWFNb2RlbCB8fCAobW9kZWxzWzBdICYmIG1vZGVsc1swXS5pZCkgfHwgJ2xsYW1hMzpsYXRlc3QnOwoKICAgICAgLy8gU2V0IG1vZGVsIHByaW1hcnkKICAgICAgZGVlcFNldChjZmcsICdhZ2VudHMuZGVmYXVsdHMubW9kZWwucHJpbWFyeScsIGBvbGxhbWEvJHtzZWxlY3RlZE1vZGVsfWApOwoKICAgICAgLy8gU2V0IG1vZGVscy5wcm92aWRlcnMub2xsYW1hCiAgICAgIGRlZXBTZXQoY2ZnLCAnbW9kZWxzLnByb3ZpZGVycy5vbGxhbWEnLCB7CiAgICAgICAgYmFzZVVybDogYCR7dXJsfS92MWAsCiAgICAgICAgYXBpS2V5OiAnb2xsYW1hLWxvY2FsJywKICAgICAgICBhcGk6ICdvcGVuYWktY29tcGxldGlvbnMnLAogICAgICAgIG1vZGVsczogbW9kZWxzCiAgICAgIH0pOwoKICAgIH0gZWxzZSBpZiAocHJvdmlkZXIgPT09ICdhbnRocm9waWMnKSB7CiAgICAgIGlmICghY2ZnLmVudikgY2ZnLmVudiA9IHt9OwogICAgICBjZmcuZW52LkFOVEhST1BJQ19BUElfS0VZID0gYW50aHJvcGljS2V5IHx8ICcnOwogICAgICBkZWxldGUgY2ZnLmVudi5PTExBTUFfQVBJX0tFWTsKICAgICAgZGVsZXRlIGNmZy5lbnYuT1BFTkFJX0FQSV9LRVk7CiAgICAgIGRlZXBTZXQoY2ZnLCAnYWdlbnRzLmRlZmF1bHRzLm1vZGVsLnByaW1hcnknLCBgYW50aHJvcGljLyR7YW50aHJvcGljTW9kZWwgfHwgJ2NsYXVkZS1zb25uZXQtNC0yMDI1MDUxNCd9YCk7CiAgICAgIGRlZXBEZWxldGUoY2ZnLCAnbW9kZWxzLnByb3ZpZGVycy5vbGxhbWEnKTsKCiAgICB9IGVsc2UgaWYgKHByb3ZpZGVyID09PSAnb3BlbmFpJykgewogICAgICBpZiAoIWNmZy5lbnYpIGNmZy5lbnYgPSB7fTsKICAgICAgY2ZnLmVudi5PUEVOQUlfQVBJX0tFWSA9IG9wZW5haUtleSB8fCAnJzsKICAgICAgZGVsZXRlIGNmZy5lbnYuT0xMQU1BX0FQSV9LRVk7CiAgICAgIGRlbGV0ZSBjZmcuZW52LkFOVEhST1BJQ19BUElfS0VZOwogICAgICBkZWVwU2V0KGNmZywgJ2FnZW50cy5kZWZhdWx0cy5tb2RlbC5wcmltYXJ5JywgYG9wZW5haS8ke29wZW5haU1vZGVsIHx8ICdncHQtNG8nfWApOwogICAgICBkZWVwRGVsZXRlKGNmZywgJ21vZGVscy5wcm92aWRlcnMub2xsYW1hJyk7CgogICAgfSBlbHNlIGlmIChwcm92aWRlciA9PT0gJ2N1c3RvbScpIHsKICAgICAgaWYgKCFjZmcuZW52KSBjZmcuZW52ID0ge307CiAgICAgIGNmZy5lbnYuT1BFTkFJX0FQSV9LRVkgPSBjdXN0b21LZXkgfHwgJyc7CiAgICAgIGRlbGV0ZSBjZmcuZW52Lk9MTEFNQV9BUElfS0VZOwogICAgICBkZWxldGUgY2ZnLmVudi5BTlRIUk9QSUNfQVBJX0tFWTsKICAgICAgZGVlcFNldChjZmcsICdhZ2VudHMuZGVmYXVsdHMubW9kZWwucHJpbWFyeScsIGBvcGVuYWkvJHtjdXN0b21Nb2RlbCB8fCAnY3VzdG9tJ31gKTsKICAgICAgZGVlcFNldChjZmcsICdtb2RlbHMucHJvdmlkZXJzLm9wZW5haScsIHsKICAgICAgICBiYXNlVXJsOiBjdXN0b21VcmwgfHwgJycsCiAgICAgICAgYXBpS2V5OiBjdXN0b21LZXkgfHwgJycsCiAgICAgICAgYXBpOiAnb3BlbmFpLWNvbXBsZXRpb25zJywKICAgICAgICBtb2RlbHM6IFtidWlsZE1vZGVsRW50cnkoY3VzdG9tTW9kZWwgfHwgJ2N1c3RvbScpXQogICAgICB9KTsKICAgICAgZGVlcERlbGV0ZShjZmcsICdtb2RlbHMucHJvdmlkZXJzLm9sbGFtYScpOwogICAgfQoKICAgIHdyaXRlQ29uZmlnKGNmZyk7CiAgICByZXN0YXJ0U2VydmljZSgpOwogICAgcmV0dXJuIGpzb24ocmVzLCB7IG9rOiB0cnVlLCBjb25maWc6IGNmZyB9KTsKICB9CgogIC8vIENoYW5uZWwgc2F2ZSDigJQgd3JpdGVzIHByb3BlciBPcGVuQ2xhdyBjaGFubmVsIGZvcm1hdAogIGlmIChwYXRobmFtZSA9PT0gJy9hcGkvY2hhbm5lbHMnICYmIHJlcS5tZXRob2QgPT09ICdQT1NUJykgewogICAgY29uc3QgYm9keSA9IGF3YWl0IHBhcnNlQm9keShyZXEpOwogICAgbGV0IGNmZyA9IHJlYWRDb25maWcoKTsKCiAgICBpZiAoYm9keS50ZWxlZ3JhbSkgewogICAgICBjb25zdCB0ZyA9IGJvZHkudGVsZWdyYW07CiAgICAgIGlmICh0Zy5ib3RUb2tlbikgewogICAgICAgIGRlZXBTZXQoY2ZnLCAnY2hhbm5lbHMudGVsZWdyYW0uYWNjb3VudHMuZGVmYXVsdC5ib3RUb2tlbicsIHRnLmJvdFRva2VuKTsKICAgICAgICBpZiAodGcuZG1Qb2xpY3kpIGRlZXBTZXQoY2ZnLCAnY2hhbm5lbHMudGVsZWdyYW0uZG1Qb2xpY3knLCB0Zy5kbVBvbGljeSk7CiAgICAgICAgaWYgKHRnLmFsbG93RnJvbSAmJiB0Zy5hbGxvd0Zyb20ubGVuZ3RoKSB7CiAgICAgICAgICBkZWVwU2V0KGNmZywgJ2NoYW5uZWxzLnRlbGVncmFtLmFsbG93RnJvbScsIHRnLmFsbG93RnJvbSk7CiAgICAgICAgfQogICAgICB9CiAgICB9CiAgICBpZiAoYm9keS5kaXNjb3JkKSB7CiAgICAgIGNvbnN0IGRjID0gYm9keS5kaXNjb3JkOwogICAgICBpZiAoZGMuYm90VG9rZW4pIHsKICAgICAgICBkZWVwU2V0KGNmZywgJ2NoYW5uZWxzLmRpc2NvcmQuYWNjb3VudHMuZGVmYXVsdC5ib3RUb2tlbicsIGRjLmJvdFRva2VuKTsKICAgICAgICBpZiAoZGMuZ3VpbGRJZCkgZGVlcFNldChjZmcsICdjaGFubmVscy5kaXNjb3JkLmd1aWxkSWQnLCBkYy5ndWlsZElkKTsKICAgICAgfQogICAgfQoKICAgIHdyaXRlQ29uZmlnKGNmZyk7CiAgICByZXN0YXJ0U2VydmljZSgpOwogICAgcmV0dXJuIGpzb24ocmVzLCB7IG9rOiB0cnVlIH0pOwogIH0KCiAgLy8gU2VydmljZSBjb250cm9scwogIGlmIChwYXRobmFtZSA9PT0gJy9hcGkvc2VydmljZScgJiYgcmVxLm1ldGhvZCA9PT0gJ1BPU1QnKSB7CiAgICBjb25zdCB7IGFjdGlvbiB9ID0gYXdhaXQgcGFyc2VCb2R5KHJlcSk7CiAgICBpZiAoIVsnc3RhcnQnLCAnc3RvcCcsICdyZXN0YXJ0JywgJ3N0YXR1cyddLmluY2x1ZGVzKGFjdGlvbikpIHJldHVybiBqc29uKHJlcywgeyBlcnJvcjogJ0ludmFsaWQgYWN0aW9uJyB9LCA0MDApOwogICAgY29uc3QgcmVzdWx0ID0gcnVuKGBzeXN0ZW1jdGwgJHthY3Rpb259ICR7U0VSVklDRV9OQU1FfSAyPiYxYCwgMTUwMDApOwogICAgcmV0dXJuIGpzb24ocmVzLCB7IHJlc3VsdCB9KTsKICB9CgogIC8vIExvZ3MKICBpZiAocGF0aG5hbWUgPT09ICcvYXBpL2xvZ3MnKSB7CiAgICBjb25zdCBsaW5lcyA9IHBhcnNlSW50KG5ldyBVUkwocmVxLnVybCwgJ2h0dHA6Ly94Jykuc2VhcmNoUGFyYW1zLmdldCgnbGluZXMnKSB8fCAnMTAwJyk7CiAgICBjb25zdCByZXN1bHQgPSBydW4oYGpvdXJuYWxjdGwgLXUgJHtTRVJWSUNFX05BTUV9IC0tbm8tcGFnZXIgLW4gJHtNYXRoLm1pbihsaW5lcywgNTAwKX0gMj4vZGV2L251bGwgfHwgZWNobyAiTm8gbG9ncyBhdmFpbGFibGUiYCwgMTUwMDApOwogICAgcmV0dXJuIGpzb24ocmVzLCB7IGxvZ3M6IHJlc3VsdCB9KTsKICB9CgogIC8vIE9sbGFtYSBlbmRwb2ludHMg4oCUIHVzZXMgY29uZmlndXJlZCBVUkwKICBpZiAocGF0aG5hbWUgPT09ICcvYXBpL29sbGFtYS9tb2RlbHMnKSB7CiAgICBjb25zdCBkYXRhID0gYXdhaXQgaHR0cEZldGNoKGAke2dldE9sbGFtYVVybCgpfS9hcGkvdGFnc2ApOwogICAgcmV0dXJuIGpzb24ocmVzLCBkYXRhKTsKICB9CiAgaWYgKHBhdGhuYW1lID09PSAnL2FwaS9vbGxhbWEvcnVubmluZycpIHsKICAgIGNvbnN0IGRhdGEgPSBhd2FpdCBodHRwRmV0Y2goYCR7Z2V0T2xsYW1hVXJsKCl9L2FwaS9wc2ApOwogICAgcmV0dXJuIGpzb24ocmVzLCBkYXRhKTsKICB9CiAgaWYgKHBhdGhuYW1lID09PSAnL2FwaS9vbGxhbWEvcHVsbCcgJiYgcmVxLm1ldGhvZCA9PT0gJ1BPU1QnKSB7CiAgICBjb25zdCB7IG1vZGVsIH0gPSBhd2FpdCBwYXJzZUJvZHkocmVxKTsKICAgIGlmICghbW9kZWwpIHJldHVybiBqc29uKHJlcywgeyBlcnJvcjogJ01vZGVsIG5hbWUgcmVxdWlyZWQnIH0sIDQwMCk7CiAgICByZXMud3JpdGVIZWFkKDIwMCwgeyAnQ29udGVudC1UeXBlJzogJ3RleHQvZXZlbnQtc3RyZWFtJywgJ0NhY2hlLUNvbnRyb2wnOiAnbm8tY2FjaGUnLCAnQ29ubmVjdGlvbic6ICdrZWVwLWFsaXZlJyB9KTsKICAgIGNvbnN0IG9sbGFtYVVybCA9IGdldE9sbGFtYVVybCgpOwogICAgY29uc3QgdXJsID0gbmV3IFVSTCgnL2FwaS9wdWxsJywgb2xsYW1hVXJsKTsKICAgIGNvbnN0IGxpYiA9IHVybC5wcm90b2NvbCA9PT0gJ2h0dHBzOicgPyBodHRwcyA6IGh0dHA7CiAgICBjb25zdCBwdWxsUmVxID0gbGliLnJlcXVlc3QoewogICAgICBob3N0bmFtZTogdXJsLmhvc3RuYW1lLCBwb3J0OiB1cmwucG9ydCB8fCAodXJsLnByb3RvY29sID09PSAnaHR0cHM6JyA/IDQ0MyA6IDgwKSwKICAgICAgcGF0aDogdXJsLnBhdGhuYW1lLCBtZXRob2Q6ICdQT1NUJywgaGVhZGVyczogeyAnQ29udGVudC1UeXBlJzogJ2FwcGxpY2F0aW9uL2pzb24nIH0KICAgIH0sIHB1bGxSZXMgPT4gewogICAgICBwdWxsUmVzLm9uKCdkYXRhJywgY2h1bmsgPT4gewogICAgICAgIGNodW5rLnRvU3RyaW5nKCkuc3BsaXQoJ1xuJykuZmlsdGVyKEJvb2xlYW4pLmZvckVhY2gobCA9PiByZXMud3JpdGUoYGRhdGE6ICR7bH1cblxuYCkpOwogICAgICB9KTsKICAgICAgcHVsbFJlcy5vbignZW5kJywgKCkgPT4geyByZXMud3JpdGUoJ2RhdGE6IHsiZG9uZSI6dHJ1ZX1cblxuJyk7IHJlcy5lbmQoKTsgfSk7CiAgICB9KTsKICAgIHB1bGxSZXEub24oJ2Vycm9yJywgZSA9PiB7IHJlcy53cml0ZShgZGF0YTogeyJlcnJvciI6IiR7ZS5tZXNzYWdlfSJ9XG5cbmApOyByZXMuZW5kKCk7IH0pOwogICAgcHVsbFJlcS53cml0ZShKU09OLnN0cmluZ2lmeSh7IG5hbWU6IG1vZGVsLCBzdHJlYW06IHRydWUgfSkpOwogICAgcHVsbFJlcS5lbmQoKTsKICAgIHJldHVybjsKICB9CiAgaWYgKHBhdGhuYW1lID09PSAnL2FwaS9vbGxhbWEvZGVsZXRlJyAmJiByZXEubWV0aG9kID09PSAnUE9TVCcpIHsKICAgIGNvbnN0IHsgbW9kZWwgfSA9IGF3YWl0IHBhcnNlQm9keShyZXEpOwogICAgY29uc3QgZGF0YSA9IGF3YWl0IGh0dHBGZXRjaChgJHtnZXRPbGxhbWFVcmwoKX0vYXBpL2RlbGV0ZWAsIHsgbWV0aG9kOiAnREVMRVRFJywgYm9keTogeyBuYW1lOiBtb2RlbCB9IH0pOwogICAgcmV0dXJuIGpzb24ocmVzLCBkYXRhLmVycm9yID8gZGF0YSA6IHsgb2s6IHRydWUgfSk7CiAgfQoKICByZXR1cm4ganNvbihyZXMsIHsgZXJyb3I6ICdOb3QgZm91bmQnIH0sIDQwNCk7Cn0KCi8vIOKUgOKUgOKUgCBGcm9udGVuZCBIVE1MIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApmdW5jdGlvbiBnZXRIVE1MKCkgewogIHJldHVybiBgPCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij48bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLGluaXRpYWwtc2NhbGU9MSI+Cjx0aXRsZT5PcGVuQ2xhdyBEYXNoYm9hcmQ8L3RpdGxlPgo8c3R5bGU+Cip7bWFyZ2luOjA7cGFkZGluZzowO2JveC1zaXppbmc6Ym9yZGVyLWJveH0KOnJvb3R7LS1iZzojMGYxMTE3Oy0tc3VyZmFjZTojMWExZDI3Oy0tc3VyZmFjZTI6IzI0MjgzNjstLWJvcmRlcjojMmQzMTQ4Oy0tYWNjZW50OiM2YzVjZTc7LS1hY2NlbnQyOiNhMjliZmU7LS10ZXh0OiNlNGU2ZjA7LS10ZXh0MjojOGI4ZmE4Oy0tZ3JlZW46IzAwYjg5NDstLXJlZDojZmY2YjZiOy0tb3JhbmdlOiNmZGNiNmU7LS1ibHVlOiM3NGI5ZmY7LS1yYWRpdXM6MTBweDstLXNoYWRvdzowIDRweCAyNHB4IHJnYmEoMCwwLDAsLjMpfQpib2R5e2ZvbnQtZmFtaWx5Oi1hcHBsZS1zeXN0ZW0sQmxpbmtNYWNTeXN0ZW1Gb250LCdTZWdvZSBVSScsUm9ib3RvLHNhbnMtc2VyaWY7YmFja2dyb3VuZDp2YXIoLS1iZyk7Y29sb3I6dmFyKC0tdGV4dCk7bWluLWhlaWdodDoxMDB2aDtkaXNwbGF5OmZsZXh9CmF7Y29sb3I6dmFyKC0tYWNjZW50Mik7dGV4dC1kZWNvcmF0aW9uOm5vbmV9CmJ1dHRvbntjdXJzb3I6cG9pbnRlcjtib3JkZXI6bm9uZTtmb250OmluaGVyaXQ7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMpO3BhZGRpbmc6OHB4IDE4cHg7YmFja2dyb3VuZDp2YXIoLS1hY2NlbnQpO2NvbG9yOiNmZmY7dHJhbnNpdGlvbjouMnN9CmJ1dHRvbjpob3ZlcntiYWNrZ3JvdW5kOnZhcigtLWFjY2VudDIpO2NvbG9yOiMxMTF9CmJ1dHRvbi5kYW5nZXJ7YmFja2dyb3VuZDp2YXIoLS1yZWQpfWJ1dHRvbi5kYW5nZXI6aG92ZXJ7YmFja2dyb3VuZDojZTA1NTU1fQpidXR0b24uc2Vjb25kYXJ5e2JhY2tncm91bmQ6dmFyKC0tc3VyZmFjZTIpO2NvbG9yOnZhcigtLXRleHQpfWJ1dHRvbi5zZWNvbmRhcnk6aG92ZXJ7YmFja2dyb3VuZDp2YXIoLS1ib3JkZXIpfQppbnB1dCx0ZXh0YXJlYSxzZWxlY3R7YmFja2dyb3VuZDp2YXIoLS1zdXJmYWNlMik7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2NvbG9yOnZhcigtLXRleHQpO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6dmFyKC0tcmFkaXVzKTtmb250OmluaGVyaXQ7d2lkdGg6MTAwJTtvdXRsaW5lOm5vbmU7dHJhbnNpdGlvbjouMnN9CmlucHV0OmZvY3VzLHRleHRhcmVhOmZvY3VzLHNlbGVjdDpmb2N1c3tib3JkZXItY29sb3I6dmFyKC0tYWNjZW50KX0KdGV4dGFyZWF7cmVzaXplOnZlcnRpY2FsO2ZvbnQtZmFtaWx5OidTRiBNb25vJyxNb25hY28sQ29uc29sYXMsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxM3B4fQouYmFkZ2V7ZGlzcGxheTppbmxpbmUtYmxvY2s7cGFkZGluZzozcHggMTBweDtib3JkZXItcmFkaXVzOjIwcHg7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NjAwfQouYmFkZ2UuZ3JlZW57YmFja2dyb3VuZDpyZ2JhKDAsMTg0LDE0OCwuMTUpO2NvbG9yOnZhcigtLWdyZWVuKX0KLmJhZGdlLnJlZHtiYWNrZ3JvdW5kOnJnYmEoMjU1LDEwNywxMDcsLjE1KTtjb2xvcjp2YXIoLS1yZWQpfQouYmFkZ2Uub3Jhbmdle2JhY2tncm91bmQ6cmdiYSgyNTMsMjAzLDExMCwuMTUpO2NvbG9yOnZhcigtLW9yYW5nZSl9Ci5iYWRnZS5ibHVle2JhY2tncm91bmQ6cmdiYSgxMTYsMTg1LDI1NSwuMTUpO2NvbG9yOnZhcigtLWJsdWUpfQojbG9naW4tcGFnZXtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7d2lkdGg6MTAwJTttaW4taGVpZ2h0OjEwMHZoO2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6MjRweH0KI2xvZ2luLXBhZ2UgLmxvZ297Zm9udC1zaXplOjQycHg7Zm9udC13ZWlnaHQ6ODAwO2xldHRlci1zcGFjaW5nOi0xcHh9CiNsb2dpbi1wYWdlIC5sb2dvIHNwYW57Y29sb3I6dmFyKC0tYWNjZW50KX0KI2xvZ2luLXBhZ2UgZm9ybXtiYWNrZ3JvdW5kOnZhcigtLXN1cmZhY2UpO3BhZGRpbmc6MzJweDtib3JkZXItcmFkaXVzOjE2cHg7d2lkdGg6MzYwcHg7bWF4LXdpZHRoOjkwdnc7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6MTZweDtib3gtc2hhZG93OnZhcigtLXNoYWRvdyl9CiNsb2dpbi1wYWdlIGZvcm0gaDJ7dGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjE4cHg7Y29sb3I6dmFyKC0tdGV4dDIpfQojYXBwe2Rpc3BsYXk6bm9uZTt3aWR0aDoxMDAlO21pbi1oZWlnaHQ6MTAwdmh9Ci5zaWRlYmFye3dpZHRoOjI0MHB4O2JhY2tncm91bmQ6dmFyKC0tc3VyZmFjZSk7Ym9yZGVyLXJpZ2h0OjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47cG9zaXRpb246Zml4ZWQ7dG9wOjA7bGVmdDowO2JvdHRvbTowO3otaW5kZXg6MTB9Ci5zaWRlYmFyIC5sb2dve3BhZGRpbmc6MjRweCAyMHB4O2ZvbnQtc2l6ZToyMnB4O2ZvbnQtd2VpZ2h0OjgwMDtsZXR0ZXItc3BhY2luZzotMXB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcil9Ci5zaWRlYmFyIC5sb2dvIHNwYW57Y29sb3I6dmFyKC0tYWNjZW50KX0KLnNpZGViYXIgbmF2e2ZsZXg6MTtwYWRkaW5nOjEycHh9Ci5zaWRlYmFyIG5hdiBhe2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEycHg7cGFkZGluZzoxMXB4IDE2cHg7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMpO2NvbG9yOnZhcigtLXRleHQyKTt0cmFuc2l0aW9uOi4yczttYXJnaW4tYm90dG9tOjJweDtmb250LXNpemU6MTRweDtmb250LXdlaWdodDo1MDB9Ci5zaWRlYmFyIG5hdiBhOmhvdmVye2JhY2tncm91bmQ6dmFyKC0tc3VyZmFjZTIpO2NvbG9yOnZhcigtLXRleHQpfQouc2lkZWJhciBuYXYgYS5hY3RpdmV7YmFja2dyb3VuZDpyZ2JhKDEwOCw5MiwyMzEsLjE1KTtjb2xvcjp2YXIoLS1hY2NlbnQyKX0KLnNpZGViYXIgbmF2IGEgLmljb257Zm9udC1zaXplOjE4cHg7d2lkdGg6MjRweDt0ZXh0LWFsaWduOmNlbnRlcn0KLnNpZGViYXIgLmJvdHRvbXtwYWRkaW5nOjE2cHggMjBweDtib3JkZXItdG9wOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLXRleHQyKX0KLm1haW57bWFyZ2luLWxlZnQ6MjQwcHg7ZmxleDoxO3BhZGRpbmc6MzJweDttYXgtd2lkdGg6MTEwMHB4fQoubWFpbiBoMXtmb250LXNpemU6MjZweDttYXJnaW4tYm90dG9tOjI0cHg7Zm9udC13ZWlnaHQ6NzAwfQoucGFnZXtkaXNwbGF5Om5vbmV9LnBhZ2UuYWN0aXZle2Rpc3BsYXk6YmxvY2t9Ci5jYXJkc3tkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOnJlcGVhdChhdXRvLWZpbGwsbWlubWF4KDIyMHB4LDFmcikpO2dhcDoxNnB4O21hcmdpbi1ib3R0b206MzJweH0KLmNhcmR7YmFja2dyb3VuZDp2YXIoLS1zdXJmYWNlKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMpO3BhZGRpbmc6MjBweH0KLmNhcmQgLmxhYmVse2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLXRleHQyKTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6MXB4O21hcmdpbi1ib3R0b206OHB4fQouY2FyZCAudmFsdWV7Zm9udC1zaXplOjIwcHg7Zm9udC13ZWlnaHQ6NzAwfQouZm9ybS1ncm91cHttYXJnaW4tYm90dG9tOjE4cHh9Ci5mb3JtLWdyb3VwIGxhYmVse2Rpc3BsYXk6YmxvY2s7Zm9udC1zaXplOjEzcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXRleHQyKTttYXJnaW4tYm90dG9tOjZweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjVweH0KLmZvcm0tcm93e2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6MTZweH0KLmJ0bi1yb3d7ZGlzcGxheTpmbGV4O2dhcDoxMHB4O21hcmdpbi10b3A6MjBweDtmbGV4LXdyYXA6d3JhcH0KLmxvZy12aWV3ZXJ7YmFja2dyb3VuZDojMGEwYzEwO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cyk7cGFkZGluZzoxNnB4O2ZvbnQtZmFtaWx5OidTRiBNb25vJyxNb25hY28sQ29uc29sYXMsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMnB4O2xpbmUtaGVpZ2h0OjEuNzttYXgtaGVpZ2h0OjUwMHB4O292ZXJmbG93OmF1dG87d2hpdGUtc3BhY2U6cHJlLXdyYXA7d29yZC1icmVhazpicmVhay1hbGw7Y29sb3I6I2EwYThjMH0KdGFibGV7d2lkdGg6MTAwJTtib3JkZXItY29sbGFwc2U6Y29sbGFwc2U7YmFja2dyb3VuZDp2YXIoLS1zdXJmYWNlKTtib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cyk7b3ZlcmZsb3c6aGlkZGVuO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKX0KdGgsdGR7cGFkZGluZzoxMnB4IDE2cHg7dGV4dC1hbGlnbjpsZWZ0O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Zm9udC1zaXplOjE0cHh9CnRoe2JhY2tncm91bmQ6dmFyKC0tc3VyZmFjZTIpO2NvbG9yOnZhcigtLXRleHQyKTtmb250LXNpemU6MTJweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjVweDtmb250LXdlaWdodDo2MDB9CnRyOmxhc3QtY2hpbGQgdGR7Ym9yZGVyLWJvdHRvbTpub25lfQoudGFic3tkaXNwbGF5OmZsZXg7Z2FwOjRweDttYXJnaW4tYm90dG9tOjI0cHg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTtwYWRkaW5nLWJvdHRvbTowfQoudGFicyBidXR0b257YmFja2dyb3VuZDpub25lO2NvbG9yOnZhcigtLXRleHQyKTtib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cykgdmFyKC0tcmFkaXVzKSAwIDA7cGFkZGluZzoxMHB4IDIwcHg7Ym9yZGVyLWJvdHRvbToycHggc29saWQgdHJhbnNwYXJlbnR9Ci50YWJzIGJ1dHRvbi5hY3RpdmV7Y29sb3I6dmFyKC0tYWNjZW50Mik7Ym9yZGVyLWJvdHRvbS1jb2xvcjp2YXIoLS1hY2NlbnQpO2JhY2tncm91bmQ6cmdiYSgxMDgsOTIsMjMxLC4wOCl9Ci5wcm9ncmVzcy1iYXJ7d2lkdGg6MTAwJTtoZWlnaHQ6NnB4O2JhY2tncm91bmQ6dmFyKC0tc3VyZmFjZTIpO2JvcmRlci1yYWRpdXM6M3B4O292ZXJmbG93OmhpZGRlbjttYXJnaW4tdG9wOjhweH0KLnByb2dyZXNzLWJhciAuZmlsbHtoZWlnaHQ6MTAwJTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx2YXIoLS1hY2NlbnQpLHZhcigtLWFjY2VudDIpKTt0cmFuc2l0aW9uOndpZHRoIC4zcztib3JkZXItcmFkaXVzOjNweH0KLnRvYXN0e3Bvc2l0aW9uOmZpeGVkO2JvdHRvbToyNHB4O3JpZ2h0OjI0cHg7YmFja2dyb3VuZDp2YXIoLS1zdXJmYWNlKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7cGFkZGluZzoxNHB4IDI0cHg7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMpO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt6LWluZGV4Ojk5OTthbmltYXRpb246c2xpZGVJbiAuM3M7Zm9udC1zaXplOjE0cHh9Ci50b2FzdC5lcnJvcntib3JkZXItY29sb3I6dmFyKC0tcmVkKTtjb2xvcjp2YXIoLS1yZWQpfQoudG9hc3Quc3VjY2Vzc3tib3JkZXItY29sb3I6dmFyKC0tZ3JlZW4pO2NvbG9yOnZhcigtLWdyZWVuKX0KQGtleWZyYW1lcyBzbGlkZUlue2Zyb217dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMjBweCk7b3BhY2l0eTowfXRve3RyYW5zZm9ybTp0cmFuc2xhdGVZKDApO29wYWNpdHk6MX19CkBtZWRpYShtYXgtd2lkdGg6NzY4cHgpewogIC5zaWRlYmFye3dpZHRoOjYwcHh9LnNpZGViYXIgLmxvZ297cGFkZGluZzoxNnB4O2ZvbnQtc2l6ZTowfS5zaWRlYmFyIC5sb2dvOjphZnRlcntjb250ZW50OidcXDFGNDNFJztmb250LXNpemU6MjRweH0KICAuc2lkZWJhciBuYXYgYSBzcGFuOm5vdCguaWNvbil7ZGlzcGxheTpub25lfS5zaWRlYmFyIG5hdiBhe2p1c3RpZnktY29udGVudDpjZW50ZXI7cGFkZGluZzoxNHB4fQogIC5zaWRlYmFyIC5ib3R0b217ZGlzcGxheTpub25lfS5tYWlue21hcmdpbi1sZWZ0OjYwcHg7cGFkZGluZzoyMHB4fQogIC5mb3JtLXJvd3tncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfS5jYXJkc3tncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfQp9Cjwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+Cgo8ZGl2IGlkPSJsb2dpbi1wYWdlIj4KICA8ZGl2IGNsYXNzPSJsb2dvIj5PcGVuPHNwYW4+Q2xhdzwvc3Bhbj4gXFx1ezFGNDNFfTwvZGl2PgogIDxmb3JtIG9uc3VibWl0PSJkb0xvZ2luKGV2ZW50KSI+CiAgICA8aDI+RGFzaGJvYXJkIExvZ2luPC9oMj4KICAgIDxpbnB1dCB0eXBlPSJwYXNzd29yZCIgaWQ9ImxvZ2luLXBhc3MiIHBsYWNlaG9sZGVyPSJQYXNzd29yZCIgYXV0b2ZvY3VzPgogICAgPGJ1dHRvbiB0eXBlPSJzdWJtaXQiIHN0eWxlPSJ3aWR0aDoxMDAlIj5TaWduIEluPC9idXR0b24+CiAgICA8ZGl2IGlkPSJsb2dpbi1lcnJvciIgc3R5bGU9ImNvbG9yOnZhcigtLXJlZCk7dGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEzcHgiPjwvZGl2PgogIDwvZm9ybT4KPC9kaXY+Cgo8ZGl2IGlkPSJhcHAiPgogIDxhc2lkZSBjbGFzcz0ic2lkZWJhciI+CiAgICA8ZGl2IGNsYXNzPSJsb2dvIj5PcGVuPHNwYW4+Q2xhdzwvc3Bhbj48L2Rpdj4KICAgIDxuYXY+CiAgICAgIDxhIGhyZWY9IiMiIGRhdGEtcGFnZT0iZGFzaGJvYXJkIiBjbGFzcz0iYWN0aXZlIj48c3BhbiBjbGFzcz0iaWNvbiI+XFx1ezFGNENBfTwvc3Bhbj48c3Bhbj5EYXNoYm9hcmQ8L3NwYW4+PC9hPgogICAgICA8YSBocmVmPSIjIiBkYXRhLXBhZ2U9InByb3ZpZGVycyI+PHNwYW4gY2xhc3M9Imljb24iPlxcdXsxRjkxNn08L3NwYW4+PHNwYW4+UHJvdmlkZXJzPC9zcGFuPjwvYT4KICAgICAgPGEgaHJlZj0iIyIgZGF0YS1wYWdlPSJvbGxhbWEiPjxzcGFuIGNsYXNzPSJpY29uIj5cXHV7MUY5OTl9PC9zcGFuPjxzcGFuPk9sbGFtYTwvc3Bhbj48L2E+CiAgICAgIDxhIGhyZWY9IiMiIGRhdGEtcGFnZT0iY29uZmlnIj48c3BhbiBjbGFzcz0iaWNvbiI+XFx1MjY5OVxcdUZFMEY8L3NwYW4+PHNwYW4+Q29uZmlnPC9zcGFuPjwvYT4KICAgICAgPGEgaHJlZj0iIyIgZGF0YS1wYWdlPSJzZXJ2aWNlcyI+PHNwYW4gY2xhc3M9Imljb24iPlxcdXsxRjUyN308L3NwYW4+PHNwYW4+U2VydmljZXM8L3NwYW4+PC9hPgogICAgICA8YSBocmVmPSIjIiBkYXRhLXBhZ2U9ImNoYW5uZWxzIj48c3BhbiBjbGFzcz0iaWNvbiI+XFx1ezFGNEFDfTwvc3Bhbj48c3Bhbj5DaGFubmVsczwvc3Bhbj48L2E+CiAgICA8L25hdj4KICAgIDxkaXYgY2xhc3M9ImJvdHRvbSI+PGEgaHJlZj0iIyIgb25jbGljaz0iZG9Mb2dvdXQoKSIgc3R5bGU9ImNvbG9yOnZhcigtLXRleHQyKTtmb250LXNpemU6MTNweCI+XFx1ezFGNkFBfSBMb2dvdXQ8L2E+PC9kaXY+CiAgPC9hc2lkZT4KICA8ZGl2IGNsYXNzPSJtYWluIj4KICAgIDwhLS0gRGFzaGJvYXJkIC0tPgogICAgPGRpdiBjbGFzcz0icGFnZSBhY3RpdmUiIGlkPSJwYWdlLWRhc2hib2FyZCI+CiAgICAgIDxoMT5EYXNoYm9hcmQ8L2gxPgogICAgICA8ZGl2IGNsYXNzPSJjYXJkcyIgaWQ9InN0YXR1cy1jYXJkcyI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImJ0bi1yb3ciPjxidXR0b24gb25jbGljaz0ibG9hZERhc2hib2FyZCgpIj5cXHV7MUY1MDR9IFJlZnJlc2g8L2J1dHRvbj48L2Rpdj4KICAgIDwvZGl2PgogICAgPCEtLSBQcm92aWRlcnMgLS0+CiAgICA8ZGl2IGNsYXNzPSJwYWdlIiBpZD0icGFnZS1wcm92aWRlcnMiPgogICAgICA8aDE+QUkgUHJvdmlkZXIgQ29uZmlndXJhdGlvbjwvaDE+CiAgICAgIDxkaXYgY2xhc3M9InRhYnMiIGlkPSJwcm92aWRlci10YWJzIj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJhY3RpdmUiIGRhdGEtcHJvdmlkZXI9Im9sbGFtYSI+T2xsYW1hPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBkYXRhLXByb3ZpZGVyPSJhbnRocm9waWMiPkFudGhyb3BpYzwvYnV0dG9uPgogICAgICAgIDxidXR0b24gZGF0YS1wcm92aWRlcj0ib3BlbmFpIj5PcGVuQUk8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGRhdGEtcHJvdmlkZXI9ImN1c3RvbSI+Q3VzdG9tPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGlkPSJwcm92aWRlci1mb3JtcyI+CiAgICAgICAgPGRpdiBjbGFzcz0icHJvdmlkZXItZm9ybSIgZGF0YS1wcm92aWRlcj0ib2xsYW1hIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5PbGxhbWEgVVJMPC9sYWJlbD48aW5wdXQgaWQ9InAtb2xsYW1hLXVybCIgcGxhY2Vob2xkZXI9Imh0dHA6Ly9sb2NhbGhvc3Q6MTE0MzQiPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncm91cCI+PGxhYmVsPk1vZGVsPC9sYWJlbD48c2VsZWN0IGlkPSJwLW9sbGFtYS1tb2RlbCI+PG9wdGlvbj5Mb2FkaW5nLi4uPC9vcHRpb24+PC9zZWxlY3Q+CiAgICAgICAgICAgIDxidXR0b24gY2xhc3M9InNlY29uZGFyeSIgb25jbGljaz0icmVmcmVzaE9sbGFtYU1vZGVscygpIiBzdHlsZT0ibWFyZ2luLXRvcDo4cHgiPlJlZnJlc2ggTW9kZWxzPC9idXR0b24+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icHJvdmlkZXItZm9ybSIgZGF0YS1wcm92aWRlcj0iYW50aHJvcGljIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5BUEkgS2V5PC9sYWJlbD48aW5wdXQgaWQ9InAtYW50aHJvcGljLWtleSIgdHlwZT0icGFzc3dvcmQiIHBsYWNlaG9sZGVyPSJzay1hbnQtLi4uIj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5Nb2RlbDwvbGFiZWw+PHNlbGVjdCBpZD0icC1hbnRocm9waWMtbW9kZWwiPgogICAgICAgICAgICA8b3B0aW9uPmNsYXVkZS1vcHVzLTQtMjAyNTA1MTQ8L29wdGlvbj48b3B0aW9uPmNsYXVkZS1zb25uZXQtNC0yMDI1MDUxNDwvb3B0aW9uPjxvcHRpb24+Y2xhdWRlLTMtNS1oYWlrdS0yMDI0MTAyMjwvb3B0aW9uPjxvcHRpb24+Y2xhdWRlLTMtNS1zb25uZXQtMjAyNDEwMjI8L29wdGlvbj4KICAgICAgICAgIDwvc2VsZWN0PjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InByb3ZpZGVyLWZvcm0iIGRhdGEtcHJvdmlkZXI9Im9wZW5haSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+QVBJIEtleTwvbGFiZWw+PGlucHV0IGlkPSJwLW9wZW5haS1rZXkiIHR5cGU9InBhc3N3b3JkIiBwbGFjZWhvbGRlcj0ic2stLi4uIj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5Nb2RlbDwvbGFiZWw+PHNlbGVjdCBpZD0icC1vcGVuYWktbW9kZWwiPgogICAgICAgICAgICA8b3B0aW9uPmdwdC00bzwvb3B0aW9uPjxvcHRpb24+Z3B0LTRvLW1pbmk8L29wdGlvbj48b3B0aW9uPmdwdC00LXR1cmJvPC9vcHRpb24+PG9wdGlvbj5vMTwvb3B0aW9uPjxvcHRpb24+bzEtbWluaTwvb3B0aW9uPjxvcHRpb24+bzMtbWluaTwvb3B0aW9uPgogICAgICAgICAgPC9zZWxlY3Q+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icHJvdmlkZXItZm9ybSIgZGF0YS1wcm92aWRlcj0iY3VzdG9tIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5CYXNlIFVSTDwvbGFiZWw+PGlucHV0IGlkPSJwLWN1c3RvbS11cmwiIHBsYWNlaG9sZGVyPSJodHRwczovL2FwaS5leGFtcGxlLmNvbS92MSI+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+QVBJIEtleTwvbGFiZWw+PGlucHV0IGlkPSJwLWN1c3RvbS1rZXkiIHR5cGU9InBhc3N3b3JkIiBwbGFjZWhvbGRlcj0iQVBJIGtleSI+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+TW9kZWwgTmFtZTwvbGFiZWw+PGlucHV0IGlkPSJwLWN1c3RvbS1tb2RlbCIgcGxhY2Vob2xkZXI9Im1vZGVsLW5hbWUiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYnRuLXJvdyI+PGJ1dHRvbiBvbmNsaWNrPSJzYXZlUHJvdmlkZXIoKSI+XFx1ezFGNEJFfSBTYXZlIFByb3ZpZGVyIENvbmZpZzwvYnV0dG9uPjwvZGl2PgogICAgPC9kaXY+CiAgICA8IS0tIE9sbGFtYSAtLT4KICAgIDxkaXYgY2xhc3M9InBhZ2UiIGlkPSJwYWdlLW9sbGFtYSI+CiAgICAgIDxoMT5PbGxhbWEgTWFuYWdlbWVudDwvaDE+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tcm93IiBzdHlsZT0ibWFyZ2luLWJvdHRvbToyNHB4Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+UHVsbCBOZXcgTW9kZWw8L2xhYmVsPgogICAgICAgICAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2dhcDo4cHgiPjxpbnB1dCBpZD0ib2xsYW1hLXB1bGwtbmFtZSIgcGxhY2Vob2xkZXI9ImxsYW1hMzo4YiI+PGJ1dHRvbiBvbmNsaWNrPSJwdWxsTW9kZWwoKSI+XFx1MkIwN1xcdUZFMEYgUHVsbDwvYnV0dG9uPjwvZGl2PgogICAgICAgICAgPGRpdiBpZD0icHVsbC1wcm9ncmVzcyIgc3R5bGU9Im1hcmdpbi10b3A6MTJweCI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8aDIgc3R5bGU9ImZvbnQtc2l6ZToxOHB4O21hcmdpbi1ib3R0b206MTJweCI+SW5zdGFsbGVkIE1vZGVsczwvaDI+CiAgICAgIDx0YWJsZT48dGhlYWQ+PHRyPjx0aD5Nb2RlbDwvdGg+PHRoPlNpemU8L3RoPjx0aD5Nb2RpZmllZDwvdGg+PHRoPkFjdGlvbnM8L3RoPjwvdHI+PC90aGVhZD48dGJvZHkgaWQ9Im9sbGFtYS1tb2RlbHMtbGlzdCI+PHRyPjx0ZCBjb2xzcGFuPSI0Ij5Mb2FkaW5nLi4uPC90ZD48L3RyPjwvdGJvZHk+PC90YWJsZT4KICAgICAgPGgyIHN0eWxlPSJmb250LXNpemU6MThweDttYXJnaW46MjRweCAwIDEycHgiPlJ1bm5pbmcgTW9kZWxzPC9oMj4KICAgICAgPHRhYmxlPjx0aGVhZD48dHI+PHRoPk1vZGVsPC90aD48dGg+U2l6ZTwvdGg+PHRoPlByb2Nlc3NvcjwvdGg+PHRoPlVudGlsPC90aD48L3RyPjwvdGhlYWQ+PHRib2R5IGlkPSJvbGxhbWEtcnVubmluZy1saXN0Ij48dHI+PHRkIGNvbHNwYW49IjQiPkxvYWRpbmcuLi48L3RkPjwvdHI+PC90Ym9keT48L3RhYmxlPgogICAgICA8ZGl2IGNsYXNzPSJidG4tcm93IiBzdHlsZT0ibWFyZ2luLXRvcDoxNnB4Ij48YnV0dG9uIG9uY2xpY2s9ImxvYWRPbGxhbWEoKSI+XFx1ezFGNTA0fSBSZWZyZXNoPC9idXR0b24+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDwhLS0gQ29uZmlnIC0tPgogICAgPGRpdiBjbGFzcz0icGFnZSIgaWQ9InBhZ2UtY29uZmlnIj4KICAgICAgPGgxPk9wZW5DbGF3IENvbmZpZ3VyYXRpb248L2gxPgogICAgICA8ZGl2IGNsYXNzPSJ0YWJzIiBpZD0iY29uZmlnLXRhYnMiPgogICAgICAgIDxidXR0b24gY2xhc3M9ImFjdGl2ZSIgZGF0YS10YWI9ImZvcm0iPkZvcm0gRWRpdG9yPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBkYXRhLXRhYj0ianNvbiI+UmF3IEpTT048L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgaWQ9ImNvbmZpZy1mb3JtLXZpZXciPgogICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tcm93Ij4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5HYXRld2F5IFBvcnQ8L2xhYmVsPjxpbnB1dCBpZD0iY2ZnLXBvcnQiIHR5cGU9Im51bWJlciIgcGxhY2Vob2xkZXI9IjE4Nzg5Ij48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5HYXRld2F5IEJpbmQ8L2xhYmVsPjxpbnB1dCBpZD0iY2ZnLWJpbmQiIHBsYWNlaG9sZGVyPSJsb29wYmFjayI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1yb3ciPgogICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncm91cCI+PGxhYmVsPlByaW1hcnkgTW9kZWw8L2xhYmVsPjxpbnB1dCBpZD0iY2ZnLW1vZGVsIiBwbGFjZWhvbGRlcj0iYW50aHJvcGljL2NsYXVkZS1zb25uZXQtNC0yMDI1MDUxNCI+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+QXV0aCBUb2tlbjwvbGFiZWw+PGlucHV0IGlkPSJjZmctdG9rZW4iIHR5cGU9InBhc3N3b3JkIiBwbGFjZWhvbGRlcj0iYXV0by1nZW5lcmF0ZWQiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBpZD0iY29uZmlnLWpzb24tdmlldyIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncm91cCI+PHRleHRhcmVhIGlkPSJjZmctcmF3IiByb3dzPSIyMCIgcGxhY2Vob2xkZXI9IkxvYWRpbmcuLi4iPjwvdGV4dGFyZWE+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJidG4tcm93Ij4KICAgICAgICA8YnV0dG9uIG9uY2xpY2s9InNhdmVDb25maWcoKSI+XFx1ezFGNEJFfSBTYXZlIENvbmZpZ3VyYXRpb248L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJzZWNvbmRhcnkiIG9uY2xpY2s9ImxvYWRDb25maWcoKSI+XFx1ezFGNTA0fSBSZWxvYWQ8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDwhLS0gU2VydmljZXMgLS0+CiAgICA8ZGl2IGNsYXNzPSJwYWdlIiBpZD0icGFnZS1zZXJ2aWNlcyI+CiAgICAgIDxoMT5TZXJ2aWNlIENvbnRyb2xzPC9oMT4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi1ib3R0b206MjRweCI+CiAgICAgICAgPGRpdiBjbGFzcz0ibGFiZWwiPk9wZW5DbGF3IEdhdGV3YXk8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJzdmMtc3RhdHVzIiBjbGFzcz0idmFsdWUiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjE2cHgiPkNoZWNraW5nLi4uPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iYnRuLXJvdyI+CiAgICAgICAgICA8YnV0dG9uIG9uY2xpY2s9InN2Y0FjdGlvbignc3RhcnQnKSIgc3R5bGU9ImJhY2tncm91bmQ6dmFyKC0tZ3JlZW4pIj5cXHUyNUI2IFN0YXJ0PC9idXR0b24+CiAgICAgICAgICA8YnV0dG9uIG9uY2xpY2s9InN2Y0FjdGlvbignc3RvcCcpIiBjbGFzcz0iZGFuZ2VyIj5cXHUyM0Y5IFN0b3A8L2J1dHRvbj4KICAgICAgICAgIDxidXR0b24gb25jbGljaz0ic3ZjQWN0aW9uKCdyZXN0YXJ0JykiIHN0eWxlPSJiYWNrZ3JvdW5kOnZhcigtLW9yYW5nZSk7Y29sb3I6IzExMSI+XFx1ezFGNTA0fSBSZXN0YXJ0PC9idXR0b24+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJzZWNvbmRhcnkiIG9uY2xpY2s9InN2Y0FjdGlvbignc3RhdHVzJykiPlxcdXsxRjRDQX0gU3RhdHVzPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8aDIgc3R5bGU9ImZvbnQtc2l6ZToxOHB4O21hcmdpbi1ib3R0b206MTJweCI+UmVjZW50IExvZ3M8L2gyPgogICAgICA8ZGl2IHN0eWxlPSJtYXJnaW4tYm90dG9tOjEycHgiPgogICAgICAgIDxzZWxlY3QgaWQ9ImxvZy1saW5lcyIgb25jaGFuZ2U9ImxvYWRMb2dzKCkiIHN0eWxlPSJ3aWR0aDphdXRvO2Rpc3BsYXk6aW5saW5lLWJsb2NrIj4KICAgICAgICAgIDxvcHRpb24gdmFsdWU9IjUwIj41MCBsaW5lczwvb3B0aW9uPjxvcHRpb24gdmFsdWU9IjEwMCIgc2VsZWN0ZWQ+MTAwIGxpbmVzPC9vcHRpb24+PG9wdGlvbiB2YWx1ZT0iMjAwIj4yMDAgbGluZXM8L29wdGlvbj48b3B0aW9uIHZhbHVlPSI1MDAiPjUwMCBsaW5lczwvb3B0aW9uPgogICAgICAgIDwvc2VsZWN0PgogICAgICAgIDxidXR0b24gY2xhc3M9InNlY29uZGFyeSIgb25jbGljaz0ibG9hZExvZ3MoKSIgc3R5bGU9Im1hcmdpbi1sZWZ0OjhweCI+XFx1ezFGNTA0fSBSZWZyZXNoPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJsb2ctdmlld2VyIiBpZD0ibG9nLW91dHB1dCI+TG9hZGluZy4uLjwvZGl2PgogICAgPC9kaXY+CiAgICA8IS0tIENoYW5uZWxzIC0tPgogICAgPGRpdiBjbGFzcz0icGFnZSIgaWQ9InBhZ2UtY2hhbm5lbHMiPgogICAgICA8aDE+Q2hhbm5lbCBDb25maWd1cmF0aW9uPC9oMT4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi1ib3R0b206MjRweCI+CiAgICAgICAgPGgzIHN0eWxlPSJtYXJnaW4tYm90dG9tOjE2cHgiPlRlbGVncmFtPC9oMz4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+Qm90IFRva2VuPC9sYWJlbD48aW5wdXQgaWQ9ImNoLXRnLXRva2VuIiB0eXBlPSJwYXNzd29yZCIgcGxhY2Vob2xkZXI9IjEyMzQ1NjpBQkMtLi4uIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWdyb3VwIj48bGFiZWw+RE0gUG9saWN5PC9sYWJlbD48c2VsZWN0IGlkPSJjaC10Zy1kbSI+PG9wdGlvbiB2YWx1ZT0iYWxsb3ciPmFsbG93PC9vcHRpb24+PG9wdGlvbiB2YWx1ZT0iZGVueSI+ZGVueTwvb3B0aW9uPjwvc2VsZWN0PjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5BbGxvdyBGcm9tIChjb21tYS1zZXBhcmF0ZWQgY2hhdCBJRHMpPC9sYWJlbD48aW5wdXQgaWQ9ImNoLXRnLWFsbG93IiBwbGFjZWhvbGRlcj0iLTEwMDEyMzQ1Njc4OSwgMTIzNDUiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi1ib3R0b206MjRweCI+CiAgICAgICAgPGgzIHN0eWxlPSJtYXJnaW4tYm90dG9tOjE2cHgiPkRpc2NvcmQ8L2gzPgogICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5Cb3QgVG9rZW48L2xhYmVsPjxpbnB1dCBpZD0iY2gtZGMtdG9rZW4iIHR5cGU9InBhc3N3b3JkIiBwbGFjZWhvbGRlcj0iRGlzY29yZCBib3QgdG9rZW4iPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tZ3JvdXAiPjxsYWJlbD5HdWlsZCBJRDwvbGFiZWw+PGlucHV0IGlkPSJjaC1kYy1ndWlsZCIgcGxhY2Vob2xkZXI9IlNlcnZlciBJRCI+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJidG4tcm93Ij48YnV0dG9uIG9uY2xpY2s9InNhdmVDaGFubmVscygpIj5cXHV7MUY0QkV9IFNhdmUgQ2hhbm5lbCBDb25maWc8L2J1dHRvbj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KCjxzY3JpcHQ+CmNvbnN0IEFQST0nJzsKbGV0IGN1cnJlbnRDb25maWc9e307Cgphc3luYyBmdW5jdGlvbiBkb0xvZ2luKGUpewogIGUucHJldmVudERlZmF1bHQoKTsKICBjb25zdCByPWF3YWl0IGZldGNoKEFQSSsnL2FwaS9sb2dpbicse21ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSxib2R5OkpTT04uc3RyaW5naWZ5KHtwYXNzd29yZDpkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9naW4tcGFzcycpLnZhbHVlfSl9KTsKICBpZihyLm9rKXtkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9naW4tcGFnZScpLnN0eWxlLmRpc3BsYXk9J25vbmUnO2RvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAnKS5zdHlsZS5kaXNwbGF5PSdmbGV4Jztpbml0KCk7fQogIGVsc2UgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvZ2luLWVycm9yJykudGV4dENvbnRlbnQ9J0ludmFsaWQgcGFzc3dvcmQnOwp9CmFzeW5jIGZ1bmN0aW9uIGRvTG9nb3V0KCl7YXdhaXQgZmV0Y2goQVBJKycvYXBpL2xvZ291dCcpO2xvY2F0aW9uLnJlbG9hZCgpO30KCmZ1bmN0aW9uIHRvYXN0KG1zZyx0eXBlPSdzdWNjZXNzJyl7CiAgY29uc3QgdD1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTt0LmNsYXNzTmFtZT0ndG9hc3QgJyt0eXBlO3QudGV4dENvbnRlbnQ9bXNnO2RvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQodCk7CiAgc2V0VGltZW91dCgoKT0+dC5yZW1vdmUoKSwzMDAwKTsKfQoKLy8gTmF2CmRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5zaWRlYmFyIG5hdiBhJykuZm9yRWFjaChhPT5hLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJyxlPT57CiAgZS5wcmV2ZW50RGVmYXVsdCgpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5zaWRlYmFyIG5hdiBhJykuZm9yRWFjaCh4PT54LmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBhLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5wYWdlJykuZm9yRWFjaChwPT5wLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFnZS0nK2EuZGF0YXNldC5wYWdlKS5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBjb25zdCBwPWEuZGF0YXNldC5wYWdlOwogIGlmKHA9PT0nZGFzaGJvYXJkJylsb2FkRGFzaGJvYXJkKCk7CiAgaWYocD09PSdvbGxhbWEnKWxvYWRPbGxhbWEoKTsKICBpZihwPT09J2NvbmZpZycpbG9hZENvbmZpZygpOwogIGlmKHA9PT0nc2VydmljZXMnKXtzdmNBY3Rpb24oJ3N0YXR1cycpO2xvYWRMb2dzKCk7fQogIGlmKHA9PT0ncHJvdmlkZXJzJylsb2FkUHJvdmlkZXJzKCk7CiAgaWYocD09PSdjaGFubmVscycpbG9hZENoYW5uZWxzKCk7Cn0pKTsKCi8vIFByb3ZpZGVyIHRhYnMKZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnI3Byb3ZpZGVyLXRhYnMgYnV0dG9uJykuZm9yRWFjaChiPT5iLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywoKT0+ewogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJyNwcm92aWRlci10YWJzIGJ1dHRvbicpLmZvckVhY2goeD0+eC5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgYi5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcucHJvdmlkZXItZm9ybScpLmZvckVhY2goZj0+e2Yuc3R5bGUuZGlzcGxheT1mLmRhdGFzZXQucHJvdmlkZXI9PT1iLmRhdGFzZXQucHJvdmlkZXI/J2Jsb2NrJzonbm9uZSd9KTsKfSkpOwoKLy8gQ29uZmlnIHRhYnMKZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnI2NvbmZpZy10YWJzIGJ1dHRvbicpLmZvckVhY2goYj0+Yi5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsKCk9PnsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcjY29uZmlnLXRhYnMgYnV0dG9uJykuZm9yRWFjaCh4PT54LmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBiLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjb25maWctZm9ybS12aWV3Jykuc3R5bGUuZGlzcGxheT1iLmRhdGFzZXQudGFiPT09J2Zvcm0nPydibG9jayc6J25vbmUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjb25maWctanNvbi12aWV3Jykuc3R5bGUuZGlzcGxheT1iLmRhdGFzZXQudGFiPT09J2pzb24nPydibG9jayc6J25vbmUnOwogIGlmKGIuZGF0YXNldC50YWI9PT0nanNvbicpZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1yYXcnKS52YWx1ZT1KU09OLnN0cmluZ2lmeShjdXJyZW50Q29uZmlnLG51bGwsMik7Cn0pKTsKCmZ1bmN0aW9uIGRpZyhvYmoscGF0aCxkZWYpewogIHJldHVybiBwYXRoLnNwbGl0KCcuJykucmVkdWNlKChvLGspPT5vJiZ0eXBlb2Ygbz09PSdvYmplY3QnP29ba106dW5kZWZpbmVkLG9iail8fGRlZnx8Jyc7Cn0KCi8vIERhc2hib2FyZAphc3luYyBmdW5jdGlvbiBsb2FkRGFzaGJvYXJkKCl7CiAgdHJ5ewogICAgY29uc3Qgcj1hd2FpdCBmZXRjaChBUEkrJy9hcGkvc3RhdHVzJyk7Y29uc3QgZD1hd2FpdCByLmpzb24oKTsKICAgIGNvbnN0IGlzQT1zPT5zJiYocy5pbmNsdWRlcygnYWN0aXZlJyl8fHMuaW5jbHVkZXMoJ3J1bm5pbmcnKSk7CiAgICBjb25zdCBiYWRnZT0ocyxsKT0+e2w9bHx8cztyZXR1cm4gaXNBKHMpPyc8c3BhbiBjbGFzcz0iYmFkZ2UgZ3JlZW4iPicrbCsnPC9zcGFuPic6cz09PSdvZmZsaW5lJ3x8cz09PSdpbmFjdGl2ZSc/JzxzcGFuIGNsYXNzPSJiYWRnZSByZWQiPicrbCsnPC9zcGFuPic6JzxzcGFuIGNsYXNzPSJiYWRnZSBvcmFuZ2UiPicrbCsnPC9zcGFuPic7fTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdGF0dXMtY2FyZHMnKS5pbm5lckhUTUw9WwogICAgICB7bDonR2F0ZXdheScsdjpiYWRnZShkLmdhdGV3YXkpfSx7bDonRG9ja2VyJyx2OmJhZGdlKGQuZG9ja2VyKX0sCiAgICAgIHtsOidPbGxhbWEnLHY6ZC5vbGxhbWE9PT0nb2ZmbGluZSc/JzxzcGFuIGNsYXNzPSJiYWRnZSByZWQiPk9mZmxpbmU8L3NwYW4+JzonPHNwYW4gY2xhc3M9ImJhZGdlIGdyZWVuIj4nK2Qub2xsYW1hKyc8L3NwYW4+J30sCiAgICAgIHtsOidIb3N0bmFtZScsdjpkLmhvc3RuYW1lfSx7bDonVXB0aW1lJyx2OmQudXB0aW1lfSx7bDonTWVtb3J5Jyx2OmQubWVtfSx7bDonRGlzaycsdjpkLmRpc2t9LHtsOidDUFUgLyBMb2FkJyx2OmQuY3B1KycgLyAnK2QubG9hZH0KICAgIF0ubWFwKGM9Pic8ZGl2IGNsYXNzPSJjYXJkIj48ZGl2IGNsYXNzPSJsYWJlbCI+JytjLmwrJzwvZGl2PjxkaXYgY2xhc3M9InZhbHVlIiBzdHlsZT0iZm9udC1zaXplOjE2cHgiPicrYy52Kyc8L2Rpdj48L2Rpdj4nKS5qb2luKCcnKTsKICB9Y2F0Y2goZSl7dG9hc3QoJ0ZhaWxlZCB0byBsb2FkIHN0YXR1cycsJ2Vycm9yJyk7fQp9CgovLyBPbGxhbWEKYXN5bmMgZnVuY3Rpb24gbG9hZE9sbGFtYSgpewogIHRyeXsKICAgIGNvbnN0W21vZGVscyxydW5uaW5nXT1hd2FpdCBQcm9taXNlLmFsbChbZmV0Y2goQVBJKycvYXBpL29sbGFtYS9tb2RlbHMnKS50aGVuKHI9PnIuanNvbigpKSxmZXRjaChBUEkrJy9hcGkvb2xsYW1hL3J1bm5pbmcnKS50aGVuKHI9PnIuanNvbigpKV0pOwogICAgY29uc3QgbWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29sbGFtYS1tb2RlbHMtbGlzdCcpOwogICAgaWYobW9kZWxzLm1vZGVscyYmbW9kZWxzLm1vZGVscy5sZW5ndGgpewogICAgICBtbC5pbm5lckhUTUw9bW9kZWxzLm1vZGVscy5tYXAobT0+Jzx0cj48dGQ+PHN0cm9uZz4nK20ubmFtZSsnPC9zdHJvbmc+PC90ZD48dGQ+JysobS5zaXplPyhtLnNpemUvMWU5KS50b0ZpeGVkKDEpKydHQic6Jz8nKSsnPC90ZD48dGQ+JysobS5tb2RpZmllZF9hdHx8JycpLnNsaWNlKDAsMTApKyc8L3RkPjx0ZD48YnV0dG9uIGNsYXNzPSJkYW5nZXIiIG9uY2xpY2s9ImRlbGV0ZU1vZGVsKFxcJycrbS5uYW1lKydcXCcpIj5EZWw8L2J1dHRvbj48L3RkPjwvdHI+Jykuam9pbignJyk7CiAgICB9ZWxzZSBtbC5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNCI+Tm8gbW9kZWxzIGZvdW5kPC90ZD48L3RyPic7CiAgICBjb25zdCBybD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb2xsYW1hLXJ1bm5pbmctbGlzdCcpOwogICAgaWYocnVubmluZy5tb2RlbHMmJnJ1bm5pbmcubW9kZWxzLmxlbmd0aCl7CiAgICAgIHJsLmlubmVySFRNTD1ydW5uaW5nLm1vZGVscy5tYXAobT0+Jzx0cj48dGQ+JyttLm5hbWUrJzwvdGQ+PHRkPicrKG0uc2l6ZT8obS5zaXplLzFlOSkudG9GaXhlZCgxKSsnR0InOic/JykrJzwvdGQ+PHRkPicrKG0uc2l6ZV92cmFtPydHUFUnOidDUFUnKSsnPC90ZD48dGQ+JysobS5leHBpcmVzX2F0fHwnJykrJzwvdGQ+PC90cj4nKS5qb2luKCcnKTsKICAgIH1lbHNlIHJsLmlubmVySFRNTD0nPHRyPjx0ZCBjb2xzcGFuPSI0Ij5ObyBydW5uaW5nIG1vZGVsczwvdGQ+PC90cj4nOwogIH1jYXRjaChlKXt0b2FzdCgnRmFpbGVkIHRvIGxvYWQgT2xsYW1hJywnZXJyb3InKTt9Cn0KYXN5bmMgZnVuY3Rpb24gZGVsZXRlTW9kZWwobil7CiAgaWYoIWNvbmZpcm0oJ0RlbGV0ZSAnK24rJz8nKSlyZXR1cm47CiAgYXdhaXQgZmV0Y2goQVBJKycvYXBpL29sbGFtYS9kZWxldGUnLHttZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sYm9keTpKU09OLnN0cmluZ2lmeSh7bW9kZWw6bn0pfSk7CiAgdG9hc3QoJ0RlbGV0ZWQnKTtsb2FkT2xsYW1hKCk7Cn0KZnVuY3Rpb24gcHVsbE1vZGVsKCl7CiAgY29uc3Qgbj1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb2xsYW1hLXB1bGwtbmFtZScpLnZhbHVlLnRyaW0oKTtpZighbilyZXR1cm47CiAgY29uc3QgcHJvZz1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHVsbC1wcm9ncmVzcycpOwogIHByb2cuaW5uZXJIVE1MPSc8ZGl2PlB1bGxpbmcgJytuKycuLi48L2Rpdj48ZGl2IGNsYXNzPSJwcm9ncmVzcy1iYXIiPjxkaXYgY2xhc3M9ImZpbGwiIGlkPSJwdWxsLWZpbGwiIHN0eWxlPSJ3aWR0aDowJSI+PC9kaXY+PC9kaXY+PGRpdiBpZD0icHVsbC1zdGF0dXMiIHN0eWxlPSJtYXJnaW4tdG9wOjhweDtmb250LXNpemU6MTNweDtjb2xvcjp2YXIoLS10ZXh0MikiPjwvZGl2Pic7CiAgZmV0Y2goQVBJKycvYXBpL29sbGFtYS9wdWxsJyx7bWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LGJvZHk6SlNPTi5zdHJpbmdpZnkoe21vZGVsOm59KX0pLnRoZW4oYXN5bmMgcmVzPT57CiAgICBjb25zdCByZWFkZXI9cmVzLmJvZHkuZ2V0UmVhZGVyKCk7Y29uc3QgZGVjPW5ldyBUZXh0RGVjb2RlcigpOwogICAgd2hpbGUodHJ1ZSl7CiAgICAgIGNvbnN0e2RvbmUsdmFsdWV9PWF3YWl0IHJlYWRlci5yZWFkKCk7aWYoZG9uZSlicmVhazsKICAgICAgZGVjLmRlY29kZSh2YWx1ZSkuc3BsaXQoJ1xcbicpLmZpbHRlcihsPT5sLnN0YXJ0c1dpdGgoJ2RhdGE6ICcpKS5mb3JFYWNoKGw9PnsKICAgICAgICB0cnl7CiAgICAgICAgICBjb25zdCBkPUpTT04ucGFyc2UobC5zbGljZSg2KSk7CiAgICAgICAgICBpZihkLmRvbmUpe3Byb2cuaW5uZXJIVE1MPSc8c3BhbiBjbGFzcz0iYmFkZ2UgZ3JlZW4iPkRvbmUhPC9zcGFuPic7bG9hZE9sbGFtYSgpO3JldHVybjt9CiAgICAgICAgICBpZihkLmVycm9yKXtwcm9nLmlubmVySFRNTD0nPHNwYW4gY2xhc3M9ImJhZGdlIHJlZCI+JytkLmVycm9yKyc8L3NwYW4+JztyZXR1cm47fQogICAgICAgICAgY29uc3QgcGN0PWQudG90YWw/TWF0aC5yb3VuZCgoZC5jb21wbGV0ZWR8fDApL2QudG90YWwqMTAwKTowOwogICAgICAgICAgY29uc3QgZj1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHVsbC1maWxsJyk7aWYoZilmLnN0eWxlLndpZHRoPXBjdCsnJSc7CiAgICAgICAgICBjb25zdCBzPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwdWxsLXN0YXR1cycpO2lmKHMpcy50ZXh0Q29udGVudD0oZC5zdGF0dXN8fCcnKSsnICcrcGN0KyclJzsKICAgICAgICB9Y2F0Y2h7fQogICAgICB9KTsKICAgIH0KICB9KS5jYXRjaChlPT57cHJvZy5pbm5lckhUTUw9JzxzcGFuIGNsYXNzPSJiYWRnZSByZWQiPicrZS5tZXNzYWdlKyc8L3NwYW4+Jzt9KTsKfQphc3luYyBmdW5jdGlvbiByZWZyZXNoT2xsYW1hTW9kZWxzKCl7CiAgY29uc3Qgcj1hd2FpdCBmZXRjaChBUEkrJy9hcGkvb2xsYW1hL21vZGVscycpO2NvbnN0IGQ9YXdhaXQgci5qc29uKCk7CiAgY29uc3Qgc2VsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwLW9sbGFtYS1tb2RlbCcpOwogIHNlbC5pbm5lckhUTUw9KGQubW9kZWxzfHxbXSkubWFwKG09Pic8b3B0aW9uPicrbS5uYW1lKyc8L29wdGlvbj4nKS5qb2luKCcnKXx8JzxvcHRpb24+Tm8gbW9kZWxzPC9vcHRpb24+JzsKfQoKLy8gQ29uZmlnCmFzeW5jIGZ1bmN0aW9uIGxvYWRDb25maWcoKXsKICBjb25zdCByPWF3YWl0IGZldGNoKEFQSSsnL2FwaS9jb25maWcnKTtjdXJyZW50Q29uZmlnPWF3YWl0IHIuanNvbigpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctcG9ydCcpLnZhbHVlPWRpZyhjdXJyZW50Q29uZmlnLCdnYXRld2F5LnBvcnQnLCcnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2ZnLWJpbmQnKS52YWx1ZT1kaWcoY3VycmVudENvbmZpZywnZ2F0ZXdheS5iaW5kJywnJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1tb2RlbCcpLnZhbHVlPWRpZyhjdXJyZW50Q29uZmlnLCdhZ2VudHMuZGVmYXVsdHMubW9kZWwucHJpbWFyeScsJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctdG9rZW4nKS52YWx1ZT1kaWcoY3VycmVudENvbmZpZywnYXV0aC50b2tlbicsJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctcmF3JykudmFsdWU9SlNPTi5zdHJpbmdpZnkoY3VycmVudENvbmZpZyxudWxsLDIpOwp9CmFzeW5jIGZ1bmN0aW9uIHNhdmVDb25maWcoKXsKICBjb25zdCBqc29uVGFiPWRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJyNjb25maWctdGFicyBidXR0b25bZGF0YS10YWI9Impzb24iXScpLmNsYXNzTGlzdC5jb250YWlucygnYWN0aXZlJyk7CiAgbGV0IGRhdGE7CiAgaWYoanNvblRhYil7CiAgICB0cnl7ZGF0YT1KU09OLnBhcnNlKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctcmF3JykudmFsdWUpO31jYXRjaHtyZXR1cm4gdG9hc3QoJ0ludmFsaWQgSlNPTicsJ2Vycm9yJyk7fQogIH1lbHNlewogICAgZGF0YT1KU09OLnBhcnNlKEpTT04uc3RyaW5naWZ5KGN1cnJlbnRDb25maWcpKTsKICAgIGNvbnN0IHBvcnQ9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1wb3J0JykudmFsdWU7CiAgICBjb25zdCBiaW5kPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjZmctYmluZCcpLnZhbHVlOwogICAgY29uc3QgbW9kZWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy1tb2RlbCcpLnZhbHVlOwogICAgY29uc3QgdG9rZW49ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NmZy10b2tlbicpLnZhbHVlOwogICAgaWYoIWRhdGEuZ2F0ZXdheSlkYXRhLmdhdGV3YXk9e307CiAgICBpZihwb3J0KWRhdGEuZ2F0ZXdheS5wb3J0PXBhcnNlSW50KHBvcnQpOwogICAgaWYoYmluZClkYXRhLmdhdGV3YXkuYmluZD1iaW5kOwogICAgaWYobW9kZWwpe2lmKCFkYXRhLmFnZW50cylkYXRhLmFnZW50cz17fTtpZighZGF0YS5hZ2VudHMuZGVmYXVsdHMpZGF0YS5hZ2VudHMuZGVmYXVsdHM9e307aWYoIWRhdGEuYWdlbnRzLmRlZmF1bHRzLm1vZGVsKWRhdGEuYWdlbnRzLmRlZmF1bHRzLm1vZGVsPXt9O2RhdGEuYWdlbnRzLmRlZmF1bHRzLm1vZGVsLnByaW1hcnk9bW9kZWw7fQogICAgaWYodG9rZW4pe2lmKCFkYXRhLmF1dGgpZGF0YS5hdXRoPXt9O2RhdGEuYXV0aC50b2tlbj10b2tlbjt9CiAgfQogIGF3YWl0IGZldGNoKEFQSSsnL2FwaS9jb25maWcnLHttZXRob2Q6J1BVVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSxib2R5OkpTT04uc3RyaW5naWZ5KGRhdGEpfSk7CiAgdG9hc3QoJ0NvbmZpZyBzYXZlZCEnKTtjdXJyZW50Q29uZmlnPWRhdGE7Cn0KCi8vIFByb3ZpZGVycwphc3luYyBmdW5jdGlvbiBsb2FkUHJvdmlkZXJzKCl7CiAgYXdhaXQgbG9hZENvbmZpZygpOwogIGNvbnN0IGM9Y3VycmVudENvbmZpZzsKICAvLyBEZXRlY3QgY3VycmVudCBwcm92aWRlciBmcm9tIGNvbmZpZwogIGNvbnN0IHByaW1hcnk9ZGlnKGMsJ2FnZW50cy5kZWZhdWx0cy5tb2RlbC5wcmltYXJ5JywnJyk7CiAgY29uc3Qgb2xsYW1hQmFzZVVybD1kaWcoYywnbW9kZWxzLnByb3ZpZGVycy5vbGxhbWEuYmFzZVVybCcsJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwLW9sbGFtYS11cmwnKS52YWx1ZT1vbGxhbWFCYXNlVXJsP29sbGFtYUJhc2VVcmwucmVwbGFjZSgvXFwvdjFcXC8/JC8sJycpOidodHRwOi8vbG9jYWxob3N0OjExNDM0JzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncC1hbnRocm9waWMta2V5JykudmFsdWU9ZGlnKGMsJ2Vudi5BTlRIUk9QSUNfQVBJX0tFWScsJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwLW9wZW5haS1rZXknKS52YWx1ZT1kaWcoYywnZW52Lk9QRU5BSV9BUElfS0VZJywnJyk7CiAgLy8gU2VsZWN0IGNvcnJlY3QgbW9kZWwgaW4gZHJvcGRvd25zCiAgaWYocHJpbWFyeS5zdGFydHNXaXRoKCdhbnRocm9waWMvJykpewogICAgY29uc3QgbT1wcmltYXJ5LnJlcGxhY2UoJ2FudGhyb3BpYy8nLCcnKTsKICAgIGNvbnN0IHNlbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncC1hbnRocm9waWMtbW9kZWwnKTsKICAgIGZvcihsZXQgbyBvZiBzZWwub3B0aW9ucylpZihvLnZhbHVlPT09bSlvLnNlbGVjdGVkPXRydWU7CiAgfQogIGlmKHByaW1hcnkuc3RhcnRzV2l0aCgnb3BlbmFpLycpKXsKICAgIGNvbnN0IG09cHJpbWFyeS5yZXBsYWNlKCdvcGVuYWkvJywnJyk7CiAgICBjb25zdCBzZWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Atb3BlbmFpLW1vZGVsJyk7CiAgICBmb3IobGV0IG8gb2Ygc2VsLm9wdGlvbnMpaWYoby52YWx1ZT09PW0pby5zZWxlY3RlZD10cnVlOwogIH0KICByZWZyZXNoT2xsYW1hTW9kZWxzKCkudGhlbigoKT0+ewogICAgaWYocHJpbWFyeS5zdGFydHNXaXRoKCdvbGxhbWEvJykpewogICAgICBjb25zdCBtPXByaW1hcnkucmVwbGFjZSgnb2xsYW1hLycsJycpOwogICAgICBjb25zdCBzZWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Atb2xsYW1hLW1vZGVsJyk7CiAgICAgIGZvcihsZXQgbyBvZiBzZWwub3B0aW9ucylpZihvLnZhbHVlPT09bSlvLnNlbGVjdGVkPXRydWU7CiAgICB9CiAgfSk7Cn0KYXN5bmMgZnVuY3Rpb24gc2F2ZVByb3ZpZGVyKCl7CiAgY29uc3QgYWN0aXZlPWRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJyNwcm92aWRlci10YWJzIGJ1dHRvbi5hY3RpdmUnKS5kYXRhc2V0LnByb3ZpZGVyOwogIGNvbnN0IGJvZHk9e3Byb3ZpZGVyOmFjdGl2ZX07CiAgaWYoYWN0aXZlPT09J29sbGFtYScpe2JvZHkub2xsYW1hVXJsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwLW9sbGFtYS11cmwnKS52YWx1ZTtib2R5Lm9sbGFtYU1vZGVsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwLW9sbGFtYS1tb2RlbCcpLnZhbHVlO30KICBpZihhY3RpdmU9PT0nYW50aHJvcGljJyl7Ym9keS5hbnRocm9waWNLZXk9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3AtYW50aHJvcGljLWtleScpLnZhbHVlO2JvZHkuYW50aHJvcGljTW9kZWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3AtYW50aHJvcGljLW1vZGVsJykudmFsdWU7fQogIGlmKGFjdGl2ZT09PSdvcGVuYWknKXtib2R5Lm9wZW5haUtleT1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncC1vcGVuYWkta2V5JykudmFsdWU7Ym9keS5vcGVuYWlNb2RlbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncC1vcGVuYWktbW9kZWwnKS52YWx1ZTt9CiAgaWYoYWN0aXZlPT09J2N1c3RvbScpe2JvZHkuY3VzdG9tVXJsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwLWN1c3RvbS11cmwnKS52YWx1ZTtib2R5LmN1c3RvbUtleT1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncC1jdXN0b20ta2V5JykudmFsdWU7Ym9keS5jdXN0b21Nb2RlbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncC1jdXN0b20tbW9kZWwnKS52YWx1ZTt9CiAgY29uc3Qgcj1hd2FpdCBmZXRjaChBUEkrJy9hcGkvcHJvdmlkZXInLHttZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sYm9keTpKU09OLnN0cmluZ2lmeShib2R5KX0pOwogIGNvbnN0IGQ9YXdhaXQgci5qc29uKCk7CiAgaWYoZC5vayl7dG9hc3QoJ1Byb3ZpZGVyIHNhdmVkICYgc2VydmljZSByZXN0YXJ0ZWQhJyk7aWYoZC5jb25maWcpY3VycmVudENvbmZpZz1kLmNvbmZpZzt9CiAgZWxzZSB0b2FzdChkLmVycm9yfHwnRmFpbGVkJywnZXJyb3InKTsKfQoKLy8gU2VydmljZXMKYXN5bmMgZnVuY3Rpb24gc3ZjQWN0aW9uKGFjdGlvbil7CiAgY29uc3Qgcj1hd2FpdCBmZXRjaChBUEkrJy9hcGkvc2VydmljZScse21ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSxib2R5OkpTT04uc3RyaW5naWZ5KHthY3Rpb259KX0pOwogIGNvbnN0IGQ9YXdhaXQgci5qc29uKCk7CiAgaWYoYWN0aW9uPT09J3N0YXR1cycpewogICAgY29uc3QgZWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N2Yy1zdGF0dXMnKTsKICAgIGNvbnN0IGE9ZC5yZXN1bHQmJihkLnJlc3VsdC5pbmNsdWRlcygnYWN0aXZlJyl8fGQucmVzdWx0LmluY2x1ZGVzKCdydW5uaW5nJykpOwogICAgZWwuaW5uZXJIVE1MPWE/JzxzcGFuIGNsYXNzPSJiYWRnZSBncmVlbiI+UnVubmluZzwvc3Bhbj4nOic8c3BhbiBjbGFzcz0iYmFkZ2UgcmVkIj5TdG9wcGVkPC9zcGFuPic7CiAgfWVsc2UgdG9hc3QoYWN0aW9uKyc6ICcrKChkLnJlc3VsdHx8JycpLnNsaWNlKDAsMTAwKXx8J09LJykpOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRMb2dzKCl7CiAgY29uc3QgbGluZXM9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvZy1saW5lcycpLnZhbHVlOwogIGNvbnN0IHI9YXdhaXQgZmV0Y2goQVBJKycvYXBpL2xvZ3M/bGluZXM9JytsaW5lcyk7Y29uc3QgZD1hd2FpdCByLmpzb24oKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9nLW91dHB1dCcpLnRleHRDb250ZW50PWQubG9nc3x8J05vIGxvZ3MnOwp9CgovLyBDaGFubmVscwphc3luYyBmdW5jdGlvbiBsb2FkQ2hhbm5lbHMoKXsKICBhd2FpdCBsb2FkQ29uZmlnKCk7CiAgY29uc3QgYz1jdXJyZW50Q29uZmlnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaC10Zy10b2tlbicpLnZhbHVlPWRpZyhjLCdjaGFubmVscy50ZWxlZ3JhbS5hY2NvdW50cy5kZWZhdWx0LmJvdFRva2VuJywnJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NoLXRnLWRtJykudmFsdWU9ZGlnKGMsJ2NoYW5uZWxzLnRlbGVncmFtLmRtUG9saWN5JywnYWxsb3cnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2gtdGctYWxsb3cnKS52YWx1ZT0oZGlnKGMsJ2NoYW5uZWxzLnRlbGVncmFtLmFsbG93RnJvbScsW10pfHxbXSkuam9pbignLCAnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2gtZGMtdG9rZW4nKS52YWx1ZT1kaWcoYywnY2hhbm5lbHMuZGlzY29yZC5hY2NvdW50cy5kZWZhdWx0LmJvdFRva2VuJywnJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NoLWRjLWd1aWxkJykudmFsdWU9ZGlnKGMsJ2NoYW5uZWxzLmRpc2NvcmQuZ3VpbGRJZCcsJycpOwp9CmFzeW5jIGZ1bmN0aW9uIHNhdmVDaGFubmVscygpewogIGNvbnN0IGJvZHk9e307CiAgY29uc3QgdGdUb2tlbj1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2gtdGctdG9rZW4nKS52YWx1ZTsKICBpZih0Z1Rva2VuKXsKICAgIGJvZHkudGVsZWdyYW09ewogICAgICBib3RUb2tlbjp0Z1Rva2VuLAogICAgICBkbVBvbGljeTpkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2gtdGctZG0nKS52YWx1ZSwKICAgICAgYWxsb3dGcm9tOmRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaC10Zy1hbGxvdycpLnZhbHVlLnNwbGl0KCcsJykubWFwKHM9PnMudHJpbSgpKS5maWx0ZXIoQm9vbGVhbikKICAgIH07CiAgfQogIGNvbnN0IGRjVG9rZW49ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NoLWRjLXRva2VuJykudmFsdWU7CiAgaWYoZGNUb2tlbil7CiAgICBib2R5LmRpc2NvcmQ9e2JvdFRva2VuOmRjVG9rZW4sZ3VpbGRJZDpkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2gtZGMtZ3VpbGQnKS52YWx1ZX07CiAgfQogIGNvbnN0IHI9YXdhaXQgZmV0Y2goQVBJKycvYXBpL2NoYW5uZWxzJyx7bWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LGJvZHk6SlNPTi5zdHJpbmdpZnkoYm9keSl9KTsKICBjb25zdCBkPWF3YWl0IHIuanNvbigpOwogIGlmKGQub2spdG9hc3QoJ0NoYW5uZWxzIHNhdmVkICYgc2VydmljZSByZXN0YXJ0ZWQhJyk7CiAgZWxzZSB0b2FzdChkLmVycm9yfHwnRmFpbGVkJywnZXJyb3InKTsKfQoKYXN5bmMgZnVuY3Rpb24gaW5pdCgpe2xvYWREYXNoYm9hcmQoKTt9CmZldGNoKEFQSSsnL2FwaS9zdGF0dXMnKS50aGVuKHI9PntpZihyLm9rKXtkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9naW4tcGFnZScpLnN0eWxlLmRpc3BsYXk9J25vbmUnO2RvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAnKS5zdHlsZS5kaXNwbGF5PSdmbGV4Jztpbml0KCk7fX0pOwo8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+YDsKfQoKLy8g4pSA4pSA4pSAIFNlcnZlciDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKY29uc3Qgc2VydmVyID0gaHR0cC5jcmVhdGVTZXJ2ZXIoYXN5bmMgKHJlcSwgcmVzKSA9PiB7CiAgY29uc3QgdXJsID0gbmV3IFVSTChyZXEudXJsLCBgaHR0cDovLyR7cmVxLmhlYWRlcnMuaG9zdH1gKTsKICBjb25zdCBwYXRobmFtZSA9IHVybC5wYXRobmFtZTsKICByZXMuc2V0SGVhZGVyKCdYLUNvbnRlbnQtVHlwZS1PcHRpb25zJywgJ25vc25pZmYnKTsKICBpZiAocGF0aG5hbWUuc3RhcnRzV2l0aCgnL2FwaS8nKSkgcmV0dXJuIGhhbmRsZUFQSShyZXEsIHJlcywgcGF0aG5hbWUpOwogIHJlcy53cml0ZUhlYWQoMjAwLCB7ICdDb250ZW50LVR5cGUnOiAndGV4dC9odG1sOyBjaGFyc2V0PXV0Zi04JyB9KTsKICByZXMuZW5kKGdldEhUTUwoKSk7Cn0pOwoKc2VydmVyLmxpc3RlbihQT1JULCAnMC4wLjAuMCcsICgpID0+IHsKICBjb25zb2xlLmxvZyhgXG4gIPCfkL4gT3BlbkNsYXcgV2ViVUkgcnVubmluZyBhdCBodHRwOi8vMC4wLjAuMDoke1BPUlR9YCk7CiAgY29uc29sZS5sb2coYCAgUGFzc3dvcmQ6ICR7UEFTU1dPUkQgPT09ICdvcGVuY2xhdycgPyAnb3BlbmNsYXcgKGRlZmF1bHQpJyA6ICcoY29uZmlndXJlZCknfVxuYCk7Cn0pOwo=' | pct exec "\$CT_ID" -- bash -c "base64 -d > /opt/openclaw-webui/server.js"
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

    local sandbox_cfg=""
    [[ "$var_docker" == "yes" ]] && sandbox_cfg=', "sandbox": {"mode": "all"}'

    local controlui_cfg=""
    [[ "$var_webui" == "yes" ]] && controlui_cfg=', "controlUi": {"enabled": true, "allowedOrigins": ["*"]}'

    if [[ "$var_ollama" == "yes" || -n "${var_ollama_url:-}" ]]; then
        # Ollama config with proper models.providers.ollama format
        local ollama_url="${var_ollama_url}"
        local model_name="llama3:latest"

        # Try to discover models from Ollama
        local models_json=""
        local available
        available=$(pct exec "$CT_ID" -- curl -sf "${ollama_url}/api/tags" 2>/dev/null || curl -sf "${ollama_url}/api/tags" 2>/dev/null || true)
        if [[ -n "$available" ]]; then
            model_name=$(echo "$available" | python3 -c "import sys,json; d=json.load(sys.stdin); ms=d.get('models',[]); print(ms[0]['name'] if ms else 'llama3:latest')" 2>/dev/null || echo "llama3:latest")
            models_json=$(echo "$available" | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = []
for m in data.get('models', []):
    models.append({'id': m['name'], 'name': m['name'], 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 32768, 'maxTokens': 8192})
if not models:
    models.append({'id': 'llama3:latest', 'name': 'llama3:latest', 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 32768, 'maxTokens': 8192})
print(json.dumps(models))
" 2>/dev/null || true)
        fi

        if [[ -z "$models_json" ]]; then
            models_json='[{"id": "llama3:latest", "name": "llama3:latest", "reasoning": false, "input": ["text"], "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}, "contextWindow": 32768, "maxTokens": 8192}]'
        fi

        # Write config with heredoc, injecting variables
        pct exec "$CT_ID" -- bash -c "cat > /home/openclaw/.openclaw/openclaw.json << CFGEOF
{
  \"gateway\": {
    \"port\": 18789,
    \"mode\": \"local\",
    \"bind\": \"loopback\"${controlui_cfg}
  },
  \"env\": {
    \"OLLAMA_API_KEY\": \"ollama-local\"
  },
  \"agents\": {
    \"defaults\": {
      \"model\": {
        \"primary\": \"ollama/${model_name}\"
      }${sandbox_cfg}
    }
  },
  \"models\": {
    \"providers\": {
      \"ollama\": {
        \"baseUrl\": \"${ollama_url}/v1\",
        \"apiKey\": \"ollama-local\",
        \"api\": \"openai-completions\",
        \"models\": ${models_json}
      }
    }
  }
}
CFGEOF
chown openclaw:openclaw /home/openclaw/.openclaw/openclaw.json"
    else
        # Anthropic/default config
        pct exec "$CT_ID" -- bash -c "cat > /home/openclaw/.openclaw/openclaw.json << CFGEOF
{
  \"gateway\": {
    \"port\": 18789,
    \"mode\": \"local\",
    \"bind\": \"loopback\"${controlui_cfg}
  },
  \"env\": {
    \"ANTHROPIC_API_KEY\": \"CHANGE_ME\"
  },
  \"agents\": {
    \"defaults\": {
      \"model\": {
        \"primary\": \"anthropic/claude-sonnet-4-20250514\"
      }${sandbox_cfg}
    }
  }
}
CFGEOF
chown openclaw:openclaw /home/openclaw/.openclaw/openclaw.json"
    fi
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
ExecStart=/usr/bin/openclaw gateway --port 18789
Restart=on-failure
RestartSec=10
Environment=NODE_ENV=production
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/dev/null
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
