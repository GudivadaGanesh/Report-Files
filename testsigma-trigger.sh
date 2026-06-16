#!/bin/bash
#**********************************************************************
# Testsigma CI/CD Trigger Script — Self-contained, no external files needed.
# HTML report template is embedded inside this script.
#**********************************************************************

#========== USER INPUTS (edit these) ==================================
TESTSIGMA_API_KEY=eyJhbGciOiJIUzUxMiJ9.eyJzdWIiOiI4MTIxYzNlZS02YjdmLTRlYTItYmJkZC0yMzUwZGE4Nzk2MjEiLCJkb21haW4iOiJ0ZXN0c2lnbWF0ZWNoLmNvbSIsInRlbmFudElkIjoyODE3LCJpc0lkbGVUaW1lb3V0Q29uZmlndXJlZCI6ZmFsc2V9.JkZiqElfo8vC4qLHvjWB2Dq0BoIWncE9GDvJDZGd14bNDODVdnPCYWiHKj9cShlWUcslZ1ep45ghl1YRvW5_Hw
TESTSIGMA_TEST_PLAN_ID=61596
MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT=45
RUNTIME_DATA_INPUT=""
BUILD_NO=$(date +"%Y%m%d%H%M")
#======================================================================

#========== OUTPUT FILE PATHS =========================================
JUNIT_REPORT_FILE_PATH=./junit-report.xml
JSON_REPORT_FILE_PATH=./testsigma.json
HTML_REPORT_FILE_PATH=./testsigma-report.html
#======================================================================

#========== GLOBAL CONSTANTS ==========================================
POLL_COUNT=30
BASE_URL=https://app.testsigma.com/api/v1
BASE_URL_V2=https://app.testsigma.com/api/v2
#======================================================================

# ── Read CLI arguments ──────────────────────────────────────────────
for i in "$@"; do
  case $i in
    -k=*|--apikey=*)        TESTSIGMA_API_KEY="${i#*=}"               ;;
    -i=*|--testplanid=*)    TESTSIGMA_TEST_PLAN_ID="${i#*=}"          ;;
    -t=*|--maxtimeinmins=*) MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT="${i#*=}";;
    -d=*|--runtimedata=*)   RUNTIME_DATA_INPUT="${i#*=}"              ;;
    -b=*|--buildno=*)       BUILD_NO="${i#*=}"                        ;;
  esac
done

# SLEEP_TIME after CLI args so --maxtimeinmins is honoured
SLEEP_TIME=$(( (MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT * 60) / POLL_COUNT ))

# ── Helpers ─────────────────────────────────────────────────────────
AUTH="Authorization:Bearer $TESTSIGMA_API_KEY"

# Extract first match of a JSON key value (simple, no jq needed)
getJsonValue() {
  local key=$1
  awk -F"[,:}]" '{for(i=1;i<=NF;i++){if($i~/\"'"$key"'\"/){print $(i+1)}}}' \
    | tr -d '"' | tr -d ' ' | head -1
}

convertsecs() {
  printf "%02d hours %02d minutes %02d seconds" \
    "$(( $1/3600 ))" "$(( ($1%3600)/60 ))" "$(( $1%60 ))"
}

# ── Build POST payload ───────────────────────────────────────────────
buildPayload() {
  local payload="{\"executionId\":$TESTSIGMA_TEST_PLAN_ID"
  if [ -n "$RUNTIME_DATA_INPUT" ]; then
    local rd='"runtimeData":{'
    local vals=""
    local OLD_IFS="$IFS"; IFS=','
    for el in $RUNTIME_DATA_INPUT; do
      vals="${vals},\"${el%%=*}\":\"${el#*=}\""
    done
    IFS="$OLD_IFS"
    rd="${rd}${vals#,}}"
    payload="${payload},${rd}"
  fi
  if [ -n "$BUILD_NO" ]; then
    payload="${payload},\"buildNo\":$BUILD_NO"
  fi
  payload="${payload}}"
  echo "$payload"
}

