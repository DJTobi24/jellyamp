#!/usr/bin/env bash
# Runs xcodebuild with a readable job log and the complete raw log on disk.
#
#   scripts/ci/xcodebuild.sh <log-name> <xcodebuild arguments...>
#
# The raw output goes to $XCODEBUILD_LOG_DIR/<log-name>.log (default
# build/logs, relative to the working directory) so CI can upload it. The job
# log shows xcbeautify's condensed output when xcbeautify is installed. When
# the build fails, every compiler error is printed again from the raw log, so
# a failure can be diagnosed from the job log alone.
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

echo "+ xcodebuild $*"
xcodebuild "$@" 2>&1 | tee "$log" | "${formatter[@]}"
status="${PIPESTATUS[0]}"

if [ "$status" -ne 0 ]; then
    echo ""
    echo "xcodebuild exited with status $status. Errors from the raw log ($log):"
    echo "------------------------------------------------------------------------"
    grep -E -A4 '(error|fatal error): |\*\* [A-Z ]+ FAILED \*\*|^Testing failed:|^The following build commands failed:|^xcodebuild: error' "$log" \
        | tail -n 300 || echo "(no error lines found; see the uploaded raw log)"
    echo "------------------------------------------------------------------------"
fi

exit "$status"
