# nakama-plus StatefulSet
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: nakama
  namespace: ${NAMESPACE}
spec:
  replicas: ${REPLICAS}
  serviceName: nakama-headless
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0
  selector:
    matchLabels:
      app: nakama
  template:
    metadata:
      labels:
        app: nakama
    spec:
      terminationGracePeriodSeconds: 60
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      initContainers:
        - name: migrate
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - "/nakama/nakama"
            - "migrate"
            - "up"
            - "--database.address"
            - "postgres:localdb@postgres:5432/nakama"
      containers:
        - name: nakama
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          args:
            - "--name"
            - "$(POD_NAME)"
            - "--database.address"
            - "postgres:localdb@postgres:5432/nakama"
            - "--config"
            - "/nakama/conf/config.yml"
            - "--cluster.gossip_bindaddr"
            - "$(POD_IP)"
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
          ports:
            - name: api
              containerPort: 7350
            - name: grpc
              containerPort: 7349
            - name: console
              containerPort: 7351
            - name: gossip
              containerPort: 7335
          volumeMounts:
            - name: config
              mountPath: /nakama/conf
              readOnly: true
            - name: data
              mountPath: /nakama/data
          readinessProbe:
            exec:
              command: ["/nakama/nakama", "healthcheck"]
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            exec:
              command: ["/nakama/nakama", "healthcheck"]
            initialDelaySeconds: 20
            periodSeconds: 15
      volumes:
        - name: config
          configMap:
            name: nakama-config
        - name: data
          emptyDir: {}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: nakama-pdb
  namespace: ${NAMESPACE}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: nakama
