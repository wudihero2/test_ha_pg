```
docker build -f ./barman.Dockerfile -t barman:test .

kind load docker-image barman:test

kubectl delete -f barman_k8s.yaml
kubectl apply -f barman_k8s.yaml

kubectl apply -f insert_job.yaml

https://www.enterprisedb.com/docs/supported-open-source/barman/single-server-streaming/step04-restore/

1. on_start
2. hba
3. pvc 互換保存等
4. wal_archiver
5. ssh
6. barman receive-wal
```