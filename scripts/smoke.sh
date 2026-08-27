#!/usr/bin/env bash
# Verify the server: health, models, chat, tool calling, streaming.
# Tool calling is the check that matters for agent harnesses like pi, and the
# one a wrong --tool-call-parser breaks silently.
set -uo pipefail
B=${1:-http://127.0.0.1:8000}
MODEL=${MODEL:-muse-glimmer-30b}
KEY=$( [ -r /etc/vllm/api-key ] && cat /etc/vllm/api-key || echo "" )
AUTH=(); [ -n "$KEY" ] && AUTH=(-H "Authorization: Bearer $KEY")
rc=0

echo "== health =="
code=$(curl -sS "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$B/health"); echo "  $code"
[ "$code" = 200 ] || rc=1

echo "== models =="
curl -sS "${AUTH[@]}" "$B/v1/models" | python3 -c "
import json,sys
for m in json.load(sys.stdin)['data']: print('  ', m['id'], '| max_model_len', m.get('max_model_len'))
" || rc=1

echo "== chat =="
# Use a generous max_tokens: the model emits a reasoning channel first, and a
# small budget gets consumed by it, returning empty content.
curl -sS "${AUTH[@]}" "$B/v1/chat/completions" -H 'Content-Type: application/json' -d "{
  \"model\":\"$MODEL\",
  \"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],
  \"max_tokens\":512,\"temperature\":0}" | python3 -c "
import json,sys
d=json.load(sys.stdin); m=d['choices'][0]['message']
c=(m.get('content') or '').strip()
print('   content:', repr(c)); print('   usage  :', d.get('usage'))
sys.exit(0 if 'OK' in c else 1)" || rc=1

echo "== tool call =="
curl -sS "${AUTH[@]}" "$B/v1/chat/completions" -H 'Content-Type: application/json' -d "{
  \"model\":\"$MODEL\",
  \"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Paris? Use the tool.\"}],
  \"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",
    \"description\":\"Get weather for a city\",
    \"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}}],
  \"tool_choice\":\"auto\",\"max_tokens\":512,\"temperature\":0}" | python3 -c "
import json,sys
d=json.load(sys.stdin); ch=d['choices'][0]; tc=ch['message'].get('tool_calls')
if not tc:
    print('   NO tool_calls. Check --tool-call-parser is muse_glimmer.'); sys.exit(1)
print('   ', tc[0]['function']['name'], tc[0]['function']['arguments'])
print('    finish_reason:', ch.get('finish_reason'))" || rc=1

echo "== streaming =="
curl -sSN "${AUTH[@]}" "$B/v1/chat/completions" -H 'Content-Type: application/json' -d "{
  \"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Count 1 to 8\"}],
  \"max_tokens\":256,\"stream\":true,\"temperature\":0}" | python3 -c "
import sys,time
t0=time.time(); first=None; n=0
for line in sys.stdin:
    if line.startswith('data: ') and 'DONE' not in line:
        n+=1
        if first is None: first=time.time()-t0
print(f'   chunks {n} | first {first:.3f}s' if n else '   NO CHUNKS')
sys.exit(0 if n>5 else 1)" || rc=1

echo
[ $rc = 0 ] && echo "SMOKE PASS" || echo "SMOKE FAIL"
exit $rc
