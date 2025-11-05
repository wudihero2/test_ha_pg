# Patroni 副本節點如何找到並連接主節點

## 目錄
- [核心機制](#核心機制)
- [詳細技術流程](#詳細技術流程)
- [在 Kubernetes 中的實現](#在-kubernetes-中的實現)
- [Istio 環境下的問題](#istio-環境下的問題)
- [解決方案](#解決方案)
- [配置範例](#配置範例)
- [故障排查](#故障排查)

---

## 核心機制

Patroni 的副本節點透過 **DCS (Distributed Configuration Store)** 來找到主節點。簡單來說：

```
副本節點 → 查詢 DCS → 獲得主節點資訊 → 生成連接字串 → PostgreSQL 開始串流複製
```

### 關鍵概念

1. **DCS (分散式配置存儲)**
   - 在 Kubernetes 中，DCS 是 **ConfigMap** 或 **Endpoint** 物件
   - 存儲了整個叢集的狀態，包括誰是主節點

2. **Leader 鍵 (Leader Key)**
   - DCS 中有一個特殊的 `leader` 鍵，指向當前的主節點
   - 包含主節點的連接資訊（host、port、URL 等）

3. **primary_conninfo**
   - PostgreSQL 的配置參數
   - 告訴副本節點如何連接到主節點進行串流複製

---

## 詳細技術流程

### 1. DCS 結構

在 Kubernetes 中，Patroni 在 DCS 中建立以下結構：

```
/{namespace}/{scope}/
├── leader           # 當前主節點的資訊
├── members/
│   ├── patroni-0    # 各節點的成員資訊
│   ├── patroni-1
│   └── patroni-2
├── config           # 全域動態配置
└── sync             # 同步複製狀態
```

### 2. Leader 資訊範例

`leader` 鍵存儲的 JSON 資料：

```json
{
  "version": 1,
  "member": {
    "name": "patroni-0",
    "data": {
      "conn_url": "postgres://replicator:password@patroni-0.patroni-headless.default.svc.cluster.local:5432/postgres",
      "api_url": "http://patroni-0.patroni-headless.default.svc.cluster.local:8008/patroni",
      "timeline": 1,
      "role": "master",
      "state": "running"
    }
  }
}
```

**重要欄位：**
- `conn_url`: PostgreSQL 的連接 URL，**副本用這個來做串流複製**
- `api_url`: Patroni REST API 端點，用於健康檢查
- `name`: 主節點的名稱（在 K8s 中通常是 Pod 名稱）

### 3. 副本如何找到主節點

#### 步驟 1: 查詢 DCS

程式碼位置：`patroni/dcs/__init__.py:1750`

```python
def get_cluster(self) -> Cluster:
    """從 DCS 獲取叢集的最新狀態"""
    cluster = self._get_mpp_cluster() if self.is_mpp_coordinator() else self.__get_postgresql_cluster()
    return cluster
```

副本節點會定期（預設每 10 秒）查詢 DCS 來獲取叢集狀態，包括 leader 資訊。

#### 步驟 2: 提取主節點連接資訊

程式碼位置：`patroni/postgresql/config.py:626`

```python
def primary_conninfo_params(self, member: Union[Leader, Member, None]) -> Optional[Dict[str, Any]]:
    """從 leader member 提取連接參數"""
    if not member or not member.conn_url or member.name == self._postgresql.name:
        return None

    # 從 member.conn_url 提取連接參數
    ret = member.conn_kwargs(self.replication)
    ret['application_name'] = self._postgresql.name
    ret.setdefault('sslmode', 'prefer')

    # PostgreSQL 12+ 的額外參數
    if self._postgresql.major_version >= 120000:
        ret.setdefault('gssencmode', 'prefer')
    if self._postgresql.major_version >= 130000:
        ret.setdefault('channel_binding', 'prefer')

    return ret
```

這個函數會：
1. 從 `member.conn_url` 解析出 host、port、user 等資訊
2. 加入 SSL 相關參數
3. 設定 application_name（用於識別副本）

#### 步驟 3: 生成 primary_conninfo

程式碼位置：`patroni/postgresql/config.py:702-713`

```python
# 生成 primary_conninfo 參數
primary_conninfo = self.primary_conninfo_params(member)
if primary_conninfo:
    # 如果使用 replication slot
    if use_slots and not (is_remote_member and member.no_replication_slot):
        recovery_params['primary_slot_name'] = slot_name_from_member_name(primary_slot_name)

    # 設定 primary_conninfo
    recovery_params['primary_conninfo'] = primary_conninfo
```

生成的 `primary_conninfo` 範例：

```
host=patroni-0.patroni-headless.default.svc.cluster.local port=5432 user=replicator password=xxx sslmode=prefer application_name=patroni-1
```

#### 步驟 4: 寫入 PostgreSQL 配置

程式碼位置：`patroni/postgresql/config.py:677-681`

```python
for name, value in sorted(recovery_params.items()):
    if name == 'primary_conninfo':
        # 轉換成 DSN 格式
        value = self.format_dsn(value)
    fd.write_param(name, value)
```

- **PostgreSQL 12+**: 寫入 `postgresql.conf` + 創建 `standby.signal` 檔案
- **PostgreSQL 11-**: 寫入 `recovery.conf`

#### 步驟 5: PostgreSQL 建立串流複製連接

PostgreSQL 的 WAL Receiver 程序會：
1. 讀取 `primary_conninfo` 參數
2. 使用 libpq 連接到主節點的 **5432 端口**
3. 建立串流複製連接
4. 持續接收 WAL 日誌並應用

---

## 在 Kubernetes 中的實現

### 使用 Headless Service

在 K8s 中，Patroni 通常使用 **Headless Service** 來提供穩定的 DNS 名稱：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: patroni-headless
spec:
  clusterIP: None  # Headless Service
  selector:
    app: patroni
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
```

每個 Pod 會有一個穩定的 DNS 名稱：
```
patroni-0.patroni-headless.default.svc.cluster.local
patroni-1.patroni-headless.default.svc.cluster.local
patroni-2.patroni-headless.default.svc.cluster.local
```

### DCS 使用 Kubernetes API

程式碼位置：`patroni/dcs/kubernetes.py`

Patroni 使用 Kubernetes API 作為 DCS：
- 透過 ServiceAccount Token 認證
- 使用 ConfigMap 或 Endpoint 物件存儲叢集狀態
- 透過 Kubernetes API Server 進行讀寫操作

---

## Istio 環境下的問題

### 為什麼在 Istio 環境下會連不上？

#### 問題 1: mTLS 加密衝突

**現象：** 副本無法建立到主節點的串流複製連接

**原因：**
- Istio 預設會對 Pod 之間的流量啟用 mTLS (mutual TLS)
- PostgreSQL 本身也有 SSL/TLS 連接
- **雙重加密導致連接失敗或性能問題**

**Istio Sidecar 流程：**
```
副本 Pod → Envoy Sidecar (mTLS 加密) → 網路 → 主節點 Envoy Sidecar (mTLS 解密) → PostgreSQL
```

當 PostgreSQL 也使用 SSL 時：
```
副本 PostgreSQL (SSL) → Envoy (mTLS) → 主節點 Envoy → 主節點 PostgreSQL (SSL)
```

這會導致：
- 連接建立失敗
- SSL handshake 錯誤
- 性能嚴重下降（雙重加密/解密）

#### 問題 2: 連接超時

**現象：** 連接建立緩慢或超時

**原因：**
- Istio 的 Envoy Sidecar 需要時間啟動
- PostgreSQL 可能在 Envoy 準備好之前就嘗試連接
- Envoy 的連接池設定可能不適合 PostgreSQL 的長連接

#### 問題 3: 健康檢查干擾

**現象：** Pod 被頻繁重啟

**原因：**
- Istio 會攔截健康檢查流量
- 如果 Envoy Sidecar 尚未準備好，健康檢查會失敗
- Kubernetes 會重啟 Pod

---

## 解決方案

### 方案 1: 對 PostgreSQL 端口禁用 mTLS（推薦）

使用 **PeerAuthentication** 資源排除 PostgreSQL 端口：

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: patroni-mtls-disable
  namespace: default
spec:
  selector:
    matchLabels:
      app: patroni
  mtls:
    mode: PERMISSIVE  # 或 DISABLE
  portLevelMtls:
    5432:
      mode: DISABLE  # PostgreSQL 端口不使用 mTLS
```

**說明：**
- `mode: PERMISSIVE`: 允許明文和 mTLS 流量
- `portLevelMtls.5432.mode: DISABLE`: 對 5432 端口完全禁用 mTLS
- PostgreSQL 自己的 SSL 配置仍然有效

### 方案 2: 使用 Istio DestinationRule

配置連接池和超時設定：

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: patroni-destination
  namespace: default
spec:
  host: patroni-headless.default.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100      # 增加連接池大小
        connectTimeout: 30s      # 增加連接超時
        tcpKeepalive:
          time: 7200s           # TCP keepalive
          interval: 75s
          probes: 9
    loadBalancer:
      simple: ROUND_ROBIN
  subsets:
  - name: postgres
    labels:
      app: patroni
    trafficPolicy:
      portLevelSettings:
      - port:
          number: 5432
        connectionPool:
          tcp:
            maxConnections: 200  # PostgreSQL 需要更多連接
```

### 方案 3: 使用 Sidecar 資源排除流量

讓 PostgreSQL 複製流量繞過 Envoy：

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Sidecar
metadata:
  name: patroni-sidecar
  namespace: default
spec:
  workloadSelector:
    labels:
      app: patroni
  egress:
  - hosts:
    - "./*"
    - "istio-system/*"
  outboundTrafficPolicy:
    mode: ALLOW_ANY  # 允許直接訪問，不經過 Envoy
```

### 方案 4: 使用 Pod Annotation 排除端口

在 StatefulSet 中添加 annotation：

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: patroni
spec:
  template:
    metadata:
      annotations:
        traffic.sidecar.istio.io/excludeInboundPorts: "5432"
        traffic.sidecar.istio.io/excludeOutboundPorts: "5432"
        # 或使用 IP 排除（推薦用於 Pod-to-Pod 通信）
        traffic.sidecar.istio.io/excludeOutboundIPRanges: "10.0.0.0/8"
    spec:
      # ... Pod spec
```

**說明：**
- `excludeInboundPorts`: 排除入站流量端口
- `excludeOutboundPorts`: 排除出站流量端口
- `excludeOutboundIPRanges`: 排除特定 IP 範圍（如 Pod CIDR）

### 方案 5: 延遲 PostgreSQL 啟動

確保 Envoy Sidecar 已準備好：

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: patroni
spec:
  template:
    spec:
      containers:
      - name: patroni
        lifecycle:
          postStart:
            exec:
              command:
              - /bin/sh
              - -c
              - |
                # 等待 Envoy Sidecar 準備好
                until curl -s http://localhost:15021/healthz/ready; do
                  echo "Waiting for Envoy..."
                  sleep 1
                done
                echo "Envoy is ready"
```

---

## 配置範例

### 完整的 Kubernetes + Istio 配置

#### 1. StatefulSet

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: patroni
  namespace: default
spec:
  serviceName: patroni-headless
  replicas: 3
  selector:
    matchLabels:
      app: patroni
  template:
    metadata:
      labels:
        app: patroni
      annotations:
        # 排除 PostgreSQL 端口，讓複製流量不經過 Istio
        traffic.sidecar.istio.io/excludeInboundPorts: "5432"
        traffic.sidecar.istio.io/excludeOutboundPorts: "5432"
    spec:
      serviceAccountName: patroni
      containers:
      - name: patroni
        image: patroni:latest
        ports:
        - containerPort: 8008  # Patroni API
          name: patroni
        - containerPort: 5432  # PostgreSQL
          name: postgres
        env:
        - name: PATRONI_KUBERNETES_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: PATRONI_KUBERNETES_LABELS
          value: "{app: patroni}"
        - name: PATRONI_SCOPE
          value: patroni-cluster
        - name: PATRONI_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: PATRONI_POSTGRESQL_DATA_DIR
          value: /var/lib/postgresql/data
        - name: PATRONI_POSTGRESQL_CONNECT_ADDRESS
          value: "$(PATRONI_NAME).patroni-headless:5432"
        - name: PATRONI_RESTAPI_CONNECT_ADDRESS
          value: "$(PATRONI_NAME).patroni-headless:8008"
        - name: PATRONI_REPLICATION_USERNAME
          value: replicator
        - name: PATRONI_REPLICATION_PASSWORD
          valueFrom:
            secretKeyRef:
              name: patroni-secret
              key: replication-password
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 10Gi
```

#### 2. Headless Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: patroni-headless
  namespace: default
spec:
  clusterIP: None
  selector:
    app: patroni
  ports:
  - name: postgres
    port: 5432
    targetPort: 5432
  - name: patroni
    port: 8008
    targetPort: 8008
```

#### 3. PeerAuthentication（禁用 PostgreSQL 端口的 mTLS）

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: patroni-mtls-policy
  namespace: default
spec:
  selector:
    matchLabels:
      app: patroni
  mtls:
    mode: STRICT  # 其他端口使用嚴格 mTLS
  portLevelMtls:
    5432:
      mode: DISABLE  # PostgreSQL 端口禁用 mTLS
```

#### 4. DestinationRule

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: patroni-destination
  namespace: default
spec:
  host: patroni-headless.default.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 200
        connectTimeout: 30s
        tcpKeepalive:
          time: 7200s
          interval: 75s
    loadBalancer:
      simple: ROUND_ROBIN
```

---

## 故障排查

### 檢查清單

#### 1. 驗證 DCS 中的 Leader 資訊

```bash
# 如果使用 ConfigMap 作為 DCS
kubectl get configmap -n default -l cluster-name=patroni-cluster -o yaml

# 查看 leader 資訊
kubectl get configmap patroni-cluster-leader -n default -o jsonpath='{.data}'
```

應該看到類似：
```json
{
  "conn_url": "postgres://replicator@patroni-0.patroni-headless:5432/postgres",
  "api_url": "http://patroni-0.patroni-headless:8008/patroni"
}
```

#### 2. 檢查副本的 PostgreSQL 配置

```bash
# 進入副本 Pod
kubectl exec -it patroni-1 -n default -- bash

# 查看 primary_conninfo（PostgreSQL 12+）
grep primary_conninfo /var/lib/postgresql/data/postgresql.conf

# 或查看 recovery.conf（PostgreSQL 11-）
cat /var/lib/postgresql/data/recovery.conf
```

應該看到：
```
primary_conninfo = 'host=patroni-0.patroni-headless.default.svc.cluster.local port=5432 user=replicator application_name=patroni-1 sslmode=prefer'
```

#### 3. 測試網路連通性

```bash
# 從副本 Pod 測試到主節點的連接
kubectl exec -it patroni-1 -n default -- bash

# DNS 解析測試
nslookup patroni-0.patroni-headless.default.svc.cluster.local

# TCP 連接測試
nc -zv patroni-0.patroni-headless.default.svc.cluster.local 5432

# PostgreSQL 連接測試
psql -h patroni-0.patroni-headless.default.svc.cluster.local -U replicator -d postgres -c "SELECT version();"
```

#### 4. 檢查 Istio 配置

```bash
# 查看 Pod 的 Istio 配置
kubectl exec -it patroni-1 -n default -c istio-proxy -- pilot-agent request GET config_dump

# 檢查 PeerAuthentication
kubectl get peerauthentication -n default

# 檢查 DestinationRule
kubectl get destinationrule -n default

# 查看 Envoy 狀態
kubectl exec -it patroni-1 -n default -c istio-proxy -- curl localhost:15000/stats | grep postgresql
```

#### 5. 查看 Patroni 日誌

```bash
# 查看 Patroni 日誌
kubectl logs -n default patroni-1 -f

# 重點關注以下關鍵字：
# - "Failed to connect to"
# - "primary_conninfo"
# - "replication connection"
# - "DCS"
```

關鍵日誌範例：
```
INFO: no action. I am (patroni-1), a secondary, and following a leader (patroni-0)
INFO: Lock owner: patroni-0; I am patroni-1
INFO: does not have lock
```

#### 6. 檢查 PostgreSQL 複製狀態

在主節點上：
```sql
-- 查看連接的副本
SELECT * FROM pg_stat_replication;

-- 應該看到：
application_name | state     | sync_state
-----------------+-----------+-----------
patroni-1       | streaming | async
patroni-2       | streaming | async
```

在副本上：
```sql
-- 確認是否在恢復模式
SELECT pg_is_in_recovery();  -- 應該返回 true

-- 查看複製延遲
SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;
```

### 常見錯誤和解決方法

#### 錯誤 1: Connection refused

**症狀：**
```
FATAL: could not connect to the primary server: connection refused
```

**可能原因：**
1. 主節點尚未準備好
2. Istio mTLS 阻止連接
3. NetworkPolicy 阻止流量

**解決方法：**
1. 等待主節點完全啟動
2. 應用 PeerAuthentication 排除 5432 端口
3. 檢查並修改 NetworkPolicy

#### 錯誤 2: SSL error

**症狀：**
```
FATAL: SSL error: certificate verify failed
```

**可能原因：**
- Istio mTLS 與 PostgreSQL SSL 衝突

**解決方法：**
- 在 Patroni 配置中設置 `sslmode: prefer` 或 `disable`
- 使用方案 1 禁用 5432 端口的 Istio mTLS

#### 錯誤 3: Timeout

**症狀：**
```
FATAL: could not connect to the primary server: timeout
```

**可能原因：**
- Envoy Sidecar 尚未準備好
- DestinationRule 的連接超時設定太短

**解決方法：**
- 使用方案 5 延遲 PostgreSQL 啟動
- 調整 DestinationRule 的 `connectTimeout`

---

## 總結

### Patroni 副本發現主節點的完整流程

1. **副本查詢 DCS**（Kubernetes ConfigMap/Endpoint）
   - 獲取 `/{namespace}/{scope}/leader` 鍵

2. **提取主節點資訊**
   - 從 leader 的 `conn_url` 中解析 host、port
   - 通常是：`patroni-0.patroni-headless.default.svc.cluster.local:5432`

3. **生成連接字串**
   - 建立 `primary_conninfo` 參數
   - 包含認證資訊、SSL 設定等

4. **寫入 PostgreSQL 配置**
   - PostgreSQL 12+: `postgresql.conf` + `standby.signal`
   - PostgreSQL 11-: `recovery.conf`

5. **PostgreSQL 建立串流複製**
   - WAL Receiver 使用 `primary_conninfo` 連接到主節點的 **5432 端口**
   - 建立長連接，持續接收 WAL 日誌

### Istio 環境下的關鍵要點

1. **必須處理 mTLS 衝突**
   - 使用 PeerAuthentication 對 5432 端口禁用 mTLS
   - 或使用 Pod annotation 排除端口

2. **調整連接池設定**
   - PostgreSQL 需要較大的連接池
   - 設定合適的超時時間

3. **確保啟動順序**
   - Envoy Sidecar 必須在 PostgreSQL 之前準備好
   - 使用 postStart hook 等待

4. **網路策略要正確**
   - 允許 Pod 之間的 5432 端口通信
   - 允許訪問 Kubernetes API（DCS）

### 推薦配置組合

對於 Kubernetes + Istio 環境，推薦使用：

1. **PeerAuthentication** 排除 5432 端口（方案 1）
2. **Pod Annotation** 排除端口流量（方案 4）
3. **DestinationRule** 調整連接設定（方案 2）

這樣可以確保：
- PostgreSQL 複製流量不受 Istio 干擾
- 其他流量（API、監控等）仍享受 Istio 的功能
- 連接穩定且性能良好

---

## 參考資料

### 相關程式碼文件

- `patroni/dcs/__init__.py:1750` - DCS 叢集查詢
- `patroni/dcs/kubernetes.py` - Kubernetes DCS 實現
- `patroni/postgresql/config.py:626` - primary_conninfo 生成
- `patroni/ha.py` - 高可用性循環邏輯

### 關鍵配置參數

| 參數 | 說明 | 預設值 |
|------|------|--------|
| `PATRONI_KUBERNETES_NAMESPACE` | Kubernetes namespace | - |
| `PATRONI_KUBERNETES_LABELS` | Pod selector labels | - |
| `PATRONI_SCOPE` | 叢集名稱 | - |
| `PATRONI_POSTGRESQL_CONNECT_ADDRESS` | PostgreSQL 連接地址 | `{name}.{service}:5432` |
| `PATRONI_RESTAPI_CONNECT_ADDRESS` | REST API 地址 | `{name}.{service}:8008` |
| `loop_wait` | DCS 查詢間隔 | 10 秒 |
| `ttl` | Leader 鍵 TTL | 30 秒 |

### Istio 相關資源

- [Istio PeerAuthentication](https://istio.io/latest/docs/reference/config/security/peer_authentication/)
- [Istio DestinationRule](https://istio.io/latest/docs/reference/config/networking/destination-rule/)
- [Istio Sidecar](https://istio.io/latest/docs/reference/config/networking/sidecar/)
