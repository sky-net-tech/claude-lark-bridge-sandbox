#!/bin/sh
set -e

exec lark-mcp mcp \
    -m streamable \
    --host 0.0.0.0 \
    -p "${LARK_MCP_PORT:-3000}" \
    -d "${LARK_DOMAIN:-https://open.larksuite.com}" \
    -t "${LARK_MCP_TOOLS:-preset.doc.default,minutes.v1.minute.get,im.v1.message.create,im.v1.chat.list,im.v1.chat.get,im.v1.chatMembers.get}"
