# Bootstrap Setup Design & Testing Plan

## Architecture Overview

The `bootstrap` directory contains configuration for a local Kubernetes environment based on `kind` (Kubernetes IN Docker). It establishes the core infrastructure, networking, and a sample application to validate the setup.

### Components

1. **Kubernetes Cluster (`kind`)**:
   - 1 Control Plane, 2 Worker Nodes.
   - Default CNI disabled (to allow Cilium installation).
   - Uses `cloud-provider-kind` for LoadBalancer services instead of NodePort + host port-mappings.

2. **Networking (`cilium`)**:
   - Deployed via Helm into the `infra-cilium` namespace.
   - Provides CNI and Network Policy enforcement.

3. **LoadBalancer (`cloud-provider-kind`)**:
   - Host-side daemon that assigns external IPs to LoadBalancer services and creates proxy containers for port forwarding.
   - Runs with `--enable-lb-port-mapping` so services are accessible via `localhost:{ephemeral-port}` on macOS.
   - Replaces the previous NodePort + kind `extraPortMappings` approach.

4. **Ingress / API Gateway (`envoy-gateway`)**:
   - Implements the Kubernetes Gateway API.
   - Deployed via Helm into `infra-envoy-gateway`.
   - Uses an `EnvoyProxy` configuration to expose Envoy as a `LoadBalancer` service. cloud-provider-kind assigns it an external IP and maps ports to the host.

5. **Test Application (`test-app`)**:
   - Deploys an unprivileged `nginx` pod in the `app` namespace.
   - Exposes a `Gateway` (listening on port 80) and an `HTTPRoute` for path `/` with hostname `bookinfo.browol.io`.
   - Secured by a `CiliumNetworkPolicy` (`default-deny-all`) that only allows ingress traffic on port 8080 if it originates from Envoy Gateway pods in `infra-envoy-gateway`.

## Testing Plan

To ensure the bootstrap setup works correctly, the following tests should be executed:

1. **Cluster Provisioning Verification**:
   - `kubectl get nodes`: Ensure 1 control-plane and 2 worker nodes are `Ready`.
   - `kubectl get pods -n infra-cilium`: Ensure Cilium daemonset is running and ready.

2. **Cloud Provider Verification**:
   - Ensure `cloud-provider-kind` process is running on the host.
   - `kubectl get svc -n infra-envoy-gateway`: Envoy proxy service should have an `EXTERNAL-IP` assigned.

3. **Gateway API Verification**:
   - `kubectl get gatewayclass`: Ensure `envoy` GatewayClass is accepted.
   - `kubectl get gateway -n app`: Ensure the `default` gateway is programmed with an assigned address.
   - `kubectl get pods -n infra-envoy-gateway`: Ensure Envoy Gateway controller and Envoy proxy instances are running.

4. **Application Routing & Network Policy Verification**:
   - **External Access**:
     - Run `make test` or manually: `kubectl wait gateway/default -n app --for=condition=programmed`, then discover the mapped port via `docker port $(docker ps --filter "name=kindccm" -q | head -1) 80/tcp` and curl with `--resolve bookinfo.browol.io:{PORT}:127.0.0.1`. Should return `200 OK` from nginx.
   - **Network Policy (Isolation)**:
     - Run a temporary pod in the `default` namespace and attempt to curl the nginx pod IP directly on port 8080. It should **timeout/fail** because the `CiliumNetworkPolicy` only allows traffic from Envoy.
     - E.g., `kubectl run test --image=curlimages/curl --restart=Never -- sleep 3600`
     - `kubectl exec test -- curl -v --max-time 5 http://<nginx-pod-ip>:8080` (should fail).
