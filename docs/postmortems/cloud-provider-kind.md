# Post-mortem: cloud-provider-kind Migration Issues

## Issue 1 — RANDOM LoadBalancer flakiness (66% failure rate)

### Summary

`make test` failed intermittently with empty reply / connection reset when curling nginx through the cloud-provider-kind LoadBalancer proxy. The Envoy Gateway-provisioned LoadBalancer service defaulted to `externalTrafficPolicy: Local`, making NodePorts only respond on the single node hosting the Envoy pod. cloud-provider-kind added all 3 cluster nodes to the LB pool with `RANDOM` load balancing — 2 out of 3 endpoints were dead, producing a 66% failure rate. Fixed by patching the EnvoyProxy CR with `externalTrafficPolicy: Cluster`.

### Symptom

```
$ make test
Mapped port: 32770
 => FAILED

$ curl -v --resolve bookinfo.browol.io:32770:127.0.0.1 http://bookinfo.browol.io:32770
* Connected to bookinfo.browol.io (127.0.0.1) port 32770
* Empty reply from server
curl: (52) Empty reply from server
```

From within the kind Docker network, the proxy at `172.18.0.6:80` intermittently returned HTTP 200 or connection reset, depending on which node endpoint was randomly selected.

Envoy admin API (`/clusters?format=json`) showed:
```
172.18.0.3:32590  eds=HEALTHY  active_fail=True
172.18.0.2:32590  eds=HEALTHY  active_fail=True
172.18.0.4:32590  eds=HEALTHY  active_fail=False
```

Envoy cluster stats:
```
cluster.cluster_IPv4_80_TCP.membership_healthy = 1
cluster.cluster_IPv4_80_TCP.membership_total  = 3
cluster.cluster_IPv4_80_TCP.upstream_cx_connect_timeout = 2
cluster.cluster_IPv4_80_TCP.upstream_cx_connect_fail    = 2
```

### Root cause

The Envoy Gateway CR `envoyproxy.yaml` (`bootstrap/envoy-gateway/envoyproxy.yaml`) specified `type: LoadBalancer` without explicit `externalTrafficPolicy`. Envoy Gateway's default for LoadBalancer services is `externalTrafficPolicy: Local` (preserves client source IP). With `Local`, kube-proxy on a node only accepts NodePort traffic if a pod matching the service's selector runs on that node. In a 3-node cluster with 1 Envoy proxy pod (on `worker2`, IP `172.18.0.4`), only the NodePort on that single node responds.

cloud-provider-kind v0.10.0, via its service controller at `pkg/controller/controller.go`, enumerates **all** node IPs as load balancer pool members. The CDS configuration generated for the proxy Envoy (`kindccm-*` container) included all three nodes:
```yaml
endpoints:
  - 172.18.0.2:32590
  - 172.18.0.3:32590
  - 172.18.0.4:32590
```
With `lb_policy: RANDOM`, each new TCP connection randomly selects an endpoint. Two of the three endpoints (`172.18.0.2`, `172.18.0.3`) had no Envoy pod, so their kube-proxy (with `Local` policy) rejected or silently dropped NodePort connections. The active health checks (`http_health_check` at `/healthz`, interval 3s) did detect the failures (`active_fail=True`), but with `unhealthy_threshold: 2`, the EDS health status never transitioned to `UNHEALTHY` — the `RANDOM` policy still picked the dead endpoints.

### Why it produced the symptom

The proxy's LDS config (`listener_IPv4_80_TCP`) listens on `0.0.0.0:80` with a `tcp_proxy` filter forwarding to `cluster_IPv4_80_TCP`. When a dead NodePort endpoint is randomly selected, the TCP connection to the kind node container times out or is refused. The TCP proxy returns an empty response (FIN without data) or connection reset to the downstream client. `curl -f` treats both as failure (exit code 52 or 56).

The symptom appeared flaky because the first `make test` on a fresh cluster sometimes picked the healthy endpoint (`172.18.0.4`) by chance, but subsequent tests or cold-start tests hit dead endpoints 66% of the time.

