CLUSTER_NAME := local-cluster

.PHONY: start-kind start-cilium start-envoy start-test-app start stop

start: start-kind start-cilium start-envoy start-test-app

start-kind:
	@echo "Creating kind cluster..."
	kind create cluster --name $(CLUSTER_NAME) --config bootstrap/kind/config.yaml

start-cilium:
	@echo "Installing Cilium..."
	helm repo add cilium https://helm.cilium.io/ || true
	helm repo update cilium
	helm upgrade --install cilium cilium/cilium --version 1.18.9 \
		--create-namespace --namespace infra-cilium \
		-f bootstrap/cilium/values.yaml
	@echo "Waiting for Cilium to be ready..."
	kubectl rollout status -n infra-cilium ds/cilium -w

start-envoy:
	@echo "Installing Envoy Gateway..."
	helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
		--version 1.7.2 \
		--create-namespace -n infra-envoy-gateway \
		-f bootstrap/envoy-gateway/values.yaml --wait
	@echo "Applying Gateway API CRDs..."
	kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
	@echo "Applying EnvoyProxy config for NodePort..."
	kubectl apply -f bootstrap/envoy-gateway/envoyproxy.yaml
	@echo "Applying GatewayClass..."
	kubectl apply -f bootstrap/envoy-gateway/gatewayclass.yaml

start-test-app:
	@echo "Deploying nginx test app..."
	kubectl apply -f bootstrap/test-app/namespace.yaml
	@echo "Applying default Gateway in app namespace..."
	kubectl apply -f bootstrap/test-app/gateway.yaml
	kubectl apply -f bootstrap/test-app/policy.yaml
	kubectl apply -f bootstrap/test-app/nginx.yaml

stop:
	@echo "Deleting kind cluster..."
	kind delete cluster --name $(CLUSTER_NAME)
