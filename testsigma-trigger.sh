#!/bin/bash
#**********************************************************************
#
# TESTSIGMA_API_KEY      -> API key from Testsigma App >> Configuration >> API Keys
# TESTSIGMA_TEST_PLAN_ID -> Test Plan ID from Test Plans >> <PLAN> >> CI/CD Integration
# MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT -> Max minutes to wait for run completion
# JUNIT_REPORT_FILE_PATH -> Path to save JUnit XML report
# HTML_REPORT_FILE_PATH  -> Path to save HTML report
# HTML_TEMPLATE_PATH     -> Path to testsigma_report_template.html (keep alongside script)
# RUNTIME_DATA_INPUT     -> Comma-separated key=value runtime variables (optional)
# BUILD_NO               -> Build number to track in Testsigma (optional)
#
#********START USER_INPUTS*********
TESTSIGMA_API_KEY=eyJhbGciOiJIUzUxMiJ9.eyJzdWIiOiI4MTIxYzNlZS02YjdmLTRlYTItYmJkZC0yMzUwZGE4Nzk2MjEiLCJkb21haW4iOiJ0ZXN0c2lnbWF0ZWNoLmNvbSIsInRlbmFudElkIjoyODE3LCJpc0lkbGVUaW1lb3V0Q29uZmlndXJlZCI6ZmFsc2V9.JkZiqElfo8vC4qLHvjWB2Dq0BoIWncE9GDvJDZGd14bNDODVdnPCYWiHKj9cShlWUcslZ1ep45ghl1YRvW5_Hw
TESTSIGMA_TEST_PLAN_ID=61596
# FIX 2 (was 5): Increased to 45 minutes so multi-suite plans have enough time to complete
MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT=45
JUNIT_REPORT_FILE_PATH=./junit-report.xml
HTML_REPORT_FILE_PATH=./testsigma-report.html
HTML_TEMPLATE_PATH="$(dirname "$0")/testsigma_report_template.html"
RUNTIME_DATA_INPUT="url=https://the-internet.herokuapp.com/login,test=1221"
BUILD_NO=$(date +"%Y%m%d%H%M")
#********END USER_INPUTS***********

#********GLOBAL variables**********
POLL_COUNT=30
# NOTE: SLEEP_TIME is NOT calculated here.
# FIX 3: Moved SLEEP_TIME calculation to AFTER CLI argument parsing so that
#         --maxtimeinmins passed via command line is correctly reflected in
#         the sleep interval. Previously it was calculated before arg parsing,
#         so --maxtimeinmins had no effect on poll frequency.
JSON_REPORT_FILE_PATH=./testsigma.json
TESTSIGMA_TEST_PLAN_REST_URL=https://app.testsigma.com/api/v1/execution_results
TESTSIGMA_JUNIT_REPORT_URL=https://app.testsigma.com/api/v1/reports/junit
TESTSIGMA_V2_RUN_URL=https://app.testsigma.com/api/v2/test_runs
TESTSIGMA_V1_TC_RESULT_URL=https://app.testsigma.com/api/v1/execution_results
TESTSIGMA_V1_TC_BULK_URL=https://app.testsigma.com/api/v1/test_case_results
#**********************************

# Read CLI arguments
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
      printf "\nExample:\n  bash testsigma-trigger.sh --apikey=YOUR_KEY --testplanid=230 --maxtimeinmins=60\n\n"
      exit 1
      ;;
  esac
done

# FIX 3: SLEEP_TIME and error message now calculated AFTER CLI args are parsed
SLEEP_TIME=$(( (MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT * 60) / POLL_COUNT ))
MAX_WAITTIME_EXCEEDED_ERRORMSG="Given Maximum Wait Time of $MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT minutes exceeded. Please log in to Testsigma to check results."

# ── Extract a JSON value by key (first match) ──────────────────────
getJsonValue() {
  json_key=$1
  awk -F"[,:}]" '{for(i=1;i<=NF;i++){if($i~/\042'"$json_key"'\042/){print $(i+1)}}}' | tr -d '"'
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
  DATA_VALUES="${DATA_VALUES#,}"   # strip leading comma
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
  RUN_STATUS=$(echo "$RUN_RESPONSE" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
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
        echo "Unexpected status '$EXECUTION_STATUS'. Check run results for details."
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
  echo "$RUN_BODY" >> "$JSON_REPORT_FILE_PATH"
  echo "Saved JSON response -> $JSON_REPORT_FILE_PATH"
}

# ── Download JUnit XML report ───────────────────────────────────────
# FIX 4: Changed "exit 1" to "return" so the script continues to write
#         testsigma.json and testsigma-report.html even when the wait
#         window is exceeded. Previously the premature exit meant Buildkite
#         had zero files to upload as artifacts.
#         The actual "exit 1" now happens at the bottom of the script,
#         after all file-save functions have completed.
saveFinalResponseToJUnitFile() {
  if [ "$IS_TEST_RUN_COMPLETED" -eq 0 ]; then
    echo "$MAX_WAITTIME_EXCEEDED_ERRORMSG"
    echo "Skipping JUnit download — run did not complete within the wait window."
    return   # was: exit 1
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

# ── Set exit code from result ───────────────────────────────────────
setExitCode() {
  RESULT=$(echo "$RUN_BODY" | getJsonValue result)
  case "$RESULT" in
    *SUCCESS*) EXITCODE=0 ;;
    *)         EXITCODE=1 ;;
  esac
  echo "Exit code: $EXITCODE"
}