### Fix

**File:** `bootstrap/envoy-gateway/envoyproxy.yaml`

Added a `StrategicMerge` patch to explicitly set `externalTrafficPolicy: Cluster`:

```yaml
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

With `Cluster` policy, kube-proxy on every node accepts NodePort traffic and forwards it to the Envoy pod via the cluster network. All 3 NodePort endpoints become functional, eliminating the dead-pool problem regardless of pod placement.

### How it was found

1. Reproducer: `make test` failed on fresh cluster, direct curl from host got "Empty reply." Curl from within kind network (`docker run --network kind curlimages/curl`) succeeded on some attempts and failed on others — confirmed network-level issue, not Docker Desktop port mapping.
2. Source trace: Inspected the proxy Envoy's CDS config (`docker exec kindccm-* cat /home/envoy/cds.yaml`) — all 3 node IPs present with `lb_policy: RANDOM`.
3. Envoy admin API at `/clusters?format=json` revealed `active_fail=True` on 2/3 endpoints despite EDS `HEALTHY` status.
4. Envoy stats at `/stats?format=json` confirmed `membership_healthy = 1` out of 3, `upstream_cx_connect_timeout = 2`.
5. Direct NodePort test: `curl 172.18.0.2:32590` (no Envoy pod) → failed. `curl 172.18.0.4:32590` (has Envoy pod) → HTTP 200. Confirmed only worker2's NodePort worked.
6. Hypothesis falsified: Docker Desktop port mapping issue — disproved by successful curl from within kind network.
7. Confirming experiment: Set `externalTrafficPolicy: Cluster` → all 3 NodePorts became responsive → 5/5 consecutive `make test` passes on fresh cluster.

### Why it slipped through

Configuration gap. The EnvoyProxy CR was initially written as a minimal LoadBalancer config:
```yaml
envoyService:
  type: LoadBalancer
```
No prior testing had validated the behavior on multi-node clusters with `externalTrafficPolicy: Local`. The NodePort architecture this project replaced (`type: NodePort` with fixed node ports and kind `extraPortMappings`) hid this entire class of problem — the old setup didn't use LoadBalancer services at all.

### Validation

- `make start` → `make test` → 5/5 consecutive passes on clean cluster.
- All 3 kind node NodePorts verified responsive: `curl 172.18.0.{2,3,4}:32590` all return HTTP 200.
- Envoy admin confirms `active_fail=False` on all 3 endpoints, `membership_healthy = 3`.

### Action items

- None — the fix is sufficient and no class-of-bug follow-up is warranted for this project's scope.

---

## Issue 2 — cloud-provider-kind restart crash on GW API CRD version conflict

### Summary

After deleting the kind cluster and recreating it (`make stop` → `make start`), cloud-provider-kind's container crashed at startup with: `Failed to start cloud controller: Installing CRDs with version before v1.5.0 is prohibited`. CPK v0.10.0 bundles Gateway API CRDs internally and tries to install them on startup; the v1.5.1 CRDs already applied by `make start-envoy-crds` include a validating admission policy (`safe-upgrades.gateway.networking.k8s.io`) that blocks downgrades. Fixed by adding `--gateway-channel disabled` to the CPK container args.

### Symptom

```
$ docker logs cloud-provider-kind
E0524 14:38:38.421687 controller.go:294] "Failed to install Gateway API CRDs"
  err="error processing embedded CRDs from crds/standard:
  failed to create CRD \"backendtlspolicies.gateway.networking.k8s.io\":
  ValidatingAdmissionPolicy 'safe-upgrades.gateway.networking.k8s.io' ...
  denied request: Installing CRDs with version before v1.5.0 is prohibited"
E0524 14:38:38.421714 controller.go:100] "Failed to start cloud controller"
  err="error processing embedded CRDs from crds/standard: ..."
