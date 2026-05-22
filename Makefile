CLUSTER_NAME := local-cluster

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: start
start: start-kind start-cilium start-envoy start-test-app ## Start the entire environment: kind cluster, Cilium, Envoy Gateway, and test app.

.PHONY: start-kind
start-kind: ## Start a local Kubernetes cluster using kind.
	@echo "Creating kind cluster..."
	kind create cluster --name $(CLUSTER_NAME) --config bootstrap/kind/config.yaml

.PHONY: start-cilium
start-cilium: ## Install Cilium CNI in the kind cluster.
	@echo "Installing Cilium..."
	helm repo add cilium https://helm.cilium.io/ || true
	helm repo update cilium
	helm upgrade --install cilium cilium/cilium --version 1.18.9 \
		--create-namespace --namespace infra-cilium \
		-f bootstrap/cilium/values.yaml
	@echo "Waiting for Cilium to be ready..."
	kubectl rollout status -n infra-cilium ds/cilium -w

.PHONY: start-envoy
start-envoy: ## Install Envoy Gateway in the kind cluster.
	@echo "Pulling EG chart to extract CRDs..."
	helm pull oci://docker.io/envoyproxy/gateway-helm --version 1.8.0 \
		--untar --destination charts/ || echo "Chart already exists, skipping pull."
	@echo "Applying Gateway API CRDs..."
	kubectl apply --server-side=true \
		-f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
	@echo "Applying Envoy Gateway CRDs..."
	kubectl apply --server-side=true \
		-f charts/gateway-helm/charts/crds/crds/generated/
	@echo "Waiting for CRDs to be established..."
	kubectl wait --for=condition=established --all crd --timeout=60s
	@echo "Cleaning up chart files..."
	rm -r charts/
	@echo "Installing Envoy Gateway..."
	helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
		--version 1.8.0 \
		--create-namespace -n infra-envoy-gateway \
		-f bootstrap/envoy-gateway/values.yaml \
		--skip-crds \
		--wait
	@echo "Applying EnvoyProxy config for NodePort..."
	kubectl apply -f bootstrap/envoy-gateway/envoyproxy.yaml
	@echo "Applying GatewayClass..."
	kubectl apply -f bootstrap/envoy-gateway/gatewayclass.yaml

.PHONY: start-test-app
start-test-app: ## Deploy a simple nginx test application in the cluster.
	@echo "Deploying nginx test app..."
	kubectl apply -f bootstrap/test-app/namespace.yaml
	@echo "Applying default Gateway in app namespace..."
	kubectl apply -f bootstrap/test-app/gateway.yaml
	kubectl apply -f bootstrap/test-app/policy.yaml
	kubectl apply -f bootstrap/test-app/nginx.yaml

.PHONY: stop
stop: ## Stop the entire environment by deleting the kind cluster.
	@echo "Deleting kind cluster..."
	kind delete cluster --name $(CLUSTER_NAME)
