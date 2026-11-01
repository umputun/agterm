#!/bin/sh
# Identity "expose" for docker: port publishing already happened at
# `docker run -p`, so exposing is a no-op that answers the reply line the
# agtermctl wrapper expects. An optional map file (lines of
# "<container port> <host port>") translates ports published under a
# different host port number.
#
# Part of the container-overlays recipe; the wrapper invokes it as
# `agt-ovl-expose <container port>` and parses the printed line.
map_file=${AGT_OVL_PORT_MAP:-/agterm-bridge/port-map.txt}
host_port=$1
if [ -f "$map_file" ]; then
    mapped=$(awk -v p="$1" '$1 == p { print $2; exit }' "$map_file")
    if [ -n "$mapped" ]; then
        host_port=$mapped
    fi
fi
echo "exposed $1 on 127.0.0.1:$host_port"