# ── Poll status ──────────────────────────────────────────────────────
pollStatus() {
  local resp
  resp=$(curl -s -H "$AUTH" -X GET "$BASE_URL/execution_results/$RUN_ID")
  echo "Test Plan Result Response: $resp"
  EXECUTION_STATUS=$(echo "$resp" | getJsonValue status)
  RUN_BODY="$resp"
}

waitForCompletion() {
  IS_COMPLETED=0
  local i=0
  while [ $i -le $POLL_COUNT ]; do
    pollStatus
    echo " Execution Status:: $EXECUTION_STATUS "
    case "$EXECUTION_STATUS" in
      *STATUS_COMPLETED*)
        IS_COMPLETED=1
        echo "Poll #$((i+1)) - Completed!"
        echo "Total run time: $(convertsecs $(( (i+1)*SLEEP_TIME )))"
        break ;;
      *STATUS_IN_PROGRESS*)
        echo "Poll #$((i+1)) - In progress... waiting ${SLEEP_TIME}s..." ;;
      *STATUS_CREATED*)
        echo "Poll #$((i+1)) - Queued... waiting ${SLEEP_TIME}s..." ;;
      *)
        echo "Poll #$((i+1)) - Status: ${EXECUTION_STATUS:-unknown}... waiting ${SLEEP_TIME}s..." ;;
    esac
    sleep "$SLEEP_TIME"
    i=$((i+1))
  done
}

# ── Save JUnit ───────────────────────────────────────────────────────
saveJUnit() {
  if [ "$IS_COMPLETED" -eq 0 ]; then
    echo "Skipping JUnit — run did not complete in time."
    return
  fi
  echo "Downloading JUnit report..."
  curl -s --progress-bar \
    -H "$AUTH" -H "Accept: application/xml" \
    -X GET "$BASE_URL/reports/junit/$RUN_ID" \
    --output "$JUNIT_REPORT_FILE_PATH"
  echo "Saved -> $JUNIT_REPORT_FILE_PATH"
}

# ── Save JSON ────────────────────────────────────────────────────────
saveJSON() {
  echo "$RUN_BODY" > "$JSON_REPORT_FILE_PATH"
  echo "Saved -> $JSON_REPORT_FILE_PATH"
}

