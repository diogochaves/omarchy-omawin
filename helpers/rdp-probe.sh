#!/bin/bash
# RDP readiness probe for chaves.omawin. Exit codes:
#
#   0  the server answered with an X.224 Connection Confirm — Windows' RDP
#      stack is up, the guest is usable
#   1  no reply before the timeout, or a reply that is not a Connection
#      Confirm (QEMU is running but the guest is still booting; docker-proxy
#      holds 3389 from the moment the container starts, so an open socket
#      alone means nothing)
#   2  connection refused / host unreachable — nothing is listening
#
# Sends the 19-byte X.224 Connection Request that nmap's rdp-ntlm-info and
# dockur's own wait use: TPKT header (03 00 00 13), X.224 CR (0e e0 00 00 00
# 00 00) and an RDP_NEG_REQ (01 00 08 00 + requestedProtocols, 4 bytes little
# endian). The negotiation block is mandatory: a bare Connection Request gets
# NO reply from Windows. A Connection Confirm starts with 03 00 00 13 0e d0.
#
# Pure bash /dev/tcp plus `timeout`; no nc, nmap or freerdp dependency.
#
# Environment (all optional):
#   RDP_HOST       host to probe                  (default 127.0.0.1)
#   RDP_PORT       port                           (default 3389)
#   RDP_TIMEOUT    seconds to wait for the reply  (default 3)
#   RDP_PROTOCOLS  requestedProtocols, 8 hex digits, little endian
#                  (default 0b000000 = RDP + TLS + CredSSP + RDSTLS)

set -uo pipefail
export LC_ALL=C

host=${RDP_HOST:-127.0.0.1}
port=${RDP_PORT:-3389}
wait=${RDP_TIMEOUT:-3}
protocols=${RDP_PROTOCOLS:-0b000000}

request='\x03\x00\x00\x13\x0e\xe0\x00\x00\x00\x00\x00\x01\x00\x08\x00'
for ((i = 0; i < 8; i += 2)); do request+="\x${protocols:i:2}"; done

# The 2>/dev/null has to be on the group: on the `exec` itself bash has already
# printed "Connection refused" by the time the redirection is applied.
{ exec 3<>"/dev/tcp/$host/$port"; } 2>/dev/null || exit 2
printf '%b' "$request" >&3 2>/dev/null || { exec 3<&-; exit 2; }

# bash `read` silently drops the NUL bytes an X.224 header is full of, so the
# reply goes through od instead.
reply=$(timeout "$wait" head -c 19 <&3 2>/dev/null | od -An -tx1 | tr -d ' \n')
exec 3<&- 3>&-

[[ $reply == 030000130ed0* ]]
