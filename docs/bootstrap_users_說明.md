# bootstrap.users 配置說明

## ⚠️ 重要：此配置已廢棄！

### 結論

**`bootstrap.users` 配置從 Patroni v4.0.0 開始已經不再支持！**

你配置中的這段：
```yaml
bootstrap:
  users:
    zalandos:
      options:
      - CREATEDB
      - NOLOGIN
      password: ''
```

**在 Patroni v4.0.0+ 中是無效的！不會創建任何用戶。**

---

## 程式碼證據

### 位置
**檔案：** `patroni/postgresql/bootstrap.py`
**行號：** 461-463

### 程式碼

```python
if config.get('users'):
    logger.error('User creation is not be supported starting from v4.0.0. '
                 'Please use "bootstrap.post_bootstrap" script to create users.')
```

當 Patroni 檢測到 `bootstrap.users` 配置時，會：
1. **記錄一條 ERROR 日誌**
2. **不會創建任何用戶**
3. **提示使用 `post_bootstrap` 腳本**

---

## 完整的 Bootstrap 流程

### 1. Bootstrap 執行順序

```
1. Initdb (或 Custom Bootstrap)
   └─> 初始化 PostgreSQL 數據目錄

2. 啟動 PostgreSQL
   └─> 使用臨時的 pg_hba.conf（允許 trust 認證）

3. 檢查 bootstrap.users 配置
   ├─> 如果存在：記錄 ERROR 日誌
   └─> 不執行任何操作

4. 調用 post_bootstrap 腳本 ✅ 正確的方式
   └─> call_post_bootstrap(config)
   └─> 執行 config.get('post_bootstrap') 或 config.get('post_init')

5. 恢復正常的 pg_hba.conf
   └─> 重新加載配置
```

### 2. call_post_bootstrap 方法

**位置：** `patroni/postgresql/bootstrap.py:213-224`

```python
def call_post_bootstrap(self, config: Dict[str, Any]) -> bool:
    """
    runs a script after initdb or custom bootstrap script is called and waits until completion.
    """
    # 優先使用 post_bootstrap，其次是 post_init
    cmd = config.get('post_bootstrap') or config.get('post_init')

    if cmd:
        r = self._postgresql.connection_pool.conn_kwargs

        # 準備環境變數，包括連接參數
        env = self._postgresql.config.write_pgpass({'host': 'localhost', **r})

        # 執行腳本...
        # （省略執行細節）
```

---

## 正確的做法

### 方案 1：使用 post_bootstrap 腳本

**推薦方式：**

```yaml
bootstrap:
  # 使用 post_bootstrap 替代 users
  post_bootstrap: /scripts/create_users.sh

  # 或者使用 post_init（效果相同）
  # post_init: /scripts/create_users.sh
```

**創建 `/scripts/create_users.sh` 腳本：**

```bash
#!/bin/bash
set -e

# Patroni 會自動設置以下環境變數：
# - PGHOST (localhost)
# - PGPORT (5432 或你配置的端口)
# - PGUSER (超級用戶名)
# - PGDATABASE (postgres)
# - PGPASSFILE (pgpass 文件路徑)

# 創建 zalandos 角色
psql -v ON_ERROR_STOP=1 <<-EOSQL
    -- 創建角色（不能登錄）
    CREATE ROLE zalandos WITH
        CREATEDB        -- 允許創建資料庫
        NOLOGIN;        -- 不允許登錄

    -- 如果需要設置密碼（對於可登錄的用戶）
    -- ALTER ROLE zalandos WITH LOGIN PASSWORD 'your_password';

    -- 可以創建其他用戶
    CREATE USER app_user WITH
        PASSWORD 'app_password'
        IN ROLE zalandos;  -- 繼承 zalandos 角色的權限

    EOSQL

echo "Users created successfully"
```

**確保腳本有執行權限：**
```bash
chmod +x /scripts/create_users.sh
```

### 方案 2：在 post_init 中創建用戶

你的配置中已經有 `post_init`：

```yaml
bootstrap:
  post_init: /scripts/post_init.sh "zalandos"
```

