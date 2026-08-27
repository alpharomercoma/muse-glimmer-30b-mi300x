#!/usr/bin/env bash
# Print everything needed to connect a client to this server.
set -uo pipefail
[ -r /etc/vllm/api-key ] || { echo "No API key. Run 06-endpoint-secure.sh first."; exit 1; }
KEY=$(cat /etc/vllm/api-key)
HOST=$(grep '^VLLM_DOMAIN=' /etc/caddy/vllm.env 2>/dev/null | cut -d= -f2)
[ -n "$HOST" ] || { echo "No domain configured. Run 06-endpoint-secure.sh first."; exit 1; }

cat <<TXT
======================================================================
 Endpoint : https://${HOST}/v1
 API key  : ${KEY}
 Model    : muse-glimmer-30b
======================================================================

1. Install pi (needs Node 20+):
     npm install -g --ignore-scripts @earendil-works/pi-coding-agent

2. ~/.pi/agent/models.json
{
  "providers": {
    "mi300x": {
      "baseUrl": "https://${HOST}/v1",
      "api": "openai-completions",
      "apiKey": "\$MI300X_API_KEY",
      "compat": { "supportsDeveloperRole": false, "supportsReasoningEffort": false },
      "models": [
        {
          "id": "muse-glimmer-30b",
          "name": "Muse Glimmer 30B (MI300X)",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 131072,
          "maxTokens": 16384,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}

3. ~/.pi/agent/settings.json
{ "defaultProvider": "mi300x", "defaultModel": "muse-glimmer-30b", "defaultThinkingLevel": "medium" }

4. Shell profile:
     export MI300X_API_KEY='${KEY}'

5. Verify, then run pi:
     curl https://${HOST}/v1/models -H "Authorization: Bearer \$MI300X_API_KEY"
     pi

Any OpenAI-compatible client works with the same two values:
     export OPENAI_BASE_URL=https://${HOST}/v1
     export OPENAI_API_KEY='${KEY}'
TXT
