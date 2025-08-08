
install-kind:
	go install sigs.k8s.io/kind@v0.13.0

start-kind:
	./hack/run-in-kind.sh

stop-kind:
	kind delete cluster --name cluster-hub
	kind delete cluster --name cluster-1
	kind delete cluster --name cluster-2

update-lock:
	find . -name Chart.lock | xargs dirname | xargs -n 1 helm dep update

update-kind-preload:
	KUBECONFIG=~/.kube/cluster-hub \
	oc get pod -A -o json \
      | jq -r '.items[].spec.containers[].image' \
      | grep -v docker.io/kindest \
      | grep -v -e "registry.k8s.io/kube-" -e "registry.k8s.io/coredns" -e "registry.k8s.io/etcd" \
      | grep -v -e "registry.k8s.io/ingress-nginx/controller" \
      | grep -v -e "ghcr.io/stakater/reloader" \
      | sort \
      | uniq \
      > ./hack/preload-cluster-hub.txt
	KUBECONFIG=~/.kube/cluster-1 \
	oc get pod -A -o json \
      | jq -r '.items[].spec.containers[].image' \
      | grep -v docker.io/kindest \
      | grep -v -e "registry.k8s.io/kube-" -e "registry.k8s.io/coredns" -e "registry.k8s.io/etcd" \
      | grep -v -e "registry.k8s.io/ingress-nginx/controller" \
      | grep -v -e "ghcr.io/stakater/reloader" \
      | sort \
      | uniq \
      > ./hack/preload-cluster-1.txt
	KUBECONFIG=~/.kube/cluster-2 \
	oc get pod -A -o json \
      | jq -r '.items[].spec.containers[].image' \
      | grep -v docker.io/kindest \
      | grep -v -e "registry.k8s.io/kube-" -e "registry.k8s.io/coredns" -e "registry.k8s.io/etcd" \
      | grep -v -e "registry.k8s.io/ingress-nginx/controller" \
      | grep -v -e "ghcr.io/stakater/reloader" \
      | sort \
      | uniq \
      > ./hack/preload-cluster-2.txt
