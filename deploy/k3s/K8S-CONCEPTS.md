# Kubernetes 概念速览（结合 nakama-plus 部署）

面向不熟悉 K8s 的读者，用「我们实际用到的配置」说明每个概念、要注意什么、以及之前 Registry 为什么会 Pending。



## **概念速查（和这次部署的关系）**


| 概念                             | 通俗理解                                               | 和我们配置的关系                                                            | 要注意什么                                                          |
| ------------------------------ | -------------------------------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------- |
| **集群 / Node**                  | 集群 = 整套 K3s；Node = 里面的一台机器。Pod 必须被调度到某台 Node 上才能跑。 | 你只有 192.168.102.224 一个 Node。之前 Registry 的 Pod 没被调度，所以 Node: <none>。 | 若 Pod 一直 Pending，先看是否没被调度（Node 为空）。                            |
| **Namespace**                  | 把资源按「项目/用途」分区，避免名字冲突。                              | registry、nakama、kubernetes-dashboard 各一个命名空间。                       | 查资源要带 -n 命名空间，否则看不到。                                           |
| **Pod**                        | 真正跑程序的最小单位，里面是容器（如 registry:2）。                    | 每个服务（registry、nakama、postgres）都是 1 个或多个 Pod。                        | Pending = 未调度或等存储/镜像；Running 才正常。                              |
| **Deployment**                 | 「保持 N 个这样的 Pod 在跑」的控制器；你改的是它的 YAML。                | 我们的 registry、nakama、postgres 都是 Deployment 管理的。                     | 改 YAML 后 apply，会滚动更新 Pod；若新 Pod 仍用未绑定的 PVC，还是会 Pending。        |
| **PVC（PersistentVolumeClaim）** | 「我要一块持久存储」的申请；要有人（StorageClass/PV）满足才会 Bound。      | 之前 registry 用了 registry-pvc，K3s 没配存储，PVC 一直 Pending。                | 单机/测试环境常不配 StorageClass，PVC 容易一直 Pending，导致用它的 Pod 也 Pending。  |
| **emptyDir**                   | 临时目录：Pod 在就有，Pod 删就丢；不依赖任何存储系统。                    | 把 registry 的卷改成 emptyDir 后，不再等 PVC，Pod 立刻能被调度并跑起来。                  | 适合测试/非关键数据；要持久化再单独配 PVC。                                       |
| **Service**                    | 给一组 Pod 一个固定名字和端口，方便访问、不随 Pod 重启变 IP。              | registry、nakama 都有对应 Service。                                       | 集群内用服务名访问；集群外要用 NodePort 或 Ingress。                            |
| **NodePort**                   | 在每台 Node 上开一个固定端口，从主机/外网访问。                        | registry 用 30500，nakama 用 30735/30751 等。                            | 本机访问用 [http://192.168.102.224:端口。](http://192.168.102.224:端口。) |
| **ConfigMap**                  | 把配置文件内容存成 K8s 资源，再挂进 Pod 当文件。                      | nakama 的 config.yml 存在 ConfigMap，挂到 /nakama/conf。                   | 改配置可只改 ConfigMap，再重启 Pod，不用重做镜像。                               |
| **readinessProbe**             | 检查 Pod 是否「可以接流量」；通过才算 Ready。                       |                                                                     |                                                                |


---

## 一、整体关系：你发一条命令，K8s 在背后做了什么

- 你执行的是：`kubectl apply -f xxx.yaml` 或运行 `setup.sh`。
- K8s 会根据 YAML 里的「资源类型」创建/更新对应的**对象**（Deployment、Pod、Service 等）。
- 这些对象之间有关系：例如 **Deployment 会创建 Pod**，**Service 会指向 Pod**。  
所以：**你改的是 YAML，真正跑程序的是 Pod；Deployment 负责「保持有 N 个这样的 Pod 在跑」。**

下面按「从大到小」的顺序说：集群 → 节点 → 命名空间 → 工作负载（Deployment/Pod）→ 存储（Volume/PVC）→ 网络（Service）。

---

## 二、集群（Cluster）和节点（Node）

- **集群**：你的一整套 K3s，就是一个 Kubernetes 集群。里面有一台或多台机器。
- **节点（Node）**：集群里的一台机器（物理机或虚拟机）。  
  - 你只有一台主机 192.168.102.224 时，集群里通常就一个 Node。  
  - `kubectl get nodes` 可以看到所有节点；之前 Registry 的 Pod 显示 `Node: <none>` 表示**还没有任何节点被选来跑这个 Pod**。

**为什么要关心？**  
Pod 最终必须被「调度」到某台 Node 上才能运行。如果调度失败（例如缺存储、资源不足、**节点有污点且 Pod 没有对应容忍**），Pod 就会一直 Pending。

**单节点且节点是 control-plane 时**：K3s 通常会给 control-plane 节点打污点（如 `node-role.kubernetes.io/control-plane:NoSchedule`），表示「默认不要把普通业务 Pod 放上来」。若集群里只有这一台节点，又不给业务 Pod 加**容忍（toleration）**，调度器就找不到可调度的节点，Pod 会一直 `Node: <none>`。我们的 registry、postgres、nakama、以及 Dashboard 的 Deployment 里都加了对应 toleration，才能在你这种单 control-plane 节点上跑起来。

---

### 什么是「污点」（Taint）？为什么叫污点？

- **污点**是打在**节点（Node）**上的一条「标记」，用来表达：**除非 Pod 明确声明能接受，否则不要把我当成可调度目标**。  
  可以理解成：节点给自己贴了一个「不接普通客」的标签，调度器默认会绕开它。
- **为什么叫污点**：英文是 **Taint**，本意是「污染、瑕疵」。用在节点上，表示「这个节点有特殊限制，算是有瑕疵的调度目标」，只有「不介意这个瑕疵」的 Pod（通过 **Toleration，容忍**）才会被放上去。
- **常见用法**：  
  - **control-plane / master 节点**：打 `NoSchedule` 污点，避免把普通业务 Pod 和系统组件挤在一起，保证控制面稳定。  
  - ** GPU 节点、特殊硬件节点**：只让带对应 toleration 的 Pod 上来。  
  - **即将下线或维护的节点**：打污点后不再调度新 Pod。
- **容忍（Toleration）**：写在 **Pod 的 spec** 里，表示「我可以接受带有某污点的节点」。  
  例如写 `key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule`，就表示「允许被调度到带有 control-plane NoSchedule 污点的节点上」。  
  这样在**单节点且该节点是 control-plane** 时，业务 Pod（registry、Dashboard、nakama 等）才能被调度上去。

---

## 三、命名空间（Namespace）

- **是什么**：集群内部的一种「分区」，用来把不同用途的资源隔开（例如 `registry`、`nakama`、`kubernetes-dashboard`）。
- **我们怎么用**：  
  - `registry` 命名空间：只放镜像仓库。  
  - `nakama` 命名空间：放 Postgres、nakama-plus。  
  - `kubernetes-dashboard`：放 Dashboard。
- **命令里经常带 `-n registry`、`-n nakama`**：表示「只查/只操作这个命名空间里的资源」。

**要注意**：  

- 不同命名空间里的同名资源不冲突（例如可以都有 `registry` 这个 Deployment，但在不同 namespace）。  
- 查 Pod、查事件时，一定要带上正确的 `-n <命名空间>`，否则看不到。

---

## 四、Pod

- **是什么**：K8s 里**真正跑你程序的最小单位**。一个 Pod 里通常是一个或多个容器（我们这里都是一个 Pod 一个容器）。
- **和「直接跑 docker run」的对比**：  
  - 以前：你在机器上 `docker run registry:2`，容器就在那台机器上跑。  
  - 现在：你写 YAML 描述「要跑 registry:2」，K8s 会在一台 Node 上创建一个 Pod，Pod 里跑这个容器。
- **Pod 有状态**：  
  - `Pending`：还没被调度到某台 Node，或还在等存储/镜像等。  
  - `Running`：已调度且容器在跑。  
  - `CrashLoopBackOff`：容器反复启动又挂掉。

**为什么会 Pending？**  

- 调度器在选 Node 时，会检查这个 Pod 的**所有条件**是否满足。  
- 我们遇到的：Pod 声明「我要挂载一个叫 `registry-pvc` 的卷」。  
  - 若 **PVC 还没绑定成功**（没有可用存储），调度器就**不会**给这个 Pod 分配 Node。  
  - 所以 Pod 一直 `Node: <none>`、`Status: Pending`。
- 改成 **emptyDir** 后，不再依赖 PVC，调度器立刻能选 Node，Pod 就能从 Pending 变成 Running。

---

## 五、Deployment（部署）

- **是什么**：一种「控制器」，负责**维持一类 Pod 的数量和样子**。  
  - 例如：`replicas: 1` 表示「始终要有 1 个符合下面模板的 Pod 在跑」。  
  - 你改的是 Deployment 的 YAML（例如把卷从 PVC 改成 emptyDir），K8s 会**滚动更新**：起新 Pod，旧 Pod 停掉。
- **和 Pod 的关系**：  
  - 你不直接创建 Pod，而是创建 Deployment；Deployment 再去创建 Pod（通过 ReplicaSet）。  
  - `kubectl get pods -n registry` 里看到的 `registry-6984479d9d-njnzp`，名字里的 `6984479d9d` 就是 ReplicaSet 的 hash，表示「这是 registry 这个 Deployment 当前模板生成的 Pod」。

**要注意**：  

- 改 YAML 后再次 `kubectl apply`，Deployment 会按新模板更新 Pod；如果新模板里仍有 PVC 且 PVC 没绑定，新 Pod 还是会 Pending。  
- `kubectl rollout status deployment/registry -n registry` 是在等「新 Pod 已经 Ready」，若 Pod 一直 Pending，这条命令就会一直卡住。

### 5.1 nakama 的 StatefulSet 与滚动更新

nakama 使用 **StatefulSet**（而非 Deployment），Pod 有固定名字（nakama-0、nakama-1），便于集群内节点发现。

**滚动更新流程**（更新镜像或配置时）：

1. K8s 按 `updateStrategy: RollingUpdate` 每次只更新一个 Pod（从高序号到低序号：nakama-1 → nakama-0）。
2. 更新某个 Pod 时：先发 **SIGTERM**，等待 `terminationGracePeriodSeconds`（60 秒）。
3. nakama 收到 SIGTERM 后，在 `shutdown_grace_sec`（30 秒）内：关闭新连接、等待现有连接结束、执行 `registerShutdown` 回调。
4. **PodDisruptionBudget**（minAvailable: 1）保证更新期间至少 1 个 nakama Pod 可用，客户端可继续连到未更新的节点。

**相关配置**：`nakama-config.yaml` 的 `shutdown_grace_sec`、`nakama-deployment.yaml` 的 `terminationGracePeriodSeconds` 和 `updateStrategy`。

---

## 六、Volume（卷）与存储：PVC 和 emptyDir

Pod 里跑的程序往往需要「一块空间」存数据（例如 registry 存镜像层）。在 K8s 里，这块空间用 **Volume** 表示，挂到容器里的某个路径（例如 `/var/lib/registry`）。

### 6.1 StorageClass（存储类）与默认存储

- **是什么**：StorageClass 定义「如何动态创建存储」——由谁（provisioner）在哪儿创建、回收策略等。  
  - **默认 StorageClass**：PVC 里不写 `storageClassName` 时，会使用集群里标记为 `is-default-class: "true"` 的那一个。  
  - 若**没有任何** StorageClass 被标成默认，且 PVC 也没写 `storageClassName`，PVC 就没人处理，会一直 Pending。
- **我们现在的做法**：  
  - 在 `setup.sh` 里先检查是否已有默认 StorageClass；若没有，就安装 **Rancher local-path-provisioner**（见 `local-path-storage.yaml`）。  
  - 它会创建一个名为 `local-path` 的 StorageClass，并标成默认；数据实际落在节点本地目录（如 `/var/lib/rancher/k3s/storage`）。  
  - 这样后续的 PVC（例如 registry 的 10Gi）就有人处理，能绑定成功。

**为什么要配？**  

- Registry 需要**持久化存储**：push 的镜像要写在磁盘上，Pod 重启或节点重启后不能丢。  
- 不配 StorageClass，PVC 绑不上，Pod 就会一直 Pending；配好后 Registry 用 PVC，数据才能固定保存。

### 6.2 PersistentVolumeClaim（PVC）——「我要一块持久存储」

- **是什么**：一种**声明**：「我要 N Gi 的存储，请集群给我绑定一块」。  
  - 集群里要有 **StorageClass**（或管理员预置的 **PersistentVolume**），才能有人去「满足」这份声明。  
  - 满足后，PVC 状态从 `Pending` 变成 `Bound`，并绑定到某一块 PersistentVolume（PV）。
- **我们现在的配置**：  
  - `registry-pvc`：申请 10Gi，**显式写 `storageClassName: local-path`**，给 registry 用。  
  - 只要集群里已按上一步装好 local-path 并设为默认，这份 PVC 会被自动满足并 Bound。
- **Pod 和 PVC 的关系**：  
  - Pod 的 volume 里写 `persistentVolumeClaim: claimName: registry-pvc`，表示「这个卷用 registry-pvc 这块存储」。  
  - **调度器规则**：若 PVC 还没 Bound，调度器**不会**把该 Pod 调度到任何 Node，所以 Pod 也会一直 Pending。

**之前你遇到 Pending 的原因**：  

- 当时集群**没有**可用的默认 StorageClass（或 PVC 没写 `storageClassName: local-path`），PVC 没人满足 → 一直 Pending → Pod 无法被调度。  
- 现在脚本会先确保有 default StorageClass，再让 Registry 使用 PVC，这样既能调度成功，又能持久化。

### 6.3 emptyDir——「临时目录，Pod 在就有，Pod 删就没」

- **是什么**：一种**临时卷**，不涉及「申请存储」。  
  - 调度器只需要选一台 Node，在那台 Node 上给这个 Pod 建一个空目录，挂进容器。  
  - Pod 删除后，这个目录里的数据就没了。
- **我们改成 emptyDir 之后**：  
  - 不再依赖任何 PVC，调度器立刻能选 Node，Pod 能正常从 Pending → Running。  
  - 代价：registry 重启或 Pod 被删后，之前 push 的镜像会丢；若要持久化，以后再单独配 StorageClass + PVC。

**要注意**：  

- **Registry 需要持久化**，所以我们已改回用 PVC + StorageClass（local-path），并保证脚本里先配好默认存储。  
- 只有「可以丢」的临时数据才用 emptyDir。

---

## 七、Service（服务）与 NodePort

- **是什么**：给一组 Pod 一个**固定访问方式**（名字 + 端口），不会因为 Pod 重启换 IP 而失效。  
  - 例如：`registry` 这个 Service 背后是 `app: registry` 的 Pod；  
  - 集群内其他 Pod 可以通过 `http://registry.registry.svc.cluster.local:5000` 访问；  
  - 集群外（你本机）要访问，就要靠 **NodePort** 或 Ingress。
- **NodePort**：  
  - 在 Service 里写 `type: NodePort`，并指定 `nodePort: 30500`。  
  - 意思是：**每台 Node 上**都开放 30500 端口；访问「任意 Node 的 IP:30500」都会转发到 registry 的 5000 端口。  
  - 所以你本机访问 `http://192.168.102.224:30500` 就能访问 registry。

**为什么要这样？**  

- Pod 的 IP 会变（重启就换），不能直接写死；  
- Service 的名字和端口在集群内是稳定的；  
- NodePort 让你从集群外用「主机 IP + 固定端口」访问，方便调试和 push 镜像。

---

## 八、ConfigMap

- **是什么**：把「配置文件内容」存成 K8s 里的一种资源，再挂进 Pod 当文件用。  
  - 我们用的：`nakama-config` 里存了 `config.yml` 的内容；  
  - nakama 的 Pod 把 ConfigMap 挂到 `/nakama/conf`，启动参数里 `--config /nakama/conf/config.yml`。
- **好处**：改配置不用重新做镜像，改 ConfigMap 再让 Pod 重启即可（例如 `kubectl rollout restart deployment/nakama -n nakama`）。

---

## 九、initContainers（初始化容器）

- **是什么**：和主容器在同一个 Pod 里，按顺序执行；**先跑完 init 容器，再跑主容器**。  
  - 我们 nakama 的 Deployment 里：  
    - 先跑 `migrate`：执行数据库迁移；  
    - 再跑 `nakama`：真正启动服务。
- **为什么要这样**：保证数据库表结构是最新的，再启动业务，避免启动报错。

---

## 十、探针：readinessProbe 与 livenessProbe

- **readinessProbe（就绪探针）**：  
  - K8s 每隔一段时间检查一次（例如对 5000 端口做 tcpSocket 检查）。  
  - **通过**：认为 Pod「就绪」，可以接流量；**不通过**：不会把流量转给这个 Pod。  
  - `kubectl rollout status` 等的就是「新 Pod 就绪」；若没有 readinessProbe，部分环境会认为 Pod 一直未就绪，rollout 就会卡住。
- **livenessProbe（存活探针）**：  
  - 若连续失败，K8s 认为容器「挂了」，会重启该容器。  
  - 用来从「假死但进程还在」的状态里恢复。

我们给 registry 加了 `tcpSocket: port: 5000` 的 readiness 和 liveness，这样：  

- 容器真正监听 5000 后，Pod 会变 Ready，rollout 能完成；  
- 若 registry 进程卡死，端口不通，会被重启。

---

## 十一、小结：之前 Registry Pending 的完整链条与当前做法

**当时 Pending 的原因**：  

1. YAML 里给 registry 的 Pod 配了 **Volume：PVC `registry-pvc`**。
2. 集群里**没有**能为 `registry-pvc` 提供存储的 StorageClass（或未设为默认），所以 **PVC 一直 Pending（未 Bound）**。
3. 调度器规则：**使用未 Bound 的 PVC 的 Pod 不会被调度**，所以 Pod 的 `Node: <none>`，**Status: Pending**。
4. `kubectl rollout status` 在等「至少 1 个新 Pod Ready」，Pod 永远没被调度，就永远等不到，所以**卡住**。

**当前做法（推荐）**：  

1. **先配置默认存储**：`setup.sh` 里检查是否已有默认 StorageClass；没有则安装 `local-path-storage.yaml`（Rancher local-path-provisioner），并设为默认。
2. **Registry 使用 PVC 持久化**：registry 的 Deployment 再次使用 `registry-pvc`，并在 PVC 里**显式写 `storageClassName: local-path`**，这样 PVC 能绑定，Pod 能被调度，且 **push 的镜像会落在节点本地磁盘，重启不丢**。
3. 保留 **readinessProbe**，让 `rollout status` 能正常完成。

之后你再看 `kubectl describe pod` 时，可以重点看：  

- **Node**：是否已经分配到某台节点；  
- **Volumes**：用的是 PVC 还是 emptyDir；  
- **Events**：是否有调度失败、拉镜像失败、健康检查失败等事件。

这样就能快速判断「为什么会 Pending / 为什么起不来」。