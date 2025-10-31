```
colima start --cpu 16 --memory 16 --disk 100

kind delete cluster
kind create cluster

helm install my-monitor oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack
helm uninstall my-monitor oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack

docker exec kind-control-plane ctr -n k8s.io images pull docker.io/library/postgres:17

docker build -t patroni:test .

kind load docker-image patroni:test

kubectl delete -f patroni_k8s.yaml
kubectl apply -f patroni_k8s.yaml
