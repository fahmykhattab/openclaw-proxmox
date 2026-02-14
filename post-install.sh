#!/usr/bin/env bash
# OpenClaw Post-Install Configuration Script
# Configures Telegram + External Ollama automatically

set -e

TELEGRAM_BOT_TOKEN="8590194099:AAH8vsXbY95vWABADRr1oHaTB9jE7UyL6rw"
TELEGRAM_USER_ID="5156466155"
OLLAMA_URL="http://192.168.178.38:11434"
DEFAULT_MODEL="qwen3:8b"

echo "🦞 OpenClaw Post-Install Setup"
echo "================================"
echo ""

# Fix any config issues
echo "→ Running config doctor..."
openclaw doctor --fix

# Configure external Ollama
echo "→ Configuring external Ollama at ${OLLAMA_URL}..."
openclaw config set models.providers.ollama.baseUrl "${OLLAMA_URL}/v1"
openclaw config set models.providers.ollama.apiKey "ollama-local"
openclaw config set models.providers.ollama.api "openai-completions"
openclaw config set env.OLLAMA_API_KEY "ollama-local"
openclaw config set agents.defaults.model.primary "ollama/${DEFAULT_MODEL}"

# Configure Telegram
echo "→ Configuring Telegram bot..."
openclaw config set channels.telegram.accounts.default.botToken "${TELEGRAM_BOT_TOKEN}"
openclaw config set channels.telegram.allowFrom "[${TELEGRAM_USER_ID}]"

# Restart gateway
echo "→ Restarting OpenClaw gateway..."
sudo systemctl restart openclaw

echo ""
echo "✅ Setup complete!"
echo ""
echo "Your bot: @Kemo88Bot"
echo "Model: ollama/${DEFAULT_MODEL}"
echo "Ollama: ${OLLAMA_URL}"
echo ""
echo "Send a message to your Telegram bot to test!"
