#!/bin/bash
# 在已安装 K3s 的主机（如 192.168.102.224）上执行
# 用法:
#   sudo ./setup.sh                              # 无代理
#   PROXY=http://192.168.102.8:7890 sudo -E ./setup.sh  # 有代理

set -e
# sudo 时 PATH 可能不含 kubectl，用 k3s kubectl 兜底
export PATH="/usr/local/bin:/usr/bin:$PATH"
if ! command -v kubectl &>/dev/null && command -v k3s &>/dev/null; then
  kubectl() { k3s kubectl "$@"; }
fi
REGISTRY_IP="${REGISTRY_IP:-192.168.102.224}"
REGISTRY_PORT="${REGISTRY_PORT:-30500}"
# 代理地址，可通过环境变量覆盖
PROXY="${PROXY:-}"

echo "=== 0. 配置代理（若提供） ==="
if [ -n "${PROXY}" ]; then
  echo "检测到代理：${PROXY}，写入 Docker 和 K3s systemd 配置..."
  # Docker 代理
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=${PROXY}"
Environment="HTTPS_PROXY=${PROXY}"
Environment="NO_PROXY=localhost,127.0.0.1,192.168.0.0/16,${REGISTRY_IP}"
EOF
  # K3s（containerd）代理
  mkdir -p /etc/systemd/system/k3s.service.d
  cat > /etc/systemd/system/k3s.service.d/proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=${PROXY}"
Environment="HTTPS_PROXY=${PROXY}"
Environment="NO_PROXY=localhost,127.0.0.1,192.168.0.0/16,${REGISTRY_IP}:${REGISTRY_PORT}"
EOF
  systemctl daemon-reload
  systemctl restart docker 2>/dev/null || true
  echo "代理配置完成。"
else
  echo "未设置 PROXY，跳过代理配置。"
fi

echo "=== 1. 配置 K3s 使用私有镜像仓库 ${REGISTRY_IP}:${REGISTRY_PORT} ==="
mkdir -p /etc/rancher/k3s
# 有代理时不需要 docker.io 镜像加速源，直连即可；无代理时可设 DOCKER_MIRROR
if [ -n "${DOCKER_MIRROR}" ]; then
  cat > /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  "docker.io":
    endpoint:
      - "${DOCKER_MIRROR}"
  "${REGISTRY_IP}:${REGISTRY_PORT}":
    endpoint:
      - "http://${REGISTRY_IP}:${REGISTRY_PORT}"
EOF
else
  cat > /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  "${REGISTRY_IP}:${REGISTRY_PORT}":
    endpoint:
      - "http://${REGISTRY_IP}:${REGISTRY_PORT}"
EOF
fi
# 若 K3s 以 systemd 运行，需重启使配置生效
if systemctl is-active --quiet k3s 2>/dev/null; then
  echo "重启 K3s 以应用配置..."
  systemctl restart k3s
  sleep 15
elif systemctl is-active --quiet k3s-agent 2>/dev/null; then
  systemctl restart k3s-agent
  sleep 5
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== 2. 确保有默认 StorageClass（供 Registry 持久化存储）==="
if ! kubectl get storageclass 2>/dev/null | grep -q '(default)'; then
  echo "未检测到默认 StorageClass，安装 local-path-provisioner 并设为默认..."
  kubectl apply -f "${SCRIPT_DIR}/local-path-storage.yaml"
  echo "等待 local-path-provisioner 就绪..."
  kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=120s
else
  echo "已有默认 StorageClass，跳过安装。"
fi

echo "=== 3. 安装私有镜像仓库（Registry，使用 PVC 持久化）==="
kubectl apply -f - <<'REGISTRY'
apiVersion: v1
kind: Namespace
metadata:
  name: registry
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-pvc
  namespace: registry
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      containers:
        - name: registry
          image: registry:2
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 5000
          volumeMounts:
            - name: data
              mountPath: /var/lib/registry
          env:
            - name: REGISTRY_STORAGE_DELETE_ENABLED
              value: "true"
          readinessProbe:
            tcpSocket:
              port: 5000
            initialDelaySeconds: 5
            periodSeconds: 3
          livenessProbe:
            tcpSocket:
              port: 5000
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: registry-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: registry
spec:
  type: NodePort
  selector:
    app: registry
  ports:
    - port: 5000
      targetPort: 5000
      nodePort: 30500
