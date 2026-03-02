# nakama 运行配置（ConfigMap）
apiVersion: v1
kind: ConfigMap
metadata:
  name: nakama-config
  namespace: ${NAMESPACE}
data:
  config.yml: |
    name: nakama-node
    data_dir: "/nakama/data"
    shutdown_grace_sec: 30
    logger:
      stdout: true
      level: "info"
    database:
      address:
        - "postgres:localdb@postgres:5432/nakama"
      conn_max_lifetime_ms: 0
      max_open_conns: 0
      max_idle_conns: 100
    runtime:
      path: "/nakama/data/modules"
      http_key: "http_key"
    socket:
      server_key: "${SERVER_KEY}"
      port: 7350
      max_message_size_bytes: 4096
    session:
      encryption_key: "${ENCRYPTION_KEY}"
      refresh_encryption_key: "${REFRESH_ENCRYPTION_KEY}"
      token_expiry_sec: 7200
    console:
      port: 7351
      username: "${CONSOLE_USER}"
      password: "${CONSOLE_PASSWORD}"
    cluster:
      gossip_bindaddr: "0.0.0.0"
      gossip_bindport: 7335
      join:
        - "nakama-headless.${NAMESPACE}.svc.cluster.local:7335"
      etcd:
        endpoints:
          - "http://etcd.${NAMESPACE}.svc.cluster.local:2379"