**可以在這個腳本中創建用戶：**

```bash
#!/bin/bash
set -e

ROLE_NAME="$1"  # zalandos

echo "Running post_init script for role: $ROLE_NAME"

# 創建角色
psql -v ON_ERROR_STOP=1 <<-EOSQL
    DO \$\$
    BEGIN
        -- 檢查角色是否已存在
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$ROLE_NAME') THEN
            CREATE ROLE $ROLE_NAME WITH
                CREATEDB
                NOLOGIN;
            RAISE NOTICE 'Role % created', '$ROLE_NAME';
        ELSE
            RAISE NOTICE 'Role % already exists', '$ROLE_NAME';
        END IF;
    END
    \$\$;
EOSQL

echo "Post init completed"
```

### 方案 3：使用 SQL 文件

**配置：**
```yaml
bootstrap:
  post_bootstrap: /usr/bin/psql -f /scripts/init_users.sql
```

**創建 `/scripts/init_users.sql`：**
```sql
-- 創建角色
CREATE ROLE IF NOT EXISTS zalandos WITH
    CREATEDB
    NOLOGIN;

-- 創建其他用戶
CREATE USER IF NOT EXISTS app_user WITH
    PASSWORD 'app_password'
    IN ROLE zalandos;

-- 授予權限
GRANT ALL PRIVILEGES ON DATABASE seasql TO zalandos;
```

---

## post_init vs post_bootstrap

### 區別

| 特性 | post_init | post_bootstrap |
|------|-----------|----------------|
| **執行時機** | initdb 後，PostgreSQL 首次啟動前 | 所有 bootstrap 步驟完成後 |
| **適用場景** | 創建用戶、擴展、初始數據 | 創建用戶、擴展、初始數據 |
| **執行次數** | 只在首次初始化時執行一次 | 只在首次初始化時執行一次 |
| **優先級** | 先執行 | 後執行（如果兩者都設置） |

### 推薦

- **如果只需要創建用戶和基本設置**：使用 `post_init`（更早執行）
- **如果需要執行複雜的初始化邏輯**：使用 `post_bootstrap`（更晚執行，環境更完整）

---

## 為什麼 bootstrap.users 被廢棄？

### 歷史原因

1. **功能有限**
   - 只能創建用戶，不能設置複雜的權限
   - 不能執行任意 SQL

2. **不夠靈活**
   - 無法根據環境動態調整
   - 無法處理錯誤和重試

3. **腳本方式更強大**
   - 可以執行任意 SQL
   - 可以根據條件創建不同的用戶
   - 可以處理錯誤和日誌
   - 可以與外部系統集成（如密鑰管理系統）

4. **維護成本**
   - Patroni 不需要維護用戶創建邏輯
   - 用戶可以使用標準的 PostgreSQL 工具

### Patroni v4.0.0 的變更

從 v4.0.0 開始，Patroni 簡化了代碼：
- **移除了 `create_users()` 方法**
- **只保留 `call_post_bootstrap()` 方法**
- **在檢測到 `users` 配置時記錄錯誤**

---

## 檢查你的環境

### 1. 查看 Patroni 版本

```bash
# 進入 Pod
kubectl exec -it seasql-base-0 -n service-software -- bash

# 查看版本
patroni --version

# 或查看 Pod annotation
kubectl get pod seasql-base-0 -n service-software -o jsonpath='{.metadata.annotations.status}' | jq -r '.version'
```

### 2. 查看日誌中的錯誤

```bash
# 查看 Patroni 日誌
kubectl logs seasql-base-0 -n service-software | grep -i "user creation"

# 應該會看到類似：
# ERROR: User creation is not be supported starting from v4.0.0. Please use "bootstrap.post_bootstrap" script to create users.
```

### 3. 驗證用戶是否存在

```bash
# 進入 PostgreSQL
kubectl exec -it seasql-base-0 -n service-software -- psql -U ssadmin -d seasql

# 查看角色
\du

# 查看 zalandos 角色
SELECT * FROM pg_roles WHERE rolname = 'zalandos';
```

