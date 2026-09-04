#!/usr/bin/env bash
# pair-adopt: put an already-running OpenAI-compatible server behind NVIDIA PAIR's LM Studio slot.
# Runs ON the node. See README.md for the three source-level gates this satisfies.
#   sudo ./adopt.sh install   --target ip:port --model id --detect /path/that/exists [--pair-unit nvpair] [--pair-user user]
#        ./adopt.sh verify    --target ip:port --model id [--pair-user user]
#   sudo ./adopt.sh uninstall [--pair-unit nvpair] [--pair-user user]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cmd="${1:-}"; shift || true
TARGET=""; MODEL=""; DETECT=""; PAIR_UNIT="nvpair"; PAIR_USER="${SUDO_USER:-$USER}"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --detect) DETECT="$2"; shift 2 ;;
    --pair-unit) PAIR_UNIT="$2"; shift 2 ;;
    --pair-user) PAIR_USER="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done
PAIR_HOME="$(getent passwd "$PAIR_USER" | cut -d: -f6)"; PAIR_GROUP="$(id -gn "$PAIR_USER")"
ENGINES="$PAIR_HOME/.config/Nvidia Corporation/Personal AI Router/engines"
OVERRIDE="$ENGINES/lmstudio.json"
PLATFORM="linux/$(case "$(uname -m)" in x86_64) echo amd64;; aarch64) echo arm64;; *) uname -m;; esac)"
SOCKET=pair-adopt-1235.socket; SERVICE=pair-adopt-1235.service; DROPIN="/etc/systemd/system/$PAIR_UNIT.service.d/10-pair-adopt.conf"

need_root() { [ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }; }
listening_1235() { ss -Hltn 'sport = :1235' | grep -q .; }
chat() {  # $1 = base url, $2 = max_tokens
  curl -s -m 180 "$1/v1/chat/completions" -H 'content-type: application/json' \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: routed\"}],\"max_tokens\":$2}" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); c=d["choices"][0]; print(repr(c["message"].get("content",""))[:60], "finish=", c.get("finish_reason"), "tokens=", d.get("usage",{}).get("completion_tokens"))'
}

do_verify() {
  [ -n "$TARGET" ] && [ -n "$MODEL" ] || { echo "verify needs --target and --model" >&2; exit 2; }
  echo "1. override is still ours (size):"
  [ -f "$OVERRIDE" ] || { echo "   FAIL: $OVERRIDE is gone — PAIR removed it (gate 2: port back at the bundled default)"; exit 1; }
  ls -la "$OVERRIDE"; sz=$(wc -c < "$OVERRIDE"); [ "$sz" -gt 500 ] || { echo "   FAIL: $sz bytes — PAIR rewrote it (gate 3). Was 1235 free when PAIR started?"; exit 1; }
  echo "2. forwarder:"; systemctl is-active "$SOCKET"; curl -s -m 10 127.0.0.1:1235/v1/models | head -c 200; echo
  echo "3. PAIR engine surface (up to 4 min):"
  for i in $(seq 1 16); do out="$(curl -s -m 5 127.0.0.1:14322/v1/models)"; echo "   t+$((i*15))s $out"; grep -q "$MODEL" <<<"$out" && break; sleep 15; done
  echo "4. routed via this node's :1234:"; chat http://127.0.0.1:1234 400
  echo "5. from any other PAIR node run:  curl 127.0.0.1:1234/v1/chat/completions -d '{\"model\":\"$MODEL\",...}'"
}

case "$cmd" in
  install)
    need_root
    [ -n "$TARGET" ] && [ -n "$MODEL" ] && [ -n "$DETECT" ] || { echo "install needs --target, --model, --detect" >&2; exit 2; }
    [ -e "$DETECT" ] || { echo "--detect path $DETECT does not exist; PAIR will never probe (gate 1)" >&2; exit 1; }
    curl -s -m 10 -o /dev/null -w '%{http_code}\n' "http://$TARGET/v1/models" | grep -q '^200$' || { echo "http://$TARGET/v1/models is not 200; PAIR's probe would fail" >&2; exit 1; }
    systemctl disable --now "$SOCKET" "$SERVICE" 2>/dev/null || true
    ! listening_1235 || { echo "something already listens on 1235; stop it first (gate 3)" >&2; exit 1; }
    install -m 0644 "$HERE/pair-adopt-1235.socket" /etc/systemd/system/
    sed -e "s#@TARGET@#$TARGET#g" -e "s#@PAIR_UNIT@#$PAIR_UNIT#g" "$HERE/pair-adopt-1235.service.in" > /etc/systemd/system/$SERVICE
    sed -i "s#@PAIR_UNIT@#$PAIR_UNIT#g" /etc/systemd/system/$SOCKET
    install -d "/etc/systemd/system/$PAIR_UNIT.service.d"; install -m 0644 "$HERE/nvpair-10-pair-adopt.conf" "$DROPIN"
    systemctl daemon-reload; systemctl enable "$SOCKET"
    install -d -o "$PAIR_USER" -g "$PAIR_GROUP" "$ENGINES"
    [ -f "$OVERRIDE" ] && cp -n "$OVERRIDE" "$OVERRIDE.bak" && echo "backed up existing override to lmstudio.json.bak"
    sed -e "s#@DETECT@#$DETECT#g" -e "s#@PLATFORM@#$PLATFORM#g" -e "s#@DISPLAY@#adopted server at $TARGET#g" "$HERE/manifest.json.in" > "$OVERRIDE"
    chown "$PAIR_USER:$PAIR_GROUP" "$OVERRIDE"; python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OVERRIDE"
    echo "restarting $PAIR_UNIT (1235 must be free while it starts; the socket binds after :1234 is up)"
    systemctl restart "$PAIR_UNIT"; sleep 3; systemctl is-active "$PAIR_UNIT"
    ! listening_1235 && echo "1235 free after restart, as required" || echo "WARN: 1235 held right after restart"
    sleep 60; do_verify
    ;;
  verify) do_verify ;;
  uninstall)
    need_root
    systemctl disable --now "$SOCKET" "$SERVICE" 2>/dev/null || true
    rm -f /etc/systemd/system/$SOCKET /etc/systemd/system/$SERVICE "$DROPIN"; systemctl daemon-reload
    if [ -f "$OVERRIDE.bak" ]; then mv "$OVERRIDE.bak" "$OVERRIDE"; echo "restored previous override"; else rm -f "$OVERRIDE"; echo "removed override"; fi
    systemctl restart "$PAIR_UNIT"; sleep 2; systemctl is-active "$PAIR_UNIT"
    ;;
  *) echo "usage: $0 install|verify|uninstall [--target ip:port] [--model id] [--detect path] [--pair-unit unit] [--pair-user user]" >&2; exit 2 ;;
esac
