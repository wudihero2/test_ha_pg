# Patroni 在 Kubernetes 的實際實現細節

## 重要發現：實際的連接方式

根據你的環境配置，我發現了關鍵細節！

### 1. Member 信息存儲在 Pod Annotations 中

每個 Patroni Pod 的 `metadata.annotations.status` 包含了該節點的連接資訊：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: patronidemo-0
  annotations:
    status: |
      {
        "conn_url": "postgres://10.244.0.125:5432/postgres",
        "api_url": "http://10.244.0.125:8008/patroni",
        "state": "running",
        "role": "primary",
        "version": "4.1.0",
        "xlog_location": 6157238632,
        "timeline": 5
      }
  labels:
    role: primary
    cluster-name: patronidemo
```

**關鍵點：** `conn_url` 使用的是 **Pod IP (10.244.0.125)** 而不是 DNS 名稱！

### 2. Leader 信息存儲在 ConfigMap Annotations 中

你展示的 ConfigMap `patronidemo-leader`：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: patronidemo-leader
  annotations:
    leader: patronidemo-0          # 指向主節點的 Pod 名稱
    acquireTime: "2025-10-31T..."
    renewTime: "2025-11-05T..."
    ttl: "30"
    optime: "6157238632"
    slots: '{"patronidemo_1":...}'
```

### 3. 副本如何找到並連接主節點（實際流程）

```
步驟 1: 副本查詢 ConfigMap
├─> kubectl get configmap patronidemo-leader -o jsonpath='{.metadata.annotations.leader}'
└─> 得到: "patronidemo-0"

步驟 2: 副本查詢主節點 Pod
├─> kubectl get pod patronidemo-0 -o jsonpath='{.metadata.annotations.status}'
└─> 得到: {"conn_url":"postgres://10.244.0.125:5432/postgres", ...}

步驟 3: 解析 conn_url
├─> Host: 10.244.0.125 (Pod IP!)
├─> Port: 5432
└─> Database: postgres

步驟 4: 生成 primary_conninfo
└─> host=10.244.0.125 port=5432 user=standby password=xxx application_name=patronidemo-1

步驟 5: PostgreSQL 連接
└─> WAL Receiver 直接連接到 Pod IP: 10.244.0.125:5432
```

## 這就是 Istio 問題的根源！

### 問題分析

**Patroni 使用 Pod IP 進行直接連接**，而不是 Service DNS！

```
副本 Pod (10.244.0.126)
    ↓
    連接到: 10.244.0.125:5432 (主節點 Pod IP)
    ↓
Istio Envoy Sidecar 攔截這個連接
    ↓
mTLS 加密/解密
    ↓
可能的問題：
- Envoy 尚未準備好
- mTLS handshake 失敗
- 雙重加密（PostgreSQL SSL + Istio mTLS）
- 連接超時
```

### 為什麼沒有 Istio 就能連上？

沒有 Istio 時：
```
副本 Pod → 直接 TCP 連接 → 主節點 Pod IP → PostgreSQL
```

有 Istio 時：
```
副本 Pod → Envoy Sidecar (出站) → mTLS → 主節點 Envoy Sidecar (入站) → PostgreSQL
```

Istio 的 Envoy Sidecar 會攔截所有基於 Pod IP 的連接！

## 解決方案（針對 Pod IP 連接）

### 方案 1: 排除 Pod CIDR（推薦）

在 StatefulSet 中添加 annotation，讓 PostgreSQL 流量繞過 Istio：

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: patronidemo
spec:
  template:
    metadata:
      annotations:
        # 排除 Pod CIDR，讓 Pod-to-Pod 流量不經過 Istio
        traffic.sidecar.istio.io/excludeOutboundIPRanges: "10.244.0.0/16"
        # 同時排除入站端口
        traffic.sidecar.istio.io/excludeInboundPorts: "5432"
    spec:
      # ...
```

**注意：** 需要替換 `10.244.0.0/16` 為你的 Pod CIDR。查看方法：

```bash
# 查看你的 Pod CIDR
kubectl cluster-info dump | grep -i pod-cidr
# 或
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
```

### 方案 2: 禁用 5432 端口的 mTLS

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: patroni-mtls-disable
  namespace: default
spec:
  selector:
    matchLabels:
      application: patroni
  portLevelMtls:
    5432:
      mode: DISABLE  # 完全禁用 5432 端口的 mTLS
```

### 方案 3: 配置 Patroni 使用 DNS 而非 Pod IP

修改 Patroni 配置，讓它使用 Headless Service DNS 而不是 Pod IP：

```yaml
env:
- name: PATRONI_POSTGRESQL_CONNECT_ADDRESS
  value: "$(PATRONI_NAME).patronidemo-headless.default.svc.cluster.local:5432"
- name: PATRONI_RESTAPI_CONNECT_ADDRESS
  value: "$(PATRONI_NAME).patronidemo-headless.default.svc.cluster.local:8008"
```

這樣 `conn_url` 會變成：
```
postgres://patronidemo-0.patronidemo-headless.default.svc.cluster.local:5432/postgres
```

**但是注意：** 這需要確保你有 Headless Service：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: patronidemo-headless
spec:
  clusterIP: None  # Headless
  selector:
    application: patroni
    cluster-name: patronidemo
  ports:
  - name: postgres
    port: 5432
  - name: patroni
    port: 8008
```

## 驗證和檢查

### 1. 檢查當前的 conn_url

```bash
# 查看主節點的 conn_url
kubectl get pod patronidemo-0 -n default -o jsonpath='{.metadata.annotations.status}' | jq -r '.conn_url'

