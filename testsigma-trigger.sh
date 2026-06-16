#!/bin/bash
#**********************************************************************
#
# TESTSIGMA_API_KEY                -> API key from Testsigma App >> Configuration >> API Keys
# TESTSIGMA_TEST_PLAN_ID           -> Test Plan ID from Test Plans >> <PLAN> >> CI/CD Integration
# MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT -> Max minutes to wait for run completion
# JUNIT_REPORT_FILE_PATH           -> Path to save JUnit XML report
# HTML_REPORT_FILE_PATH            -> Path to save HTML report
# HTML_TEMPLATE_PATH               -> Path to testsigma_report_template.html (keep alongside script)
# RUNTIME_DATA_INPUT               -> Comma-separated key=value runtime variables (optional)
# BUILD_NO                         -> Build number to track in Testsigma (optional)
#
#********START USER_INPUTS*********
TESTSIGMA_API_KEY=eyJhbGciOiJIUzUxMiJ9.eyJzdWIiOiI4MTIxYzNlZS02YjdmLTRlYTItYmJkZC0yMzUwZGE4Nzk2MjEiLCJkb21haW4iOiJ0ZXN0c2lnbWF0ZWNoLmNvbSIsInRlbmFudElkIjoyODE3LCJpc0lkbGVUaW1lb3V0Q29uZmlndXJlZCI6ZmFsc2V9.JkZiqElfo8vC4qLHvjWB2Dq0BoIWncE9GDvJDZGd14bNDODVdnPCYWiHKj9cShlWUcslZ1ep45ghl1YRvW5_Hw
TESTSIGMA_TEST_PLAN_ID=61596
MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT=45
JUNIT_REPORT_FILE_PATH=./junit-report.xml
HTML_REPORT_FILE_PATH=./testsigma-report.html
HTML_TEMPLATE_PATH="$(dirname "$0")/testsigma_report_template.html"
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
    --htmltemplate=*)        HTML_TEMPLATE_PATH="${i#*=}"              ;;
    -h|--help)
      echo "Arguments:"
      echo "  [-k | --apikey]         = <TESTSIGMA_API_KEY>"
      echo "  [-i | --testplanid]     = <TESTSIGMA_TEST_PLAN_ID>"
      echo "  [-t | --maxtimeinmins]  = <MAX_WAIT_TIME_IN_MINS>"
      echo "  [-r | --reportfilepath] = <JUNIT_REPORT_FILE_PATH>"
      echo "  [-d | --runtimedata]    = <COMMA SEPARATED KEY=VALUE>"
      echo "  [-b | --buildno]        = <BUILD_NO>"
      echo "         --htmlreport     = <HTML_REPORT_FILE_PATH>"
      echo "         --htmltemplate   = <HTML_TEMPLATE_PATH>"
      printf "\nExample:\n  bash testsigma-trigger.sh --apikey=YOUR_KEY --testplanid=61596 --maxtimeinmins=45\n\n"
      exit 0
      ;;
  esac
done

# Calculated AFTER CLI args so --maxtimeinmins overrides are honoured
SLEEP_TIME=$(( (MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT * 60) / POLL_COUNT ))
MAX_WAITTIME_EXCEEDED_ERRORMSG="Given Maximum Wait Time of $MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT minutes exceeded. Please log in to Testsigma to check results."

# ── Extract a JSON value by key (first match) ──────────────────────
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