**如果 `zalandos` 角色不存在，說明：**
1. 你的 Patroni 版本 >= 4.0.0
2. `bootstrap.users` 配置沒有生效
3. 需要使用 `post_bootstrap` 腳本來創建

---

## 遷移指南

### 步驟 1：移除廢棄的配置

**修改前：**
```yaml
bootstrap:
  users:
    zalandos:
      options:
      - CREATEDB
      - NOLOGIN
      password: ''
```

**修改後：**
```yaml
bootstrap:
  # 移除 users 配置
  # users:  # ← 刪除這段

  # 添加 post_bootstrap 腳本
  post_bootstrap: /scripts/create_users.sh
```

### 步驟 2：創建用戶創建腳本

**創建 `/scripts/create_users.sh`：**

```bash
#!/bin/bash
set -e

echo "Creating database users..."

# 使用 psql 創建用戶
# Patroni 已經設置好了連接參數（環境變數）
psql -v ON_ERROR_STOP=1 <<-EOSQL
    -- 創建 zalandos 角色
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'zalandos') THEN
            CREATE ROLE zalandos WITH
                CREATEDB
                NOLOGIN;
            RAISE NOTICE 'Role zalandos created';
        ELSE
            RAISE NOTICE 'Role zalandos already exists';
        END IF;
    END
    \$\$;

    -- 可以創建其他用戶
    -- CREATE USER app_user WITH PASSWORD 'password' IN ROLE zalandos;
EOSQL

echo "User creation completed successfully"
```

### 步驟 3：更新 Docker 鏡像或 ConfigMap

**如果腳本在 Docker 鏡像中：**
```dockerfile
# Dockerfile
COPY scripts/create_users.sh /scripts/
RUN chmod +x /scripts/create_users.sh
```

**如果腳本在 ConfigMap 中：**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: patroni-scripts
data:
  create_users.sh: |
    #!/bin/bash
    set -e
    echo "Creating database users..."
    psql -v ON_ERROR_STOP=1 <<-EOSQL
        CREATE ROLE IF NOT EXISTS zalandos WITH CREATEDB NOLOGIN;
    EOSQL
```

**然後掛載到 Pod：**
```yaml
volumes:
- name: scripts
  configMap:
    name: patroni-scripts
    defaultMode: 0755

volumeMounts:
- name: scripts
  mountPath: /scripts
```

### 步驟 4：測試

**如果是新建叢集：**
1. 刪除舊的 StatefulSet 和 PVC
2. 應用新的配置
3. 等待叢集初始化
4. 驗證用戶已創建

**如果是現有叢集：**
- `post_bootstrap` 腳本**只在首次初始化時執行**
- 對於已運行的叢集，需要手動創建用戶：
  ```bash
  kubectl exec -it seasql-base-0 -n service-software -- \
    psql -U ssadmin -d seasql -c "CREATE ROLE zalandos WITH CREATEDB NOLOGIN;"
  ```

---

## 總結

### 關鍵點

1. **`bootstrap.users` 從 Patroni v4.0.0 開始已廢棄**
2. **必須使用 `post_bootstrap` 或 `post_init` 腳本**
3. **這個變更是為了提供更大的靈活性**
4. **腳本只在首次初始化時執行一次**

### 推薦配置

```yaml
bootstrap:
  # 移除 users 配置
  # 使用 post_bootstrap 腳本
  post_bootstrap: /scripts/create_users.sh

  # 或使用 post_init
  # post_init: /scripts/create_users.sh
```

### 檢查清單

- [ ] 確認 Patroni 版本（是否 >= 4.0.0）
- [ ] 移除 `bootstrap.users` 配置
- [ ] 創建用戶創建腳本
- [ ] 確保腳本有執行權限
- [ ] 測試腳本（可以手動執行驗證）
- [ ] 更新 Patroni 配置
- [ ] （如果是新叢集）初始化並驗證
- [ ] （如果是現有叢集）手動創建用戶

需要我提供更詳細的腳本範例或遷移步驟嗎？