E0524 14:38:38.421796 shared_informer.go:352] "Unable to sync caches"
```

The kindccm proxy container was not recreated after cluster restart because CPK's cloud controller never started.

### Root cause

cloud-provider-kind v0.10.0 has native Gateway API support (enabled by default via `--gateway-channel standard`). On startup, at `pkg/controller/controller.go:294`, it calls an internal function that applies embedded Gateway API CRDs from `crds/standard/`. These bundled CRDs are from a version older than v1.5.1 (likely v1.2.x — the version CPK ships with).

The `make start-envoy-crds` target applies Gateway API CRDs v1.5.1 from upstream, which includes a `ValidatingAdmissionPolicy` named `safe-upgrades.gateway.networking.k8s.io`. This policy blocks the installation of CRDs with a version prior to v1.5.0 as a safeguard against accidental downgrades.

When `make stop` deletes the kind cluster and `make start` recreates it:
1. `start-envoy-crds` installs GW API v1.5.1 CRDs, including the safe-upgrades policy.
2. `start-cloud-provider` starts the CPK container.
3. CPK's `Start cloud controller` function tries to install its own older GW API CRDs.
4. The validating admission policy rejects the downgrade → CPK's controller fails to start → the LB proxy container is never created.

### Why it produced the symptom

The Envoy LB service (`envoy-app-default-*`) was created correctly (LoadBalancer type with external IP assigned from a previous CPK session), but CPK couldn't watch the service because its controller never started — the CRD installation failure aborted the entire cloud controller initialization. No proxy container was created, so `docker ps --filter "name=kindccm"` returned empty, and `make test` failed with "No kindccm container found" (or hung waiting for the Gateway).

### Fix

**File:** `Makefile`, target `start-cloud-provider`

Added `--gateway-channel disabled` to the CPK container run arguments:

```makefile
docker run -d --name cloud-provider-kind \
    --network kind \
    -v /var/run/docker.sock:/var/run/docker.sock \
    $(CPK_IMAGE):$(CPK_VERSION) \
    --enable-lb-port-mapping --gateway-channel disabled
```

This disables CPK's native Gateway API controller entirely. Since this project uses Envoy Gateway (`gateway.envoyproxy.io/gatewayclass-controller`) for Gateway API, CPK's Gateway API support is redundant and its bundled CRD installation is unnecessary and harmful.

### How it was found

1. Reproducer: `make stop` → `make start` → `make test` failed. `docker ps --filter "name=kindccm"` returned no containers.
2. Source trace: `docker logs cloud-provider-kind` showed the CRD installation error at `controller.go:294` and `controller.go:100`.
3. Hypothesis: CPK version incompatibility. Tested by deleting the `safe-upgrades` policy manually — CPK started successfully. Confirmed CPK's bundled CRDs are older.
4. Simpler fix: Disable CPK's Gateway API support with `--gateway-channel disabled` — CRD installation skipped, controller starts normally.

### Why it slipped through

Inter-component conflict. CPK v0.10.0 was tested with its own bundled GW API CRDs (older version). The project separately installs GW API v1.5.1 for Envoy Gateway compatibility. The `safe-upgrades` policy (added in v1.5.0) creates a hard incompatibility that neither component documents. The issue only manifests on **restart** — the initial bootstrap (fresh cluster) succeeds because CPK installs its CRDs first (no conflict), then `make start-envoy-crds` applies v1.5.1 on top (upgrade, which is allowed). On restart, CPK tries to install its older CRDs over v1.5.1 (downgrade, blocked).

### Validation

- `make stop` → `make start` → `make test` passes. CPK container starts cleanly, controller initializes, kindccm proxy container created.
- Verified on two full teardown/rebuild cycles.
- CPK logs show no CRD-related errors with `--gateway-channel disabled`: `"Starting cloud controller" cluster="local-cluster"`.

### Action items

- None for this project. CPK upstream issue: CPK should detect existing CRDs and skip installation, or upgrade its bundled CRDs to match the cluster's version.

---

## Issue 3 — Race condition: Gateway "programmed" before proxy health checks stabilize

### Summary

`make test` failed on the first attempt after a cold `make start`, but passed on subsequent manual retries. The `kubectl wait --for=condition=programmed` on the Gateway only guarantees that Envoy Gateway has configured the Envoy proxy — it does not guarantee that cloud-provider-kind's proxy Envoy health checks have marked all LoadBalancer pool endpoints as healthy. Curling too early could hit an endpoint whose health check hasn't passed yet. Fixed by adding `--retry-all-errors --retry 5 --retry-delay 2` to the curl in `make test`.

### Symptom

```
$ make test  (immediately after make start)
Waiting for Gateway...
gateway.gateway.networking.k8s.io/default condition met
Mapped port: 32778
 => FAILED

