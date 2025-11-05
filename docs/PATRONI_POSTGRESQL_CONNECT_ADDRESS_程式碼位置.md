# PATRONI_POSTGRESQL_CONNECT_ADDRESS 在程式碼中的位置

## 問題
`PATRONI_POSTGRESQL_CONNECT_ADDRESS` 環境變數在程式碼的哪裡被讀取並使用？

## 答案

### 關鍵程式碼位置

**檔案：** `patroni/postgresql/config.py`
**方法：** `ConfigHandler.resolve_connection_addresses()`
**行號：** 1140 和 1153

---

## 完整程式碼流程

### 1. 讀取 connect_address 配置

**位置：** `patroni/postgresql/config.py:1140`

```python
def resolve_connection_addresses(self) -> None:
    """Calculates and sets local and remote connection urls and options.

    This method sets:
        * :attr:`Postgresql.connection_string` attribute, which
          is later written to the member key in DCS as ``conn_url``.
        * :attr:`ConfigHandler.local_replication_address` attribute
        * :attr:`ConnectionPool.conn_kwargs` attribute
    """
    port = self._server_parameters['port']
    tcp_local_address = self._get_tcp_local_address()

    # ✅ 關鍵行：這裡讀取 connect_address 配置
    netloc = self._config.get('connect_address') or tcp_local_address + ':' + port

    # ... 其他邏輯 ...

    # ✅ 關鍵行：使用 netloc 設置 connection_string
    self._postgresql.connection_string = uri('postgres', netloc, self._postgresql.database)
```

### 2. 配置讀取邏輯

**`self._config.get('connect_address')`** 會：

1. **優先使用環境變數：** `PATRONI_POSTGRESQL_CONNECT_ADDRESS`
2. **其次使用配置文件中的值：** `postgresql.connect_address`
3. **最後回退到自動檢測：** `tcp_local_address + ':' + port`

### 3. 詳細的邏輯分解

```python
# 第 1140 行的完整邏輯
netloc = self._config.get('connect_address') or tcp_local_address + ':' + port

# 等價於：
if self._config.get('connect_address'):
    # 如果設置了 PATRONI_POSTGRESQL_CONNECT_ADDRESS 環境變數
    # 或配置文件中有 postgresql.connect_address
    netloc = self._config.get('connect_address')
else:
    # 否則，自動檢測本地 TCP 地址並加上端口
    netloc = tcp_local_address + ':' + port
```

### 4. 生成 connection_string

**位置：** `patroni/postgresql/config.py:1153`

```python
# 使用 netloc 生成 PostgreSQL 連接字串
self._postgresql.connection_string = uri('postgres', netloc, self._postgresql.database)
```

**結果範例：**

| netloc 值 | connection_string 結果 |
|-----------|------------------------|
| `10.244.0.125:5432` | `postgres://10.244.0.125:5432/postgres` |
| `patronidemo-0.patronidemo-headless:5432` | `postgres://patronidemo-0.patronidemo-headless:5432/postgres` |
| `patronidemo-0.patronidemo-headless.default.svc.cluster.local:5432` | `postgres://patronidemo-0.patronidemo-headless.default.svc.cluster.local:5432/postgres` |

---

## 完整的配置讀取流程

### 流程圖

