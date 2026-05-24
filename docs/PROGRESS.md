## 2026-05-24 — Fix flaky `make test`: externalTrafficPolicy + CPK gateway channel

**Status:** `make test` now passes 5/5 consecutive runs. Two root causes identified and fixed.

**Done:**
- **Bug 1: `externalTrafficPolicy: Local` causes RANDOM LB flakiness.** Envoy Gateway defaults the LB service to `Local` for client IP preservation. With 3 nodes and only 1 hosting the Envoy pod, 2/3 NodePorts are dead. cloud-provider-kind adds all 3 nodes to the LB pool with `RANDOM` policy → 66% of connections hit dead nodes. **Fix:** Added `externalTrafficPolicy: Cluster` patch to `bootstrap/envoy-gateway/envoyproxy.yaml`.
- **Bug 2: CPK restart crashes on GW API CRD version conflict.** CPK v0.10.0 bundles older Gateway API CRDs that conflict with our v1.5.1 installation (the v1.5.1 `safe-upgrades` validating admission policy blocks downgrade). On CPK restart, this causes: `Failed to start cloud controller: Installing CRDs with version before v1.5.0 is prohibited`. **Fix:** Added `--gateway-channel disabled` flag to CPK container — we use Envoy Gateway for Gateway API, not CPK's built-in implementation.
- Updated `Makefile`: `start-cloud-provider` includes `--gateway-channel disabled`.
- Ran 5x consecutive `make test` — all passed.
- Full fresh bootstrap from scratch (`make start` → `make test` → `make stop`) verified.

**Next:**
- None.

**Blockers:** None

**Open questions:** None

---

## 2026-05-24 — cloud-provider-kind Migration (NodePort → LoadBalancer)

**Status:** Full migration implemented and verified. Architecture now uses cloud-provider-kind (container-based, no sudo) for LoadBalancer services instead of NodePort + kind `extraPortMappings`.

**Done:**
- Removed empty `bootstrap/metallb/` directory.
- Updated `bootstrap/kind/config.yaml`: removed `extraPortMappings`, added second worker node.
- Simplified `bootstrap/envoy-gateway/envoyproxy.yaml`: `type: LoadBalancer`, no NodePort patch.
- Renamed `bootstrap/test-app/` files with numeric prefixes (`00-namespace.yaml`, `01-gateway.yaml`, `02-policy.yaml`, `03-nginx.yaml`) to support `kubectl apply -f bootstrap/test-app/` directory apply.
- Rewrote `Makefile`:
  - All versions/namespaces as variables (`CPK_VERSION`, `CPK_IMAGE`, etc.).
  - `##@` headers for visual grouping (Cluster, Infrastructure, Gateway, Application, Orchestration, Verification).
  - Split `start-envoy` into `start-envoy-crds` + `start-envoy` (each ~5 lines).
  - `start-cloud-provider` uses Docker container approach (`docker run -d --network kind -v /var/run/docker.sock`), not host binary — avoids sudo requirement on macOS.
  - `--force-conflicts` on GW API CRD apply (cloud-provider-kind v0.10.0 bundles its own GW API CRDs).
  - New `test` target: auto-discovers ephemeral port via `docker port`, curls with `--resolve`.
  - `stop` cleanly removes cluster + CPK container + `kindccm-*` proxy containers.
- Updated `AGENTS.md` project structure tree.
- Updated `docs/plan/01-bootstrap.md`: replaced NodePort with LoadBalancer + cloud-provider-kind, 2 workers, updated testing.
- End-to-end verification:
  - `make start-kind` — 3 nodes, no port bindings.
  - `make start-cilium` — All Ready, 3/3 cilium pods.
  - `make start-cloud-provider` — Container running, no sudo.
  - `make start-envoy` — Envoy proxy as LoadBalancer, external IP assigned (172.18.0.6).
  - `make start-test-app` — All resources created via directory apply.
  - `make test` — HTTP 200 from nginx through full LB + Gateway + HTTPRoute chain.
  - `make stop` — All containers removed, no remnants.

**Next:**
- None — plan complete.

**Blockers:** None

**Open questions:** None

---

## 2026-05-22 — Add bookinfo.browol.io hostname to HTTPRoute

**Status:** Added `bookinfo.browol.io` hostname filter to the nginx HTTPRoute.

**Done:**
- Added `hostnames: [bookinfo.browol.io]` to the `nginx-route` HTTPRoute in `bootstrap/test-app/nginx.yaml`.
- The Gateway only routes requests with `Host: bookinfo.browol.io` to the nginx backend. All other hostnames will return 404 from Envoy.
- To test locally: add `127.0.0.1 bookinfo.browol.io` to `/etc/hosts`, then `curl -i http://bookinfo.browol.io`.

**Next:**
- Apply change to cluster: `kubectl apply -f bootstrap/test-app/nginx.yaml`
- Verify: `curl -i http://bookinfo.browol.io` should return 200.