# ── Generate HTML report ────────────────────────────────────────────
generate_html_report() {
  if [ "$IS_TEST_RUN_COMPLETED" -eq 0 ]; then
    echo "Skipping HTML report — test run did not complete within wait window."
    return
  fi
  if [ ! -f "$HTML_TEMPLATE_PATH" ]; then
    echo "Error: HTML template not found at '$HTML_TEMPLATE_PATH'."
    echo "  Ensure testsigma_report_template.html is in the same folder as this script."
    return
  fi

  echo ""
  echo "Generating HTML report for Run ID: $RUN_ID ..."

  TEMP_V2=$(mktemp /tmp/testsigma_v2_XXXXXX.json)
  TEMP_TC=$(mktemp /tmp/testsigma_tc_XXXXXX.json)
  TEMP_ERR=$(mktemp /tmp/testsigma_err_XXXXXX.json)

  # 1. v2 run: counts + timing metadata (always populated on v2)
  curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
    -H "Accept: application/json" --silent \
    -o "$TEMP_V2" -X GET "$TESTSIGMA_V2_RUN_URL/${RUN_ID}"

  # 2. v1 nested: test case list with names and suite info
  curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
    -H "Accept: application/json" --silent \
    -o "$TEMP_TC" -X GET "$TESTSIGMA_V1_TC_RESULT_URL/${RUN_ID}/test_case_results"

  # 3. v1 bulk: error messages per test case
  curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
    -H "Accept: application/json" --silent \
    -o "$TEMP_ERR" -X GET "$TESTSIGMA_V1_TC_BULK_URL?executionResultId=${RUN_ID}&page=0&size=200"

  python3 - "$HTML_TEMPLATE_PATH" "$TEMP_V2" "$TEMP_TC" \
            "$TEMP_ERR" "$HTML_REPORT_FILE_PATH" << 'HEREDOC_PY'
import sys, json, re

template_path = sys.argv[1]
v2_path       = sys.argv[2]
tc_path       = sys.argv[3]
err_path      = sys.argv[4]
output_path   = sys.argv[5]

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

# Error message lookup by testCaseResultId
error_map = {}
for tc in (err_data.get('content') or []):
    rid = tc.get('id')
    msg = (tc.get('message') or '').strip()
    if rid and msg and 'executed successfully' not in msg.lower():
        error_map[rid] = re.sub(r'<[^>]+>', '', msg)[:300]

# Build test case list
cases = []
for tc in (tc_data.get('testCases') or []):
    cases.append({
        'testCaseName':  tc.get('testCaseName')  or '-',
        'testSuiteName': tc.get('testSuiteName') or '-',
        'machineName':   tc.get('machineTitle')  or '-',
        'result':        tc.get('result')        or '-',
        'errorMessage':  error_map.get(tc.get('testCaseResultId'), ''),
    })

merged = {
    'id':               v2_data.get('id'),
    'executionName':    'Execution #' + str(tc_data.get('executionId', '-')),
    'buildNo':          v2_data.get('buildNo'),
    'result':           (metrics.get('result') or v2_data.get('result') or '-').upper(),
    'startTime':        v2_data.get('startTime'),
    'endTime':          v2_data.get('endTime'),
    'duration':         metrics.get('duration'),
    'environmentId':    v2_data.get('environmentId'),
    'totalCount':       metrics.get('totalCount',       len(cases)),
    'passedCount':      metrics.get('passedCount',      0),
    'failedCount':      metrics.get('failedCount',      0),
    'stoppedCount':     metrics.get('stoppedCount',     0),
    'notExecutedCount': metrics.get('notExecutedCount', 0),
    'testCaseResults':  cases,
}

js_object = json.dumps(merged, ensure_ascii=False).replace('</script>', '<\\/script>')

with open(template_path, 'r', encoding='utf-8') as f:
    html = f.read()

html = re.sub(r'/\*TESTSIGMA_JSON_PLACEHOLDER\*/null/\*END_PLACEHOLDER\*/', js_object, html)

with open(output_path, 'w', encoding='utf-8') as f:
    f.write(html)

c = merged
print("HTML report -> {}  [total={} passed={} failed={} stopped={} notRun={}]  testCases={}".format(
    output_path,
    c['totalCount'], c['passedCount'], c['failedCount'],
    c['stoppedCount'], c['notExecutedCount'], len(cases)))
HEREDOC_PY

  PYEXIT=$?
  rm -f "$TEMP_V2" "$TEMP_TC" "$TEMP_ERR"

  if [ "$PYEXIT" -ne 0 ]; then
    echo "Error: Python step failed (exit $PYEXIT). HTML report was not created."
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
# Before POSTing a new run, check if a run for this plan is already
# QUEUED or IN_PROGRESS. If so, reuse that run ID instead of creating
# a duplicate. This means clicking Retry in Buildkite will safely
# attach to the existing Testsigma execution rather than starting a new one.
echo "Checking for an existing active run for plan $TESTSIGMA_TEST_PLAN_ID ..."

LAST_RUN_RESPONSE=$(curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
  -H "Accept: application/json" --silent \
  -X GET "${TESTSIGMA_LAST_RUN_URL}/${TESTSIGMA_TEST_PLAN_ID}/test_plan_results?page=0&size=1&sortBy=id&direction=DESC")

LAST_RUN_ID=$(echo "$LAST_RUN_RESPONSE" | getJsonValue id    | head -1)
LAST_STATUS=$(echo "$LAST_RUN_RESPONSE" | getJsonValue status | head -1)

REUSING_RUN=0
case "$LAST_STATUS" in
  *STATUS_CREATED*|*STATUS_IN_PROGRESS*)
    echo "Active run found (ID: $LAST_RUN_ID, Status: $LAST_STATUS) — reusing instead of triggering a new one."
    RUN_ID="$LAST_RUN_ID"
    REUSING_RUN=1
    ;;
  *)
    echo "No active run found (last status: ${LAST_STATUS:-none}). Triggering a new run..."
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

# ── Final exit — after all files written ───────────────────────────
echo "************************************************"
if [ "$IS_TEST_RUN_COMPLETED" -eq 0 ]; then
  echo "$MAX_WAITTIME_EXCEEDED_ERRORMSG"
  echo "Exiting with failure — run did not complete within ${MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT} minutes."
  exit 1
fi

echo "Result: $RESULT"
echo "************ Testsigma: Completed executing automated tests ************"
exit $EXITCODE
