# Patroni conn_url 寫入 Pod Annotations 的完整流程

## 問題
你在 Pod annotations 看到的 `conn_url` 是在哪裡生成並寫入的？

```json
{
  "conn_url": "postgres://10.244.0.125:5432/postgres",
  "api_url": "http://10.244.0.125:8008/patroni",
  "state": "running",
  "role": "primary"
}
```

## 答案：完整的程式碼流程

### 流程圖

```
┌─────────────────────────────────────────────────────────────┐
│  1. Patroni HA 循環 (patroni/ha.py)                        │
│     Ha.run_cycle() → post_recover()                        │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  2. 收集節點狀態數據 (patroni/ha.py:1256-1257)             │
│     data = {                                                │
│       'conn_url': self.state_handler.connection_string,     │
│       'api_url': self.patroni.api.connection_string,        │
│       'state': ..., 'role': ..., 'timeline': ...           │
│     }                                                       │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  3. 調用 DCS touch_member (patroni/ha.py:508)              │
│     ret = self.dcs.touch_member(data)                      │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  4. Kubernetes DCS 實現 (patroni/dcs/kubernetes.py:1359)   │
│     def touch_member(self, data: Dict[str, Any])           │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  5. 將 data 序列化為 JSON (kubernetes.py:1391)              │
│     annotations = {                                         │
│       'status': json.dumps(data, separators=(',', ':'))    │
│     }                                                       │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  6. 使用 Kubernetes API 更新 Pod (kubernetes.py:1392-1393) │
│     body = k8s_client.V1Pod(                               │
│         metadata=k8s_client.V1ObjectMeta(                  │
│             annotations={'status': json_string}            │
│         )                                                  │
│     )                                                      │
│     self._api.patch_namespaced_pod(...)                    │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  7. Pod annotation 更新完成                                 │
│     kubectl get pod patronidemo-0 -o yaml                  │
│     → metadata.annotations.status 包含完整的 JSON          │
└─────────────────────────────────────────────────────────────┘
```

---

## 詳細程式碼分析

### 1. 入口：HA 循環 (patroni/ha.py)

每個 Patroni 循環（預設 10 秒）都會調用 `post_recover()` 方法。

**檔案位置：** `patroni/ha.py:444-445` 和 `patroni/ha.py:1256-1257`

```python
# patroni/ha.py:444-445
# 在 demote() 方法中準備數據
data = {
    'conn_url': self.state_handler.connection_string,
    'api_url': self.patroni.api.connection_string,
    # ... 其他欄位
}
```

```python
# patroni/ha.py:1256-1257
# 在 post_recover() 方法中準備數據
def post_recover(self) -> None:
    """建立節點狀態數據並更新到 DCS"""
    data: Dict[str, Any] = {
        'conn_url': self.state_handler.connection_string,  # ← PostgreSQL 連接 URL
        'api_url': self.patroni.api.connection_string,     # ← Patroni API URL
        'state': self.state_handler.state.value,           # 狀態：running, starting 等
        'role': self.state_handler.role.value,             # 角色：primary, replica
        'version': self.patroni.version                    # Patroni 版本
    }
```

### 2. connection_string 的生成

**問題：** `self.state_handler.connection_string` 和 `self.patroni.api.connection_string` 是從哪來的？

#### PostgreSQL connection_string

**檔案位置：** 根據配置文件中的設定生成

配置範例：
```yaml
# 從環境變數或配置文件
postgresql:
  connect_address: 10.244.0.125:5432  # ← 這是關鍵！
  # 或
  connect_address: ${POD_IP}:5432
  # 或
  connect_address: patronidemo-0.patronidemo-headless:5432
```

在你的環境中，根據 Pod spec：
```yaml
env:
- name: PATRONI_KUBERNETES_POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP  # ← 獲取 Pod IP
```

**如果沒有明確設置 `PATRONI_POSTGRESQL_CONNECT_ADDRESS`**：
- Patroni 會使用 `PATRONI_KUBERNETES_POD_IP` 的值
- 生成的 `conn_url` 就會是 `postgres://10.244.0.125:5432/postgres`

**如果設置了 `PATRONI_POSTGRESQL_CONNECT_ADDRESS`**：
```bash
PATRONI_POSTGRESQL_CONNECT_ADDRESS=$(PATRONI_NAME).patronidemo-headless:5432
```
- 生成的 `conn_url` 就會是 `postgres://patronidemo-0.patronidemo-headless:5432/postgres`

#### Patroni API connection_string

