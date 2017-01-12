#!/bin/bash
# run.sh -- Service runner for Reader
# Written 2016 by Michael Slone.
# This file is in the public domain, except for the argument parsing,
# which is licensed under the MIT license.
#
set -e
set -u

# Argument parsing as suggested by Bruno Bronosky.
# http://stackoverflow.com/a/14203146/237176
while [[ $# > 1 ]]
do
key="$1"
case $key in
    -r|--root)
    ROOT="$2"
    shift
    ;;
    -d|--destination)
    DESTINATION="$2"
    shift
    ;;
    -l|--log)
    BASELOG="$2"
    shift
    ;;
    -r|--report)
    REPORT="$2"
    shift
    ;;
    *)
    ;;
esac
shift
done

# Handy for timestamping logs
function timestamp {
    now=$(date +"%Y-%m-%d %H:%M:%S %z")
}

function log() {
    message=$1
    timestamp
    echo "Reader [$now]: $message" >> "$BASELOG"
}

log "started"
log "running perl -I\"$ROOT/service/lib\" \"$ROOT/service/reader.pl\" --root \"$ROOT\" --destination \"$DESTINATION\" --log \"$BASELOG\" --report \"$REPORT\""
perl -I"$ROOT/service/lib" "$ROOT/service/reader.pl" --root "$ROOT" --destination "$DESTINATION" --log "$BASELOG" --report "$REPORT"
log "finished"
