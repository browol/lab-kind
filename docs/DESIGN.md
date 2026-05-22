# Bootstrap Setup Design & Testing Plan

## Architecture Overview

The `bootstrap` directory contains configuration for a local Kubernetes environment based on `kind` (Kubernetes IN Docker). It establishes the core infrastructure, networking, and a sample application to validate the setup.

### Components

1. **Kubernetes Cluster (`kind`)**:
   - 1 Control Plane, 1 Worker Node.
   - Default CNI disabled (to allow Cilium installation).
   - Host ports 80 and 443 are mapped to NodePorts 30080 and 30443 respectively.

2. **Networking (`cilium`)**:
   - Deployed via Helm into the `infra-cilium` namespace.
   - Provides CNI and Network Policy enforcement.

3. **Ingress / API Gateway (`envoy-gateway`)**:
   - Implements the Kubernetes Gateway API.
   - Deployed via Helm into `infra-envoy-gateway`.
   - Uses an `EnvoyProxy` configuration to expose Envoy as a `NodePort` service (30080 for HTTP, 30443 for HTTPS) which maps back to the host ports via `kind`.

4. **Test Application (`test-app`)**:
   - Deploys an unprivileged `nginx` pod in the `app` namespace.
   - Exposes a `Gateway` (listening on port 80) and an `HTTPRoute` for path `/`.
   - Secured by a `CiliumNetworkPolicy` (`default-deny-all`) that only allows ingress traffic on port 8080 if it originates from Envoy Gateway pods in `infra-envoy-gateway`.

## Testing Plan

To ensure the bootstrap setup works correctly, the following tests should be executed:

1. **Cluster Provisioning Verification**:
   - `kubectl get nodes`: Ensure control-plane and worker nodes are `Ready`.
   - `kubectl get pods -n infra-cilium`: Ensure Cilium daemonset is running and ready.

2. **Gateway API Verification**:
   - `kubectl get gatewayclass`: Ensure `envoy` GatewayClass is accepted.
   - `kubectl get gateway -n app`: Ensure the `default` gateway has an assigned IP/status.
   - `kubectl get pods -n infra-envoy-gateway`: Ensure Envoy Gateway controller and Envoy proxy instances are running.

3. **Application Routing & Network Policy Verification**:
   - **External Access**: 
     - Run `curl -i http://localhost:80`. It should return a `200 OK` from nginx. This validates the host port mapping -> NodePort -> Envoy Proxy -> HTTPRoute -> nginx pod.
   - **Network Policy (Isolation)**:
     - Run a temporary pod in the `default` namespace and attempt to curl the nginx pod IP directly on port 8080. It should **timeout/fail** because the `CiliumNetworkPolicy` only allows traffic from Envoy.
     - E.g., `kubectl run test --image=curlimages/curl --restart=Never -- sleep 3600`
     - `kubectl exec test -- curl -v --max-time 5 http://<nginx-pod-ip>:8080` (should fail).