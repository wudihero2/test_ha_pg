# Patroni + Istio 整合解決方案

## 問題背景

Patroni 在 Kubernetes 環境中使用 **Pod IP** 進行 PostgreSQL 串流複製連接。當啟用 Istio 時，Envoy Sidecar 會攔截所有 Pod IP 流量並嘗試建立 mTLS 連接，導致與 PostgreSQL 協議衝突，造成串流複製失敗。

### 核心問題

```
副本 Pod (PostgreSQL)
    ↓
嘗試連接主節點 Pod IP (10.244.0.125:5432)
    ↓
Envoy Sidecar 攔截流量，要求 mTLS handshake
    ↓
PostgreSQL 協議不兼容 Istio mTLS
    ↓
❌ 連接失敗
```

---

## 解決方案總覽

| 方案 | 難度 | 影響範圍 | 推薦指數 |
|------|------|----------|----------|
| [方案 1: 禁用 PostgreSQL 端口的 mTLS](#方案-1-禁用-postgresql-端口的-mtls推薦) | ⭐ 簡單 | 僅 5432 端口 | ⭐⭐⭐⭐⭐ |
| [方案 2: 排除端口流量](#方案-2-排除端口流量推薦) | ⭐ 簡單 | 僅 5432 端口 | ⭐⭐⭐⭐⭐ |
| [方案 3: 改用 DNS + Headless Service](#方案-3-改用-dns--headless-service) | ⭐⭐⭐ 複雜 | 需要重構配置 | ⭐⭐⭐ |

**最佳實踐：方案 1 + 方案 2 組合使用**

---

## 方案 1: 禁用 PostgreSQL 端口的 mTLS（推薦）

### 說明

使用 Istio 的 `PeerAuthentication` 資源，**僅對 5432 端口禁用 mTLS**，其他端口（如 8008 Patroni API）仍然享受 mTLS 保護。

### 優點

- ✅ **配置簡單**：只需一個 YAML 文件
- ✅ **精確控制**：只影響 PostgreSQL 端口
- ✅ **其他端口仍受保護**：Patroni API (8008) 仍使用 mTLS
- ✅ **不需要修改 StatefulSet**：無需重啟 Pod
- ✅ **Kubernetes 原生**：符合 Istio 最佳實踐

### 缺點

- ⚠️ 5432 端口流量仍會經過 Envoy（有輕微性能開銷）
- ⚠️ 需要 Istio 安裝在集群中

### 配置步驟

#### 1. 創建 PeerAuthentication

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: patroni-mtls-disable
  namespace: default  # 替換為你的 namespace
spec:
  selector:
    matchLabels:
      application: patroni
      cluster-name: patronidemo
  mtls:
    mode: STRICT  # 預設所有端口使用嚴格 mTLS
  portLevelMtls:
    5432:
      mode: DISABLE  # 只禁用 5432 端口的 mTLS
```

#### 2. 應用配置

```bash
kubectl apply -f patroni_istio_mtls.yaml
```

#### 3. 驗證配置

```bash
# 查看 PeerAuthentication
kubectl get peerauthentication -n default

# 檢查配置是否生效
kubectl describe peerauthentication patroni-mtls-disable -n default
```

#### 4. 測試連接

```bash
# 從副本 Pod 測試到主節點的連接
kubectl exec -it patronidemo-1 -n default -- bash -c \
  "psql -h patronidemo-0 -U postgres -c 'SELECT version();'"

# 檢查串流複製狀態
kubectl exec -it patronidemo-0 -n default -- psql -U postgres -c \
  "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

### 完整配置文件

保存為 `patroni_istio_mtls.yaml`：

```yaml
---
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
  mtls:
    mode: STRICT
  portLevelMtls:
    5432:
      mode: DISABLE
```

---

## 方案 2: 排除端口流量（推薦）

### 說明

使用 Pod annotation 讓 Envoy Sidecar **完全不攔截** 5432 端口的流量，PostgreSQL 連接直接繞過 Istio。

> **重要：** 不需要手動填寫 Pod CIDR IP 範圍！只需排除端口即可。

### 優點

- ✅ **性能最佳**：流量完全繞過 Envoy，無任何開銷
- ✅ **配置簡單**：只需添加 annotation
- ✅ **不需要 IP 範圍**：只排除端口，不需要知道 Pod CIDR
- ✅ **即時生效**：Pod 重啟後立即生效

### 缺點

- ⚠️ 需要重啟 StatefulSet 的 Pod
- ⚠️ 5432 端口完全沒有 Istio 的可觀測性（但有 PostgreSQL 自己的日誌）

### 配置步驟

#### 1. 修改 StatefulSet

編輯 `patroni_k8s.yaml`：

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: patronidemo
spec:
  template:
    metadata:
      labels:
        application: patroni
        cluster-name: patronidemo
      annotations:
        # 排除 PostgreSQL 端口，讓流量不經過 Envoy
        traffic.sidecar.istio.io/excludeInboundPorts: "5432"
        traffic.sidecar.istio.io/excludeOutboundPorts: "5432"
    spec:
      # ... 其他配置保持不變
```

#### 2. 應用配置並滾動重啟

```bash
# 應用配置
kubectl apply -f patroni_k8s.yaml

# 滾動重啟 StatefulSet
kubectl rollout restart statefulset patronidemo -n default

# 等待所有 Pod 就緒
kubectl rollout status statefulset patronidemo -n default

# 或者手動刪除 Pod（StatefulSet 會自動重建）
kubectl delete pod patronidemo-0 -n default
kubectl delete pod patronidemo-1 -n default
kubectl delete pod patronidemo-2 -n default
```

#### 3. 驗證配置

```bash
# 檢查 Pod annotation
kubectl get pod patronidemo-0 -n default -o jsonpath='{.metadata.annotations}' | jq

# 檢查 Envoy 配置（應該不包含 5432 端口）
kubectl exec -it patronidemo-1 -n default -c istio-proxy -- \
  curl -s localhost:15000/config_dump | grep -A 5 "5432"

# 測試串流複製
kubectl exec -it patronidemo-0 -n default -- psql -U postgres -c \
  "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

### 完整的 Annotation 說明

```yaml
annotations:
  # 排除入站端口：外部到 Pod 的流量
  traffic.sidecar.istio.io/excludeInboundPorts: "5432"

  # 排除出站端口：Pod 到外部的流量
  traffic.sidecar.istio.io/excludeOutboundPorts: "5432"

  # ❌ 不推薦：排除 IP 範圍（需要手動填寫 Pod CIDR）
  # traffic.sidecar.istio.io/excludeOutboundIPRanges: "10.244.0.0/16"
```

### 為什麼不需要填寫 IP 範圍？

**錯誤做法**（需要手動填寫 Pod CIDR）：

```yaml
annotations:
  traffic.sidecar.istio.io/excludeOutboundIPRanges: "10.244.0.0/16"  # ❌ 需要知道 Pod CIDR
```

問題：
- 不同集群的 Pod CIDR 不同
- GKE、EKS、AKS、kind、minikube 都有不同的預設值
- 硬編碼 IP 範圍違反 Kubernetes 的動態性原則

**正確做法**（只排除端口）：

```yaml
annotations:
  traffic.sidecar.istio.io/excludeInboundPorts: "5432"   # ✅ 簡單且通用
  traffic.sidecar.istio.io/excludeOutboundPorts: "5432"  # ✅ 不需要知道 IP
```

優點：
- ✅ 不需要知道 Pod CIDR
- ✅ 跨集群通用
- ✅ 配置簡單明確

---

## 方案 3: 改用 DNS + Headless Service

### 說明

修改 Patroni 配置，讓它使用 **DNS 名稱**而非 Pod IP 進行連接。配合 Headless Service 提供穩定的 DNS 解析。

### 優點

- ✅ **符合 Kubernetes 最佳實踐**：使用 DNS 而非 IP
- ✅ **Pod IP 變化不影響連接**：DNS 始終指向正確的 Pod
- ✅ **與 Istio 兼容性更好**：DNS 流量更容易管理
- ✅ **可使用 DestinationRule**：可精確控制流量策略

### 缺點

- ⚠️ **配置複雜**：需要修改多個文件
- ⚠️ **需要重建 Patroni 集群**：涉及 entrypoint.sh 修改
- ⚠️ **仍需配合方案 1 或 2**：DNS 解析後仍是 Pod IP 連接
- ⚠️ **測試成本高**：需要驗證 Patroni 的所有功能

### 配置步驟

#### 1. 創建 Headless Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: patronidemo-headless
  namespace: default
  labels:
    application: patroni
    cluster-name: patronidemo
spec:
  clusterIP: None  # Headless Service 關鍵設定
  selector:
    application: patroni
    cluster-name: patronidemo
  ports:
  - name: tcp-postgresql
    port: 5432
    targetPort: 5432
    protocol: TCP
  - name: http-patroni
    port: 8008
    targetPort: 8008
    protocol: TCP
```

#### 2. 修改 entrypoint.sh

```bash
cat > /home/postgres/patroni.yml <<__EOF__
bootstrap:
  dcs:
    postgresql:
      use_pg_rewind: true
      parameters:
        summarize_wal: on
      pg_hba:
      - host all all 0.0.0.0/0 md5
      - host replication ${PATRONI_REPLICATION_USERNAME} ${PATRONI_KUBERNETES_POD_IP}/16 md5
      - host replication ${PATRONI_REPLICATION_USERNAME} 127.0.0.1/32 md5
restapi:
  connect_address: '${PATRONI_NAME}.patronidemo-headless.default.svc.cluster.local:8008'
postgresql:
  connect_address: '${PATRONI_NAME}.patronidemo-headless.default.svc.cluster.local:5432'
  authentication:
    superuser:
      password: '${PATRONI_SUPERUSER_PASSWORD}'
    replication:
      password: '${PATRONI_REPLICATION_PASSWORD}'
  parameters:
    summarize_wal: on
__EOF__
```

**關鍵變更：**

```diff
- connect_address: '${PATRONI_KUBERNETES_POD_IP}:8008'
+ connect_address: '${PATRONI_NAME}.patronidemo-headless.default.svc.cluster.local:8008'

- connect_address: '${PATRONI_KUBERNETES_POD_IP}:5432'
+ connect_address: '${PATRONI_NAME}.patronidemo-headless.default.svc.cluster.local:5432'
```

#### 3. 重新構建 Docker Image

```bash
# 構建新的 image
docker build -t patroni:test .

# Load 到 Kubernetes（kind 範例）
kind load docker-image patroni:test

# 或者推送到 registry
docker tag patroni:test your-registry/patroni:test
docker push your-registry/patroni:test
```

#### 4. 重建 Patroni 集群

```bash
# 刪除現有的 StatefulSet（會刪除所有數據！）
kubectl delete statefulset patronidemo -n default

# 應用新配置
kubectl apply -f patroni_k8s.yaml
kubectl apply -f patroni_istio_mtls.yaml  # 仍需方案 1
```

#### 5. 驗證 DNS 解析

```bash
# 測試 DNS 解析
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- \
  nslookup patronidemo-0.patronidemo-headless.default.svc.cluster.local

# 檢查 Patroni 的 conn_url（應該使用 DNS）
kubectl get pod patronidemo-0 -n default -o jsonpath='{.metadata.annotations.status}' | jq -r '.conn_url'

# 應該看到類似：
# postgres://patronidemo-0.patronidemo-headless.default.svc.cluster.local:5432/postgres
```

---

## 推薦組合方案

### 最佳實踐：方案 1 + 方案 2

同時使用兩個方案，雙重保障：

```yaml
---
# 方案 1: PeerAuthentication
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
  mtls:
    mode: STRICT
  portLevelMtls:
    5432:
      mode: DISABLE

---
# 方案 2: StatefulSet with Annotations
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: patronidemo
spec:
  template:
    metadata:
      annotations:
        traffic.sidecar.istio.io/excludeInboundPorts: "5432"
        traffic.sidecar.istio.io/excludeOutboundPorts: "5432"
    spec:
      # ... 其他配置
```

### 為什麼組合使用？

1. **方案 1**：在 Istio 層面禁用 mTLS
2. **方案 2**：在 Envoy 層面完全排除流量

**結果**：
- ✅ 雙重保障，確保 PostgreSQL 流量不受干擾
- ✅ 如果其中一個配置失效，另一個仍然生效
- ✅ 性能最佳，流量完全繞過 Istio

---

## 額外配置：DestinationRule

雖然 PostgreSQL 流量繞過了 mTLS，但仍可以配置連接池和超時設定（針對其他端口）：

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: patronidemo-destination
  namespace: default
spec:
  host: patronidemo-headless.default.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
        connectTimeout: 30s
        tcpKeepalive:
          time: 7200s
          interval: 75s
          probes: 9
    loadBalancer:
      simple: ROUND_ROBIN
    tls:
      mode: DISABLE  # PostgreSQL 不使用 TLS
```

---

## 驗證和測試

### 1. 檢查 Istio 配置

```bash
# 查看 PeerAuthentication
kubectl get peerauthentication -n default

# 查看 Pod annotations
kubectl get pod patronidemo-0 -n default -o jsonpath='{.metadata.annotations}' | jq

# 查看 Envoy 配置
kubectl exec -it patronidemo-1 -n default -c istio-proxy -- \
  curl -s localhost:15000/config_dump | grep -A 10 "5432"
```

### 2. 測試 PostgreSQL 連接

```bash
# 從副本測試到主節點的連接
kubectl exec -it patronidemo-1 -n default -- bash -c \
  "psql -h patronidemo-0 -U postgres -c 'SELECT version();'"

# 測試 DNS 解析（如果使用方案 3）
kubectl exec -it patronidemo-1 -n default -- bash -c \
  "nslookup patronidemo-0.patronidemo-headless"
```

### 3. 檢查串流複製狀態

```bash
# 在主節點檢查連接的副本
kubectl exec -it patronidemo-0 -n default -- psql -U postgres <<EOF
SELECT
  application_name,
  client_addr,
  state,
  sync_state,
  replay_lag
FROM pg_stat_replication;
EOF

# 應該看到：
# application_name | client_addr  | state     | sync_state | replay_lag
# -----------------+--------------+-----------+------------+------------
# patronidemo-1   | 10.244.0.126 | streaming | async      | 00:00:00
# patronidemo-2   | 10.244.0.127 | streaming | async      | 00:00:00
```

### 4. 檢查複製延遲

```bash
# 在副本上檢查延遲
kubectl exec -it patronidemo-1 -n default -- psql -U postgres <<EOF
SELECT
  pg_is_in_recovery() AS is_replica,
  CASE
    WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
    ELSE EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp())
  END AS lag_seconds;
EOF

# 應該看到：
# is_replica | lag_seconds
# -----------+-------------
# t          | 0
```

### 5. 測試 Patroni API（應該仍有 mTLS）

```bash
# 測試 Patroni API（8008 端口應該仍使用 mTLS）
kubectl exec -it patronidemo-1 -n default -- curl -s http://localhost:8008/patroni | jq
```

---

## 故障排查

### 問題 1: 串流複製仍然失敗

**症狀：**
```bash
kubectl exec -it patronidemo-0 -- psql -U postgres -c \
  "SELECT * FROM pg_stat_replication;"
# 沒有任何輸出
```

**排查步驟：**

1. 檢查 PeerAuthentication 是否生效：
```bash
kubectl get peerauthentication patroni-mtls-disable -n default -o yaml
```

2. 檢查 Pod annotations 是否正確：
```bash
kubectl get pod patronidemo-1 -n default -o yaml | grep -A 2 "traffic.sidecar.istio.io"
```

3. 檢查 Envoy 是否排除了 5432 端口：
```bash
kubectl exec -it patronidemo-1 -n default -c istio-proxy -- \
  curl -s localhost:15000/config_dump | grep "5432"
```

4. 查看 Patroni 日誌：
```bash
kubectl logs patronidemo-1 -n default --tail=100
```

### 問題 2: Pod 重啟循環

**症狀：**
```bash
kubectl get pods -n default
# patronidemo-1   1/2   CrashLoopBackOff
```

**排查步驟：**

1. 檢查 Envoy Sidecar 是否準備好：
```bash
kubectl logs patronidemo-1 -n default -c istio-proxy
```

2. 檢查 PostgreSQL 啟動日誌：
```bash
kubectl logs patronidemo-1 -n default -c patronidemo
```

3. 確保 Envoy 在 PostgreSQL 之前啟動（如需要）：
```yaml
lifecycle:
  postStart:
    exec:
      command:
      - /bin/sh
      - -c
      - |
        until curl -s http://localhost:15021/healthz/ready; do
          echo "Waiting for Envoy..."
          sleep 1
        done
```

### 問題 3: 性能下降

**症狀：**
- 串流複製延遲增加
- 查詢響應變慢

**排查步驟：**

1. 確認 5432 端口是否真的繞過了 Envoy：
```bash
# 應該看不到 5432 相關的 cluster
kubectl exec -it patronidemo-1 -n default -c istio-proxy -- \
  curl -s localhost:15000/clusters | grep "5432"
```

2. 檢查網路性能：
```bash
# 從副本到主節點的網路測試
kubectl exec -it patronidemo-1 -n default -- bash -c \
  "time psql -h patronidemo-0 -U postgres -c 'SELECT 1;'"
```

---

## 方案比較總結

| 特性 | 方案 1 | 方案 2 | 方案 3 | 方案 1+2 |
|------|--------|--------|--------|----------|
| **配置難度** | 簡單 | 簡單 | 複雜 | 簡單 |
| **性能影響** | 小 | 無 | 小 | 無 |
| **可觀測性** | 部分保留 | 完全失去 | 部分保留 | 完全失去 |
| **需要重啟 Pod** | 否 | 是 | 是 | 是 |
| **需要重建集群** | 否 | 否 | 是 | 否 |
| **Istio 功能** | 部分可用 | 不可用 | 部分可用 | 不可用 |
| **推薦指數** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |

---

## 總結與建議

### 快速開始（推薦）

如果你想快速解決問題，使用 **方案 1 + 方案 2**：

```bash
# 1. 應用 PeerAuthentication
kubectl apply -f patroni_istio_mtls.yaml

# 2. 修改 StatefulSet 添加 annotations
kubectl patch statefulset patronidemo -n default -p '{
  "spec": {
    "template": {
      "metadata": {
        "annotations": {
          "traffic.sidecar.istio.io/excludeInboundPorts": "5432",
          "traffic.sidecar.istio.io/excludeOutboundPorts": "5432"
        }
      }
    }
  }
}'

# 3. 滾動重啟
kubectl rollout restart statefulset patronidemo -n default

# 4. 驗證
kubectl exec -it patronidemo-0 -n default -- psql -U postgres -c \
  "SELECT application_name, state FROM pg_stat_replication;"
```

### 長期規劃

如果你想要更好的架構，考慮 **方案 3（DNS + Headless Service）**，但需要：
1. 充分測試
2. 計劃停機時間
3. 備份數據
4. 準備回滾方案

### 不推薦的做法

❌ **不要使用 `excludeOutboundIPRanges`**
- 需要手動填寫 Pod CIDR
- 不同集群配置不同
- 維護成本高

✅ **使用 `excludeOutboundPorts`**
- 簡單明確
- 跨集群通用
- 易於維護

---

## 參考資料

- [Istio Security - PeerAuthentication](https://istio.io/latest/docs/reference/config/security/peer_authentication/)
- [Istio Traffic Management - DestinationRule](https://istio.io/latest/docs/reference/config/networking/destination-rule/)
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [PostgreSQL Streaming Replication](https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION)