同理，從 `restapi.connect_address` 配置生成：
```yaml
restapi:
  connect_address: 10.244.0.125:8008
  # 或
  connect_address: patronidemo-0.patronidemo-headless:8008
```

### 3. 調用 touch_member

**檔案位置：** `patroni/ha.py:508`

```python
# patroni/ha.py:498-513
def post_recover(self) -> None:
    # ... 建立 data 字典（包含 conn_url, api_url 等）

    # 調用 DCS 的 touch_member 方法，將數據寫入 DCS
    ret = self.dcs.touch_member(data)  # ← 這裡！

    if ret:
        new_state = (data['state'], data['role'])
        if self._last_state != new_state and new_state == (PostgresqlState.RUNNING, PostgresqlRole.PRIMARY):
            self.notify_mpp_coordinator('after_promote')
        self._last_state = new_state
```

### 4. Kubernetes DCS 的 touch_member 實現

**檔案位置：** `patroni/dcs/kubernetes.py:1359-1398`

```python
@catch_kubernetes_errors
def touch_member(self, data: Dict[str, Any]) -> bool:
    """
    更新當前節點的狀態到 Kubernetes Pod annotations

    參數：
        data: 包含 conn_url, api_url, state, role, timeline 等的字典

    返回：
        True 如果成功更新
    """
    # 1. 獲取當前叢集狀態
    cluster = self.cluster

    # 2. 根據角色設置 labels（primary/replica）
    if cluster and cluster.leader and cluster.leader.name == self._name:
        role = self._leader_label_value  # 'primary'
        tmp_role = 'primary'
    elif data['state'] == PostgresqlState.RUNNING and data['role'] != PostgresqlRole.PRIMARY:
        role = self._follower_label_value  # 'replica'
        tmp_role = data['role']
    else:
        role = None
        tmp_role = None

    # 3. 準備更新的 labels
    updated_labels = {self._role_label: role}
    if self._tmp_role_label:
        updated_labels[self._tmp_role_label] = tmp_role

    # 4. 檢查是否需要更新（避免不必要的 API 調用）
    member = cluster and cluster.get_member(self._name, fallback_to_leader=False)
    pod_labels = member and member.data.pop('pod_labels', None)
    ret = member and pod_labels is not None\
        and all(pod_labels.get(k) == v for k, v in updated_labels.items())\
        and deep_compare(data, member.data)

    # 5. 如果需要更新，調用 Kubernetes API
    if not ret:
        # 建立 Pod metadata
        metadata: Dict[str, Any] = {
            'namespace': self._namespace,     # default
            'name': self._name,               # patronidemo-0
            'labels': updated_labels,         # role: primary
            'annotations': {
                'status': json.dumps(data, separators=(',', ':'))  # ← 重點！將整個 data 字典序列化為 JSON
            }
        }

        # 建立 Kubernetes API 的 Pod 物件
        body = k8s_client.V1Pod(
            metadata=k8s_client.V1ObjectMeta(**metadata)
        )

        # 調用 Kubernetes API 更新 Pod
        ret = self._api.patch_namespaced_pod(self._name, self._namespace, body)

        # 更新本地快取
        if ret:
            self._pods.set(self._name, ret)

    # 6. 如果使用 Endpoints，創建 config service
    if self._should_create_config_service:
        self._create_config_service()

    return bool(ret)
```

### 5. Kubernetes API 調用

**檔案位置：** `patroni/dcs/kubernetes.py:1393`

```python
# 這裡調用 Kubernetes API
ret = self._api.patch_namespaced_pod(self._name, self._namespace, body)
```

這相當於執行：
```bash
kubectl patch pod patronidemo-0 -n default --type=strategic -p '
{
  "metadata": {
    "labels": {
      "role": "primary"
    },
    "annotations": {
      "status": "{\"conn_url\":\"postgres://10.244.0.125:5432/postgres\",\"api_url\":\"http://10.244.0.125:8008/patroni\",\"state\":\"running\",\"role\":\"primary\",\"version\":\"4.1.0\",\"xlog_location\":6157238632,\"timeline\":5}"
    }
  }
}
'
```

---

## conn_url 的值是如何決定的？

### 關鍵配置參數

**環境變數或配置文件中：**

```yaml
postgresql:
  connect_address: ${CONNECT_ADDRESS}  # 這決定了 conn_url

restapi:
  connect_address: ${API_CONNECT_ADDRESS}  # 這決定了 api_url
```

### 你的環境（使用 Pod IP）

從你的 Pod 配置：
```yaml
env:
- name: PATRONI_KUBERNETES_POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP  # 獲取 Pod IP: 10.244.0.125
```

