# nakama 对外服务（NodePort）
apiVersion: v1
kind: Service
metadata:
  name: nakama
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    app: nakama
  ports:
    - name: grpc
      port: 7349
      targetPort: 7349
      nodePort: ${NODE_PORT_GRPC}
    - name: socket
      port: 7350
      targetPort: 7350
      nodePort: ${NODE_PORT_SOCKET}
    - name: console
      port: 7351
      targetPort: 7351
      nodePort: ${NODE_PORT_CONSOLE}
---
# Headless Service（节点间 gossip）
apiVersion: v1
kind: Service
metadata:
  name: nakama-headless
  namespace: ${NAMESPACE}
spec:
  clusterIP: None
  selector:
    app: nakama
  ports:
    - name: gossip
      port: 7335
      targetPort: 7335
