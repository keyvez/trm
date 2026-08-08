#!/bin/bash
#
# trm pane stress test
#
# Sends keystrokes to the running trm app to exercise pane creation,
# navigation, stacking, process execution, and teardown.
#
# Usage:
#   1. Launch trm:  open zig-out/trm.app
#   2. Run:         ./scripts/stress-test.sh [rounds]
#
# Default: 10 rounds. Each round creates panes, runs processes,
# navigates, closes, and checks the app is still alive.

set -euo pipefail

ROUNDS=${1:-10}
APP_NAME="trm"
LOG="/tmp/trm-stress-test.log"
CRASH_LOG="/tmp/trm-stress-crashes.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "$(date '+%H:%M:%S') $1" | tee -a "$LOG"; }
pass() { log "${GREEN}[PASS]${NC} $1"; }
fail() { log "${RED}[FAIL]${NC} $1"; }
info() { log "${YELLOW}[INFO]${NC} $1"; }

# Check if trm is running, return PID
get_pid() {
    pgrep -x "$APP_NAME" 2>/dev/null | head -1
}

# Send a keystroke to trm via AppleScript
# $1 = key character or key code
# $2 = modifiers: "command", "command shift", "control option", etc.
send_key() {
    local key="$1"
    local mods="${2:-}"

    local using_clause=""
    if [[ -n "$mods" ]]; then
        local parts=""
        for mod in $mods; do
            case "$mod" in
                command|cmd)   parts+="command down, " ;;
                shift)         parts+="shift down, " ;;
                option|alt)    parts+="option down, " ;;
                control|ctrl)  parts+="control down, " ;;
            esac
        done
        parts="${parts%, }"
        using_clause="using {$parts}"
    fi

    if [[ ${#key} -eq 1 ]]; then
        osascript -e "
            tell application \"System Events\"
                tell process \"$APP_NAME\"
                    keystroke \"$key\" $using_clause
                end tell
            end tell
        " 2>/dev/null
    else
        # key code
        osascript -e "
            tell application \"System Events\"
                tell process \"$APP_NAME\"
                    key code $key $using_clause
                end tell
            end tell
        " 2>/dev/null
    fi
}

# Send text to the terminal (types it character by character)
send_text() {
    osascript -e "
        tell application \"System Events\"
            tell process \"$APP_NAME\"
                keystroke \"$1\"
            end tell
        end tell
    " 2>/dev/null
}

# Press Return
send_return() {
    send_key 36  # key code 36 = Return
}

# Wait and check app is alive
check_alive() {
    local context="$1"
    sleep 0.3
    if ! get_pid > /dev/null; then
        fail "App crashed during: $context"
        echo "$(date): CRASH during $context" >> "$CRASH_LOG"
        return 1
    fi
    return 0
}

# Wait for app to settle
settle() {
    sleep "${1:-0.5}"
}

# --- Pane Operations ---

# Cmd+D = new split right
split_right() {
    send_key "d" "command"
    settle 0.8
}

# Cmd+Shift+D = new split down
split_down() {
    send_key "d" "command shift"
    settle 0.8
}

# Cmd+W = close surface
close_pane() {
    send_key "w" "command"
    settle 0.5
}

# Cmd+Opt+Arrow = navigate splits
goto_split_right() { send_key 124 "command option"; settle 0.3; }  # arrow right
goto_split_left()  { send_key 123 "command option"; settle 0.3; }  # arrow left
goto_split_up()    { send_key 126 "command option"; settle 0.3; }  # arrow up
goto_split_down()  { send_key 125 "command option"; settle 0.3; }  # arrow down

# Cmd+] / Cmd+[ = next/prev split
goto_split_next() { send_key "]" "command"; settle 0.3; }
goto_split_prev() { send_key "[" "command"; settle 0.3; }

# Cmd+1-9 = jump to pane by index
jump_to_pane() {
    send_key "$1" "command"
    settle 0.3
}

# --- Process helpers ---

# Run a command in the current pane
run_cmd() {
    send_text "$1"
    send_return
    settle "${2:-0.5}"
}

# Run a background process that produces output
run_noisy_process() {
    run_cmd "for i in \$(seq 1 50); do echo \"stress-line-\$i-\$(date +%s%N)\"; done" 0.3
}

# Run a long-running process
run_long_process() {
    run_cmd "sleep 30 &" 0.3
}

# Run a process that exits quickly
run_quick_exit() {
    run_cmd "true" 0.2
}

# Run a process that produces continuous output
run_continuous_output() {
    run_cmd "yes stress-test-output | head -200 &" 0.5
}

# ============================================================
# TEST PHASES
# ============================================================

test_basic_split_and_close() {
    info "Phase 1: Basic split and close"

    # Create 3 splits right
    for i in 1 2 3; do
        split_right
        check_alive "split_right #$i" || return 1
    done
    pass "Created 3 right splits"

    # Navigate through all
    for i in 1 2 3; do
        goto_split_next
        check_alive "goto_split_next #$i" || return 1
    done
    pass "Navigated through splits"

    # Close all splits (go back to 1 pane)
    for i in 1 2 3; do
        close_pane
        check_alive "close_pane #$i" || return 1
    done
    pass "Closed all extra splits"
}

test_grid_creation() {
    info "Phase 2: Grid creation (2x2)"

    # Create a 2x2 grid: split right, then split each down
    split_right
    check_alive "grid: split_right" || return 1

    split_down
    check_alive "grid: split_down (right)" || return 1

    goto_split_left
    check_alive "grid: goto_split_left" || return 1

    split_down
    check_alive "grid: split_down (left)" || return 1

    pass "Created 2x2 grid"

    # Navigate all 4 panes
    for dir in right down left up; do
        case $dir in
            right) goto_split_right ;;
            down)  goto_split_down ;;
            left)  goto_split_left ;;
            up)    goto_split_up ;;
        esac
        check_alive "grid navigate: $dir" || return 1
    done
    pass "Navigated 2x2 grid"

    # Close down to 1
    close_pane; check_alive "grid close 1" || return 1
    close_pane; check_alive "grid close 2" || return 1
    close_pane; check_alive "grid close 3" || return 1
    pass "Closed grid back to 1 pane"
}

