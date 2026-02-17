# Proxmox OpenClaw Helper Scripts

Automated deployment scripts for Proxmox VE homelab setups.

## 📄 Paperless AI Stack

**One-liner** to deploy a full AI-powered Document Management System:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fahmykhattab/openclaw-proxmox/master/paperless-ai-stack.sh)"
```

### What it deploys

| Service | Port | Description |
|---------|------|-------------|
| **Paperless-ngx** | 8000 | Document Management System with OCR |
| **Paperless-GPT** | 8081 | LLM-powered OCR enhancement & auto-tagging |
| **Paperless-AI** | 3000 | Auto classification & RAG chat |
| **PostgreSQL 16** | — | Database |
| **Redis 7** | — | Message broker |

### Features

- 🔧 **Interactive setup** — prompts for IP, admin creds, timezone, OCR languages
- 🤖 **Ollama auto-detection** — finds local Ollama and lists available models
- 🔑 **Auto API token** — generates and wires the Paperless API token automatically
- 📋 **Health checks** — verifies all services are running before finishing
- 🌍 **Multi-language OCR** — supports any Tesseract language pack
- 📁 **Drop folder** — place files in `consume/` for automatic ingestion

### Requirements

- Docker & Docker Compose v2+
- (Optional) [Ollama](https://ollama.ai) for local AI inference

### Post-Install

1. Open Paperless-ngx at `http://YOUR_IP:8000` and log in
2. Upload a document or drop it in the `consume/` folder
3. Tag documents with `paperless-gpt` to trigger AI OCR & tagging
4. Configure Paperless-AI at `http://YOUR_IP:3000` (first-run web setup)

### Configuration

All config is in `docker-compose.yaml` at the install directory (default `/opt/paperless/`).

Credentials are saved to `.credentials` in the install directory.

---

## 🖥️ OpenClaw LXC Installer

Automated OpenClaw deployment in a Proxmox LXC container:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fahmykhattab/openclaw-proxmox/master/install.sh)"
```

---

## License

MIT — see [LICENSE](LICENSE)
