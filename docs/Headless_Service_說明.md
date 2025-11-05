# Headless Service 詳解

## 什麼是 Headless Service？

**Headless Service** 是一種特殊的 Kubernetes Service，它**不分配 Cluster IP**，而是直接返回後端 Pod 的 IP 地址。

### 普通 Service vs Headless Service

#### 普通 Service (ClusterIP)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  clusterIP: 10.96.100.50  # 有 Cluster IP
  selector:
    app: my-app
  ports:
  - port: 80
```

**行為：**
```
客戶端查詢 DNS: my-service.default.svc.cluster.local
    ↓
返回: 10.96.100.50 (Service 的 Cluster IP)
    ↓
客戶端連接到: 10.96.100.50:80
    ↓
kube-proxy 做負載均衡，隨機轉發到一個 Pod
    ↓
實際到達: 10.244.0.10:80 或 10.244.0.11:80 或 10.244.0.12:80 (隨機)
```

**問題：** 你無法指定要連接到哪個特定的 Pod！

#### Headless Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service-headless
spec:
  clusterIP: None  # ← 關鍵：設為 None
  selector:
    app: my-app
  ports:
  - port: 80
```

**行為：**
```
客戶端查詢 DNS: my-service-headless.default.svc.cluster.local
    ↓
返回: 10.244.0.10, 10.244.0.11, 10.244.0.12 (所有 Pod 的 IP)
    ↓
客戶端可以選擇連接到哪個 IP
```

**更重要的是，每個 Pod 都有自己的 DNS 記錄：**
```
pod-0.my-service-headless.default.svc.cluster.local → 10.244.0.10
pod-1.my-service-headless.default.svc.cluster.local → 10.244.0.11
pod-2.my-service-headless.default.svc.cluster.local → 10.244.0.12
```

**優勢：** 你可以通過 DNS 名稱直接連接到特定的 Pod！

---

## 為什麼 Patroni 需要 Headless Service？

### 原因 1: 需要連接到特定的 Pod（主節點）

Patroni 的副本需要連接到**特定的主節點**，而不是隨機的 Pod。

**場景：**
```
patronidemo-leader ConfigMap 說: "主節點是 patronidemo-0"
    ↓
副本需要連接到: patronidemo-0 (不是隨機的 Pod！)
    ↓
使用 Headless Service:
    patronidemo-0.patronidemo-headless.default.svc.cluster.local
    ↓
直接解析到 patronidemo-0 的 Pod IP
```

**如果使用普通 Service：**
```
副本連接到: patronidemo.default.svc.cluster.local
    ↓
隨機連接到: patronidemo-0 或 patronidemo-1 或 patronidemo-2
    ↓
❌ 可能連接到副本，而不是主節點！
    ↓
串流複製失敗！
```

### 原因 2: StatefulSet 的穩定網路標識

StatefulSet 的每個 Pod 都有一個**穩定的名稱**：
- `patronidemo-0`
- `patronidemo-1`
- `patronidemo-2`

配合 Headless Service，這些 Pod 就有了**穩定的 DNS 名稱**：
- `patronidemo-0.patronidemo-headless.default.svc.cluster.local`
- `patronidemo-1.patronidemo-headless.default.svc.cluster.local`
- `patronidemo-2.patronidemo-headless.default.svc.cluster.local`

**即使 Pod 重啟，DNS 名稱也不會改變！**（但 Pod IP 可能會變）

### 原因 3: 每個副本都需要知道主節點的地址

PostgreSQL 串流複製需要：
```sql
-- 副本的 primary_conninfo 配置
primary_conninfo = 'host=patronidemo-0.patronidemo-headless port=5432 ...'
```

這樣：
- **patronidemo-1** 連接到 `patronidemo-0.patronidemo-headless:5432`
- **patronidemo-2** 連接到 `patronidemo-0.patronidemo-headless:5432`
- 即使 patronidemo-0 重啟，DNS 仍然指向新的 Pod IP

---

## 實際示範

### 1. 創建 Headless Service

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: patronidemo-headless
  namespace: default
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
EOF
```

### 2. 驗證 DNS 解析

```bash
# 查詢 Service 的所有 Pod IP（返回多個 IP）
kubectl run -it --rm debug --image=busybox --restart=Never -- \
  nslookup patronidemo-headless.default.svc.cluster.local