**Blockers:** None

**Open questions:** None

---

## 2026-05-22 — Implement Option B: kubectl owns all CRDs

**Status:** Implemented clean CRD ownership — kubectl applies all CRDs, Helm skips them.

**Done:**
- Replaced `--force-conflicts` approach with Option B: single owner for all CRDs.
- `start-envoy` now:
  1. `helm pull` the EG chart to `/tmp/eg-chart` to extract EG-specific CRDs locally.
  2. `kubectl apply --server-side=true` GW API CRDs from upstream (`v1.5.1`).
  3. `kubectl apply --server-side=true` EG-specific CRDs from `/tmp/eg-chart/gateway-helm/charts/crds/crds/generated/`.
  4. `kubectl wait --for=condition=established --all crd` to confirm readiness.
  5. `helm upgrade --install --skip-crds` — Helm installs the release only, CRDs already handled.
- No `--force-conflicts` needed because `kubectl` is the sole field manager for all CRDs. No two tools apply the same resource.

**Next:**
- Run `make start-envoy` to verify end-to-end.

**Blockers:** None

**Open questions:** None

---

## 2026-05-22 — Implement --force-conflicts for idempotent CRD install

**Status:** Implemented SSA `--force-conflicts` approach for robust GW API CRD handling.

**Done:**
- Investigated EG Helm chart v1.8.0 structure. All CRDs (GW API + EG-specific) are packaged in a `crds` sub-chart (`charts/crds/`). The sub-chart has **no `condition` field** in `Chart.yaml`, so there is no values flag to skip only the GW API CRDs (Option 3 as discussed is not available for this chart).
- Implemented the `--force-conflicts` approach (equivalent to Option 1) instead:
  - `kubectl apply --server-side=true --force-conflicts` for GW API CRDs: forcefully takes/keeps field ownership on every run regardless of which manager previously owned those fields.
  - `helm upgrade --install --server-side=true --force-conflicts`: Helm 4 forcefully takes ownership of all fields (including CRD fields) on install/upgrade, resolving any field manager conflicts.
- Both sides using `--force-conflicts` makes the step fully idempotent: safe on fresh install, re-runs, and cluster restarts.

**Next:**
- Run `make start-envoy` to verify end-to-end.

**Blockers:** None

**Open questions:** None

---

## 2026-05-22 — Fix EnvoyProxy CRD not found after --skip-crds

**Status:** Fixed second error in `start-envoy` — `EnvoyProxy` CRD missing after install.

**Done:**
- Previous fix added `--skip-crds` to the helm command. This was too aggressive: it skipped not only the Gateway API CRDs (which caused the SSA conflict) but also Envoy Gateway's own CRDs (e.g. `EnvoyProxy`, `gateway.envoyproxy.io/v1alpha1`), causing `kubectl apply -f envoyproxy.yaml` to fail.
- Correct fix: removed the manual `kubectl apply --server-side=true` Gateway API CRD step and the `kubectl wait --for=condition=established` step entirely. The Envoy Gateway Helm chart v1.8.0 already bundles the compatible Gateway API CRDs and all its own CRDs. Helm's `--wait` flag ensures everything is ready before proceeding.
- Removed `--skip-crds` from the helm command.

**Next:**
- Run `make start-envoy` to verify end-to-end.

**Blockers:** None

**Open questions:** None

---

## 2026-05-22 — Fix start-envoy CRD conflict

**Status:** Fixed Server-Side Apply conflict in `start-envoy` Makefile target.

**Done:**
- Diagnosed root cause: `kubectl apply --server-side=true` in `start-envoy` installs Gateway API CRDs with field manager `kubectl`. The Envoy Gateway Helm chart (v1.8.0) also bundles Gateway API CRDs and tries to re-apply them with Helm's own field manager, causing SSA conflicts on `.metadata.annotations.gateway.networking.k8s.io/channel` and `.spec.versions`.
- Fixed by adding `--skip-crds` to the `helm upgrade --install eg ...` command in `Makefile`. This tells Helm to skip its bundled CRDs (already installed manually) and avoids the double-apply conflict.

**Next:**
- Run `make start-envoy` to verify the fix end-to-end.
- Run full `make start` if cluster isn't already up.

**Blockers:** None

**Open questions:** None

---

## 2026-05-22 — Regress bootstrap and write testing plan

**Status:** Completed initial architecture analysis and documented testing plan in DESIGN.md.

**Done:**
- Analyzed `Makefile` and `bootstrap` directory (kind, cilium, envoy-gateway, test-app).
- Reverse-engineered architecture: kind maps host 80/443 to NodePort 30080/30443, Envoy NodePort picks it up, HTTPRoute sends to nginx, CiliumNetworkPolicy restricts ingress to Envoy only.
- Wrote architecture overview and testing plan into `docs/DESIGN.md`.

**Next:**
- Wait for user feedback or proceed with testing execution if requested.

**Blockers:** None

**Open questions:** None