REGISTRY
echo "等待 Registry Pod 就绪（最多 180 秒，含 PVC 绑定）..."
if ! kubectl rollout status deployment/registry -n registry --timeout=180s; then
  echo ""
  echo ">>> Registry 未在时限内就绪，改用临时存储（emptyDir）以继续..."
  kubectl delete deployment registry -n registry --ignore-not-found
  kubectl delete pvc registry-pvc -n registry --ignore-not-found
  kubectl apply -f - <<'REGISTRY_EMPTYDIR'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      containers:
        - name: registry
          image: registry:2
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 5000
          volumeMounts:
            - name: data
              mountPath: /var/lib/registry
          env:
            - name: REGISTRY_STORAGE_DELETE_ENABLED
              value: "true"
          readinessProbe:
            tcpSocket:
              port: 5000
            initialDelaySeconds: 5
            periodSeconds: 3
          livenessProbe:
            tcpSocket:
              port: 5000
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - name: data
          emptyDir: {}
REGISTRY_EMPTYDIR
  if ! kubectl rollout status deployment/registry -n registry --timeout=90s; then
    echo ">>> 改用 emptyDir 后仍失败，请排查：kubectl get pods -n registry; kubectl describe pod -n registry -l app=registry"
    exit 1
  fi
  echo ">>> Registry 已用临时存储启动，重启后已推送的镜像会丢失。"
fi

echo "=== 4. 安装 Kubernetes Dashboard ==="
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.5.0/aio/deploy/recommended.yaml
kubectl apply -f "${SCRIPT_DIR}/dashboard.yaml"
# 允许 Dashboard 调度到 control-plane 节点（单节点必须，官方只带了 master 污点容忍）
kubectl patch deployment kubernetes-dashboard -n kubernetes-dashboard -p '{"spec":{"template":{"spec":{"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}]}}}}'
kubectl patch deployment dashboard-metrics-scraper -n kubernetes-dashboard -p '{"spec":{"template":{"spec":{"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}]}}}}'
# 改为 NodePort 便于本机浏览器访问（端口由 K8s 分配，见下方输出）
kubectl patch svc kubernetes-dashboard -n kubernetes-dashboard -p '{"spec":{"type":"NodePort"}}'
echo "获取 Dashboard 登录 token（复制下面输出）:"
kubectl -n kubernetes-dashboard create token admin-user 2>/dev/null || \
  kubectl -n kubernetes-dashboard describe secret $(kubectl -n kubernetes-dashboard get secret | grep admin-user | awk '{print $1}') | grep token:

echo "=== 5. 部署 nakama 命名空间与 Postgres ==="
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
kubectl apply -f "${SCRIPT_DIR}/nakama-namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/postgres.yaml"
kubectl rollout status deployment/postgres -n nakama --timeout=120s

echo "=== 6. 部署 nakama-plus 配置与应用 ==="
kubectl apply -f "${SCRIPT_DIR}/nakama-config.yaml"
kubectl apply -f "${SCRIPT_DIR}/nakama-deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/nakama-service.yaml"
kubectl rollout status statefulset/nakama -n nakama --timeout=180s

echo ""
echo "=== 完成 ==="
echo "Dashboard: kubectl proxy 后访问 http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
echo "或 NodePort: kubectl get svc -n kubernetes-dashboard 查看 kubernetes-dashboard 的 PORT(S) 获取端口，用 https://${REGISTRY_IP}:<nodePort>"
echo ""
echo "Nakama-plus 访问（本机或同网段）:"
echo "  - 客户端/API:  http://${REGISTRY_IP}:30735  (socket port 7350)"
echo "  - gRPC:        ${REGISTRY_IP}:30734 (7349)"
echo "  - 控制台:      http://${REGISTRY_IP}:30751 (admin / password)"
echo ""
echo "首次部署前请在能访问 ${REGISTRY_IP}:30500 的机器上构建并推送镜像:"
echo "  docker build -f build/Dockerfile -t ${REGISTRY_IP}:30500/nakama-plus:latest ."
echo "  docker push ${REGISTRY_IP}:30500/nakama-plus:latest"
