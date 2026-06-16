#!/bin/bash
#**********************************************************************
# Testsigma CI/CD Trigger Script
#
# ONE FILE — the HTML report template is embedded directly inside
# this script. No separate testsigma_report_template.html needed.
#
# USER INPUTS:
#   TESTSIGMA_API_KEY                -> API key from Testsigma App >> Configuration >> API Keys
#   TESTSIGMA_TEST_PLAN_ID           -> Test Plan ID from CI/CD Integration tab
#   MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT -> Max minutes to wait for completion
#   RUNTIME_DATA_INPUT               -> Comma-separated key=value (optional, leave empty if not needed)
#   BUILD_NO                         -> Auto-generated from date, or pass --buildno=X
#**********************************************************************

#********START USER_INPUTS*********
TESTSIGMA_API_KEY=eyJhbGciOiJIUzUxMiJ9.eyJzdWIiOiI4MTIxYzNlZS02YjdmLTRlYTItYmJkZC0yMzUwZGE4Nzk2MjEiLCJkb21haW4iOiJ0ZXN0c2lnbWF0ZWNoLmNvbSIsInRlbmFudElkIjoyODE3LCJpc0lkbGVUaW1lb3V0Q29uZmlndXJlZCI6ZmFsc2V9.JkZiqElfo8vC4qLHvjWB2Dq0BoIWncE9GDvJDZGd14bNDODVdnPCYWiHKj9cShlWUcslZ1ep45ghl1YRvW5_Hw
TESTSIGMA_TEST_PLAN_ID=61596
MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT=45
JUNIT_REPORT_FILE_PATH=./junit-report.xml
HTML_REPORT_FILE_PATH=./testsigma-report.html
RUNTIME_DATA_INPUT=""
BUILD_NO=$(date +"%Y%m%d%H%M")
#********END USER_INPUTS***********

#********GLOBAL variables**********
POLL_COUNT=30
JSON_REPORT_FILE_PATH=./testsigma.json
TESTSIGMA_TEST_PLAN_REST_URL=https://app.testsigma.com/api/v1/execution_results
TESTSIGMA_JUNIT_REPORT_URL=https://app.testsigma.com/api/v1/reports/junit
TESTSIGMA_V2_RUN_URL=https://app.testsigma.com/api/v2/test_runs
TESTSIGMA_V1_TC_RESULT_URL=https://app.testsigma.com/api/v1/execution_results
TESTSIGMA_V1_TC_BULK_URL=https://app.testsigma.com/api/v1/test_case_results
TESTSIGMA_LAST_RUN_URL=https://app.testsigma.com/api/v1/executions
#**********************************

# ── Read CLI arguments ──────────────────────────────────────────────
for i in "$@"; do
  case $i in
    -k=*|--apikey=*)         TESTSIGMA_API_KEY="${i#*=}"               ;;
    -i=*|--testplanid=*)     TESTSIGMA_TEST_PLAN_ID="${i#*=}"          ;;
    -t=*|--maxtimeinmins=*)  MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT="${i#*=}";;
    -r=*|--reportfilepath=*) JUNIT_REPORT_FILE_PATH="${i#*=}"          ;;
    -d=*|--runtimedata=*)    RUNTIME_DATA_INPUT="${i#*=}"              ;;
    -b=*|--buildno=*)        BUILD_NO="${i#*=}"                        ;;
    --htmlreport=*)          HTML_REPORT_FILE_PATH="${i#*=}"           ;;
    -h|--help)
      echo "Arguments:"
      echo "  [-k | --apikey]         = <TESTSIGMA_API_KEY>"
      echo "  [-i | --testplanid]     = <TESTSIGMA_TEST_PLAN_ID>"
      echo "  [-t | --maxtimeinmins]  = <MAX_WAIT_TIME_IN_MINS>"
      echo "  [-r | --reportfilepath] = <JUNIT_REPORT_FILE_PATH>"
      echo "  [-d | --runtimedata]    = <COMMA SEPARATED KEY=VALUE>"
      echo "  [-b | --buildno]        = <BUILD_NO>"
      echo "         --htmlreport     = <HTML_REPORT_FILE_PATH>"
      printf "\nExample:\n  bash testsigma-trigger.sh --apikey=YOUR_KEY --testplanid=61596 --maxtimeinmins=45\n\n"
      exit 0
      ;;
  esac
