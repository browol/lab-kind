CLUSTER_NAME    := local-cluster
GW_API_VERSION  := v1.5.1
EG_VERSION      := 1.8.0
CILIUM_VERSION  := 1.18.9
CPK_VERSION     := v0.10.0
CPK_IMAGE       := registry.k8s.io/cloud-provider-kind/cloud-controller-manager
NS_CILIUM       := infra-cilium
NS_EG           := infra-envoy-gateway
NS_APP          := app

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9.-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Cluster
.PHONY: start-kind
start-kind: ## Create a local kind cluster.
	kind create cluster --name $(CLUSTER_NAME) --config bootstrap/kind/config.yaml

.PHONY: stop
stop: ## Delete the kind cluster and stop cloud-provider-kind.
	kind delete cluster --name $(CLUSTER_NAME)
	docker rm -f cloud-provider-kind || true
	docker rm -f $$(docker ps -q --filter "name=kindccm") || true

##@ Infrastructure
.PHONY: start-cilium
start-cilium: ## Install Cilium CNI.
	@echo "Installing Cilium $(CILIUM_VERSION)..."
	helm repo add cilium https://helm.cilium.io/ || true
	helm repo update cilium
	helm upgrade --install cilium cilium/cilium --version $(CILIUM_VERSION) \
		--create-namespace --namespace $(NS_CILIUM) \
		-f bootstrap/cilium/values.yaml
	kubectl rollout status -n $(NS_CILIUM) ds/cilium -w

.PHONY: start-cloud-provider
start-cloud-provider: ## Start cloud-provider-kind daemon.
	@echo "Starting cloud-provider-kind $(CPK_VERSION)..."
	docker run -d --name cloud-provider-kind \
		--network kind \
		-v /var/run/docker.sock:/var/run/docker.sock \
		$(CPK_IMAGE):$(CPK_VERSION) \
		--enable-lb-port-mapping --gateway-channel disabled
	sleep 2

##@ Gateway
.PHONY: start-envoy-crds
start-envoy-crds: ## Apply Gateway API and Envoy Gateway CRDs.
	@echo "Applying Gateway API CRDs $(GW_API_VERSION)..."
	helm pull oci://docker.io/envoyproxy/gateway-helm --version $(EG_VERSION) \
		--untar --destination charts/
	kubectl apply --server-side=true \
		-f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GW_API_VERSION)/standard-install.yaml
	kubectl apply --server-side=true \
		-f charts/gateway-helm/charts/crds/crds/generated/
	rm -r charts/
	kubectl wait --for=condition=established --all crd --timeout=60s

.PHONY: start-envoy
start-envoy: start-envoy-crds ## Install Envoy Gateway and apply config.
	@echo "Installing Envoy Gateway $(EG_VERSION)..."
	helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
		--version $(EG_VERSION) \
		--create-namespace -n $(NS_EG) \
		-f bootstrap/envoy-gateway/values.yaml \
		--skip-crds --wait
	kubectl apply -f bootstrap/envoy-gateway/envoyproxy.yaml
	kubectl apply -f bootstrap/envoy-gateway/gatewayclass.yaml

##@ Application
.PHONY: start-test-app
start-test-app: ## Deploy nginx test app, Gateway, HTTPRoute, and network policy.
	@echo "Deploying test app..."
	kubectl apply -f bootstrap/test-app/

##@ Orchestration
.PHONY: start
start: start-kind start-cilium start-cloud-provider start-envoy start-test-app ## Bootstrap the full environment.

##@ Verification
.PHONY: test
test: ## Verify routing by curling nginx through the Gateway.
	@echo "Waiting for Gateway..."
	kubectl wait --for=condition=programmed gateway/default -n $(NS_APP) --timeout=60s
	@CID=$$(docker ps --filter "name=kindccm" --format "{{.ID}}" | head -1); \
	PORT=$$(docker port $$CID 80/tcp | head -1 | sed 's/.*://'); \
	echo "Mapped port: $$PORT"; \
	curl -sf --retry-all-errors --retry 5 --retry-delay 2 --max-time 3 \
		--resolve bookinfo.browol.io:$$PORT:127.0.0.1 http://bookinfo.browol.io:$$PORT \
		&& echo " => OK" \
		|| (echo " => FAILED" && exit 1)