**如果沒有設置** `PATRONI_POSTGRESQL_CONNECT_ADDRESS`：
- Patroni 會自動使用 Pod IP
- 結果：`conn_url = "postgres://10.244.0.125:5432/postgres"`

### 改用 Headless Service DNS

**設置環境變數：**
```yaml
env:
- name: PATRONI_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name  # patronidemo-0

- name: PATRONI_POSTGRESQL_CONNECT_ADDRESS
  value: "$(PATRONI_NAME).patronidemo-headless.default.svc.cluster.local:5432"

- name: PATRONI_RESTAPI_CONNECT_ADDRESS
  value: "$(PATRONI_NAME).patronidemo-headless.default.svc.cluster.local:8008"
```

**結果：**
- `conn_url = "postgres://patronidemo-0.patronidemo-headless.default.svc.cluster.local:5432/postgres"`
- `api_url = "http://patronidemo-0.patronidemo-headless.default.svc.cluster.local:8008/patroni"`

---

## 完整的程式碼追蹤路徑

### 路徑 1: 從配置到 connection_string

```
1. 配置文件/環境變數
   ├─> PATRONI_POSTGRESQL_CONNECT_ADDRESS (或 POD_IP)
   └─> PATRONI_RESTAPI_CONNECT_ADDRESS

2. Patroni 初始化 (patroni/postgresql/__init__.py)
   ├─> 讀取配置
   └─> 設置 self.connection_string

3. PostgreSQL connection_string 屬性
   └─> 返回配置的 connect_address

範例：
  如果 PATRONI_POSTGRESQL_CONNECT_ADDRESS = "10.244.0.125:5432"
  則 connection_string = "postgres://10.244.0.125:5432/postgres"
```

### 路徑 2: 從 connection_string 到 Pod annotation

```
1. HA 循環觸發 (每 10 秒)
   └─> patroni/ha.py:run_cycle()

2. 進入 post_recover()
   ├─> patroni/ha.py:1256-1257
   └─> data = {
           'conn_url': self.state_handler.connection_string,  # ← 從配置獲取
           'api_url': self.patroni.api.connection_string,
           ...
       }

3. 調用 DCS touch_member
   ├─> patroni/ha.py:508
   └─> ret = self.dcs.touch_member(data)

4. Kubernetes DCS 處理
   ├─> patroni/dcs/kubernetes.py:1359
   └─> def touch_member(self, data)

5. 序列化為 JSON
   ├─> patroni/dcs/kubernetes.py:1391
   └─> 'status': json.dumps(data, separators=(',', ':'))

6. 更新 Pod annotation
   ├─> patroni/dcs/kubernetes.py:1393
   └─> self._api.patch_namespaced_pod(...)

7. Kubernetes API Server 處理
   └─> 更新 etcd 中的 Pod 物件

8. 完成
   └─> kubectl get pod patronidemo-0 -o yaml
       → metadata.annotations.status 包含 conn_url
```

---

## 實際驗證

### 查看當前的 conn_url

```bash
# 方法 1: 查看 Pod annotation
kubectl get pod patronidemo-0 -n default -o jsonpath='{.metadata.annotations.status}' | jq -r '.conn_url'

# 方法 2: 進入 Pod 查看環境變數
kubectl exec -it patronidemo-0 -n default -- env | grep PATRONI_POSTGRESQL_CONNECT_ADDRESS
```

### 修改為使用 DNS

```bash
# 方法 1: 使用 kubectl set env
kubectl set env statefulset/patronidemo -n default \
  PATRONI_POSTGRESQL_CONNECT_ADDRESS='$(PATRONI_NAME).patronidemo-headless.default.svc.cluster.local:5432' \
  PATRONI_RESTAPI_CONNECT_ADDRESS='$(PATRONI_NAME).patronidemo-headless.default.svc.cluster.local:8008'

# 方法 2: 編輯 StatefulSet
kubectl edit statefulset patronidemo -n default

# 添加或修改環境變數：
# env:
# - name: PATRONI_POSTGRESQL_CONNECT_ADDRESS
#   value: "$(PATRONI_NAME).patronidemo-headless.default.svc.cluster.local:5432"
# - name: PATRONI_RESTAPI_CONNECT_ADDRESS
#   value: "$(PATRONI_NAME).patronidemo-headless.default.svc.cluster.local:8008"

# 重啟 Pods
kubectl rollout restart statefulset patronidemo -n default

# 等待完成
kubectl rollout status statefulset patronidemo -n default

# 驗證新的 conn_url
kubectl get pod patronidemo-0 -n default -o jsonpath='{.metadata.annotations.status}' | jq -r '.conn_url'

# 應該顯示：
# postgres://patronidemo-0.patronidemo-headless.default.svc.cluster.local:5432/postgres
```

