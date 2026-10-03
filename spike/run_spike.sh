#!/bin/bash
# apiKeyHelper feasibility spike. Usage: spike/run_spike.sh [claude-binary]
# Uses only fake sk-test-* keys, an isolated CLAUDE_CONFIG_DIR and a local mock gateway.
set -u
CLAUDE_BIN="${1:-claude}"
PORT=18471
W="$(mktemp -d)/spike"; mkdir -p "$W"
LOG="$W/mock.log"; HLOG="$W/helper.log"
SPIKE_DIR="$(cd "$(dirname "$0")" && pwd)"
MOCK_LOG="$LOG" MOCK_REVOKED="sk-test-revoked" python3 "$SPIKE_DIR/mock_gateway.py" $PORT & MOCK=$!
trap 'kill $MOCK 2>/dev/null' EXIT
sleep 0.5

# Fake helper: reads the "keychain" file for a profile; never echoes into logs.
mkdir -p "$W/keys"
cat > "$W/helper.sh" <<'H'
#!/bin/sh
echo "$(date +%T) helper profile=$2 cwd=$PWD" >> "$HLOG"
cat "$KEYDIR/$2"
H
chmod +x "$W/helper.sh"
echo -n sk-test-A > "$W/keys/A"; echo -n sk-test-B > "$W/keys/B"

bind() { # dir profile
  mkdir -p "$1/.claude"
  cat > "$1/.claude/settings.local.json" <<J
{ "apiKeyHelper": "HLOG='$HLOG' KEYDIR='$W/keys' '$W/helper.sh' --profile $2",
  "env": { "ANTHROPIC_BASE_URL": "http://127.0.0.1:$PORT/proj$2" } }
J
}
mkdir -p "$W/projA/sub" "$W/proj B with space"
git -C "$W/projA" init -q && git -C "$W/projA" commit -q --allow-empty -m init
git -C "$W/projA" worktree add -q "$W/projA-wt" 2>/dev/null
bind "$W/projA" A; bind "$W/proj B with space" B

run() { # label dir [extra env...]
  local label="$1" dir="$2"; shift 2
  echo "== $label" >> "$LOG"
  (cd "$dir" && env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
     CLAUDE_CONFIG_DIR="$W/cfg" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
     ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT/fallback" "$@" \
     "$CLAUDE_BIN" -p "say OK" --max-turns 1 >"$W/out.txt" 2>&1; echo "   exit=$? out=$(tail -c 160 "$W/out.txt" | tr '\n' ' ')" >> "$LOG")
}

run "T1 projA" "$W/projA"
run "T2 projB (path with spaces)" "$W/proj B with space"
run "T3 A and B concurrently (A)" "$W/projA" & P1=$!; run "T3 A and B concurrently (B)" "$W/proj B with space" & P2=$!; wait $P1 $P2
run "T4 subfolder of A" "$W/projA/sub"
run "T5 git worktree of A without own settings" "$W/projA-wt"
run "T6 A + ANTHROPIC_API_KEY in process env" "$W/projA" ANTHROPIC_API_KEY=sk-test-ENVKEY
run "T7 A + ANTHROPIC_AUTH_TOKEN in process env" "$W/projA" ANTHROPIC_AUTH_TOKEN=sk-test-ENVTOKEN
echo -n sk-test-A2 > "$W/keys/A"
run "T8 A after key change (new session)" "$W/projA"
if [ "${SLOW:-0}" = 1 ]; then
  echo -n sk-test-revoked > "$W/keys/A"
  run "T9 A with server-side revoked key" "$W/projA"
fi
rm "$W/keys/A"
run "T10 A with missing credential (helper fails)" "$W/projA"
echo -n sk-test-A > "$W/keys/A"
bind "$W/projA-wt" B
run "T11 worktree of A with its own binding to B" "$W/projA-wt"
# Neutralise inherited auth env via the project env block
python3 - "$W/projA/.claude/settings.local.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["env"].update(ANTHROPIC_API_KEY="", ANTHROPIC_AUTH_TOKEN=""); json.dump(d,open(p,"w"))
PY
run "T12 A + inherited API_KEY/AUTH_TOKEN, neutralised by empty env in settings" "$W/projA" ANTHROPIC_API_KEY=sk-test-ENVKEY ANTHROPIC_AUTH_TOKEN=sk-test-ENVTOKEN
rm "$W/keys/A"
run "T13 A missing credential with neutralised env" "$W/projA"
echo -n sk-test-A > "$W/keys/A"
echo "== T14 running session, key changed mid-session, TTL=2000ms" >> "$LOG"
U='{"type":"user","message":{"role":"user","content":"say OK"}}'
(cd "$W/projA" && { echo "$U"; sleep 4; echo -n sk-test-A3 > "$W/keys/A"; sleep 4; echo "$U"; sleep 4; echo "$U"; sleep 4; } | env -i HOME="$HOME" PATH="/usr/bin:/bin" CLAUDE_CONFIG_DIR="$W/cfg" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_API_KEY_HELPER_TTL_MS=2000 \
  "$CLAUDE_BIN" -p --input-format stream-json --output-format stream-json --verbose >/dev/null 2>&1; echo "   exit=$?" >> "$LOG")

bind "$W/projA/sub" B
run "T15 subfolder of A with its own binding to B, started in subfolder" "$W/projA/sub"
mkdir -p "$W/plain/inner"; bind "$W/plain" A; bind "$W/plain/inner" B
run "T16 non-git folder: inner folder bound to B inside outer bound to A" "$W/plain/inner"
mkdir -p "$W/plain/other"; run "T17 non-git folder: unbound child of bound folder (falls back to process env)" "$W/plain/other"
if [ "${REAL_CONFIG:-0}" = 1 ]; then  # uses the developer's real ~/.claude login; values are never logged
  echo -n sk-test-A > "$W/keys/A"
  (cd "$W/projA" && env -i HOME="$HOME" PATH="/usr/bin:/bin" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 "$CLAUDE_BIN" -p "say OK" --max-turns 1 >"$W/out.txt" 2>&1; echo "== T18 real login + helper ok: exit=$? $(tail -c 200 "$W/out.txt"|tr '\n' ' ')" >> "$LOG")
  rm "$W/keys/A"
  (cd "$W/projA" && env -i HOME="$HOME" PATH="/usr/bin:/bin" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 "$CLAUDE_BIN" -p "say OK" --max-turns 1 >"$W/out.txt" 2>&1; echo "== T19 real login + helper failing: exit=$? $(tail -c 200 "$W/out.txt"|tr '\n' ' ')" >> "$LOG")
fi
echo "######## gateway log"; cat "$LOG"
echo "######## helper log"; cat "$HLOG"