# ── Generate HTML (fully embedded, no external template file) ────────
generateHTML() {
  if [ "$IS_COMPLETED" -eq 0 ]; then
    echo "Skipping HTML report — run did not complete in time."
    return
  fi

  echo "Generating HTML report for Run ID $RUN_ID ..."

  local TMP_V2 TMP_TC TMP_ERR
  TMP_V2=$(mktemp /tmp/ts_v2_XXXXXX.json)
  TMP_TC=$(mktemp /tmp/ts_tc_XXXXXX.json)
  TMP_ERR=$(mktemp /tmp/ts_er_XXXXXX.json)

  # Fetch data from 3 API endpoints
  curl -s -H "$AUTH" -H "Accept: application/json" \
    -o "$TMP_V2" "$BASE_URL_V2/test_runs/${RUN_ID}"

  curl -s -H "$AUTH" -H "Accept: application/json" \
    -o "$TMP_TC" "$BASE_URL/execution_results/${RUN_ID}/test_case_results"

  curl -s -H "$AUTH" -H "Accept: application/json" \
    -o "$TMP_ERR" "$BASE_URL/test_case_results?executionResultId=${RUN_ID}&page=0&size=200"

  python3 - "$TMP_V2" "$TMP_TC" "$TMP_ERR" "$HTML_REPORT_FILE_PATH" << 'PYEOF'
import sys, json, re, datetime

def load(p):
    try:
        with open(p, 'rb') as f:
            return json.loads(f.read().strip().decode('utf-8', errors='replace'), strict=False)
    except:
        return {}

v2  = load(sys.argv[1])
tc  = load(sys.argv[2])
err = load(sys.argv[3])
out = sys.argv[4]

m = v2.get('metrics') or {}

# Error message map: testCaseResultId -> message
em = {}
for x in (err.get('content') or []):
    rid, msg = x.get('id'), (x.get('message') or '').strip()
    if rid and msg and 'executed successfully' not in msg.lower():
        em[rid] = re.sub(r'<[^>]+>', '', msg)[:300]

# Build test case rows
cases = []
for x in (tc.get('testCases') or []):
    cases.append({
        'name':    x.get('testCaseName')  or '-',
        'suite':   x.get('testSuiteName') or '-',
        'machine': x.get('machineTitle')  or '-',
        'result':  x.get('result')        or '-',
        'error':   em.get(x.get('testCaseResultId'), ''),
    })

total   = int(m.get('totalCount')       or len(cases) or 0)
passed  = int(m.get('passedCount')      or 0)
failed  = int(m.get('failedCount')      or 0)
stopped = int(m.get('stoppedCount')     or 0)
notrun  = int(m.get('notExecutedCount') or 0)

if total == 0 and cases:
    total   = len(cases)
    passed  = sum(1 for c in cases if c['result'].upper() == 'SUCCESS')
    failed  = sum(1 for c in cases if c['result'].upper() == 'FAILURE')
    stopped = sum(1 for c in cases if c['result'].upper() == 'STOPPED')
    notrun  = sum(1 for c in cases if c['result'].upper() == 'NOT_EXECUTED')

result  = (m.get('result') or v2.get('result') or 'UNKNOWN').upper()
run_id  = str(v2.get('id') or '-')
build   = str(v2.get('buildNo') or '-')
start   = str(v2.get('startTime') or '-')
end     = str(v2.get('endTime')   or '-')
dur_ms  = m.get('duration')
now     = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')

def e(s):
    return str(s).replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('"','&quot;')

def dur(ms):
    if not ms: return '-'
    ms=int(ms); h=ms//3600000; mn=(ms%3600000)//60000; s=(ms%60000)//1000
    return ' '.join(filter(None, [f'{h}h' if h else '', f'{mn}m' if mn else '', f'{s}s']))

def pct(v): return round(v*100/total,1) if total>0 else 0

def badge(r):
    r=r.upper()
    m2={'SUCCESS':('passed','Passed'),'FAILURE':('failed','Failed'),
        'STOPPED':('stopped','Stopped'),'NOT_EXECUTED':('notrun','Not Run')}
    cls,lbl=m2.get(r,('notrun',r))
    return f'<span class="b {cls}">{lbl}</span>'

banner_cls = 'ok' if result=='SUCCESS' else 'fail' if result=='FAILURE' else 'run'
banner_ico = '✓' if result=='SUCCESS' else '✗' if result=='FAILURE' else '↻'
banner_txt = 'All tests passed' if result=='SUCCESS' else f'{failed} test(s) failed' if result=='FAILURE' else f'Status: {result}'

rows = ''.join(
    f'<tr><td class="n">{e(c["name"])}</td><td>{e(c["suite"])}</td>'
    f'<td class="sm">{e(c["machine"])}</td><td>{badge(c["result"])}</td>'
    f'<td class="er" title="{e(c["error"])}">{e(c["error"]) or "-"}</td></tr>'
    for c in cases
) or '<tr><td colspan="5" class="empty">No test case results available</td></tr>'

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Testsigma Report – Run {e(run_id)}</title>
<style>
*,*::before,*::after{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f0f2f5;color:#1e293b}}
.hdr{{background:linear-gradient(135deg,#1a1a2e 0%,#0f3460 100%);color:#fff;padding:22px 36px;display:flex;justify-content:space-between;align-items:center;box-shadow:0 4px 20px rgba(0,0,0,.3)}}
.hdr-l{{display:flex;align-items:center;gap:12px}}
.logo{{width:38px;height:38px;border-radius:9px;background:linear-gradient(135deg,#e94560,#0f3460);display:flex;align-items:center;justify-content:center;font-size:17px;font-weight:800}}
.hdr h1{{font-size:19px;font-weight:700}}
.hdr p{{font-size:12px;opacity:.6;margin-top:2px}}
.hdr-r{{text-align:right;font-size:11px;opacity:.65;line-height:1.9}}
.hdr-r strong{{color:#fff;opacity:1}}
.banner{{margin:18px 36px 0;padding:13px 18px;border-radius:10px;font-weight:700;font-size:14px;display:flex;align-items:center;gap:10px}}
.banner.ok  {{background:#d1fae5;color:#065f46;border-left:4px solid #10b981}}
.banner.fail{{background:#fee2e2;color:#991b1b;border-left:4px solid #ef4444}}
.banner.run {{background:#ede9fe;color:#5b21b6;border-left:4px solid #7c3aed}}
.ico{{font-size:18px}}
.cards{{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:12px;padding:18px 36px 0}}
.card{{background:#fff;border-radius:11px;padding:16px 18px;box-shadow:0 2px 8px rgba(0,0,0,.07);border-top:4px solid transparent}}
.card.t{{border-color:#6c63ff}}.card.p{{border-color:#10b981}}
.card.f{{border-color:#ef4444}}.card.s{{border-color:#f59e0b}}
.card.n{{border-color:#94a3b8}}
.lbl{{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.7px;color:#64748b;margin-bottom:5px}}
.val{{font-size:30px;font-weight:800}}
.card.t .val{{color:#6c63ff}}.card.p .val{{color:#10b981}}
.card.f .val{{color:#ef4444}}.card.s .val{{color:#f59e0b}}
.card.n .val{{color:#94a3b8}}
.prog-sec{{padding:14px 36px 0}}
.prog{{height:8px;border-radius:99px;background:#e2e8f0;overflow:hidden;display:flex}}
.prog span{{display:block;height:100%;transition:width .5s}}
.pp{{background:#10b981}}.pf{{background:#ef4444}}.ps{{background:#f59e0b}}.pn{{background:#cbd5e1}}
.leg{{display:flex;gap:14px;margin-top:6px;font-size:11px;color:#64748b;font-weight:500}}
.leg span{{display:flex;align-items:center;gap:4px}}
.dot{{width:7px;height:7px;border-radius:50%;display:inline-block}}
.meta{{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px;padding:14px 36px 0}}
.mc{{background:#fff;border-radius:10px;padding:11px 14px;box-shadow:0 1px 5px rgba(0,0,0,.06);display:flex;align-items:center;gap:10px}}
.mi{{width:32px;height:32px;border-radius:8px;background:#f1f5f9;display:flex;align-items:center;justify-content:center;font-size:15px;flex-shrink:0}}
.ml{{font-size:10px;color:#94a3b8;font-weight:600;text-transform:uppercase;letter-spacing:.4px}}
.mv{{font-size:13px;font-weight:600;color:#1e293b;margin-top:1px;word-break:break-all}}
.sh{{padding:18px 36px 8px;font-size:14px;font-weight:700;color:#1e293b}}
.tw{{padding:0 36px 36px;overflow-x:auto}}
table{{width:100%;border-collapse:collapse;background:#fff;border-radius:11px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.07);font-size:12px}}
thead tr{{background:#f8fafc}}
th{{padding:10px 13px;text-align:left;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.6px;color:#64748b;border-bottom:2px solid #e2e8f0}}
td{{padding:10px 13px;border-bottom:1px solid #f1f5f9;color:#374151;vertical-align:middle}}
tbody tr:last-child td{{border-bottom:none}}
tbody tr:hover{{background:#fafbfc}}
td.n{{font-weight:600;color:#1e293b}}
td.sm{{color:#64748b;font-size:11px}}
td.er{{color:#ef4444;font-size:11px;max-width:250px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
.empty{{text-align:center;padding:36px;color:#94a3b8}}
.b{{display:inline-flex;align-items:center;padding:3px 8px;border-radius:99px;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.4px}}
.b.passed {{background:#d1fae5;color:#065f46}}
.b.failed {{background:#fee2e2;color:#991b1b}}
.b.stopped{{background:#fef3c7;color:#92400e}}
.b.notrun {{background:#f1f5f9;color:#475569}}
.footer{{text-align:center;padding:16px;font-size:11px;color:#94a3b8}}
</style>
</head>
<body>
<div class="hdr">
  <div class="hdr-l">
    <div class="logo">TS</div>
    <div><h1>Test Run Report</h1><p>Testsigma Automated Execution</p></div>
  </div>
  <div class="hdr-r">
    Run ID: <strong>{e(run_id)}</strong><br>
    Build: <strong>{e(build)}</strong><br>
    Generated: <strong>{now}</strong>
  </div>
</div>

<div class="banner {banner_cls}">
  <span class="ico">{banner_ico}</span>
  <span>{banner_txt}</span>
</div>

<div class="cards">
  <div class="card t"><div class="lbl">Total</div><div class="val">{total}</div></div>
  <div class="card p"><div class="lbl">Passed</div><div class="val">{passed}</div></div>
  <div class="card f"><div class="lbl">Failed</div><div class="val">{failed}</div></div>
  <div class="card s"><div class="lbl">Stopped</div><div class="val">{stopped}</div></div>
  <div class="card n"><div class="lbl">Not Run</div><div class="val">{notrun}</div></div>
</div>

<div class="prog-sec">
  <div class="prog">
    <span class="pp" style="width:{pct(passed)}%"></span>
    <span class="pf" style="width:{pct(failed)}%"></span>
    <span class="ps" style="width:{pct(stopped)}%"></span>
    <span class="pn" style="width:{pct(notrun)}%"></span>
  </div>
  <div class="leg">
    <span><i class="dot" style="background:#10b981"></i>Passed {pct(passed)}%</span>
    <span><i class="dot" style="background:#ef4444"></i>Failed {pct(failed)}%</span>
    <span><i class="dot" style="background:#f59e0b"></i>Stopped {pct(stopped)}%</span>
    <span><i class="dot" style="background:#cbd5e1"></i>Not Run {pct(notrun)}%</span>
  </div>
</div>

<div class="meta">
  <div class="mc"><div class="mi">🗓</div><div><div class="ml">Start Time</div><div class="mv">{e(start)}</div></div></div>
  <div class="mc"><div class="mi">🏁</div><div><div class="ml">End Time</div><div class="mv">{e(end)}</div></div></div>
  <div class="mc"><div class="mi">⏱</div><div><div class="ml">Duration</div><div class="mv">{dur(dur_ms)}</div></div></div>
  <div class="mc"><div class="mi">📋</div><div><div class="ml">Cases</div><div class="mv">{total}</div></div></div>
</div>

<div class="sh">📋 Test Case Results <span style="font-size:12px;font-weight:500;color:#64748b">({len(cases)} cases)</span></div>
<div class="tw">
  <table>
    <thead><tr><th>Test Case</th><th>Suite</th><th>Machine</th><th>Result</th><th>Error</th></tr></thead>
    <tbody>{rows}</tbody>
  </table>
</div>

<div class="footer">Generated by Testsigma CI/CD Script &mdash; {now}</div>
</body>
</html>"""

with open(out, 'w', encoding='utf-8') as f:
    f.write(html)

print(f"HTML report -> {out}  [total={total} passed={passed} failed={failed} stopped={stopped} notRun={notrun} cases={len(cases)}]")
PYEOF

  local ex=$?
  rm -f "$TMP_V2" "$TMP_TC" "$TMP_ERR"
  if [ $ex -ne 0 ]; then
    echo "ERROR: HTML generation failed (exit $ex)."
  else
    echo "HTML report saved -> $HTML_REPORT_FILE_PATH"
  fi
}

# ══════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════

echo "************ Testsigma: Start executing automated tests ************"

JSON_DATA=$(buildPayload)
echo "InputData=$JSON_DATA"

# ── Retry guard: reuse existing active run to prevent duplicates ────
# Uses the CORRECT endpoint: /api/v1/execution_results?executionId=PLAN_ID
echo "Checking for an existing active run for plan $TESTSIGMA_TEST_PLAN_ID ..."

LAST_RESP=$(curl -s -H "$AUTH" -H "Accept: application/json" \
  "$BASE_URL/execution_results?executionId=${TESTSIGMA_TEST_PLAN_ID}&page=0&size=1&sortBy=id&direction=DESC")

# Extract from content[0] — the response wraps results in a "content" array
LAST_ID=$(echo "$LAST_RESP" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    c=d.get('content') or []
    print(c[0]['id'] if c else '')
except:
    print('')
" 2>/dev/null)

LAST_STATUS=$(echo "$LAST_RESP" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    c=d.get('content') or []
    print(c[0].get('status','') if c else '')
except:
    print('')
" 2>/dev/null)

REUSING=0
case "$LAST_STATUS" in
  STATUS_CREATED|STATUS_IN_PROGRESS)
    echo "Active run found (ID: $LAST_ID, Status: $LAST_STATUS) — reusing it, no new run triggered."
    RUN_ID="$LAST_ID"
    REUSING=1
    ;;
  *)
    echo "No active run (last status: ${LAST_STATUS:-none}). Triggering new run..."
    ;;
esac

# ── Trigger new run only when needed ────────────────────────────────
if [ "$REUSING" -eq 0 ]; then
  RESP=$(curl -s -H "$AUTH" \
    -H "Accept: application/json" \
    -H "content-type: application/json" \
    --write-out "HTTPSTATUS:%{http_code}" \
    -d "$JSON_DATA" -X POST "$BASE_URL/execution_results")

  HTTP_STATUS=$(echo "$RESP" | tr -d '\n' | sed 's/.*HTTPSTATUS://')
  BODY=$(echo "$RESP" | sed 's/HTTPSTATUS:[0-9]*//')
  RUN_ID=$(echo "$BODY" | getJsonValue id)

  if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "Failed to start test plan! HTTP $HTTP_STATUS"
    echo "$BODY"
    exit 1
  fi
fi

case "$RUN_ID" in
  ''|*[!0-9]*) echo "Could not get Run ID: '$RUN_ID'"; exit 1 ;;
  *) echo "Run ID: $RUN_ID" ;;
esac

echo "Polls: $POLL_COUNT  |  Interval: ${SLEEP_TIME}s  |  Max wait: ${MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT}m"

# ── Run all steps — files always written before exit ────────────────
waitForCompletion
saveJUnit
saveJSON
generateHTML

# ── Final result and exit code ───────────────────────────────────────
FINAL_RESULT=$(echo "$RUN_BODY" | getJsonValue result)
echo "================================================"
echo "Final Result: $FINAL_RESULT"
echo "Artifacts written:"
ls -lh "$JUNIT_REPORT_FILE_PATH" "$JSON_REPORT_FILE_PATH" "$HTML_REPORT_FILE_PATH" 2>/dev/null || true
echo "************ Testsigma: Completed ************"

if [ "$IS_COMPLETED" -eq 0 ]; then
  echo "TIMEOUT: Run did not complete within ${MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT} minutes."
  exit 1
fi

case "$FINAL_RESULT" in
  *SUCCESS*) exit 0 ;;
  *)         exit 1 ;;
esac
