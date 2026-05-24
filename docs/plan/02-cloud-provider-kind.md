# cloud-provider-kind Migration

## Goal

Replace the NodePort-based ingress (host port-mapping via kind `extraPortMappings`) with `cloud-provider-kind`, which assigns real LoadBalancer IPs to services and manages port forwarding through Docker proxy containers.

## Architecture Change

```
Before (NodePort):
  localhost:80 → kind extraPortMappings → NodePort 30080 → Envoy → HTTPRoute → nginx

After (LoadBalancer with cloud-provider-kind):
  localhost:{ephemeral} → kindccm proxy container → Envoy LoadBalancer Svc → HTTPRoute → nginx
```

## Tasks

### 1. Remove `bootstrap/metallb/` (empty, unused) — DONE

Deleted the untracked empty directory.

### 2. Update `bootstrap/kind/config.yaml` — DONE

Removed `extraPortMappings`. Added second worker node.

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: local-cluster
networking:
  disableDefaultCNI: true
nodes:
- role: control-plane
- role: worker
- role: worker
```

### 3. Update `bootstrap/envoy-gateway/envoyproxy.yaml` — DONE

`type: LoadBalancer` with `externalTrafficPolicy: Cluster` patch. The `Cluster` policy is critical: `Local` (Envoy Gateway's default) would make NodePort only work on the node hosting the Envoy pod, causing cloud-provider-kind's multi-node LB pool to have mostly dead endpoints. See Edge Cases.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: default-proxy-config
  namespace: infra-envoy-gateway
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: LoadBalancer
        patch:
          type: StrategicMerge
          value:
            spec:
              externalTrafficPolicy: Cluster
```

### 4. Rename test-app files for directory apply ordering — DONE

| Before | After |
|--------|-------|
| `namespace.yaml` | `00-namespace.yaml` |
| `gateway.yaml` | `01-gateway.yaml` |
| `policy.yaml` | `02-policy.yaml` |
| `nginx.yaml` | `03-nginx.yaml` |

### 5. Rewrite `Makefile` — DONE

Full replacement with variables, `##@` grouping, split `start-envoy-crds`/`start-envoy`, directory apply for test-app.

**Key design decisions discovered during implementation:**

- **Container approach (no sudo)**: On macOS, the `cloud-provider-kind` binary requires sudo regardless of `--enable-lb-port-mapping`. Solved by running the official container image via Docker (`docker run -d --network kind -v /var/run/docker.sock:/var/run/docker.sock`). No sudo needed.
- **`--force-conflicts` on GW API CRDs**: cloud-provider-kind v0.10.0 bundles and manages its own copy of the Gateway API CRDs (for its native Gateway API support). The `kubectl apply --server-side=true` of the upstream GW API CRDs needs `--force-conflicts` to take field ownership.
- **kindccm proxy container cleanup in `stop`**: `kind delete cluster` doesn't remove the proxy containers created by cloud-provider-kind. Added `docker rm -f $(docker ps -q --filter "name=kindccm")` to the `stop` target.

### 6. Update `AGENTS.md` project structure — DONE

Reflect renamed test-app file names.

### 7. Update `docs/plan/01-bootstrap.md` — DONE

Replaced NodePort architecture with LoadBalancer + cloud-provider-kind. Updated node count to 2 workers. Updated testing section.

### 8. Final Makefile

```makefile
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
	kubectl apply --server-side=true --force-conflicts \
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
	curl -sf --resolve bookinfo.browol.io:$$PORT:127.0.0.1 http://bookinfo.browol.io:$$PORT \
		&& echo " => OK" \
		|| (echo " => FAILED" && exit 1)
```

## Edge Cases Encountered

| Scenario | Handling |
|----------|----------|
| Binary requires sudo on macOS | Switched to container approach (`docker run`) — no sudo needed |
| cloud-provider-kind v0.10.0 bundles GW API CRDs | Added `--force-conflicts` to upstream GW API CRD apply |
| Orphaned `kindccm-*` proxy containers after stop | Added cleanup in `stop`: `docker rm -f $(docker ps -q --filter "name=kindccm")` |

| `helm pull --untar` fails if `charts/` already exists | `rm -r charts/` after CRD extraction + `start-envoy` depends on `start-envoy-crds` which always cleans up first || **`externalTrafficPolicy: Local` + multi-node = flaky RANDOM LB** | Envoy Gateway defaults the LB service to `Local` for client IP preservation. With 3 nodes and only 1 hosting the Envoy pod, 2/3 NodePorts are dead. cloud-provider-kind adds all 3 nodes to the LB pool with `RANDOM` policy → 66% failure rate. **Fix:** EnvoyProxy patch sets `externalTrafficPolicy: Cluster` so all node NodePorts work. |
| **CPK restart crashes on GW API CRD downgrade** | CPK v0.10.0 bundles GW API CRDs older than v1.5.1. Our v1.5.1 `safe-upgrades` validating admission policy blocks the downgrade on CPK restart, causing CPK's cloud controller to fail to start. **Fix:** `--gateway-channel disabled` flag on CPK container — we use Envoy Gateway's Gateway API, not CPK's. |
| **Docker Desktop macOS port mapping can stale** | After proxy container recreation, host port forwarding sometimes stops working (Docker Desktop / vpnkit known issue). Restarting the proxy container (via CPK restart) fixes it. |

## Verification Results

```
make start-kind            — 3 nodes (1 CP + 2 workers) created, no port bindings
make start-cilium          — All nodes Ready, 3/3 cilium pods running
make start-cloud-provider  — CPK container running, --gateway-channel disabled
make start-envoy-crds      — All CRDs established (--force-conflicts for GW API)
make start-envoy           — EG installed, envoy-proxy LB service with externalTrafficPolicy: Cluster
make start-test-app        — All 6 resources created via directory apply
make test                  — 5/5 consecutive passes (HTTP 200 from nginx)
make stop                  — Cluster deleted, all CPK + kindccm containers removed
```
```
