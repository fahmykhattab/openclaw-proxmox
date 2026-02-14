#!/usr/bin/env bash
# OpenClaw Post-Install - Kimi K2.5 Cloud Configuration

set -e

TELEGRAM_BOT_TOKEN="8590194099:AAH8vsXbY95vWABADRr1oHaTB9jE7UyL6rw"
TELEGRAM_USER_ID="5156466155"
OLLAMA_URL="http://192.168.178.38:11434"
DEFAULT_MODEL="kimi-k2.5:cloud"

echo "🦞 OpenClaw Post-Install Setup (Kimi K2.5)"
echo "=========================================="
echo ""

# Fix config structure
echo "→ Creating proper config..."
cat > /home/openclaw/.openclaw/openclaw.json << 'CFGEOF'
{
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "loopback",
    "controlUi": {
      "enabled": true,
      "allowedOrigins": ["*"]
    }
  },
  "env": {
    "OLLAMA_API_KEY": "ollama-local"
  },
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://192.168.178.38:11434/v1",
        "apiKey": "ollama-local",
        "api": "openai-completions",
        "models": [
          {
            "id": "kimi-k2.5:cloud",
            "name": "kimi-k2.5:cloud",
            "reasoning": false,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 32768,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "ollama/kimi-k2.5:cloud"
      },
      "workspace": "/home/openclaw/.openclaw/workspace",
      "sandbox": {
        "mode": "all"
      }
    }
  },
  "channels": {
    "telegram": {
      "accounts": {
        "default": {
          "botToken": "8590194099:AAH8vsXbY95vWABADRr1oHaTB9jE7UyL6rw"
        }
      },
      "allowFrom": [5156466155]
    }
  }
}
CFGEOF

# Create required directories
mkdir -p ~/.openclaw/agents/main/sessions ~/.openclaw/credentials
chmod 700 ~/.openclaw

echo "→ Restarting OpenClaw gateway..."
sudo systemctl restart openclaw

sleep 3
sudo systemctl status openclaw --no-pager

echo ""
echo "✅ Setup complete!"
echo ""
echo "Your bot: @Kemo88Bot"
echo "Model: ${DEFAULT_MODEL}"
echo "Ollama: ${OLLAMA_URL}"
echo ""
echo "Send a message to your Telegram bot to test!"
