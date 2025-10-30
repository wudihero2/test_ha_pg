```
# monitor pg
https://github.com/pgsty/pg_exporter/blob/main/config/0110-pg.yml
https://erhwenkuo.github.io/prometheus/postgres-exporter/postgres-exporter-integration/#dashboards-configmaps-gitops


# 使用 Helm 本地安裝 Apache Airflow 指南
```
# 0) 一次確認環境
helm version
kubectl version --client

# 1) 加 repo & 更新索引（只需一次）
helm repo add apache-airflow https://airflow.apache.org
helm repo update

# 2) 準備命名空間
export NAMESPACE=example-namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 3) 把 chart 拉到本地（解壓成目錄）
#    可指定版本：--version 1.15.0（舉例）
mkdir -p charts
helm pull apache-airflow/airflow --untar --untardir charts
# 會得到 ./charts/airflow/ 這個本地 chart 目錄

# 4)（可選）鎖定/下載子 chart 相依
#    進到 chart 目錄，依 Chart.yaml 把依賴抓到 ./charts 子資料夾
cd charts/airflow
helm dependency update
cd -  # 回到原目錄

# 5) 檢查/覆蓋 values（可先看看有哪些 key）
helm show values ./charts/airflow | less

# 6) 安裝本地 chart（用你的 airflow.yaml 覆蓋）
export RELEASE_NAME=example-release
helm install "$RELEASE_NAME" ./charts/airflow \
  --values "$(pwd)/airflow.yaml"

kubectl port-forward svc/$RELEASE_NAME-api-server 8080:8080
```


```
psql -h 127.0.0.1 -p 5432 -U postgres -d postgres
```


```
https://github.com/patroni/patroni/issues/3459
https://github.com/patroni/patroni/blob/master/postgres0.yml
```