#!/bin/bash
# 在 Linux 开发机上用：把源码同步到测试机 X-STATION V2 并编译或运行测试。
# 用法：
#   scripts/remote-build.sh             编译 build/XSensei.app
#   scripts/remote-build.sh --install   编译并安装启动 /Applications/XSensei.app
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
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

# 双网卡环境下刷新 wlp4s0 到 X-STATION V2 的 ARP 项，确保连接稳定
ping -c 1 -W 1 -I wlp4s0 $PING_HOST >/dev/null 2>&1 || true

echo "==> 同步到 $MAC_HOST:$REMOTE_DIR"
rsync -az --delete -e "sshpass -e ssh ${SSH_OPTS[*]}" \
    --exclude .git --exclude build --exclude .testmac.env --exclude .superpowers \
    ./ "$MAC_HOST:$REMOTE_DIR/"

if [[ "${1:-}" == "--test" ]]; then
    shift
    echo "==> 在测试机上编译并运行测试"
    printf '%s\n' "$MAC_PASSWORD" | sshpass -e ssh "${SSH_OPTS[@]}" "$MAC_HOST" \
        "read -r PW; security unlock-keychain -p \"\$PW\" login.keychain-db 2>/dev/null || true; cd $REMOTE_DIR && scripts/run-tests.sh $*"
else
    echo "==> 在测试机上编译应用"
    printf '%s\n' "$MAC_PASSWORD" | sshpass -e ssh "${SSH_OPTS[@]}" "$MAC_HOST" \
        "read -r PW; security unlock-keychain -p \"\$PW\" login.keychain-db 2>/dev/null || true; cd $REMOTE_DIR && scripts/build-app.sh $*"
fi
