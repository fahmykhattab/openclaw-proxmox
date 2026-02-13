<div align="center">

# 🐾 OpenClaw LXC for Proxmox VE

**One-line installer to deploy OpenClaw AI Gateway as a Proxmox LXC container**

Docker • Ollama • Web Dashboard • Reverse Proxy — all in one script.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Proxmox](https://img.shields.io/badge/Proxmox-VE%207.x%2F8.x-orange)](https://www.proxmox.com/)
[![OpenClaw](https://img.shields.io/badge/OpenClaw-Latest-green)](https://docs.openclaw.ai)

</div>

---

## ⚡ Quick Start

Run this on your **Proxmox host** as root:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/fahmykhattab/proxmox-openclaw/main/install.sh)"
```

Or with curl:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fahmykhattab/proxmox-openclaw/main/install.sh)"
```

---

## 📦 What Gets Installed

The interactive script creates a Debian 12 LXC container with:

| Component | Description | Default |
|-----------|-------------|---------|
| 🤖 **OpenClaw** | AI Gateway + systemd service | ✅ Always |
| 🐳 **Docker CE** | Container sandbox provider | ✅ Yes |
| 🦙 **Ollama** | Local AI model inference | Optional |
| 🌐 **Nginx/Caddy** | Reverse proxy for Control UI | ✅ Yes |
| 🖥️ **Dashboard** | Web management panel | ✅ Yes |
| 🔑 **SSH** | Remote shell access | Optional |

## 🖥️ Web Interfaces

After installation you get two web interfaces:

| Interface | URL | Purpose |
|-----------|-----|---------|
| **Control UI** | `http://<IP>:80` | Chat with AI, manage sessions |
| **Dashboard** | `http://<IP>:3333` | Switch providers, manage Ollama models, edit config, view logs |

### Dashboard Features

- 🔧 **Provider Switcher** — Ollama, Anthropic, OpenAI, or custom endpoints
- 🦙 **Ollama Manager** — Pull, delete, and switch models from the browser
- ⚙️ **Config Editor** — Form-based + raw JSON editor for `openclaw.json`
- 📊 **Service Controls** — Start/stop/restart OpenClaw, view live logs
- 📡 **Channel Setup** — Configure Telegram, Discord, and more

## 🛠️ Configuration

The script is fully interactive and asks you to configure:

```
Container ID, Hostname, CPU, RAM, Disk
Network (DHCP or static IP)
Docker (yes/no)
Ollama (install locally / external URL / none)
Reverse Proxy (nginx / caddy with auto-HTTPS)
Management Dashboard (yes/no)
SSH (yes/no)
```

### Smart Defaults

- 🧠 Auto-bumps RAM to **4 GB** and disk to **16 GB** when Ollama is selected
- 🐳 Switches to **privileged container** when Docker or Ollama is needed
- 🔧 Pre-configures OpenClaw for the selected provider
- 🔑 Auto-generates dashboard password
- ⚙️ Sets up all systemd dependencies correctly

## 📋 Requirements

- **Proxmox VE** 7.x or 8.x
- **Root access** on the Proxmox host
- **Internet connection** (to download packages)
- ~8 GB disk minimum (16 GB+ recommended with Ollama)

## 🚀 Post-Install

After the script completes:

```bash
# 1. Enter the container
pct enter <CT_ID>

# 2. Switch to openclaw user
su - openclaw

# 3. Run setup wizard
openclaw setup

# 4. Pull an Ollama model (if using Ollama)
ollama pull llama3

# 5. Connect a messaging channel
openclaw channels login

# 6. Start the gateway
sudo systemctl start openclaw
```

Or just open the **Dashboard** in your browser and do everything from there! 🌐

## 🔧 Useful Commands

```bash
# Inside the container
openclaw status              # Gateway status
sudo systemctl restart openclaw   # Restart gateway
sudo journalctl -u openclaw -f   # Live logs
docker ps                    # Running containers
ollama list                  # Installed models
```

## 🏗️ Architecture

```
┌─────────────────────────────────────────────┐
│              Proxmox VE Host                │
│                                             │
│  ┌────────────────────────────────────────┐ │
│  │         LXC Container (Debian 12)      │ │
│  │                                        │ │
│  │  ┌──────────┐  ┌──────────────────┐   │ │
│  │  │ Nginx/   │  │ OpenClaw Gateway │   │ │
│  │  │ Caddy    │──│ (port 18789)     │   │ │
│  │  │ (:80)    │  └──────────────────┘   │ │
│  │  └──────────┘           │              │ │
│  │                         ▼              │ │
│  │  ┌──────────┐  ┌──────────────────┐   │ │
│  │  │Dashboard │  │ Docker Sandbox   │   │ │
│  │  │ (:3333)  │  └──────────────────┘   │ │
│  │  └──────────┘                          │ │
│  │                ┌──────────────────┐    │ │
│  │                │ Ollama (:11434)  │    │ │
│  │                └──────────────────┘    │ │
│  └────────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
```

## 📄 License

MIT License — see [LICENSE](LICENSE)

## 🙏 Credits

- [OpenClaw](https://openclaw.ai) — AI Gateway
- [Ollama](https://ollama.com) — Local AI inference
- [Proxmox VE](https://www.proxmox.com/) — Virtualization platform
- Inspired by [tteck/Proxmox](https://github.com/tteck/Proxmox) helper scripts

---

<div align="center">

**⭐ Star this repo if it helped you!**

[Report Bug](https://github.com/fahmykhattab/proxmox-openclaw/issues) · [Request Feature](https://github.com/fahmykhattab/proxmox-openclaw/issues)

</div>
