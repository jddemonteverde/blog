# Giving Traefik a Fixed Tailnet Address with the Tailscale Kubernetes Operator

*October 4, 2026*

My apps should be reachable from any of my devices over Tailscale, no matter which node Traefik happens to run on. The Tailscale Kubernetes operator does this by putting Traefik on my tailnet as a Tailscale Service with its own fixed address.

Every app behind Traefik then shares that one address. TLS still ends at Traefik, so the operator's proxies only ever forward encrypted traffic.

Placeholders: `<oauth-client-id>` comes from the admin console, and the OAuth secret is typed at a prompt. `<service-ip>` is the address the Service gets.

## How it works

```text
my device ──tailnet──► <service-ip>  (svc:lab)
                          │  advertised by 2 proxy pods, tagged tag:k8s
                          ▼
                     Traefik's ClusterIP, ports 80 and 443
```

- **A ProxyGroup** runs two proxy pods. Each joins the tailnet as a device tagged `tag:k8s`.
- **A Tailscale Service, `svc:lab`,** is advertised by those proxies. Its address, the TailVIP, belongs to the service rather than to a pod, so it survives proxy restarts. That's what lets a DNS record point at it permanently.
- **Traffic to the TailVIP** is forwarded to Traefik's ClusterIP at layer 3. The proxies never terminate TLS.

The Tailscale I already run on the node itself stays as it is, for SSH only. See [`../../homelab-security/tailscale/`](../../homelab-security/tailscale/).

## The tailnet policy

These entries go into the policy file in the admin console, merged with what's already there:

```json
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"]
  },
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["svc:lab"],
      "ip":  ["tcp:80", "tcp:443"]
    }
  ]
}
```

- **`tagOwners`** lets the operator, tagged `tag:k8s-operator`, create proxies tagged `tag:k8s`.
- **The grant** lets my devices reach the service on ports 80 and 443, and nothing else.

`tag:k8s` never appears as a source. The proxies can receive connections but can't open any to my other devices.

There's deliberately no `autoApprovers` entry for `svc:lab`. I approve the two proxies as hosts of the service by hand, once, under **Services** in the admin console. If the operator's OAuth credential ever leaked, someone could add a device to my tailnet, but couldn't slip it behind `svc:lab`.

## The OAuth client

The operator authenticates to Tailscale with an OAuth client. Create one under **Settings → Trust credentials**, with write access to these scopes, each tagged `tag:k8s-operator`:

- **General → Services**
- **Devices → Core**
- **Keys → Auth Keys**

Tailscale also supports workload identity federation, which avoids a long-lived secret. It needs the cluster's OIDC discovery endpoints to be reachable from the internet, which a private homelab cluster doesn't offer, so I use the OAuth client.

The Helm chart looks for a Secret named `operator-oauth` when no credentials are passed as values. I seal it like any other secret:

```bash
read -rs TS_SECRET && kubectl create secret generic operator-oauth -n tailscale \
  --from-literal=client_id=<oauth-client-id> \
  --from-literal=client_secret="$TS_SECRET" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > infra/tailscale-operator/secrets/operator-oauth.yaml
unset TS_SECRET
```

## Installing the operator

The install follows the same pattern as cert-manager: an Argo CD `Application` with the chart, the values, the sealed secret and a manifests folder. The whole file is [`application.yaml`](application.yaml).

The values pin the operator and every proxy it creates to the control-plane node:

```yaml
operatorConfig:
  nodeSelector:
    kubernetes.io/os: linux
    node-role.kubernetes.io/control-plane: "true"
proxyConfig:
  defaultProxyClass: control-plane
```

The operator holds the OAuth secret, and each proxy holds a tailnet identity. Neither belongs on the node where CI jobs run. [`proxyclass.yaml`](proxyclass.yaml) defines the `control-plane` class.

The chart's default `nodeSelector` is `kubernetes.io/os: linux`. Setting the field replaces that map instead of merging with it, so the line is repeated here.

## The ProxyGroup and Traefik's tailnet Service

The ProxyGroup creates the two proxies:

```yaml
apiVersion: tailscale.com/v1alpha1
kind: ProxyGroup
metadata:
  name: ingress
spec:
  type: ingress
  replicas: 2
  proxyClass: control-plane
```

A second Service for Traefik, next to the one k3s manages, asks the operator to put Traefik on the tailnet:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: traefik-tailnet
  namespace: kube-system
  annotations:
    tailscale.com/proxy-group: ingress
    tailscale.com/hostname: lab
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  selector:
    app.kubernetes.io/name: traefik
    app.kubernetes.io/instance: traefik-kube-system
  ports:
    - name: web
      port: 80
      targetPort: web
    - name: websecure
      port: 443
      targetPort: websecure
```

`loadBalancerClass: tailscale` hands this Service to the operator. k3s's built-in ServiceLB has ignored Services that set a class since v1.26.2, so it won't also try to claim ports 80 and 443 on the nodes.

Keeping this as a separate Service also leaves k3s's own Traefik Service alone. Removing the tailnet route later doesn't touch LAN access.

## Finding the address

The service only starts answering once its two proxies are approved as hosts under **Services → svc:lab**. The same page lists its address. The Service's status should show it too:

```bash
kubectl -n kube-system get svc traefik-tailnet \
  -o jsonpath='{.status.loadBalancer.ingress}'
```

That address is `<service-ip>` in the [DNS post](../dns/). From a device on the tailnet, check that the port answers:

```bash
nc -vz -G 3 <service-ip> 443    # macOS; on Linux use -w 3
```

## What stays off

- **Funnel.** It would put the service on the public internet, and nothing here needs it.
- **Wider grants.** The one grant to `svc:lab` covers every app behind Traefik. If I ever share a single app with someone, that app gets its own entry point rather than a broader grant.