done

# Calculated AFTER CLI args so --maxtimeinmins overrides are honoured
SLEEP_TIME=$(( (MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT * 60) / POLL_COUNT ))
MAX_WAITTIME_EXCEEDED_ERRORMSG="Given Maximum Wait Time of $MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT minutes exceeded. Please log in to Testsigma to check results."

# ── Extract a JSON value by key ─────────────────────────────────────
getJsonValue() {
  json_key=$1
  awk -F"[,:}]" '{for(i=1;i<=NF;i++){if($i~/\042'"$json_key"'\042/){print $(i+1)}}}' | tr -d '"' | tr -d ' '
}

# ── Convert seconds to hh:mm:ss ────────────────────────────────────
convertsecs() {
  _h=$(( $1 / 3600 ))
  _m=$(( ($1 % 3600) / 60 ))
  _s=$(( $1 % 60 ))
  printf "%02d hours %02d minutes %02d seconds" $_h $_m $_s
}

# ── Build runtimeData JSON fragment ────────────────────────────────
populateRuntimeData() {
  RUN_TIME_DATA=""
  if [ -z "$RUNTIME_DATA_INPUT" ]; then
    return
  fi
  RUN_TIME_DATA='"runtimeData":{'
  DATA_VALUES=""
  OLD_IFS="$IFS"
  IFS=','
  for element in $RUNTIME_DATA_INPUT; do
    key="${element%%=*}"
    val="${element#*=}"
    DATA_VALUES="${DATA_VALUES},\"${key}\":\"${val}\""
  done
  IFS="$OLD_IFS"
  DATA_VALUES="${DATA_VALUES#,}"
  RUN_TIME_DATA="${RUN_TIME_DATA}${DATA_VALUES}}"
}

# ── Build buildNo JSON fragment ─────────────────────────────────────
populateBuildNo() {
  if [ -z "$BUILD_NO" ]; then
    BUILD_DATA=""
  else
    BUILD_DATA="\"buildNo\":$BUILD_NO"
  fi
}

# ── Assemble POST payload ───────────────────────────────────────────
populateJsonPayload() {
  JSON_DATA="{\"executionId\":$TESTSIGMA_TEST_PLAN_ID"
  populateRuntimeData
  populateBuildNo
  if [ -z "$BUILD_DATA" ] && [ -z "$RUN_TIME_DATA" ]; then
    JSON_DATA="${JSON_DATA}}"
  elif [ -z "$BUILD_DATA" ]; then
    JSON_DATA="${JSON_DATA},${RUN_TIME_DATA}}"
  elif [ -z "$RUN_TIME_DATA" ]; then
    JSON_DATA="${JSON_DATA},${BUILD_DATA}}"
  else
    JSON_DATA="${JSON_DATA},${RUN_TIME_DATA},${BUILD_DATA}}"
  fi
  echo "InputData=$JSON_DATA"
}

# ── Poll run status ─────────────────────────────────────────────────
get_status() {
  RUN_RESPONSE=$(curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
    --silent --write-out "HTTPSTATUS:%{http_code}" \
    -X GET "$TESTSIGMA_TEST_PLAN_REST_URL/$RUN_ID")
  RUN_BODY=$(echo "$RUN_RESPONSE" | sed -e 's/HTTPSTATUS\:.*//g')
  echo "Test Plan Result Response: $RUN_BODY"
  EXECUTION_STATUS=$(echo "$RUN_BODY" | getJsonValue status)
}

