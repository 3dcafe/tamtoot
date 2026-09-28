import json
import sys

for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request.get("method")
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {}}
    elif method == "tools/list":
        result = {"tools": [{
            "name": "echo",
            "description": "Echo arguments",
            "inputSchema": {"type": "object"},
        }]}
    elif method == "tools/call":
        text = json.dumps(request.get("params", {}).get("arguments", {}), separators=(",", ":"))
        result = {"content": [{"type": "text", "text": text}]}
    else:
        result = {}
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
