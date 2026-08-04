#!/usr/bin/env bash
# Hostile Input :: Pre-Workshop QA Smoke Test
#
# Run this where the PDF TOOLS live. That is your Kali VM if you are using one,
# or your machine directly if you are not.
#
# Architecture: the tools run here. The MODEL runs natively on your host, because
# inference inside a VM is too slow to be usable. So this script checks two separate
# things: that the tools are present locally, and that the model API on your host is
# actually reachable from here. The second is the one that breaks on the day.
set -u
PASS="[ PASS ]"; FAIL="[ FAIL ]"; fail=0
FAST=0
[ "${1:-}" = "--fast" ] && FAST=1   # skip the live model prompt; re-check between lessons

HERE="$(cd "$(dirname "$0")" && pwd)"
for c in "$HERE/config.env" "$HERE/../config.env"; do [ -f "$c" ] && . "$c" && break; done
MODEL="${MODEL:-gemma4:e4b}"

check() {
  if eval "$2" >/dev/null 2>&1; then
    printf "%s %s\n" "$PASS" "$1"
  else
    printf "%s %s\n" "$FAIL" "$1"; fail=1
  fi
}

echo "== Tool presence (these run HERE) =="
check "file present"        "command -v file"
check "pdfid present"       "command -v pdfid || command -v pdfid.py"
check "pdf-parser present"  "command -v pdf-parser || command -v pdf-parser.py"
check "pdftotext present"   "command -v pdftotext"
check "pdfinfo present"    "command -v pdfinfo"
check "pdffonts present"   "command -v pdffonts"
check "qpdf present"        "command -v qpdf"
check "jq present"          "command -v jq"
check "curl present"        "command -v curl"

echo; echo "== Sample set =="
# Resolved against this script, not the shell's CWD, so the QA test runs from anywhere.
SAMPLE="$HERE/samples/smoke.pdf"
[ -f "$SAMPLE" ] || SAMPLE="$HERE/../samples/smoke.pdf"
check "smoke sample present" "test -f \"$SAMPLE\""

echo; echo "== Tools run against sample =="
if [ -f "$SAMPLE" ]; then
  check "file reads sample"       "file \"$SAMPLE\""
  check "pdfid reads sample"      "{ command -v pdfid >/dev/null && pdfid \"$SAMPLE\"; } || pdfid.py \"$SAMPLE\""
  check "pdf-parser reads sample" "{ command -v pdf-parser >/dev/null && pdf-parser \"$SAMPLE\"; } || pdf-parser.py \"$SAMPLE\""
  check "pdftotext reads sample"  "pdftotext \"$SAMPLE\" -"
  check "qpdf reads sample"       "qpdf --qdf \"$SAMPLE\" -"
else
  echo "$FAIL sample missing, skipping tool-vs-sample checks"; fail=1
fi

echo; echo "== Model API (runs on your HOST, reached from here) =="

# Find the model API. Order: what you told us, then localhost (running natively,
# no VM), then the usual host gateways for VirtualBox NAT and UTM/VMware shared
# networking, then whatever the default route points at.
CANDIDATES=""
[ -n "${OLLAMA_HOST:-}" ] && CANDIDATES="${OLLAMA_HOST}"
GW="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
CANDIDATES="$CANDIDATES http://127.0.0.1:11434 http://10.0.2.2:11434 http://192.168.64.1:11434"
[ -n "$GW" ] && CANDIDATES="$CANDIDATES http://$GW:11434"

API=""
for c in $CANDIDATES; do
  case "$c" in http*) url="$c" ;; *) url="http://$c" ;; esac
  if curl -sf --max-time 3 "$url/api/tags" >/dev/null 2>&1; then API="$url"; break; fi
done

if [ -z "$API" ]; then
  printf "%s model API not reachable from here\n" "$FAIL"; fail=1
  echo "         Tried:$(printf ' %s' $CANDIDATES)"
  echo
  echo "         By default Ollama listens on localhost only, so the VM cannot see it."
  echo "         On the HOST, bind it to all interfaces:"
  echo "           macOS:  launchctl setenv OLLAMA_HOST \"0.0.0.0:11434\"   (then quit and reopen Ollama)"
  echo "           Linux:  OLLAMA_HOST=0.0.0.0:11434 ollama serve"
  echo "         Allow port 11434 through the host firewall, then re-run this test."
  echo "         Then set OLLAMA_HOST in config.env to that address."
else
  printf "%s model API reachable at %s\n" "$PASS" "$API"

  MODEL_OK=0
  TAGS="$(curl -sf --max-time 5 "$API/api/tags" 2>/dev/null)"
  if printf '%s' "$TAGS" | grep -q "\"$MODEL\""; then
    printf "%s %s is pulled\n" "$PASS" "$MODEL"; MODEL_OK=1
  elif printf '%s' "$TAGS" | grep -q "\"${MODEL}-mlx\""; then
    # Apple Silicon users pull the MLX build. Every script, slide and lab in this
    # workshop says "gemma4:e4b", so alias it once and never think about it again.
    printf "%s %s not found, but %s-mlx is on the host\n" "$FAIL" "$MODEL" "$MODEL"; fail=1
    echo "         Alias it so the workshop's default name works everywhere:"
    echo "           ollama cp ${MODEL}-mlx $MODEL"
    echo "         That costs no extra disk and keeps one model name everywhere."
  else
    printf "%s %s not in the host model list\n" "$FAIL" "$MODEL"; fail=1
    echo "         On the HOST run:  ollama pull $MODEL"
    echo "         Apple Silicon:    ollama pull ${MODEL}-mlx && ollama cp ${MODEL}-mlx $MODEL"
  fi

  if [ "$MODEL_OK" -eq 1 ] && [ "$FAST" -eq 0 ]; then
    REPLY_JSON="$(curl -sf --max-time 120 "$API/api/generate" \
        -d "{\"model\":\"$MODEL\",\"prompt\":\"Reply with the single word: ready\",\"stream\":false,\"options\":{\"num_ctx\":16384}}" 2>/dev/null)"
    if printf '%s' "$REPLY_JSON" | grep -iq ready; then
      printf "%s %s answered a live prompt at num_ctx 16384\n" "$PASS" "$MODEL"
    else
      printf "%s %s did not answer\n" "$FAIL" "$MODEL"; fail=1
      echo "         The API is up but the model did not respond. Check the host is awake and"
      echo "         has enough free RAM for a 16k context on top of the model itself."
    fi
  elif [ "$FAST" -eq 1 ]; then
    echo "         (--fast: skipped the live prompt)"
  else
    echo "         (skipping the live prompt until the model above is sorted)"
  fi

  echo
  echo "         Put this in config.env and you never type it again:"
  echo "           OLLAMA_HOST=$API"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL GREEN. You are ready for the workshop."
else
  echo "One or more checks FAILED. See the troubleshooting section before the con."
fi