```
用戶設置環境變數或配置文件
    ↓
PATRONI_POSTGRESQL_CONNECT_ADDRESS="patronidemo-0.patronidemo-headless:5432"
或 postgresql.connect_address 在配置文件中
    ↓
Patroni 啟動，讀取配置 (patroni/config.py)
    ↓
創建 Config 物件，合併環境變數和配置文件
    ↓
創建 Postgresql 實例 (patroni/__main__.py:76)
    └─> Postgresql(self.config['postgresql'], ...)
    ↓
創建 ConfigHandler (patroni/postgresql/__init__.py:99)
    └─> self.config = ConfigHandler(self, config)
    ↓
ConfigHandler.__init__ 調用 resolve_connection_addresses()
    ↓
resolve_connection_addresses() 讀取 connect_address
    ├─> patroni/postgresql/config.py:1140
    │   netloc = self._config.get('connect_address') or ...
    │   ✅ 這裡讀取 PATRONI_POSTGRESQL_CONNECT_ADDRESS
    │
    └─> patroni/postgresql/config.py:1153
        self._postgresql.connection_string = uri('postgres', netloc, ...)
        ✅ 設置 connection_string
    ↓
後續在 HA 循環中使用
    └─> patroni/ha.py:1256
        data = {
            'conn_url': self.state_handler.connection_string,  ← 使用這個值
            ...
        }
```

---

## 關鍵程式碼片段

### 1. ConfigHandler 初始化

**位置：** `patroni/postgresql/config.py` (ConfigHandler.__init__)

```python
class ConfigHandler(object):
    def __init__(self, postgresql: 'Postgresql', config: Dict[str, Any]) -> None:
        self._postgresql = postgresql
        self._config = config
        # ... 其他初始化 ...

        # 讀取 server parameters
        self._server_parameters = self.get_server_parameters(config)

        # ✅ 調用 resolve_connection_addresses，設置 connection_string
        self.resolve_connection_addresses()
```

### 2. resolve_connection_addresses 完整實現

**位置：** `patroni/postgresql/config.py:1112-1168`

```python
def resolve_connection_addresses(self) -> None:
    """Calculates and sets local and remote connection urls and options.

    This method sets:
        * :attr:`Postgresql.connection_string <patroni.postgresql.Postgresql.connection_string>` attribute, which
          is later written to the member key in DCS as ``conn_url``.
        * :attr:`ConfigHandler.local_replication_address` attribute, which is used for replication connections to
          local postgres.
        * :attr:`ConnectionPool.conn_kwargs <patroni.postgresql.connection.ConnectionPool.conn_kwargs>` attribute,
          which is used for superuser connections to local postgres.

    .. note::
        If there is a valid directory in ``postgresql.parameters.unix_socket_directories`` in the Patroni
        configuration and ``postgresql.use_unix_socket`` and/or ``postgresql.use_unix_socket_repl``
        are set to ``True``, we respectively use unix sockets for superuser and replication connections
        to local postgres.

        If there is a requirement to use unix sockets, but nothing is set in the
        ``postgresql.parameters.unix_socket_directories``, we omit a ``host`` in connection parameters relying
        on the ability of ``libpq`` to connect via some default unix socket directory.

        If unix sockets are not requested we "switch" to TCP, preferring to use ``localhost`` if it is possible
        to deduce that Postgres is listening on a local interface address.

        Otherwise we just used the first address specified in the ``listen_addresses`` GUC.
    """
    port = self._server_parameters['port']
    tcp_local_address = self._get_tcp_local_address()

    # ✅ 關鍵：讀取 connect_address 配置
    # 優先順序：
    # 1. PATRONI_POSTGRESQL_CONNECT_ADDRESS 環境變數
    # 2. postgresql.connect_address 配置文件
    # 3. 自動檢測的本地地址
    netloc = self._config.get('connect_address') or tcp_local_address + ':' + port

    unix_local_address = {'port': port}
    unix_socket_directories = self._server_parameters.get('unix_socket_directories')
    if unix_socket_directories is not None:
        # fallback to tcp if unix_socket_directories is set, but there are no suitable values
        unix_local_address['host'] = self._get_unix_local_address(unix_socket_directories) or tcp_local_address

    tcp_local_address = {'host': tcp_local_address, 'port': port}

    self.local_replication_address = unix_local_address\
        if self._config.get('use_unix_socket_repl') else tcp_local_address

    # ✅ 關鍵：設置 postgresql.connection_string
    self._postgresql.connection_string = uri('postgres', netloc, self._postgresql.database)

    local_address = unix_local_address if self._config.get('use_unix_socket') else tcp_local_address
    local_conn_kwargs = {
        **local_address,
        **self._superuser,
        'dbname': self._postgresql.database,
        'fallback_application_name': 'Patroni',
        'connect_timeout': 3,
        'options': '-c statement_timeout=2000'
    }
    # if the "username" parameter is present, it actually needs to be "user" for connecting to PostgreSQL
    if 'username' in local_conn_kwargs:
        local_conn_kwargs['user'] = local_conn_kwargs.pop('username')
    # "notify" connection_pool about the "new" local connection address
    self._postgresql.connection_pool.conn_kwargs = local_conn_kwargs
```

