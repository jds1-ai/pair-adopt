#!/usr/bin/env bash
# sweep: one small completion for EVERY model id PAIR advertises on this node's :1234.
# "Advertised" and "will serve" are different claims; this prints which is which.
# 400 "model is not loaded" = an engine listing an unloaded model (by design on autoload-off nodes);
# 502 "no available node" = a stale cluster entry; 000 = your own timeout, not the server's answer.
set -euo pipefail
curl -s -m 15 127.0.0.1:1234/v1/models | python3 -c '
import sys, json, subprocess, time
ms = json.load(sys.stdin)["data"]
print("advertised:", len(ms))
for m in ms:
    mid = m["id"]
    body = json.dumps({"model": mid, "messages": [{"role": "user", "content": "Say the single word: ok"}], "max_tokens": 48})
    t = time.time()
    p = subprocess.run(["curl", "-s", "-m", "150", "-w", "\n%{http_code}", "127.0.0.1:1234/v1/chat/completions",
                        "-H", "content-type: application/json", "-d", body], capture_output=True, text=True)
    dt = time.time() - t
    out, _, code = p.stdout.rpartition("\n")
    try:
        d = json.loads(out)
        if "choices" in d:
            c = d["choices"][0]
            res = "OK  " + repr(c["message"].get("content", ""))[:24] + " fin=" + str(c.get("finish_reason")) + " tok=" + str(d.get("usage", {}).get("completion_tokens"))
        else:
            res = "ERR " + str(d.get("error", d))[:90]
    except Exception:
        res = "ERR(non-json) " + out[:80]
    print(f"{code:>4} {dt:6.1f}s  {mid:45s} {m.get('owned_by', '?'):9s} {res}")
'
