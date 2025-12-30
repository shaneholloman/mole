#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-debug-logging.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    export TERM="xterm-256color"
    rm -rf "${HOME:?}"/*
    mkdir -p "$HOME/.config/mole"
}

@test "mo clean --debug creates debug log file" {
    run env HOME="$HOME" MOLE_TEST_MODE=1 MO_DEBUG=1 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    MOLE_OUTPUT="$output"

    # Check if log file exists
    DEBUG_LOG="$HOME/.config/mole/mole_debug_session.log"
    [ -f "$DEBUG_LOG" ]

    # Validates log content
    run grep "Mole Debug Session" "$DEBUG_LOG"
    [ "$status" -eq 0 ]

    # Validates standard output message (ignoring colors)
    [[ "$MOLE_OUTPUT" =~ "Debug session log saved to" ]]
}

@test "mo clean without debug does not show debug log path" {
    run env HOME="$HOME" MOLE_TEST_MODE=1 MO_DEBUG=0 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]

    [[ "$output" != *"Debug session log saved to"* ]]
}

@test "mo clean --debug logs system info" {
    run env HOME="$HOME" MOLE_TEST_MODE=1 MO_DEBUG=1 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]

    DEBUG_LOG="$HOME/.config/mole/mole_debug_session.log"

    # Check for system info headers
    run grep "User:" "$DEBUG_LOG"
    [ "$status" -eq 0 ]

    run grep "Architecture:" "$DEBUG_LOG"
    [ "$status" -eq 0 ]
}
