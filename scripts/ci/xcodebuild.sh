#!/usr/bin/env bash
# Runs xcodebuild with a readable job log and the complete raw log on disk.
#
#   scripts/ci/xcodebuild.sh <log-name> <xcodebuild arguments...>
#
# The raw output goes to $XCODEBUILD_LOG_DIR/<log-name>.log (default
# build/logs, relative to the working directory) so CI can upload it. The job
# log shows xcbeautify's condensed output when xcbeautify is installed. When
# the build fails, every compiler error is printed again from the raw log, so
# a failure can be diagnosed from the job log alone. For a failed test run
# that also means: the failed tests of the result bundle, and the crash
# reports written while it ran (a crashed app otherwise only shows up as
# "Restarting after unexpected exit"). A test run that passed ends with its
# counts, so skipped tests do not go unnoticed.
set -uo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <log-name> <xcodebuild arguments...>" >&2
    exit 64
fi

name="$1"
shift

log_dir="${XCODEBUILD_LOG_DIR:-build/logs}"
mkdir -p "$log_dir"
log="$log_dir/$name.log"

# Pick the formatter up front and test-run it: a formatter that rejects a flag
# must never be the reason a build is reported as failed (or as passed).
formatter=(cat)
if command -v xcbeautify >/dev/null 2>&1; then
    if [ -n "${GITHUB_ACTIONS:-}" ] && echo "" | xcbeautify --renderer github-actions >/dev/null 2>&1; then
        formatter=(xcbeautify --renderer github-actions)
    elif echo "" | xcbeautify >/dev/null 2>&1; then
        formatter=(xcbeautify)
    fi
fi

# The result bundle, if this invocation writes one.
result_bundle=""
previous=""
for argument in "$@"; do
    if [ "$previous" = "-resultBundlePath" ]; then result_bundle="$argument"; fi
    previous="$argument"
done
started_at="$(date +%s)"

# Counts (and failures) of the result bundle. Xcode 16+; older Xcodes do not
# know the subcommand, then nothing is printed.
test_summary() {
    xcrun xcresulttool get test-results summary --path "$result_bundle" 2>/dev/null \
        | python3 -c '
import json, sys
try:
    summary = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for key in ("result", "totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"):
    if key in summary:
        print(f"  {key}: {summary[key]}")
for failure in summary.get("testFailures", [])[:60]:
    name = failure.get("testIdentifierString") or failure.get("testName", "?")
    text = " ".join(str(failure.get("failureText", "")).split())
    print(f"  FAILED {name}: {text[:600]}")
' || true
}

echo "+ xcodebuild $*"
xcodebuild "$@" 2>&1 | tee "$log" | "${formatter[@]}"
status="${PIPESTATUS[0]}"

if [ "$status" -ne 0 ]; then
    echo ""
    echo "xcodebuild exited with status $status. Errors from the raw log ($log):"
    echo "------------------------------------------------------------------------"
    grep -E -A4 '(error|[Ff]atal error): |\*\* [A-Z ]+ FAILED \*\*|^Testing failed:|^The following build commands failed:|^xcodebuild: error|Terminating app due to uncaught exception|required condition is false|Thread [0-9]+: (signal|EXC_)|[Cc]rash(ed)?:' "$log" \
        | tail -n 300 || echo "(no error lines found; see the uploaded raw log)"
    echo "------------------------------------------------------------------------"
    if grep -q 'UI-HIERARCHY| ' "$log"; then
        # Printed by the UI tests when an assertion fails (JellyampUITestCase).
        echo "What was on screen when the UI tests failed:"
        grep -o 'UI-HIERARCHY| .*' "$log" | cut -c1-400 | tail -n 4000
        echo "------------------------------------------------------------------------"
    fi
    if [ -n "$result_bundle" ] && [ -d "$result_bundle" ]; then
        echo "Test summary of $result_bundle:"
        test_summary
        echo "------------------------------------------------------------------------"
    fi
    python3 "$(dirname "$0")/print-crash-reports.py" --since "$started_at" || true
    echo "------------------------------------------------------------------------"
fi

if [ "$status" -eq 0 ] && [ -n "$result_bundle" ] && [ -d "$result_bundle" ]; then
    # Also for a green run: tests that skipped themselves (no audio output on
    # the machine, wrong device family) must be visible, not assumed away.
    echo "Test summary of $result_bundle:"
    test_summary
fi

exit "$status"
