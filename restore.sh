#!/bin/bash
# Patroni Restore 自動化腳本
# 用途：從 Barman 備份恢復指定的 Patroni pod

set -euo pipefail

# 配置
NAMESPACE="${NAMESPACE:-default}"
PATRONI_STATEFULSET="patronidemo"
BARMAN_STATEFULSET="barman"
TARGET_POD="${1:-patronidemo-0}"  # 要恢復的 pod 名稱

# 從 pod 名稱提取 PVC 名稱
TARGET_PVC="pgdata-${TARGET_POD}"
BARMAN_PVC="pgdata-barman-0"

echo "=========================================="
echo "Patroni Restore from Barman Backup"
echo "=========================================="
echo "Target Pod: $TARGET_POD"
echo "Target PVC: $TARGET_PVC"
echo "Barman PVC: $BARMAN_PVC"
echo "Namespace: $NAMESPACE"
echo "=========================================="
echo ""

# 確認
read -p "Continue with restore? This will STOP the target pod and Barman! (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "[1/7] Deleting target Patroni pod: $TARGET_POD"
kubectl delete pod "$TARGET_POD" -n "$NAMESPACE" --ignore-not-found=true

echo ""
echo "[2/7] Waiting for pod to terminate..."
kubectl wait --for=delete pod/"$TARGET_POD" -n "$NAMESPACE" --timeout=60s || true

echo ""
echo "[3/7] Scaling down Barman to release backup PVC..."
kubectl scale statefulset "$BARMAN_STATEFULSET" --replicas=0 -n "$NAMESPACE"

echo ""
echo "[4/7] Waiting for Barman pod to terminate..."
sleep 5

echo ""
echo "[5/7] Creating restore job..."

# 生成臨時 Job YAML
cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: patroni-restore-$(date +%s)
  labels:
    app: patroni-restore
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 600  # 10分鐘後自動清理
  template:
    metadata:
      labels:
        app: patroni-restore
    spec:
      restartPolicy: Never
      containers:
      - name: restore
        image: postgres:17
        command: ["/bin/bash", "-c"]
        args:
          - |
            set -euo pipefail
            echo "=== Restore Starting ==="
            BARMAN_BASE="/barman-backup/patronidemo/base"
            LATEST_BACKUP=\$(ls -td "\$BARMAN_BASE"/*/ 2>/dev/null | head -1)

            if [[ -z "\$LATEST_BACKUP" ]]; then
              echo "ERROR: No backup found"
              exit 1
            fi

            echo "Using backup: \$LATEST_BACKUP"
            TARGET_DIR="/pgdata/pgroot/data"

            rm -rf "\$TARGET_DIR"/*
            cp -a "\$LATEST_BACKUP/data/." "\$TARGET_DIR/"
            chmod 0700 "\$TARGET_DIR"

            echo "=== Restore Completed ==="
        volumeMounts:
        - name: barman-backup
          mountPath: /barman-backup
          readOnly: true
        - name: target-pgdata
          mountPath: /pgdata
      volumes:
      - name: barman-backup
        persistentVolumeClaim:
          claimName: $BARMAN_PVC
      - name: target-pgdata
        persistentVolumeClaim:
          claimName: $TARGET_PVC
EOF

echo ""
echo "[6/7] Waiting for restore job to complete..."
JOB_NAME=$(kubectl get jobs -n "$NAMESPACE" -l app=patroni-restore --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
echo "Job name: $JOB_NAME"

kubectl wait --for=condition=complete job/"$JOB_NAME" -n "$NAMESPACE" --timeout=30m

echo ""
echo "Restore job logs:"
kubectl logs -n "$NAMESPACE" job/"$JOB_NAME"

echo ""
echo "[7/7] Restoring services..."
echo "Scaling up Barman..."
kubectl scale statefulset "$BARMAN_STATEFULSET" --replicas=1 -n "$NAMESPACE"

echo ""
echo "=========================================="
echo "Restore completed successfully!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Wait for Barman pod to be ready"
echo "2. The target Patroni pod ($TARGET_POD) will be automatically recreated by StatefulSet"
echo "3. Check Patroni cluster status: kubectl exec -it patronidemo-0 -- patronictl list"
echo ""
echo "If you scaled down the StatefulSet, scale it back up:"
echo "  kubectl scale statefulset $PATRONI_STATEFULSET --replicas=N -n $NAMESPACE"