### 3. Config.get() 方法

Config 物件的 `get()` 方法會：
1. 首先查找對應的環境變數（大寫並加上前綴）
2. 然後查找配置文件中的值
3. 最後返回默認值（如果提供）

**環境變數命名規則：**
```python
# 配置路徑: postgresql.connect_address
# 對應環境變數: PATRONI_POSTGRESQL_CONNECT_ADDRESS

# 配置路徑: restapi.connect_address
# 對應環境變數: PATRONI_RESTAPI_CONNECT_ADDRESS
```

---

## 實際範例

### 範例 1：使用 Pod IP（未設置環境變數）

**配置：**
```yaml
# 沒有設置 PATRONI_POSTGRESQL_CONNECT_ADDRESS
# 沒有在配置文件中設置 postgresql.connect_address

postgresql:
  listen: 0.0.0.0:5432
  # connect_address 未設置
```

**結果：**
```python
# tcp_local_address 會被自動檢測為 Pod IP
tcp_local_address = "10.244.0.125"  # 從 PATRONI_KUBERNETES_POD_IP 獲取
port = "5432"

# netloc 使用回退值
netloc = tcp_local_address + ':' + port  # "10.244.0.125:5432"

# connection_string
connection_string = uri('postgres', netloc, 'postgres')
# 結果: "postgres://10.244.0.125:5432/postgres"
```

### 範例 2：使用環境變數設置 DNS

**配置：**
```yaml
env:
- name: PATRONI_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name  # "patronidemo-0"

- name: PATRONI_POSTGRESQL_CONNECT_ADDRESS
  value: "$(PATRONI_NAME).patronidemo-headless:5432"
```

**結果：**
```python
# Kubernetes 會先展開 $(PATRONI_NAME)
# PATRONI_POSTGRESQL_CONNECT_ADDRESS = "patronidemo-0.patronidemo-headless:5432"

# netloc 使用環境變數的值
netloc = self._config.get('connect_address')  # "patronidemo-0.patronidemo-headless:5432"

# connection_string
connection_string = uri('postgres', netloc, 'postgres')
# 結果: "postgres://patronidemo-0.patronidemo-headless:5432/postgres"
```

### 範例 3：使用配置文件

**配置文件 (patroni.yml)：**
```yaml
postgresql:
  connect_address: patronidemo-0.patronidemo-headless.default.svc.cluster.local:5432
  listen: 0.0.0.0:5432
```

**結果：**
```python
# netloc 從配置文件讀取
netloc = self._config.get('connect_address')
# "patronidemo-0.patronidemo-headless.default.svc.cluster.local:5432"

# connection_string
connection_string = uri('postgres', netloc, 'postgres')
# 結果: "postgres://patronidemo-0.patronidemo-headless.default.svc.cluster.local:5432/postgres"
```

---

## 優先順序總結

`connect_address` 的值決定邏輯（從高到低）：

1. **環境變數：** `PATRONI_POSTGRESQL_CONNECT_ADDRESS`
   ```bash
   export PATRONI_POSTGRESQL_CONNECT_ADDRESS="patronidemo-0.patronidemo-headless:5432"
   ```

2. **配置文件：** `postgresql.connect_address`
   ```yaml
   postgresql:
     connect_address: patronidemo-0.patronidemo-headless:5432
   ```

