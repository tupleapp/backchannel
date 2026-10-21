#!/bin/sh
# Tuple runs this on call-connected, room-joined and call-ended (./install copies it into
# Tuple's triggers folder). It only wakes backchannel.py, which then checks `tuple state`.
echo "$(date +%s) ${0##*/} ${TUPLE_TRIGGER_CALL_ID:-}" > "$(dirname "$0")/wake"