# 輸出範例：
# Name:   patronidemo-headless.default.svc.cluster.local
# Address: 10.244.0.10  # patronidemo-0
# Address: 10.244.0.11  # patronidemo-1
# Address: 10.244.0.12  # patronidemo-2
```

```bash
# 查詢特定 Pod 的 DNS（返回單個 IP）
kubectl run -it --rm debug --image=busybox --restart=Never -- \
  nslookup patronidemo-0.patronidemo-headless.default.svc.cluster.local

# 輸出範例：
# Name:   patronidemo-0.patronidemo-headless.default.svc.cluster.local
# Address: 10.244.0.10  # 只有這一個 Pod 的 IP
```

### 3. 測試連接

```bash
# 從副本 Pod 測試連接到主節點
kubectl exec -it patronidemo-1 -- bash

# 使用 DNS 連接（推薦）
psql -h patronidemo-0.patronidemo-headless -U postgres -c "SELECT version();"

# 使用 Pod IP 連接（不推薦，IP 會變）
psql -h 10.244.0.10 -U postgres -c "SELECT version();"
```

---

## Headless Service 的 DNS 記錄

### Service 層級的 DNS

```bash
patronidemo-headless.default.svc.cluster.local
```

**返回：** 所有符合 selector 的 Pod IP（A 記錄）

```
10.244.0.10
10.244.0.11
10.244.0.12
```

### Pod 層級的 DNS

```bash
patronidemo-0.patronidemo-headless.default.svc.cluster.local
patronidemo-1.patronidemo-headless.default.svc.cluster.local
patronidemo-2.patronidemo-headless.default.svc.cluster.local
```

**返回：** 單個 Pod 的 IP（A 記錄）

```
patronidemo-0 → 10.244.0.10
patronidemo-1 → 10.244.0.11
patronidemo-2 → 10.244.0.12
```

**格式：**
```
{pod-name}.{service-name}.{namespace}.svc.cluster.local
```

---

## Patroni 中如何使用

### 配置 Patroni 使用 Headless Service

在 StatefulSet 的環境變數中：

```yaml
env:
- name: PATRONI_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name  # patronidemo-0, patronidemo-1, etc.

- name: PATRONI_POSTGRESQL_CONNECT_ADDRESS
  value: "$(PATRONI_NAME).patronidemo-headless.default.svc.cluster.local:5432"

- name: PATRONI_RESTAPI_CONNECT_ADDRESS
  value: "$(PATRONI_NAME).patronidemo-headless.default.svc.cluster.local:8008"
```

### 結果

每個 Pod 會發布自己的連接地址：

**patronidemo-0 的 annotation：**
```json
{
  "conn_url": "postgres://patronidemo-0.patronidemo-headless.default.svc.cluster.local:5432/postgres",
  "api_url": "http://patronidemo-0.patronidemo-headless.default.svc.cluster.local:8008/patroni"
}
```

**patronidemo-1 的 annotation：**
```json
{
  "conn_url": "postgres://patronidemo-1.patronidemo-headless.default.svc.cluster.local:5432/postgres",
  "api_url": "http://patronidemo-1.patronidemo-headless.default.svc.cluster.local:8008/patroni"
}
```

### 副本如何找到主節點

```
1. 副本查詢 ConfigMap:
   ├─> patronidemo-leader.annotations.leader = "patronidemo-0"

2. 副本查詢 patronidemo-0 Pod:
   ├─> annotations.status.conn_url = "patronidemo-0.patronidemo-headless:5432"

3. 副本解析 DNS:
   ├─> nslookup patronidemo-0.patronidemo-headless
   └─> 返回: 10.244.0.10

4. 副本建立連接:
   └─> PostgreSQL 連接到 10.244.0.10:5432
```

---

## Headless Service 的其他用途

### 1. 客戶端負載均衡

客戶端可以獲取所有 Pod IP，自己決定連接哪個：

```python
import socket

# 獲取所有 Pod IP
ips = socket.getaddrinfo('patronidemo-headless.default.svc.cluster.local', 5432)

