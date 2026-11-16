#!/bin/bash
# 在 Linux 开发机上用：把源码同步到测试机 X-STATION V2 并编译或运行测试。
# 用法：
#   scripts/remote-build.sh             编译 build/Xmonitor.app
#   scripts/remote-build.sh --install   编译并安装启动 /Applications/Xmonitor.app
#   scripts/remote-build.sh --test      编译并在真机运行 scripts/run-tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .testmac.env ]]; then
    echo "缺少 .testmac.env（MAC_HOST=user@host、MAC_PASSWORD=...）" >&2
    exit 1
fi

set -a
. ./.testmac.env
set +a
export SSHPASS="$MAC_PASSWORD"
REMOTE_DIR=${MAC_DIR:-xsensei}
SSH_BASE_OPTS=(-o StrictHostKeyChecking=accept-new)

TARGET_HOST="$MAC_HOST"
PING_HOST="${TARGET_HOST#*@}"
PING_HOST="${PING_HOST#[}"
PING_HOST="${PING_HOST%]}"

SSH_OPTS=("${SSH_BASE_OPTS[@]}" -o ConnectTimeout=10)
RSYNC_EXTRA=()

# 双网卡环境下优先绑定 wlp4s0 源地址避免 eno1 路由劫持；若 IPv4 探测失败则自动切换 IPv6 链路本地地址
if [[ "$PING_HOST" == *:* ]]; then
    ping -6 -c 1 -W 1 "$PING_HOST" >/dev/null 2>&1 || true
    SSH_OPTS=(-6 "${SSH_BASE_OPTS[@]}" -o ConnectTimeout=10)
    RSYNC_EXTRA=(--ipv6)
else
    ping -c 1 -W 1 -I wlp4s0 "$PING_HOST" >/dev/null 2>&1 || true
    WLP_IPV4=$(ip -4 -o addr show dev wlp4s0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
    PROBE_OPTS=("${SSH_BASE_OPTS[@]}" -o ConnectTimeout=3)
    if [[ -n "$WLP_IPV4" ]]; then
        PROBE_OPTS+=(-o "BindAddress=$WLP_IPV4")
    fi
    if sshpass -e ssh "${PROBE_OPTS[@]}" "$TARGET_HOST" true >/dev/null 2>&1; then
        if [[ -n "$WLP_IPV4" ]]; then
            SSH_OPTS+=("-o" "BindAddress=$WLP_IPV4")
        fi
    elif [[ -n "${MAC_IPV6_HOST:-}" ]]; then
        echo "==> IPv4 ($TARGET_HOST) 连接不可达，自动切换 IPv6 链路本地地址: $MAC_IPV6_HOST"
        TARGET_HOST="$MAC_IPV6_HOST"
        SSH_OPTS=(-6 "${SSH_BASE_OPTS[@]}" -o ConnectTimeout=10)
        RSYNC_EXTRA=(--ipv6)
    fi
fi

if [[ "${TARGET_HOST#*@}" == *:* ]]; then
    RSYNC_USER="${TARGET_HOST%@*}"
    RSYNC_ADDR="${TARGET_HOST#*@}"
    RSYNC_ADDR="${RSYNC_ADDR#[}"
    RSYNC_ADDR="${RSYNC_ADDR%]}"
    RSYNC_DEST="${RSYNC_USER}@[${RSYNC_ADDR}]:${REMOTE_DIR}/"
else
    RSYNC_DEST="${TARGET_HOST}:${REMOTE_DIR}/"
fi

echo "==> 同步到 $TARGET_HOST:$REMOTE_DIR"
rsync -az "${RSYNC_EXTRA[@]}" --delete -e "sshpass -e ssh ${SSH_OPTS[*]}" \
    --exclude .git --exclude build --exclude .testmac.env --exclude .superpowers \
    ./ "$RSYNC_DEST"

if [[ "${1:-}" == "--test" ]]; then
    shift
    echo "==> 在测试机上编译并运行测试"
    printf '%s\n' "$MAC_PASSWORD" | sshpass -e ssh "${SSH_OPTS[@]}" "$TARGET_HOST" \
        "read -r PW; security unlock-keychain -p \"\$PW\" login.keychain-db 2>/dev/null || true; cd $REMOTE_DIR && scripts/run-tests.sh $*"
else
    echo "==> 在测试机上编译应用"
    printf '%s\n' "$MAC_PASSWORD" | sshpass -e ssh "${SSH_OPTS[@]}" "$TARGET_HOST" \
        "read -r PW; security unlock-keychain -p \"\$PW\" login.keychain-db 2>/dev/null || true; cd $REMOTE_DIR && scripts/build-app.sh $*"
fi
