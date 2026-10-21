#!/bin/sh
# Test-only Release capture. Never launches the Herm application.
set -eu
umask 077
[ "$#" -eq 1 ] || { printf '%s\n' 'usage: sh Scripts/capture-scroll-performance.sh /absolute/new-output-directory' >&2; exit 2; }
case "${HERM_SCROLL_PERF_PROFILE:-0}" in 0|1) ;; *) printf '%s\n' 'HERM_SCROLL_PERF_PROFILE must be 0 or 1' >&2; exit 2 ;; esac
OUT=$1
case "$OUT" in /*) ;; *) printf '%s\n' 'usage: sh Scripts/capture-scroll-performance.sh /absolute/new-output-directory' >&2; exit 2 ;; esac
if [ -e "$OUT" ] || [ -L "$OUT" ]; then
    printf '%s\n' 'output must not already exist (retains prior captures)' >&2
    exit 2
fi
mkdir -p "$(dirname "$OUT")"
mkdir "$OUT"
OUT=$(cd "$OUT" && pwd -P)
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
cd "$ROOT"
{
    printf 'command: HERM_SCROLL_PERF_PROFILE=%s sh Scripts/capture-scroll-performance.sh "%s"\n' "${HERM_SCROLL_PERF_PROFILE:-0}" "$OUT"
    printf 'profile: %s\n' "${HERM_SCROLL_PERF_PROFILE:-0}"
    git rev-parse HEAD
    git status --short
    sw_vers
    uname -m
    sysctl -n machdep.cpu.brand_string
    swift --version
    uptime
} > "$OUT/environment.txt" 2>&1
# Each command gets its own process group; timeout/interrupt cleans up only that group.
bounded() {
    /usr/bin/perl -MPOSIX -e '
        my $seconds = shift @ARGV;
        my $pid = fork();
        defined($pid) or die "fork: $!";
        if (!$pid) { POSIX::setpgid(0, 0); exec @ARGV; exit 127; }
        POSIX::setpgid($pid, $pid);
        my $stop = sub {
            kill "TERM", -$pid;
            sleep 2;
            kill "KILL", -$pid;
            waitpid($pid, 0);
            exit 124;
        };
        $SIG{ALRM} = $stop;
        $SIG{TERM} = $stop;
        $SIG{INT} = $stop;
        alarm $seconds;
        waitpid($pid, 0);
        my $status = $?;
        alarm 0;
        kill "TERM", -$pid;
        sleep 1;
        kill "KILL", -$pid;
        exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
    ' "$@"
}
build_result=0
bounded 1200 swift build -c release --build-tests --disable-automatic-resolution -Xswiftc -no-whole-module-optimization -Xswiftc -enable-testing > "$OUT/build.txt" 2>&1 || build_result=$?
printf 'build exit: %s\n' "$build_result" > "$OUT/build-status.txt"
[ "$build_result" -eq 0 ] || exit "$build_result"
(
    bounded 900 env HERMES_DOCK_DEBUG_LOGS=0 HERM_SCROLL_PERF_OUTPUT="$OUT" HERM_SCROLL_PERF_PROFILE="${HERM_SCROLL_PERF_PROFILE:-0}" \
        swift test -c release --skip-build --disable-automatic-resolution --filter ScrollPerformanceCaptureTests
) > "$OUT/test.txt" 2>&1 &
test_job=$!
if [ "${HERM_SCROLL_PERF_PROFILE:-0}" = 1 ]; then
    attempt=0
    while [ ! -f "$OUT/capture.pid" ] && [ "$attempt" -lt 15 ]; do
        sleep 1
        attempt=$((attempt + 1))
    done
    if [ -f "$OUT/capture.pid" ]; then
        capture_pid=$(cat "$OUT/capture.pid")
        case "$capture_pid" in ''|*[!0-9]*) printf '%s\n' 'unavailable: invalid owned capture PID' > "$OUT/profiler-status.txt" ;;
        *)
            # Overlap the recording with workload, not only the 15-second grace.
            sleep 10
            profile_exit=0
            bounded 45 xcrun xctrace record --template 'Time Profiler' --attach "$capture_pid" \
                --time-limit 10s --no-prompt --output "$OUT/time-profiler.trace" > "$OUT/profiler.txt" 2>&1 || profile_exit=$?
            export_exit=0
            bounded 30 xcrun xctrace export --input "$OUT/time-profiler.trace" --toc \
                > "$OUT/profiler-toc.xml" 2> "$OUT/profiler-export.txt" || export_exit=$?
            printf 'record exit: %s\nTOC export exit: %s\n' "$profile_exit" "$export_exit" > "$OUT/profiler-status.txt"
            ;;
        esac
    else
        printf '%s\n' 'unavailable: owned capture PID absent within 15 seconds' > "$OUT/profiler-status.txt"
    fi
else
    printf '%s\n' 'unavailable: profiler not requested' > "$OUT/profiler-status.txt"
fi
result=0
wait "$test_job" || result=$?
printf 'test exit: %s\n' "$result" > "$OUT/status.txt"
if [ "$result" -eq 0 ] && [ ! -s "$OUT/summary.json" ]; then
    printf '%s\n' 'capture missing: Release test did not export a summary' >&2
    exit 1
fi
printf 'capture: %s; test exit: %s\n' "$OUT" "$result"
exit "$result"
