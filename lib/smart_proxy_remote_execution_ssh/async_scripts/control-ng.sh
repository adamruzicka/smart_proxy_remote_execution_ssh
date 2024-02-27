#!/usr/bin/sh

# set -x

die() {
    echo "$2" >&2
    exit "$1"
}

PROJECT_ROOT="$(dirname "$0")"
cd "$PROJECT_ROOT" || die 1 "Could not change working directory to '$PROJECT_ROOT'"

signal_exit() {
    # Create a listener on the pipe to prevent blocking on write into the pipe
    cat "done" >/dev/null &
    cat_pid="$!"
    echo >"done"
    kill "$cat_pid"
    wait "$cat_pid"
    rm 'done'
    rm 'stdout-pipe'
    rm 'stderr-pipe'
}

attach_done() {
    cat stdout stderr | sort
    exit "$(cat exit-status)"
}

to_base64() {
    encoded="$(base64 --wrap 0)"
    printf "%s" "$encoded"
}

to_json() {
    case "$JSON" in
        python3)
            python3 -c 'import json; import sys; print(json.dumps(sys.stdin.read()))'
            ;;
        jq)
            jq -MRsc
            ;;
        base64)
            to_base64
            ;;
    esac
}

random_id() {
    tr -dc '[:alpha:]' < /dev/urandom | fold -w 16 | head -n 1
}

json_message() {
    timestamp="$(TZ=UTC date -Ins)"
    cat <<EOF
{ "timestamp": "$timestamp", "kind": "$1", "$OUTPUT_KEY": $(echo "$2" | to_json), "id": "$(random_id)", "version": "v1" }
EOF
}

detect_parameters() {
    HAS_USERNS=0
    if unshare -Ucfp --mount-proc true >/dev/null 2>/dev/null; then
        HAS_USERNS=1
    fi

    if jq --version >/dev/null 2>/dev/null; then
        JSON=jq
        OUTPUT_KEY=output
    elif python3 -c 'import json; import sys' >/dev/null 2>/dev/null; then
        JSON=python3
        OUTPUT_KEY=output
    else
        JSON=base64
        OUTPUT_KEY=base64output
    fi
}

command_start() {
    [ -f 'script' ] || die 1 "script file does not exist"

    detect_parameters

    touch stdout
    touch stderr
    mkfifo "done"
    mkfifo "stdout-pipe"
    mkfifo "stderr-pipe"

    # shellcheck disable=SC2094
    "$0" timestamped-jsonl stdout >stdout < stdout-pipe &
    # shellcheck disable=SC2094
    "$0" timestamped-jsonl stderr >stderr < stderr-pipe &

    (if [ $HAS_USERNS -eq 1 ]; then
         unshare -Ucfp --mount-proc --kill-child "$0" inner-start
     else
         nohup "$0" inner-start
     fi) > stdout-pipe 2> stderr-pipe &

    echo $! >pid
    cp pid top-pid
}

command_run() {
    command_start
    echo $$ >top-pid

    trap signal_exit EXIT

    sleep 0.1
    command_attach
}

timestamped_jsonl() {
    kind="$1"
    if [ "$JSON" = "python3" ]; then
        python3 -c "
import datetime
import json
import random
import string
import sys

while l := sys.stdin.readline():
    now = datetime.datetime.now()
    id = ''.join(random.choices(string.ascii_uppercase + string.digits, k=16))
    msg = {'version': 'v1', 'timestamp': now.isoformat(), 'id': id, 'kind': '$kind', '$OUTPUT_KEY': l}
    print(json.dumps(msg))
    sys.stdout.flush()
"
    else
        while read -r LINE; do
            json_message "$kind" "$LINE"
        done
    fi
}

command_inner_start() {
    ./script
    echo $? >exit-status
    signal_exit
    exit "$(cat exit-status)"
}

command_kill() {
    [ -f pid ] || die 1 "No pidfile present"

    # We need to kill the top-level process in the unshared namespace
    PGID="$(ps -o pgid= -p "$(cat pid)" | cut -c 3-)"
    if [ -z "$PGID" ]; then
        if [ -f "exit-status" ]; then
            exit "$(cat exit-status)"
        else
            die 1 "Parent process of process $(cat pid) not found, exiting."
        fi
    fi
    pkill -9 -g "$PGID"

    # SESSION="$(ps -o session= -p "$(cat pid)" | cut -c 2-)"
    # pkill -9 --session "$SESSION"
    echo 137 >"exit-status"
    signal_exit
    exit 137
}

command_attach() {
    [ -f 'pid' ] || die 1 "Cannot attach, process has not been started yet"
    [ -f 'stdout' ] || die 1 "Cannot attach, stdout file is missing"
    [ -f 'stderr' ] || die 1 "Cannot attach, stderr file is missing"
    [ -f 'exit-status' ] && attach_done
    [ -p 'done' ] ||  die 1 "Cannot attach, notification pipe missing"

    tail -q -c +0 -f stdout stderr &
    trap 'kill %tail; exit 1' INT
    cat 'done' >/dev/null
    sleep 1
    kill %tail
    wait
    exit "$(cat exit-status)"
}

command_dwim() {
    [ -f 'exit-status' ] && attach_done
    [ -p 'done' ] && command_attach

    command_run
}

command_pstree() {
    # TODO checks
    pstree "$(cat top-pid)"
}

command_cleanup() {
    for f in exit-status pid stdout stderr top-pid; do
        [ -f "$f" ] && rm "$f"
    done
}

case "$1" in
    "start")
        command_start "$@"
        ;;
    "inner-start")
        shift
        command_inner_start "$@"
        ;;
    "kill")
        shift
        command_kill "$@"
        ;;
    "attach")
        shift
        command_attach "$@"
        ;;
    "run")
        shift
        command_run "$@"
        ;;
    "dwim")
        shift
        command_dwim "$@"
        ;;
    "pstree")
        shift
        command_pstree "$@"
        ;;
    "timestamped-jsonl")
        shift
        detect_parameters
        timestamped_jsonl "$@"
        ;;
    "cleanup")
        shift
        command_cleanup "$@"
        ;;
    *)
        die 1 "Unknown command '$1'"
        ;;
esac
