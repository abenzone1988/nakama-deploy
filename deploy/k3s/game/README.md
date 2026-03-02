# 多游戏统一部署

按游戏独立部署 nakama 完整栈，不同游戏使用不同 namespace、镜像、NodePort，互不影响。

## 目录结构

```
game/
├── default.env           # 默认配置（各游戏可覆盖）
├── deploy-game.sh        # 部署脚本
├── games/                # 各游戏配置
│   ├── metal-slug.env   # 合金战线
│   └── stellar-mission.env  # 星际使命
├── templates/            # K8s 资源模板
│   ├── namespace.yaml.tpl
│   ├── postgres.yaml.tpl
│   ├── etcd.yaml.tpl
│   ├── nakama-config.yaml.tpl
│   ├── nakama-deployment.yaml.tpl
│   └── nakama-service.yaml.tpl
└── .generated/           # 生成的 YAML（按游戏分目录，可 gitignore）
```

## 快速部署

```bash
cd deploy/k3s/game
chmod +x deploy-game.sh

# 部署合金战线
./deploy-game.sh metal-slug

# 部署星际使命
./deploy-game.sh stellar-mission
```

## 新增游戏

1. 复制 `games/metal-slug.env` 为 `games/<游戏id>.env`
2. 修改配置：
   - `NAMESPACE`：K8s 命名空间（建议与游戏 id 一致）
   - `IMAGE`：该游戏的 nakama 镜像
   - `NODE_PORT_*`：与已有游戏错开（范围 30000-32767）
3. 执行 `./deploy-game.sh <游戏id>`

## 配置说明

| 变量 | 说明 | 默认 |
|------|------|------|
| NAMESPACE | K8s 命名空间 | 必填 |
| IMAGE | nakama 镜像地址 | 必填 |
| GAME_ID | 游戏标识（用于 label） | 同 NAMESPACE |
| REPLICAS | nakama 副本数 | 2 |
| NODE_PORT_SOCKET | 客户端连接端口 | 30735 |
| NODE_PORT_GRPC | gRPC 端口 | 30734 |
| NODE_PORT_CONSOLE | 控制台端口 | 30751 |
| SERVER_KEY | 客户端连接密钥 | sparkgame |
| ENCRYPTION_KEY | Session 加密密钥 | defaultencryptionkey |
| REFRESH_ENCRYPTION_KEY | Refresh token 密钥 | defaultrefreshencryptionkey |
| CONSOLE_USER | 控制台用户名 | admin |
| CONSOLE_PASSWORD | 控制台密码 | password |

**多游戏 NodePort 建议**：每游戏 +20 错开，如 30735/30755/30775...

## 与原有 nakama 部署的关系

- **原有方式**（`setup.sh`）：部署到 `nakama` 命名空间，适合单游戏或测试
- **本方式**（`deploy-game.sh`）：按游戏独立部署，适合多游戏生产

两者可并存：`nakama` 命名空间继续用原有配置，新游戏用 `deploy-game.sh` 部署到各自 namespace。