# ── Generate HTML report ────────────────────────────────────────────
#
#  Uses these global URL variables:
#
#  $TESTSIGMA_V2_RUN_URL/{RUN_ID}
#    GET /api/v2/test_runs/{RUN_ID}
#    -> metrics.{totalCount, passedCount, failedCount,
#               stoppedCount, notExecutedCount, duration}
#    -> startTime, endTime (ISO strings), buildNo
#    Always populated in v2; single call, no pagination needed.
#
#  $TESTSIGMA_V1_TC_RESULT_URL/{RUN_ID}/test_case_results
#    GET /api/v1/execution_results/{RUN_ID}/test_case_results
#    -> testCases[].{testCaseName, testSuiteName, machineTitle,
#                    result, testCaseResultId}
#    Only this nested v1 route returns names inline.
#
#  $TESTSIGMA_V1_TC_BULK_URL?executionResultId={RUN_ID}
#    GET /api/v1/test_case_results?executionResultId={RUN_ID}
#    -> content[].{id, message}
#    Matched onto test cases by testCaseResultId = id.
#    Written via curl -o (not shell var) to avoid corruption
#    from control characters in Testsigma error message strings.
# ───────────────────────────────────────────────────────────────────
generate_html_report() {
  if [ "$IS_TEST_RUN_COMPLETED" -eq 0 ]; then
    echo "Skipping HTML report — test run did not complete within wait window."
    return
  fi
  if [ ! -f "$HTML_TEMPLATE_PATH" ]; then
    echo "Error: HTML template not found at '$HTML_TEMPLATE_PATH'."
    echo "  Place testsigma_report_template.html alongside this script."
    return
  fi

  echo ""
  echo "Generating HTML report for Run ID: $RUN_ID ..."

  TEMP_V2=$(mktemp /tmp/testsigma_v2_XXXXXX.json)
  TEMP_TC=$(mktemp /tmp/testsigma_tc_XXXXXX.json)
  TEMP_ERR=$(mktemp /tmp/testsigma_err_XXXXXX.json)

  # 1. v2: counts + metadata
  curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
    -H "Accept: application/json" --silent \
    -o "$TEMP_V2" -X GET "$TESTSIGMA_V2_RUN_URL/${RUN_ID}"

  # 2. v1 nested: test case list with names
  curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
    -H "Accept: application/json" --silent \
    -o "$TEMP_TC" -X GET "$TESTSIGMA_V1_TC_RESULT_URL/${RUN_ID}/test_case_results"

  # 3. v1 bulk: error messages (curl -o avoids control-char shell corruption)
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
        # strict=False handles unescaped control chars in Testsigma error messages
        return json.loads(raw.decode('utf-8', errors='replace'), strict=False)
    except Exception as e:
        print("Warning: could not parse {}: {}".format(path, e), file=sys.stderr)
        return {}

v2_data  = load_json(v2_path)   # /api/v2/test_runs/{id}
tc_data  = load_json(tc_path)   # /api/v1/execution_results/{id}/test_case_results
err_data = load_json(err_path)  # /api/v1/test_case_results?executionResultId={id}

# Counts from v2 metrics — always populated on the v2 endpoint
metrics = v2_data.get('metrics') or {}

# Error message lookup: testCaseResultId -> cleaned message
error_map = {}
for tc in (err_data.get('content') or []):
    rid = tc.get('id')
    msg = (tc.get('message') or '').strip()
    if rid and msg and 'executed successfully' not in msg.lower():
        error_map[rid] = re.sub(r'<[^>]+>', '', msg)[:300]

# Test case list — names come from v1 nested route
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
    'result':           (metrics.get('result') or '-').upper(),
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
    echo "HTML Report saved -> $HTML_REPORT_FILE_PATH"
  fi
}

#******************************************************

echo "************ Testsigma: Start executing automated tests ************"

populateJsonPayload

# Trigger the test plan run
HTTP_RESPONSE=$(curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
  -H "Accept: application/json" \
  -H "content-type:application/json" \
  --silent --write-out "HTTPSTATUS:%{http_code}" \
  -d "$JSON_DATA" -X POST "$TESTSIGMA_TEST_PLAN_REST_URL")

HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -e 's/HTTPSTATUS\:.*//g')
RUN_ID=$(echo "$HTTP_RESPONSE" | getJsonValue id)
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

case "$RUN_ID" in
  [0-9]*) echo "Run ID: $RUN_ID" ;;
  *)      echo "$RUN_ID" ;;
esac

EXITCODE=0
if [ "$HTTP_STATUS" -ne 200 ]; then
  echo "Failed to start Test Plan execution!"
  echo "$HTTP_RESPONSE"
  EXITCODE=1
else
  echo "Number of maximum polls to be done: $POLL_COUNT"
  checkTestPlanRunStatus

  # FIX 4 (cont): All three save/report functions always run regardless of
  # timeout, so Buildkite always has files to upload as artifacts.
  saveFinalResponseToJUnitFile
  saveFinalResponseToJSONFile
  generate_html_report
  setExitCode

  # FIX 4 (cont): Single controlled exit point — after all files are written.
  # Exits 1 on timeout so Buildkite marks the build failed, but artifacts exist.
  if [ "$IS_TEST_RUN_COMPLETED" -eq 0 ]; then
    echo "Exiting with failure — run did not complete within ${MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT} minutes."
    exit 1
  fi
fi

echo "************************************************"
echo "Result JSON Response: $RUN_BODY"
echo "************ Testsigma: Completed executing automated tests ************"
exit $EXITCODE