checkTestPlanRunStatus() {
  IS_TEST_RUN_COMPLETED=0
  i=0
  while [ $i -le $POLL_COUNT ]; do
    get_status
    echo " Execution Status:: $EXECUTION_STATUS "
    case "$EXECUTION_STATUS" in
      *STATUS_IN_PROGRESS*)
        echo "Poll #$((i+1)) - In progress... waiting ${SLEEP_TIME}s..."
        sleep "$SLEEP_TIME"
        ;;
      *STATUS_CREATED*)
        echo "Poll #$((i+1)) - Created/queued... waiting ${SLEEP_TIME}s..."
        sleep "$SLEEP_TIME"
        ;;
      *STATUS_COMPLETED*)
        IS_TEST_RUN_COMPLETED=1
        echo "Poll #$((i+1)) - Execution completed."
        TOTALRUNSECONDS=$(( (i+1) * SLEEP_TIME ))
        echo "Total script run time: $(convertsecs $TOTALRUNSECONDS)"
        break
        ;;
      *)
        echo "Poll #$((i+1)) - Unexpected status '$EXECUTION_STATUS'. Waiting ${SLEEP_TIME}s..."
        sleep "$SLEEP_TIME"
        ;;
    esac
    i=$((i+1))
  done
}

# ── Save raw JSON response ──────────────────────────────────────────
saveFinalResponseToJSONFile() {
  if [ "$IS_TEST_RUN_COMPLETED" -eq 0 ]; then
    echo "$MAX_WAITTIME_EXCEEDED_ERRORMSG"
  fi
  echo "$RUN_BODY" > "$JSON_REPORT_FILE_PATH"
  echo "Saved JSON response -> $JSON_REPORT_FILE_PATH"
}

# ── Download JUnit XML report ───────────────────────────────────────
saveFinalResponseToJUnitFile() {
  if [ "$IS_TEST_RUN_COMPLETED" -eq 0 ]; then
    echo "Skipping JUnit download — run did not complete within the wait window."
    return
  fi
  echo ""
  echo "Downloading JUnit report..."
  curl --progress-bar \
    -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
    -H "Accept: application/xml" \
    -H "content-type:application/json" \
    -X GET "$TESTSIGMA_JUNIT_REPORT_URL/$RUN_ID" \
    --output "$JUNIT_REPORT_FILE_PATH"
  echo "JUnit report -> $JUNIT_REPORT_FILE_PATH"
}

# ── Set exit code based on test result ─────────────────────────────
setExitCode() {
  RESULT=$(echo "$RUN_BODY" | getJsonValue result)
  case "$RESULT" in
    *SUCCESS*) EXITCODE=0 ;;
    *)         EXITCODE=1 ;;
  esac
  echo "Test Result: $RESULT  |  Exit code: $EXITCODE"
}