test_processes_in_panes() {
    info "Phase 3: Processes in panes"

    # Create 3 panes with different processes
    run_noisy_process
    check_alive "noisy in pane 1" || return 1

    split_right
    run_long_process
    check_alive "long proc in pane 2" || return 1

    split_down
    run_continuous_output
    check_alive "continuous in pane 3" || return 1

    settle 1

    # Close pane with running process
    close_pane
    check_alive "close pane with continuous output" || return 1
    pass "Closed pane with running process"

    close_pane
    check_alive "close pane with long process" || return 1
    pass "Closed pane with long process"
}

test_rapid_split_close() {
    info "Phase 4: Rapid split/close cycles"

    for i in $(seq 1 8); do
        split_right
        settle 0.2
        check_alive "rapid split #$i" || return 1
    done
    pass "8 rapid splits created"

    for i in $(seq 1 8); do
        close_pane
        settle 0.2
        check_alive "rapid close #$i" || return 1
    done
    pass "8 rapid closes completed"
}

test_navigation_stress() {
    info "Phase 5: Navigation stress"

    # Create 4 panes
    split_right; split_down; goto_split_left; split_down
    check_alive "nav stress: setup" || return 1

    # Rapidly navigate in circles
    for i in $(seq 1 15); do
        goto_split_next
        settle 0.1
    done
    check_alive "rapid next navigation" || return 1
    pass "15 rapid next navigations"

    for i in $(seq 1 15); do
        goto_split_prev
        settle 0.1
    done
    check_alive "rapid prev navigation" || return 1
    pass "15 rapid prev navigations"

    # Directional navigation
    for i in $(seq 1 5); do
        goto_split_right
        goto_split_down
        goto_split_left
        goto_split_up
        settle 0.1
    done
    check_alive "directional navigation loop" || return 1
    pass "Directional navigation loops"

    # Jump to panes by index
    for i in 1 2 3 4 3 2 1 4 1 3; do
        jump_to_pane "$i"
        settle 0.1
    done
    check_alive "jump-to-pane stress" || return 1
    pass "Pane index jumping"

    # Cleanup
    close_pane; close_pane; close_pane
    check_alive "nav stress cleanup" || return 1
}

test_split_with_output() {
    info "Phase 6: Splits with heavy output"

    # Create panes and blast output in each
    for i in 1 2 3; do
        if [ $i -gt 1 ]; then split_right; fi
        run_cmd "for j in \$(seq 1 200); do echo \"pane${i}-line\$j-\$(openssl rand -hex 16)\"; done" 0.3
        check_alive "heavy output pane $i" || return 1
    done
    settle 2
    pass "3 panes with heavy output"

    # Now rapidly navigate while output might still be rendering
    for i in $(seq 1 10); do
        goto_split_next
        settle 0.05
    done
    check_alive "navigate during output" || return 1
    pass "Navigation during heavy output"

    close_pane; close_pane
    check_alive "close after heavy output" || return 1
}

test_many_panes() {
    info "Phase 7: Many panes (stress limit)"

    local count=0
    for i in $(seq 1 6); do
        split_right
        settle 0.3
        if ! check_alive "many panes: split $i"; then
            fail "Crashed at $count panes"
            return 1
        fi
        count=$((count + 1))
    done
    pass "Created $count additional panes"

    # Run something in each
    for i in $(seq 1 $count); do
        jump_to_pane "$i"
        run_cmd "echo pane-$i" 0.2
    done
    check_alive "commands in many panes" || return 1
    pass "Ran commands in all panes"

    # Close all
    for i in $(seq 1 $count); do
        close_pane
        settle 0.2
        check_alive "close many pane $i" || return 1
    done
    pass "Closed all $count panes"
}