---

## 關鍵程式碼位置總結

| 功能 | 檔案位置 | 說明 |
|------|---------|------|
| **conn_url 生成** | `patroni/postgresql/__init__.py` | 從配置的 `connect_address` 生成 |
| **收集狀態數據** | `patroni/ha.py:1256-1257` | 建立包含 conn_url 的 data 字典 |
| **調用 touch_member** | `patroni/ha.py:508` | 將數據提交到 DCS |
| **K8s touch_member 實現** | `patroni/dcs/kubernetes.py:1359-1398` | 序列化數據並調用 K8s API |
| **JSON 序列化** | `patroni/dcs/kubernetes.py:1391` | `json.dumps(data)` |
| **K8s API 調用** | `patroni/dcs/kubernetes.py:1393` | `patch_namespaced_pod()` |
| **配置讀取** | `patroni/config.py` | 讀取環境變數或配置文件 |

---

## 為什麼這很重要？

### 理解了這個流程，你就知道：

1. **為什麼會使用 Pod IP**
   - 如果沒有設置 `PATRONI_POSTGRESQL_CONNECT_ADDRESS`
   - Patroni 會使用 `PATRONI_KUBERNETES_POD_IP`（從 `status.podIP` 獲取）
   - 結果就是 Pod IP 出現在 `conn_url` 中

2. **如何改成使用 DNS**
   - 設置 `PATRONI_POSTGRESQL_CONNECT_ADDRESS` 環境變數
   - 使用 `$(PATRONI_NAME).{service}.{namespace}.svc.cluster.local:5432` 格式
   - Patroni 會使用這個值作為 `connection_string`
   - 最終寫入 Pod annotation 的 `conn_url` 就會是 DNS 名稱

3. **更新頻率**
   - 每個 HA 循環（預設 10 秒）都會調用 `post_recover()`
   - 如果數據有變化，就會更新 Pod annotation
   - 這就是為什麼 annotation 中的 `renewTime` 會不斷更新

4. **Istio 問題的根源**
   - 使用 Pod IP 時，Istio Envoy 需要攔截所有 Pod IP 的連接
   - 使用 DNS 時，Istio 可以更好地管理流量
   - 這就是為什麼推薦使用 Headless Service + DNS 的方式

---

## 調試技巧

### 即時查看 touch_member 的調用

```bash
# 進入 Patroni Pod
kubectl exec -it patronidemo-0 -n default -- bash

# 查看 Patroni 日誌（如果啟用了 debug）
tail -f /var/log/patroni.log

# 或使用 kubectl logs
kubectl logs -f patronidemo-0 -n default | grep -i "touch_member\|conn_url"
```

### 追蹤 Kubernetes API 調用

```bash
# 啟用 Kubernetes API Server 審計日誌
kubectl get events -n default --watch | grep patronidemo-0

# 查看 Pod 的最近更新
kubectl get pod patronidemo-0 -n default -o yaml | grep -A 20 annotations
```

### 驗證配置的傳遞

```bash
# 檢查環境變數
kubectl exec patronidemo-0 -n default -- printenv | grep PATRONI

# 檢查實際的 connection_string
kubectl exec patronidemo-0 -n default -- python3 -c "
import os, json
connect_address = os.getenv('PATRONI_POSTGRESQL_CONNECT_ADDRESS', os.getenv('PATRONI_KUBERNETES_POD_IP') + ':5432')
print('connection_string:', 'postgres://' + connect_address + '/postgres')
"
```

---

## 總結

### conn_url 寫入流程的三個關鍵點：

1. **來源**：從 `PATRONI_POSTGRESQL_CONNECT_ADDRESS` 環境變數（或 Pod IP）
2. **傳遞**：通過 `ha.py:post_recover()` → `dcs.touch_member()`
3. **寫入**：通過 Kubernetes API 的 `patch_namespaced_pod()` 更新 Pod annotation

### 修改建議：

要改變 `conn_url` 的值，只需要：
1. 創建 Headless Service
2. 設置 `PATRONI_POSTGRESQL_CONNECT_ADDRESS` 環境變數使用 DNS
3. 重啟 Pods，讓新配置生效
4. Patroni 會自動在下一個 HA 循環更新 Pod annotation

就這麼簡單！