# ── Generate HTML report (template embedded — no external file needed) ──
generate_html_report() {
  if [ "$IS_TEST_RUN_COMPLETED" -eq 0 ]; then
    echo "Skipping HTML report — test run did not complete within wait window."
    return
  fi

  echo ""
  echo "Generating HTML report for Run ID: $RUN_ID ..."

  TEMP_V2=$(mktemp /tmp/testsigma_v2_XXXXXX.json)
  TEMP_TC=$(mktemp /tmp/testsigma_tc_XXXXXX.json)
  TEMP_ERR=$(mktemp /tmp/testsigma_err_XXXXXX.json)

  # 1. v2 run: counts + timing metadata
  curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
    -H "Accept: application/json" --silent \
    -o "$TEMP_V2" -X GET "$TESTSIGMA_V2_RUN_URL/${RUN_ID}"

  # 2. v1 nested: test case list with names
  curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
    -H "Accept: application/json" --silent \
    -o "$TEMP_TC" -X GET "$TESTSIGMA_V1_TC_RESULT_URL/${RUN_ID}/test_case_results"

  # 3. v1 bulk: error messages
  curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
    -H "Accept: application/json" --silent \
    -o "$TEMP_ERR" -X GET "$TESTSIGMA_V1_TC_BULK_URL?executionResultId=${RUN_ID}&page=0&size=200"

  # Build the HTML entirely in Python — template is embedded here
  python3 - "$TEMP_V2" "$TEMP_TC" "$TEMP_ERR" "$HTML_REPORT_FILE_PATH" << 'HEREDOC_PY'
import sys, json, re

v2_path     = sys.argv[1]
tc_path     = sys.argv[2]
err_path    = sys.argv[3]
output_path = sys.argv[4]

def load_json(path):
    try:
        with open(path, 'rb') as f:
            raw = f.read().strip()
        return json.loads(raw.decode('utf-8', errors='replace'), strict=False)
    except Exception as e:
        print("Warning: could not parse {}: {}".format(path, e), file=sys.stderr)
        return {}

v2_data  = load_json(v2_path)
tc_data  = load_json(tc_path)
err_data = load_json(err_path)

metrics = v2_data.get('metrics') or {}

error_map = {}
for tc in (err_data.get('content') or []):
    rid = tc.get('id')
    msg = (tc.get('message') or '').strip()
    if rid and msg and 'executed successfully' not in msg.lower():
        error_map[rid] = re.sub(r'<[^>]+>', '', msg)[:300]

cases = []
for tc in (tc_data.get('testCases') or []):
    cases.append({
        'testCaseName':  tc.get('testCaseName')  or '-',
        'testSuiteName': tc.get('testSuiteName') or '-',
        'machineName':   tc.get('machineTitle')  or '-',
        'result':        tc.get('result')        or '-',
        'errorMessage':  error_map.get(tc.get('testCaseResultId'), ''),
    })

total   = int(metrics.get('totalCount')       or len(cases))
passed  = int(metrics.get('passedCount')      or 0)
failed  = int(metrics.get('failedCount')      or 0)
stopped = int(metrics.get('stoppedCount')     or 0)
not_run = int(metrics.get('notExecutedCount') or 0)

# Derive counts from case list if API returned nulls
if total == 0 and cases:
    total   = len(cases)
    passed  = sum(1 for c in cases if c['result'].upper() == 'SUCCESS')
    failed  = sum(1 for c in cases if c['result'].upper() == 'FAILURE')
    stopped = sum(1 for c in cases if c['result'].upper() == 'STOPPED')
    not_run = sum(1 for c in cases if c['result'].upper() == 'NOT_EXECUTED')

result_raw = (metrics.get('result') or v2_data.get('result') or 'UNKNOWN').upper()
run_id     = str(v2_data.get('id') or tc_data.get('executionId') or '-')
build_no   = str(v2_data.get('buildNo') or '-')
start_time = str(v2_data.get('startTime') or '')
end_time   = str(v2_data.get('endTime')   or '')
duration   = metrics.get('duration')

def esc(s):
    return str(s).replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('"','&quot;')

def badge(result):
    r = result.upper()
    if r == 'SUCCESS':      return '<span class="badge passed">Passed</span>'
    if r == 'FAILURE':      return '<span class="badge failed">Failed</span>'
    if r == 'STOPPED':      return '<span class="badge stopped">Stopped</span>'
    if r == 'NOT_EXECUTED': return '<span class="badge notrun">Not Run</span>'
    return '<span class="badge notrun">' + esc(result) + '</span>'

def result_banner(r):
    if r == 'SUCCESS':
        return '<div class="banner success">&#10003;&nbsp; All tests passed successfully</div>'
    if r == 'FAILURE':
        return '<div class="banner failure">&#10007;&nbsp; {} test case(s) failed</div>'.format(failed)
    return '<div class="banner running">&#8635;&nbsp; Test run status: {}</div>'.format(esc(r))

def pct(v):
    return round(v * 100 / total, 1) if total > 0 else 0

def fmt_duration(ms):
    if ms is None: return '-'
    ms = int(ms)
    h = ms // 3600000
    m = (ms % 3600000) // 60000
    s = (ms % 60000) // 1000
    parts = []
    if h: parts.append('{}h'.format(h))
    if m: parts.append('{}m'.format(m))
    parts.append('{}s'.format(s))
    return ' '.join(parts)

rows = ''
for i, tc in enumerate(cases):
    err = esc(tc['errorMessage'])
    rows += (
        '<tr>'
        '<td class="tc-name">{}</td>'
        '<td>{}</td>'
        '<td class="machine">{}</td>'
        '<td>{}</td>'
        '<td class="err" title="{}">{}</td>'
        '</tr>'
    ).format(
        esc(tc['testCaseName']),
        esc(tc['testSuiteName']),
        esc(tc['machineName']),
        badge(tc['result']),
        err,
        err if err else '-'
    )

if not rows:
    rows = '<tr><td colspan="5" class="empty-row">No test case results available</td></tr>'

html = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Testsigma Report</title>
<style>
*,*::before,*::after{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f0f2f5;color:#1a1a2e;min-height:100vh}}
.header{{background:linear-gradient(135deg,#1a1a2e,#0f3460);color:#fff;padding:24px 40px;display:flex;align-items:center;justify-content:space-between;box-shadow:0 4px 20px rgba(0,0,0,.3)}}
.logo{{width:40px;height:40px;border-radius:10px;background:linear-gradient(135deg,#e94560,#0f3460);display:flex;align-items:center;justify-content:center;font-size:18px;font-weight:800;color:#fff;margin-right:14px}}
.header-left{{display:flex;align-items:center}}
.header h1{{font-size:20px;font-weight:700}}
.header p{{font-size:12px;color:rgba(255,255,255,.6);margin-top:2px}}
.header-meta{{text-align:right;font-size:11px;color:rgba(255,255,255,.55);line-height:1.8}}
.header-meta strong{{color:#fff;font-weight:600}}
.banner{{margin:20px 40px 0;padding:14px 20px;border-radius:10px;font-weight:700;font-size:14px}}
.banner.success{{background:#d1fae5;color:#065f46;border-left:4px solid #10b981}}
.banner.failure{{background:#fee2e2;color:#991b1b;border-left:4px solid #ef4444}}
.banner.running{{background:#ede9fe;color:#5b21b6;border-left:4px solid #7c3aed}}
.cards{{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:14px;padding:20px 40px 0}}
.card{{background:#fff;border-radius:12px;padding:18px 20px;box-shadow:0 2px 10px rgba(0,0,0,.07);border-top:4px solid transparent}}
.card.total  {{border-color:#6c63ff}}.card.passed {{border-color:#10b981}}
.card.failed {{border-color:#ef4444}}.card.stopped{{border-color:#f59e0b}}
.card.notrun {{border-color:#94a3b8}}
.card .lbl{{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.8px;color:#64748b;margin-bottom:6px}}
.card .val{{font-size:34px;font-weight:800;line-height:1}}
.card.total  .val{{color:#6c63ff}}.card.passed .val{{color:#10b981}}
.card.failed .val{{color:#ef4444}}.card.stopped .val{{color:#f59e0b}}
.card.notrun .val{{color:#94a3b8}}
.prog-wrap{{padding:16px 40px 0}}
.prog{{height:9px;border-radius:99px;background:#e2e8f0;overflow:hidden;display:flex}}
.prog span{{display:block;height:100%;transition:width .5s}}
.p-pass{{background:#10b981}}.p-fail{{background:#ef4444}}
.p-stop{{background:#f59e0b}}.p-nrun{{background:#cbd5e1}}
.legend{{display:flex;gap:16px;margin-top:7px;font-size:11px;color:#64748b;font-weight:500}}
.legend span{{display:flex;align-items:center;gap:4px}}
.dot{{width:8px;height:8px;border-radius:50%;display:inline-block}}
.meta{{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px;padding:16px 40px 0}}
.meta-card{{background:#fff;border-radius:10px;padding:12px 16px;box-shadow:0 1px 5px rgba(0,0,0,.06);display:flex;align-items:center;gap:10px}}
.meta-icon{{width:34px;height:34px;border-radius:8px;background:#f1f5f9;display:flex;align-items:center;justify-content:center;font-size:16px;flex-shrink:0}}
.meta-lbl{{font-size:10px;color:#94a3b8;font-weight:600;text-transform:uppercase;letter-spacing:.5px}}
.meta-val{{font-size:13px;font-weight:600;color:#1e293b;margin-top:2px;word-break:break-all}}
.sec-hdr{{padding:20px 40px 10px;font-size:14px;font-weight:700;color:#1e293b}}
.tbl-wrap{{padding:0 40px 40px;overflow-x:auto}}
table{{width:100%;border-collapse:collapse;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 2px 10px rgba(0,0,0,.07);font-size:12px}}
thead tr{{background:#f8fafc}}
th{{padding:11px 14px;text-align:left;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.7px;color:#64748b;border-bottom:2px solid #e2e8f0}}
td{{padding:11px 14px;border-bottom:1px solid #f1f5f9;color:#374151;vertical-align:middle}}
tbody tr:last-child td{{border-bottom:none}}
tbody tr:hover{{background:#fafbfc}}
td.tc-name{{font-weight:600;color:#1e293b}}
td.machine{{color:#64748b;font-size:11px}}
td.err{{color:#ef4444;font-size:11px;max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
.empty-row{{text-align:center;padding:40px;color:#94a3b8}}
.badge{{display:inline-flex;align-items:center;padding:3px 9px;border-radius:99px;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px}}
.badge.passed {{background:#d1fae5;color:#065f46}}
.badge.failed {{background:#fee2e2;color:#991b1b}}
.badge.stopped{{background:#fef3c7;color:#92400e}}
.badge.notrun {{background:#f1f5f9;color:#475569}}
.footer{{text-align:center;padding:18px;font-size:11px;color:#94a3b8}}
</style>
</head>
<body>
<div class="header">
  <div class="header-left">
    <div class="logo">TS</div>
    <div><h1>Test Run Report</h1><p>Testsigma Automated Execution</p></div>
  </div>
  <div class="header-meta">
    <div>Run ID: <strong>{run_id}</strong></div>
    <div>Build: <strong>{build_no}</strong></div>
    <div>Generated: <strong>{generated}</strong></div>
  </div>
</div>
{banner}
<div class="cards">
  <div class="card total"> <div class="lbl">Total</div>  <div class="val">{total}</div>  </div>
  <div class="card passed"><div class="lbl">Passed</div> <div class="val">{passed}</div> </div>
  <div class="card failed"><div class="lbl">Failed</div> <div class="val">{failed}</div> </div>
  <div class="card stopped"><div class="lbl">Stopped</div><div class="val">{stopped}</div></div>
  <div class="card notrun"><div class="lbl">Not Run</div><div class="val">{not_run}</div></div>
</div>
<div class="prog-wrap">
  <div class="prog">
    <span class="p-pass" style="width:{pct_pass}%"></span>
    <span class="p-fail" style="width:{pct_fail}%"></span>
    <span class="p-stop" style="width:{pct_stop}%"></span>
    <span class="p-nrun" style="width:{pct_nrun}%"></span>
  </div>
  <div class="legend">
    <span><i class="dot" style="background:#10b981"></i> Passed {pct_pass}%</span>
    <span><i class="dot" style="background:#ef4444"></i> Failed {pct_fail}%</span>
    <span><i class="dot" style="background:#f59e0b"></i> Stopped {pct_stop}%</span>
    <span><i class="dot" style="background:#cbd5e1"></i> Not Run {pct_nrun}%</span>
  </div>
</div>
<div class="meta">
  <div class="meta-card"><div class="meta-icon">&#128197;</div><div><div class="meta-lbl">Start Time</div><div class="meta-val">{start_time}</div></div></div>
  <div class="meta-card"><div class="meta-icon">&#127937;</div><div><div class="meta-lbl">End Time</div><div class="meta-val">{end_time}</div></div></div>
  <div class="meta-card"><div class="meta-icon">&#9201;</div><div><div class="meta-lbl">Duration</div><div class="meta-val">{duration}</div></div></div>
  <div class="meta-card"><div class="meta-icon">&#128221;</div><div><div class="meta-lbl">Total Cases</div><div class="meta-val">{total}</div></div></div>
</div>
<div class="sec-hdr">Test Case Results ({case_count} cases)</div>
<div class="tbl-wrap">
  <table>
    <thead><tr><th>Test Case</th><th>Suite</th><th>Machine</th><th>Result</th><th>Error Message</th></tr></thead>
    <tbody>{rows}</tbody>
  </table>
</div>
<div class="footer">Generated by Testsigma CI/CD Script</div>
</body>
</html>'''.format(
    run_id=esc(run_id),
    build_no=esc(build_no),
    generated=__import__('datetime').datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    banner=result_banner(result_raw),
    total=total, passed=passed, failed=failed, stopped=stopped, not_run=not_run,
    pct_pass=pct(passed), pct_fail=pct(failed), pct_stop=pct(stopped), pct_nrun=pct(not_run),
    start_time=esc(start_time), end_time=esc(end_time),
    duration=esc(fmt_duration(duration)),
    case_count=len(cases),
    rows=rows
)

with open(output_path, 'w', encoding='utf-8') as f:
    f.write(html)

print("HTML report -> {} [total={} passed={} failed={} stopped={} notRun={} cases={}]".format(
    output_path, total, passed, failed, stopped, not_run, len(cases)))
HEREDOC_PY

  PYEXIT=$?
  rm -f "$TEMP_V2" "$TEMP_TC" "$TEMP_ERR"

  if [ "$PYEXIT" -ne 0 ]; then
    echo "Error: HTML report generation failed (exit $PYEXIT)."
  else
    echo "HTML report saved -> $HTML_REPORT_FILE_PATH"
  fi
}

# ══════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════

echo "************ Testsigma: Start executing automated tests ************"

populateJsonPayload

# ── Guard: prevent duplicate runs on Buildkite Retry ───────────────
echo "Checking for an existing active run for plan $TESTSIGMA_TEST_PLAN_ID ..."

LAST_RUN_RESPONSE=$(curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
  -H "Accept: application/json" --silent \
  -X GET "${TESTSIGMA_LAST_RUN_URL}/${TESTSIGMA_TEST_PLAN_ID}/test_plan_results?page=0&size=1&sortBy=id&direction=DESC")

LAST_RUN_ID=$(echo "$LAST_RUN_RESPONSE" | getJsonValue id     | head -1)
LAST_STATUS=$(echo "$LAST_RUN_RESPONSE" | getJsonValue status | head -1)

REUSING_RUN=0
case "$LAST_STATUS" in
  *STATUS_CREATED*|*STATUS_IN_PROGRESS*)
    echo "Active run found (ID: $LAST_RUN_ID, Status: $LAST_STATUS) — reusing it."
    RUN_ID="$LAST_RUN_ID"
    REUSING_RUN=1
    ;;
  *)
    echo "No active run found (last status: ${LAST_STATUS:-none}). Triggering new run..."
    ;;
esac

# ── Trigger new run only when no active run exists ─────────────────
EXITCODE=0
if [ "$REUSING_RUN" -eq 0 ]; then
  HTTP_RESPONSE=$(curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
    -H "Accept: application/json" \
    -H "content-type:application/json" \
    --silent --write-out "HTTPSTATUS:%{http_code}" \
    -d "$JSON_DATA" -X POST "$TESTSIGMA_TEST_PLAN_REST_URL")

  HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -e 's/HTTPSTATUS\:.*//g')
  RUN_ID=$(echo "$HTTP_RESPONSE" | getJsonValue id)
  HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

  if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "Failed to start Test Plan execution! HTTP status: $HTTP_STATUS"
    echo "$HTTP_RESPONSE"
    exit 1
  fi
fi

case "$RUN_ID" in
  [0-9]*) echo "Run ID: $RUN_ID" ;;
  *)      echo "Could not determine Run ID. Response: $RUN_ID"; exit 1 ;;
esac

echo "Number of maximum polls to be done: $POLL_COUNT"
echo "Poll interval: ${SLEEP_TIME}s  |  Max wait: ${MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT} minutes"

# ── Poll → Save → Report ───────────────────────────────────────────
checkTestPlanRunStatus
saveFinalResponseToJUnitFile
saveFinalResponseToJSONFile
generate_html_report
setExitCode

# ── Final exit — after all files are written ───────────────────────
echo "************************************************"
if [ "$IS_TEST_RUN_COMPLETED" -eq 0 ]; then
  echo "$MAX_WAITTIME_EXCEEDED_ERRORMSG"
  echo "Exiting with failure — run did not complete within ${MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT} minutes."
  exit 1
fi

echo "Result: $RESULT"
echo "************ Testsigma: Completed executing automated tests ************"
exit $EXITCODE