# 自己實現負載均衡邏輯
# 例如：輪詢、最少連接、權重等
```

### 2. StatefulSet 的有狀態應用

除了 Patroni，其他有狀態應用也需要 Headless Service：
- **Kafka**: 每個 broker 有唯一地址
- **Cassandra**: 節點間需要互相發現
- **Elasticsearch**: Master/Data 節點需要穩定地址
- **ZooKeeper**: 每個節點有唯一 ID 和地址
- **etcd**: 叢集成員需要穩定地址

### 3. 服務發現

應用可以通過 DNS 發現所有實例：

```bash
# 獲取所有健康的 Pod
dig +short patronidemo-headless.default.svc.cluster.local
```

---

## 普通 Service vs Headless Service 比較表

| 特性 | 普通 Service (ClusterIP) | Headless Service |
|------|-------------------------|------------------|
| **Cluster IP** | 有（如 10.96.100.50） | 無 (None) |
| **DNS 返回** | Service 的 Cluster IP | 所有 Pod 的 IP |
| **負載均衡** | 由 kube-proxy 處理 | 由客戶端處理 |
| **Pod DNS** | ❌ 無 | ✅ 有 `pod-name.service-name` |
| **用途** | 無狀態應用 | 有狀態應用 |
| **連接方式** | 隨機到任一 Pod | 可選擇特定 Pod |
| **適用場景** | Web 服務、API 服務 | 數據庫、訊息佇列 |

---

## 檢查你的環境

### 查看是否有 Headless Service

```bash
# 列出所有 Service
kubectl get svc -n default

# 檢查是否有 ClusterIP: None 的 Service
kubectl get svc -n default -o custom-columns=NAME:.metadata.name,CLUSTER-IP:.spec.clusterIP,TYPE:.spec.type

# 輸出範例：
# NAME                    CLUSTER-IP   TYPE
# kubernetes              10.96.0.1    ClusterIP
# patronidemo             10.96.100.50 ClusterIP      # 普通 Service (用於客戶端連接)
# patronidemo-headless    None         ClusterIP      # Headless Service (用於內部複製)
```

### 如果沒有 Headless Service

```bash
# 創建 Headless Service
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: patronidemo-headless
  namespace: default
  labels:
    application: patroni
    cluster-name: patronidemo
spec:
  clusterIP: None  # 這是關鍵！
  selector:
    application: patroni
    cluster-name: patronidemo
  ports:
  - name: postgres
    port: 5432
    targetPort: 5432
    protocol: TCP
  - name: patroni
    port: 8008
    targetPort: 8008
    protocol: TCP
EOF
```

### 驗證 DNS 工作

```bash
# 測試 Service DNS
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- \
  nslookup patronidemo-headless.default.svc.cluster.local

# 測試 Pod DNS
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- \
  nslookup patronidemo-0.patronidemo-headless.default.svc.cluster.local

# 測試連接
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- \
  nc -zv patronidemo-0.patronidemo-headless 5432
```

---

## 為什麼你的環境可能沒有使用 Headless Service

從你的 Pod annotation 看到：
```json
"conn_url": "postgres://10.244.0.125:5432/postgres"
```

這是 **Pod IP**，不是 DNS 名稱。

### 可能的原因：

1. **環境變數未設置**
   - `PATRONI_POSTGRESQL_CONNECT_ADDRESS` 沒有配置
   - Patroni 自動使用 Pod IP

2. **沒有 Headless Service**
   - StatefulSet 可以不需要 Headless Service 運行
   - 但這樣就只能用 Pod IP

3. **舊的配置方式**
   - 某些 Patroni 部署使用 Pod IP 而非 DNS

### 為什麼要改用 DNS？

| 使用 Pod IP | 使用 Headless Service DNS |
|------------|---------------------------|
| ❌ Pod 重啟後 IP 會變 | ✅ DNS 始終指向正確的 Pod |
| ❌ Istio 難以處理動態 IP | ✅ Istio 可以正確處理 DNS |
| ❌ 需要排除 Pod CIDR | ✅ 可以使用 mTLS 策略 |
| ❌ 依賴 Pod 網路穩定 | ✅ 透過 DNS 抽象網路 |
| ✅ 配置簡單 | ❌ 需要額外配置 |

---

## 總結

### Headless Service 是什麼？
- 一種 `clusterIP: None` 的 Kubernetes Service
- 返回 Pod IP 而非 Service IP
- 為 StatefulSet 的每個 Pod 提供穩定的 DNS 名稱

### 為什麼 Patroni 需要它？
1. **精確連接**：副本需要連接到特定的主節點
2. **穩定地址**：Pod 重啟後 DNS 保持不變
3. **Istio 兼容**：DNS 連接比 Pod IP 更容易管理

### 如何使用？
1. 創建 Headless Service (`clusterIP: None`)
2. 配置 Patroni 使用 DNS (`PATRONI_POSTGRESQL_CONNECT_ADDRESS`)
3. 配置 Istio 策略（`PeerAuthentication`）

### 下一步
查看你的環境是否有 Headless Service：
```bash
kubectl get svc patronidemo-headless -n default
```

如果沒有，按照上面的步驟創建一個！
