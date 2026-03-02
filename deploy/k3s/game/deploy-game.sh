#!/bin/bash
# 按游戏配置部署 nakama 完整栈（namespace + postgres + etcd + nakama）
# 用法:
#   ./deploy-game.sh alloy-frontline
#   ./deploy-game.sh stellar-mission
#   GAME=my-game ./deploy-game.sh
#
# 游戏配置在 games/<game>.env，可复制 games/alloy-frontline.env 修改

set -e
export PATH="/usr/local/bin:/usr/bin:$PATH"
if ! command -v kubectl &>/dev/null && command -v k3s &>/dev/null; then
  kubectl() { k3s kubectl "$@"; }
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GAME="${GAME:-${1:?用法: ./deploy-game.sh <game-id> 或 GAME=xxx ./deploy-game.sh}}"
CONFIG_FILE="${SCRIPT_DIR}/games/${GAME}.env"
DEFAULT_FILE="${SCRIPT_DIR}/default.env"
GENERATED_DIR="${SCRIPT_DIR}/.generated/${GAME}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "错误: 未找到游戏配置 $CONFIG_FILE"
  echo "请复制 games/alloy-frontline.env 为 games/${GAME}.env 并修改"
  exit 1
fi

# 加载默认值
set -a
[ -f "$DEFAULT_FILE" ] && source "$DEFAULT_FILE"
source "$CONFIG_FILE"
set +a

# 必需变量
: "${NAMESPACE:?请在 ${GAME}.env 中设置 NAMESPACE}"
: "${IMAGE:?请在 ${GAME}.env 中设置 IMAGE}"
: "${GAME_ID:=${GAME}}"

# 导出供 envsubst 使用
export NAMESPACE IMAGE GAME_ID REPLICAS
export NODE_PORT_SOCKET NODE_PORT_GRPC NODE_PORT_CONSOLE
export SERVER_KEY ENCRYPTION_KEY REFRESH_ENCRYPTION_KEY
export CONSOLE_USER CONSOLE_PASSWORD

echo "=== 部署游戏: ${GAME_ID} (namespace: ${NAMESPACE}) ==="
echo "镜像: ${IMAGE}"
echo "NodePort: socket=${NODE_PORT_SOCKET} grpc=${NODE_PORT_GRPC} console=${NODE_PORT_CONSOLE}"
echo ""

# 模板变量替换
subst() {
  local f="$1" out="$2"
  if command -v envsubst &>/dev/null; then
    envsubst < "$f" > "$out"
  else
    while IFS= read -r line; do
      for var in NAMESPACE IMAGE GAME_ID REPLICAS NODE_PORT_SOCKET NODE_PORT_GRPC NODE_PORT_CONSOLE SERVER_KEY ENCRYPTION_KEY REFRESH_ENCRYPTION_KEY CONSOLE_USER CONSOLE_PASSWORD; do
        line="${line//\$\{$var\}/${!var}}"
      done
      echo "$line"
    done < "$f" > "$out"
  fi
}

mkdir -p "$GENERATED_DIR"
for tpl in namespace postgres etcd nakama-config nakama-deployment nakama-service; do
  subst "${SCRIPT_DIR}/templates/${tpl}.yaml.tpl" "${GENERATED_DIR}/${tpl}.yaml"
done

echo "=== 1. 创建 Namespace ==="
kubectl apply -f "${GENERATED_DIR}/namespace.yaml"

echo "=== 2. 部署 Postgres ==="
kubectl apply -f "${GENERATED_DIR}/postgres.yaml"
kubectl rollout status deployment/postgres -n "$NAMESPACE" --timeout=120s

echo "=== 3. 部署 etcd ==="
kubectl apply -f "${GENERATED_DIR}/etcd.yaml"
kubectl rollout status deployment/etcd -n "$NAMESPACE" --timeout=120s

echo "=== 4. 部署 nakama 配置与应用 ==="
kubectl apply -f "${GENERATED_DIR}/nakama-config.yaml"
kubectl apply -f "${GENERATED_DIR}/nakama-deployment.yaml"
kubectl apply -f "${GENERATED_DIR}/nakama-service.yaml"
kubectl rollout status statefulset/nakama -n "$NAMESPACE" --timeout=180s

echo ""
echo "=== 完成: ${GAME_ID} ==="
REGISTRY_IP="${REGISTRY_IP:-192.168.102.224}"
echo "访问地址:"
echo "  - 客户端/API:  http://${REGISTRY_IP}:${NODE_PORT_SOCKET}"
echo "  - gRPC:        ${REGISTRY_IP}:${NODE_PORT_GRPC}"
echo "  - 控制台:      http://${REGISTRY_IP}:${NODE_PORT_CONSOLE} (${CONSOLE_USER} / ${CONSOLE_PASSWORD})"
echo ""
echo "更新镜像: kubectl rollout restart statefulset/nakama -n ${NAMESPACE}"