3. **自動檢測：** 從 `listen` 或 Pod IP 推斷
   ```python
   tcp_local_address + ':' + port
   # 例如: "10.244.0.125:5432"
   ```

---

## 在 HA 循環中的使用

設置好 `connection_string` 後，它會在每個 HA 循環中被使用：

**位置：** `patroni/ha.py:1256`

```python
def post_recover(self) -> None:
    """準備節點狀態數據並更新到 DCS"""
    data: Dict[str, Any] = {
        'conn_url': self.state_handler.connection_string,  # ← 使用這裡設置的值
        'api_url': self.patroni.api.connection_string,
        'state': self.state_handler.state.value,
        'role': self.state_handler.role.value,
        'version': self.patroni.version
        # ... 其他欄位
    }

    # 更新到 DCS（Kubernetes Pod annotations）
    ret = self.dcs.touch_member(data)
```

---

## 調試方法

### 1. 檢查環境變數

```bash
# 進入 Pod
kubectl exec -it patronidemo-0 -n default -- bash

# 查看環境變數
echo $PATRONI_POSTGRESQL_CONNECT_ADDRESS

# 或查看所有 PATRONI 相關環境變數
env | grep PATRONI | sort
```

### 2. 查看 Patroni 配置

```bash
# 進入 Pod
kubectl exec -it patronidemo-0 -n default -- bash

# 查看 Patroni 配置（如果使用配置文件）
cat /etc/patroni/patroni.yml

# 或使用 Patroni API 查看配置
curl http://localhost:8008/config | jq
```

### 3. 查看實際的 connection_string

```bash
# 查看 Pod annotation 中的 conn_url
kubectl get pod patronidemo-0 -n default -o jsonpath='{.metadata.annotations.status}' | jq -r '.conn_url'

# 這就是 connection_string 的值
```

### 4. 在 Python 中驗證

```python
# 進入 Patroni Pod
kubectl exec -it patronidemo-0 -n default -- python3

# 在 Python 中模擬配置讀取
import os

# 模擬 Config.get('connect_address')
connect_address = os.getenv('PATRONI_POSTGRESQL_CONNECT_ADDRESS')
if connect_address:
    print(f"使用環境變數: {connect_address}")
else:
    # 回退到自動檢測
    pod_ip = os.getenv('PATRONI_KUBERNETES_POD_IP', 'unknown')
    port = '5432'
    connect_address = f"{pod_ip}:{port}"
    print(f"使用自動檢測: {connect_address}")

# 生成 connection_string
connection_string = f"postgres://{connect_address}/postgres"
print(f"connection_string: {connection_string}")
```

---

## 總結

### 關鍵要點

1. **讀取位置：** `patroni/postgresql/config.py:1140`
   ```python
   netloc = self._config.get('connect_address') or tcp_local_address + ':' + port
   ```

2. **設置位置：** `patroni/postgresql/config.py:1153`
   ```python
   self._postgresql.connection_string = uri('postgres', netloc, self._postgresql.database)
   ```

3. **使用位置：** `patroni/ha.py:1256`
   ```python
   data = {'conn_url': self.state_handler.connection_string, ...}
   ```

4. **優先順序：**
   - 環境變數 `PATRONI_POSTGRESQL_CONNECT_ADDRESS`
   - 配置文件 `postgresql.connect_address`
   - 自動檢測（Pod IP + port）

### 修改建議

要將 Pod IP 改為 DNS：

```bash
# 設置環境變數
kubectl set env statefulset/patronidemo -n default \
  PATRONI_POSTGRESQL_CONNECT_ADDRESS='$(PATRONI_NAME).patronidemo-headless:5432'

# 重啟生效
kubectl rollout restart statefulset patronidemo -n default

# 驗證
kubectl get pod patronidemo-0 -n default -o jsonpath='{.metadata.annotations.status}' | jq -r '.conn_url'
```

就是這麼簡單！
