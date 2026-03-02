# K3s 部署 nakama-plus

在已安装 K3s 的主机（如 192.168.102.224）上完成：  
1）安装 Dashboard；2）安装私有镜像仓库；3）构建并推送 nakama-plus 镜像，用 K3s 启动并对外提供 Service，本机可访问。

---

## 前提

- 主机已安装 K3s，`kubectl` 可用（且当前为 root 或具备 sudo）。
- 本机或开发机已安装 Docker，能访问主机 192.168.102.224。

---

## 步骤一：在 K3s 主机上执行（XShell 登录 192.168.102.224）

```bash
# 使用 root 登录后，进入本仓库 deploy/k3s 目录（若从本机拷贝则先 scp 整个 repo 或 deploy/k3s 到主机）
cd /path/to/nakama-plus/deploy/k3s
chmod +x setup.sh
sudo ./setup.sh
```

脚本会：

1. 配置 K3s 信任私有仓库 `192.168.102.224:30500`，并重启 K3s。
2. 部署 Registry（NodePort 30500）。
3. 安装 Kubernetes Dashboard（NodePort 30443），并创建 admin 账号，输出登录 token。
4. 部署 Postgres、nakama ConfigMap、nakama Deployment、nakama Service（NodePort 30735/30751 等）。

**注意**：首次运行前，必须先完成步骤二，把镜像推到 192.168.102.224:30500，否则 nakama Deployment 会拉不到镜像。

**可选（国内/受限网络）**：若需使用 docker.io 加速源，可在执行脚本前设置环境变量，脚本会写入 `registries.yaml` 并自动配置国内 pause 镜像，避免 403：
```bash
export DOCKER_MIRROR="https://dt8eih9m.mirror.aliyuncs.com"   # 换成你自己的阿里云加速地址
sudo -E ./setup.sh
```

---

## 步骤二：构建并推送 nakama-plus 镜像（在能访问 192.168.102.224 的机器上）

在 **nakama-plus 项目根目录**（含 `build/Dockerfile` 和 `vendor` 的目录）执行：

```bash
# 构建（上下文为项目根，Dockerfile 在 build/）
docker build -f build/Dockerfile -t 192.168.102.224:30500/nakama-plus:latest .

# 若 K3s 主机上 registry 未配置为 insecure，需在 Docker 端配置信任
# Linux: /etc/docker/daemon.json 增加 "insecure-registries": ["192.168.102.224:30500"] 并重启 docker
# Windows: Docker Desktop -> Settings -> Docker Engine 增加同上，Apply

docker push 192.168.102.224:30500/nakama-plus:latest
```

推送成功后，再在 K3s 主机上执行或重跑 `setup.sh`（或仅 `kubectl apply -f nakama-deployment.yaml`），nakama Pod 会拉取镜像并启动。

---

## 步骤三：访问服务（本机）

| 服务 | 地址 | 说明 |
|------|------|------|
| **Nakama 客户端/API** | http://192.168.102.224:30735 | 对应 socket 7350，游戏连接与 HTTP API |
| **Nakama 控制台** | http://192.168.102.224:30751 | 用户名 admin，密码见 `nakama-config.yaml`（默认 password） |
| **K8s Dashboard** | https://192.168.102.224:30443 | 使用 setup.sh 输出的 token 登录（浏览器可能需接受自签名证书） |
| **私有镜像仓库** | http://192.168.102.224:30500/v2/_catalog | 查看已推送镜像 |

---

## 可选：仅更新 nakama 配置或镜像（滚动更新）

nakama 为 StatefulSet，已配置**滚动更新**：每次只更新一个 Pod，配合 `shutdown_grace_sec` 和 `terminationGracePeriodSeconds` 实现优雅关闭。

- **改配置**：编辑 `nakama-config.yaml` 后执行  
  `kubectl apply -f nakama-config.yaml`  
  再 `kubectl rollout restart statefulset/nakama -n nakama`
- **更新镜像**：重新 `docker build` 并 `docker push` 后执行  
  `kubectl rollout restart statefulset/nakama -n nakama`  
  或修改 `nakama-deployment.yaml` 中 image 的 tag 后 `kubectl apply -f nakama-deployment.yaml`

- **查看滚动进度**：`kubectl rollout status statefulset/nakama -n nakama`

---

## 多游戏部署（按游戏独立 namespace）

当需要部署多个游戏（如合金战线、星际使命）时，每个游戏使用独立 namespace 和镜像，互不影响。详见 `game/README.md`：

```bash
cd deploy/k3s/game
./deploy-game.sh alloy-frontline   # 合金战线
./deploy-game.sh stellar-mission   # 星际使命
```

新增游戏：复制 `games/alloy-frontline.env` 为 `games/<游戏id>.env`，修改 NAMESPACE、IMAGE、NODE_PORT_* 后执行 `./deploy-game.sh <游戏id>`。

---

## 为什么 PVC 无法使用？如何获得正常 PVC？