test_process_exit_during_close() {
    info "Phase 8: Process exit race conditions"

    # Pane with process that exits just as we close
    split_right
    run_cmd "sleep 0.5" 0.1
    settle 0.3
    close_pane
    check_alive "close during sleep exit" || return 1
    pass "Close during process exit"

    # Pane with process that was killed
    split_right
    run_cmd "sleep 999 &" 0.3
    run_cmd "kill %1 2>/dev/null" 0.3
    close_pane
    check_alive "close after kill" || return 1
    pass "Close after process kill"

    # Pane where shell exits
    split_right
    run_cmd "exit" 0.5
    settle 0.5
    # The pane may auto-close or stay; either way app should be alive
    check_alive "pane after exit command" || return 1
    pass "Pane after shell exit"
}

test_alternating_split_directions() {
    info "Phase 9: Alternating split directions"

    for i in $(seq 1 5); do
        if [ $((i % 2)) -eq 0 ]; then
            split_right
        else
            split_down
        fi
        settle 0.3
        check_alive "alternating split $i" || return 1
    done
    pass "5 alternating direction splits"

    # Close in reverse
    for i in $(seq 1 5); do
        close_pane
        settle 0.2
        check_alive "alternating close $i" || return 1
    done
    pass "Closed alternating splits"
}

test_concurrent_output() {
    info "Phase 10: Concurrent output in multiple panes"

    # Create 4 panes with simultaneous output
    split_right
    split_down
    goto_split_left
    split_down
    check_alive "concurrent setup" || return 1

    # Start continuous output in all panes
    jump_to_pane 1
    run_cmd "while true; do echo \$(date +%s%N); sleep 0.01; done &" 0.2
    jump_to_pane 2
    run_cmd "while true; do echo \$(date +%s%N); sleep 0.01; done &" 0.2
    jump_to_pane 3
    run_cmd "while true; do echo \$(date +%s%N); sleep 0.01; done &" 0.2
    jump_to_pane 4
    run_cmd "while true; do echo \$(date +%s%N); sleep 0.01; done &" 0.2

    # Let it run and navigate
    for i in $(seq 1 20); do
        goto_split_next
        settle 0.1
    done
    check_alive "navigate during concurrent output" || return 1
    pass "Navigation during concurrent output in 4 panes"

    # Kill background processes and close
    for i in 1 2 3 4; do
        jump_to_pane "$i"
        settle 0.1
        run_cmd "kill %1 2>/dev/null; true" 0.2
    done
    settle 0.5

    close_pane; close_pane; close_pane
    check_alive "cleanup concurrent" || return 1
    pass "Cleaned up concurrent output test"
}

# ============================================================
# MAIN
# ============================================================

main() {
    echo "" > "$LOG"
    echo "" > "$CRASH_LOG"

    info "=== trm Pane Stress Test ==="
    info "Rounds: $ROUNDS"
    info "Log: $LOG"
    info "Crash log: $CRASH_LOG"
    echo ""

    # Check app is running
    local pid
    pid=$(get_pid)
    if [ -z "$pid" ]; then
        fail "trm is not running. Launch it first: open zig-out/trm.app"
        exit 1
    fi
    info "trm PID: $pid"

    # Bring trm to front
    osascript -e "tell application \"$APP_NAME\" to activate" 2>/dev/null || true
    settle 1

    local total_pass=0
    local total_fail=0

    for round in $(seq 1 "$ROUNDS"); do
        info "========== Round $round / $ROUNDS =========="

        local tests=(
            test_basic_split_and_close
            test_grid_creation
            test_processes_in_panes
            test_rapid_split_close
            test_navigation_stress
            test_split_with_output
            test_many_panes
            test_process_exit_during_close
            test_alternating_split_directions
            test_concurrent_output
        )

        for test in "${tests[@]}"; do
            if ! get_pid > /dev/null; then
                fail "App died before $test in round $round"
                total_fail=$((total_fail + 1))
                echo "$(date): DEAD before $test, round $round" >> "$CRASH_LOG"

                info "Waiting for restart..."
                sleep 3
                if ! get_pid > /dev/null; then
                    fail "App did not restart. Aborting."
                    break 2
                fi
            fi

            if $test; then
                total_pass=$((total_pass + 1))
            else
                total_fail=$((total_fail + 1))
                # Try to recover by closing splits
                for i in $(seq 1 10); do
                    if get_pid > /dev/null; then
                        close_pane 2>/dev/null || true
                        settle 0.2
                    fi
                done
                settle 1
            fi
        done
    done

    echo ""
    info "=== RESULTS ==="
    info "Rounds: $ROUNDS"
    pass "Passed: $total_pass"
    if [ $total_fail -gt 0 ]; then
        fail "Failed: $total_fail"
    else
        pass "Failed: 0"
    fi

    if [ -s "$CRASH_LOG" ] && [ "$(wc -l < "$CRASH_LOG")" -gt 1 ]; then
        fail "Crashes detected! See $CRASH_LOG"
        cat "$CRASH_LOG"
    else
        pass "No crashes detected"
    fi
}

main