$ make test  (10 seconds later)
 => OK
```

Envoy stats at failure time showed:
```
cluster.cluster_IPv4_80_TCP.health_check.failure = 407
cluster.cluster_IPv4_80_TCP.health_check.success = 193
```

The proxy's health checks had a ~32% success rate, meaning endpoints were still transitioning. Several seconds later, all endpoints became healthy.

### Root cause

The `make test` recipe has two sequential steps:
1. `kubectl wait --for=condition=programmed gateway/default` — blocks until Envoy Gateway's controller creates the Envoy proxy deployment and service. Condition met typically within 15-30s after `make start-test-app`.
2. `curl` via cloud-provider-kind's proxy container — fires immediately after step 1.

The gap between these two steps: cloud-provider-kind's service controller creates the proxy container and writes the initial CDS/LDS config, but its active health checks (HTTP `/healthz`, interval 3s, timeout 5s) need multiple cycles to mark all endpoints healthy. With `externalTrafficPolicy: Cluster` (from fix #1) all 3 NodePorts work, but the health checks still need time to pass at least once per endpoint (health check startup can take 6-12s). The `RANDOM` LB policy doesn't distinguish between a pending and a healthy endpoint during this window.

### Why it produced the symptom

The curl request triggered before health checks stabilized. If the RANDOM selector picked a not-yet-health-checked endpoint, the TCP proxy connection to that endpoint timed out (health check hadn't confirmed reachability yet, or the connection hit a stale cached state). `curl -f` returns non-zero on empty reply or timeout.

### Fix

**File:** `Makefile`, target `test`

Added retry flags to curl:

```makefile
curl -sf --retry-all-errors --retry 5 --retry-delay 2 --max-time 3 \
    --resolve bookinfo.browol.io:$$PORT:127.0.0.1 http://bookinfo.browol.io:$$PORT
```

`--retry-all-errors` makes curl retry on any error (not just 5xx), including empty reply or connection reset. With 5 retries at 2s intervals and 3s per-request timeout, the total retry window is ~25s — enough to cover the health check stabilization period. The retry is transparent: once all endpoints are healthy, curl succeeds.

### How it was found

1. Symptom: `make test` failed on fresh cluster, then passed when re-run 10s later.
2. Source trace: Envoy stats at `/stats?format=json` showed `health_check.failure = 407, health_check.success = 193` — health checks still stabilizing.
3. Hypothesis: The Gateway "programmed" condition arrives too early. Confirmed by adding a 15s sleep after `kubectl wait` → test passed. This proved the fix should be a wait or retry, not a config change.
4. Rejected alternative: querying envoy admin API for `membership_healthy` count. Too complex vs. simple curl retry.
5. Confirming experiment: `make stop` → `make start` → immediate `make test` passes with retry flags.

### Why it slipped through

Timing gap not exercised in initial testing. The first implementation tests were run manually with built-in delays (debugging between steps), masking the race condition. The port discovery through `docker port` added no artificial delay, exposing the timing gap on the user's first cold `make test`.

### Validation

- `make stop` → `make start` → immediate `make test` passes (tested on 2 cold builds).
- 5 consecutive `make test` runs on fresh cluster: 5/5 passes.
- No impact on normal operation: curl exits immediately on success; retries only activate on failure.

### Action items

- None — the fix is sufficient for this project's scope. For a production setup, the proper fix would be a readiness probe on the kindccm proxy container or waiting for `membership_healthy == membership_total` via the envoy admin API.