**依赖关系**：  
`registry-pvc` 使用 StorageClass `local-path` → 需要 **local-path-provisioner** 在跑 → provisioner 是一个 Pod，需要能拉取镜像 `rancher/local-path-provisioner:v0.0.28`。  
若你这边**访问 Docker Hub 超时或被墙**，provisioner 一直处于 ErrImagePull/ContainerCreating，就不会去处理 PVC，PVC 就一直是 Pending，用这个 PVC 的 registry Pod 也就起不来。

**要获得正常 PVC，按顺序做：**

1. **让 local-path-provisioner 跑起来**  
   - 若 `kubectl get pods -n local-path-storage` 里 provisioner 已是 **Running**，跳到第 3 步。  
   - 若一直是 **ErrImagePull / ContainerCreating**：在能访问外网的机器（如你本机）执行：
     ```bash
     docker pull rancher/local-path-provisioner:v0.0.28
     docker save rancher/local-path-provisioner:v0.0.28 -o local-path-provisioner.tar
     scp local-path-provisioner.tar root@192.168.102.224:/root/
     ```
     在 K3s 主机上：
     ```bash
     ctr -n k8s.io images import /root/local-path-provisioner.tar
     kubectl delete pod -n local-path-storage -l app=local-path-provisioner
     ```
     等 provisioner 变为 Running。

2. **（可选）确认 pause 镜像**  
   若之前有 sandbox 拉取失败，确保 K3s 使用国内 pause 镜像（`/etc/rancher/k3s/config.yaml` 里有 `pause-image: registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.6`），然后 `systemctl restart k3s`。

3. **用 PVC 部署 registry**  
   provisioner Running 后，删掉当前用 emptyDir 的 registry，改用带 PVC 的配置：
   ```bash
   kubectl delete deployment registry -n registry
   kubectl delete pvc registry-pvc -n registry --ignore-not-found
   # 然后重新执行 setup.sh，或只 apply 步骤 3 的 manifest（含 PVC + Deployment）
   cd /path/to/nakama-plus/deploy/k3s
   sudo ./setup.sh
   ```
   或只重新创建 PVC 和 registry Deployment（从 setup.sh 里复制步骤 3 的 YAML 单独 apply）。  
   此时 PVC 会由 provisioner 自动绑定（Bound），registry Pod 会挂载该卷并正常启动，**数据会持久化**，重启不丢。

**小结**：PVC 无法使用是因为 **provisioner 没起来**（多半是镜像拉不到）。先让 provisioner 有镜像并 Running，再部署使用 PVC 的 registry，就能获得正常 PVC。

---

## 故障排查

- **Registry 一直 Pending（PVC Pending、Pod 未调度到任何节点）**  
  StorageClass 已是 `local-path (default)` 时，PVC 仍不绑定、Pod 不被调度，通常是下面之一：  
  1）**节点未 Ready**：`kubectl get nodes` 看 STATUS 是否为 Ready；若 NotReady 需修节点（网络、kubelet 等）。  
  2）**local-path-provisioner 未跑起来**：`kubectl get pods -n local-path-storage`，若 provisioner 不是 Running，看 `kubectl logs -n local-path-storage -l app=local-path-provisioner` 和 `kubectl describe pod -n local-path-storage -l app=local-path-provisioner`。  
  3）**看调度/绑定原因**：`kubectl describe pvc registry-pvc -n registry`（看 Events）、`kubectl get events -n registry --sort-by=.lastTimestamp`（看是否有 FailedScheduling 等）。  
  **先让流程跑通**：删掉 Registry 和 PVC，改用临时存储再继续后续步骤：  
  `kubectl delete deployment registry -n registry`  
  `kubectl delete pvc registry-pvc -n registry --ignore-not-found`  
  `kubectl apply -f deploy/k3s/registry-emptydir.yaml`  
  `kubectl rollout status deployment/registry -n registry --timeout=90s`  
  通过后从「安装 Kubernetes Dashboard」起手动执行 setup.sh 里后续步骤。镜像持久化可之后修好 provisioner 再改回 PVC。
- **nakama Pod 一直 ImagePullBackOff**  
  确认 192.168.102.224:30500 已部署且 K3s 的 `/etc/rancher/k3s/registries.yaml` 已配置并重启 K3s；确认本机已执行 `docker push 192.168.102.224:30500/nakama-plus:latest`。
- **nakama 起不来 / CrashLoopBackOff**  
  `kubectl logs -n nakama deployment/nakama` 查看日志；常见为数据库未就绪，等 postgres Pod Ready 后再看。
- **本机无法访问 30735/30751**  
  检查防火墙是否放行 30735、30751、30443、30500；确认 K3s 节点 IP 为 192.168.102.224。
- **Dashboard Pod 一直 Pending（Node: &lt;none&gt;）**  
  单节点且为 control-plane 时，节点有污点，官方 Dashboard 只带了 `master` 容忍，K3s 常用 `control-plane`。`setup.sh` 已对 Dashboard 和 metrics-scraper 做 patch 增加 control-plane 容忍。若之前未用脚本安装，可手动执行：  
  `kubectl patch deployment kubernetes-dashboard -n kubernetes-dashboard -p '{"spec":{"template":{"spec":{"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}'`  
  同样对 `dashboard-metrics-scraper` 做一次（把名字换成 dashboard-metrics-scraper）。