# 輸出範例：
# postgres://10.244.0.125:5432/postgres  (使用 Pod IP)
# 或
# postgres://patronidemo-0.patronidemo-headless:5432/postgres  (使用 DNS)
```

### 2. 檢查副本的 primary_conninfo

```bash
# 進入副本 Pod
kubectl exec -it patronidemo-1 -n default -- bash

# 查看 PostgreSQL 配置
grep primary_conninfo /home/postgres/pgdata/pgroot/data/postgresql.conf
```

應該看到：
```
primary_conninfo = 'host=10.244.0.125 port=5432 ...'  (如果用 Pod IP)
# 或
primary_conninfo = 'host=patronidemo-0.patronidemo-headless port=5432 ...'  (如果用 DNS)
```

### 3. 測試網路連接

```bash
# 從副本 Pod 測試到主節點的連接
kubectl exec -it patronidemo-1 -n default -- bash

# 測試 Pod IP 連接（當前方式）
nc -zv 10.244.0.125 5432

# 測試 DNS 連接（如果配置了 Headless Service）
nc -zv patronidemo-0.patronidemo-headless 5432

# 查看實際的路由
ip route get 10.244.0.125
```

### 4. 檢查 Istio 是否攔截了流量

```bash
# 進入副本 Pod 的 Istio Sidecar
kubectl exec -it patronidemo-1 -n default -c istio-proxy -- curl localhost:15000/clusters | grep 10.244.0.125
kubectl exec -it patronidemo-1 -n default -c istio-proxy -- curl localhost:15000/config_dump | grep -A 10 "10.244.0.125"

# 查看 Envoy 統計
kubectl exec -it patronidemo-1 -n default -c istio-proxy -- curl localhost:15000/stats | grep "10.244.0.125"
```

## 推薦的完整解決方案

### 選項 A: 快速方案（排除流量）

如果你只想快速解決問題，使用 annotation 排除 Pod CIDR：

```bash
# 獲取你的 Pod CIDR
POD_CIDR=$(kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}')
echo "Pod CIDR: $POD_CIDR"

# 更新 StatefulSet
kubectl patch statefulset patronidemo -n default -p "
spec:
  template:
    metadata:
      annotations:
        traffic.sidecar.istio.io/excludeOutboundIPRanges: \"$POD_CIDR\"
        traffic.sidecar.istio.io/excludeInboundPorts: \"5432\"
"

# 滾動重啟 Pods
kubectl rollout restart statefulset patronidemo -n default
```

### 選項 B: 標準方案（使用 DNS + PeerAuthentication）

1. **創建 Headless Service**（如果還沒有）：

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: patronidemo-headless
  namespace: default
spec:
  clusterIP: None
  selector:
    application: patroni
    cluster-name: patronidemo
  ports:
  - name: postgres
    port: 5432
    targetPort: 5432
  - name: patroni
    port: 8008
    targetPort: 8008
EOF
```

2. **配置 Patroni 使用 DNS**：

```bash
kubectl set env statefulset/patronidemo -n default \
  PATRONI_POSTGRESQL_CONNECT_ADDRESS='$(PATRONI_NAME).patronidemo-headless.default.svc.cluster.local:5432' \
  PATRONI_RESTAPI_CONNECT_ADDRESS='$(PATRONI_NAME).patronidemo-headless.default.svc.cluster.local:8008'
```

3. **禁用 PostgreSQL 端口的 mTLS**：

```bash
cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: patroni-mtls-disable
  namespace: default
spec:
  selector:
    matchLabels:
      application: patroni
      cluster-name: patronidemo
  portLevelMtls:
    5432:
      mode: DISABLE
EOF
```

4. **滾動重啟**：

```bash
kubectl rollout restart statefulset patronidemo -n default
kubectl rollout status statefulset patronidemo -n default
```

### 驗證解決方案

```bash
# 等待所有 Pods 重啟
kubectl wait --for=condition=ready pod -l application=patroni -n default --timeout=300s

# 檢查新的 conn_url（應該使用 DNS）
kubectl get pod patronidemo-0 -n default -o jsonpath='{.metadata.annotations.status}' | jq -r '.conn_url'

# 檢查副本的複製狀態
kubectl exec -it patronidemo-0 -n default -- psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"

# 應該看到：
#  application_name | state     | sync_state
# ------------------+-----------+------------
#  patronidemo-1   | streaming | async
#  patronidemo-2   | streaming | async
```

## 總結

### 核心問題

- Patroni 預設使用 **Pod IP** 進行直接連接
- Istio Envoy Sidecar 會攔截所有 Pod IP 的連接
- mTLS 加密與 PostgreSQL 串流複製不兼容

### 最佳實踐

1. **使用 DNS 而非 Pod IP**：配置 `PATRONI_POSTGRESQL_CONNECT_ADDRESS` 使用 Headless Service
2. **禁用 5432 端口的 mTLS**：使用 `PeerAuthentication` 資源
3. **或排除 Pod CIDR**：如果不想改變 Patroni 配置，直接排除 Pod 網路

### 為什麼這很重要

- PostgreSQL 串流複製是長連接，需要穩定的 TCP 連接
- Istio 的 mTLS 增加了延遲和複雜度
- PostgreSQL 有自己的 SSL/TLS 機制，不需要 Istio 的 mTLS

### 後續優化

配置完成後，你還可以：

1. **監控複製延遲**：
```sql
SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;
```

2. **配置同步複製**（可選）：
```yaml
# 在 Patroni 配置中
synchronous_mode: true
synchronous_mode_strict: true
```

3. **設置 NetworkPolicy**（增強安全性）：
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: patroni-network-policy
spec:
  podSelector:
    matchLabels:
      application: patroni
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          application: patroni
    ports:
    - protocol: TCP
      port: 5432
  egress:
  - to:
    - podSelector:
        matchLabels:
          application: patroni
    ports:
    - protocol: TCP
      port: 5432
```
