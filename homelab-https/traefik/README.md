# Serving Every k3s Ingress over HTTPS with One Default Certificate

*October 4, 2026*

With a wildcard certificate in the cluster, I don't want TLS settings in every Ingress. Traefik can serve one certificate as its default, and the Traefik that ships with k3s already turns on TLS for every route on its HTTPS port.

Together, those mean an Ingress with a `*.lab.example.com` host is served over HTTPS without a `tls:` section at all.

Placeholders: `example.com` is your domain, and `<app>` is any app behind Traefik.

## How it works

Two pieces of Traefik configuration combine:

- **The `websecure` entrypoint has TLS on.** In the Traefik Helm chart that k3s ships, `ports.websecure.http.tls.enabled` defaults to `true`. Every router on port 443 terminates TLS, including routers created from plain Ingresses.
- **A router without its own certificate uses the default one.** Traefik takes it from a `TLSStore` named `default`. Without one, it serves a self-signed certificate it generates at startup.

So the only missing piece is that `TLSStore`.

## Setting the default certificate

The certificate from the [Let's Encrypt post](../lets-encrypt/) is stored in the `wildcard-lab-tls` Secret in `kube-system`, where k3s runs Traefik. The `TLSStore` points at it:

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: kube-system
spec:
  defaultCertificate:
    secretName: wildcard-lab-tls
```

Two details are easy to miss:

- **The name has to be `default`.** Traefik only uses the store with that name for the default certificate.
- **The Secret has to be in the same namespace as the `TLSStore`.** That's why the certificate is issued into `kube-system` rather than cert-manager's own namespace.

In my repo this file sits in `infra/traefik/manifests/`, next to the `HelmChartConfig` that already customizes k3s's Traefik.

## Checking the certificate

From a device on the tailnet:

```bash
openssl s_client -connect forgejo.lab.example.com:443 \
  -servername forgejo.lab.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -ext subjectAltName
```

The issuer should be Let's Encrypt, and the names should include `*.lab.example.com`. This works before any app has moved, because Traefik serves the default certificate for every name it receives.

## Redirecting HTTP to HTTPS

k3s customizes its packaged Traefik through a `HelmChartConfig` named `traefik` in `kube-system`. The redirect is one chart value:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    nodeSelector:
      node-role.kubernetes.io/control-plane: "true"
    ports:
      web:
        http:
          redirections:
            entryPoint:
              to: websecure
              scheme: https
              permanent: true
```

The `nodeSelector` was already there. Traefik can read every Secret in the cluster, so it stays off the node where CI runs.

**Turn the redirect on last**, after every app has moved to its `lab.example.com` name. It applies to every request on port 80. An app still reached by an old LAN name would be sent to HTTPS with a certificate that doesn't match that name, and the browser would refuse it.

## Taking Traefik off the LAN

Once nothing uses the old LAN names, Traefik doesn't need to listen on the nodes at all. k3s's built-in ServiceLB only exposes `LoadBalancer` Services, so one more value removes the listeners:

```yaml
service:
  spec:
    type: ClusterIP
```

The Tailscale proxy and in-cluster clients still reach Traefik through its Service, so nothing else changes. Every device that uses the apps now needs Tailscale, even at home.

If Tailscale is ever down, `kubectl port-forward` to an app's Service still works, because the Kubernetes API is a separate listener.

## Adding a new app

Once this is in place, a new app needs one Ingress:

```yaml
spec:
  ingressClassName: traefik
  rules:
    - host: <app>.lab.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <app>
                port:
                  number: 8080
```

No `tls:` block, no new certificate and no DNS change. The tailnet grant from the [proxy post](../tailscale-proxy/) already covers it.
