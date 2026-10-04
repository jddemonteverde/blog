# Wildcard Let's Encrypt Certificates for Private Services with cert-manager

*October 4, 2026*

My homelab services are only reachable over Tailscale, but I still want certificates that every browser and tool trusts. Let's Encrypt can issue them for services that aren't on the internet at all, as long as the proof of ownership happens in DNS.

This post sets up cert-manager in k3s, through Argo CD, to get one wildcard certificate for `*.lab.example.com` and keep it renewed.

Placeholders: `example.com` is your domain. The Cloudflare token is typed at a prompt and never written to a file in plaintext.

## Why DNS-01 and a wildcard

Let's Encrypt only issues a certificate to someone who proves they control the name. There are two common proofs:

- **HTTP-01:** serve a file on the name over port 80, from the public internet. My services aren't on the internet, so this can't work.
- **DNS-01:** publish a TXT record at `_acme-challenge.lab.example.com`. It works for private services, and it's the only proof Let's Encrypt accepts for a wildcard.

A wildcard also fits the rest of the setup. One certificate covers every app I add later, and public certificate logs show only `*.lab.example.com`, not the name of each service.

## The Cloudflare API token

cert-manager publishes and removes the TXT record itself on every renewal, so it needs permission to edit DNS records. A Cloudflare API token gives it exactly that and nothing else.

Create it under **My Profile → API Tokens → Create Token → Create Custom Token**:

- **Permissions:** `Zone · DNS · Edit` and `Zone · Zone · Read`.
- **Zone Resources:** `Include · Specific zone · example.com`.
- **TTL:** leave it empty. A token that expires quietly breaks renewals months later.

Don't use the Global API Key instead. It has access to the whole Cloudflare account.

Seal the token straight into the repo. `read -rs` takes it from a prompt without echoing it, so it never reaches the shell history:

```bash
read -rs CF_TOKEN && printf '%s' "$CF_TOKEN" \
  | kubectl create secret generic cloudflare-api-token -n cert-manager \
      --from-file=api-token=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --format yaml > infra/cert-manager/secrets/cloudflare-api-token.yaml
unset CF_TOKEN
```

The Secret has to be in the `cert-manager` namespace. A `ClusterIssuer` reads its secrets from there.

## Installing cert-manager

cert-manager is a Helm chart, installed by an Argo CD `Application` with four sources: the chart, my repo for `values.yaml`, the sealed token, and the issuer and certificate manifests. The whole file is [`application.yaml`](application.yaml).

The values are short:

```yaml
crds:
  enabled: true
dns01RecursiveNameservers: "1.1.1.1:53,9.9.9.9:53"
dns01RecursiveNameserversOnly: true
global:
  nodeSelector:
    node-role.kubernetes.io/control-plane: "true"
```

- **`crds.enabled`** is off by default. Without it, the chart installs a controller with no resource types to watch.
- **The two `dns01` settings** make cert-manager check its TXT record against public resolvers only. Later in this series, CoreDNS inside the cluster answers some `lab.example.com` names itself, and the propagation check shouldn't ask it.
- **`global.nodeSelector`** keeps all four cert-manager components on the control-plane node. The controller holds the Cloudflare token, so it stays off the node where CI jobs run. A top-level `nodeSelector` would only move the controller.

The `Application` also has a `retry` block. On the first sync, the issuers are applied while cert-manager's webhook is still starting, and that first attempt can fail.

## The issuer

One `ClusterIssuer`, pointed at Let's Encrypt's production service:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-production-account
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

Let's Encrypt also runs a staging service for testing, with looser rate limits and untrusted certificates. I skip it. cert-manager waits at least an hour before retrying a failed attempt, so a misconfiguration stays well inside the production limits.

Two details:

- **No email address.** Let's Encrypt stopped sending expiry emails in June 2025, and cert-manager renews long before expiry, so the issuer doesn't need one.
- **`SkipDryRunOnMissingResource`.** Argo CD dry-runs every manifest before applying it. On the first sync the `ClusterIssuer` kind doesn't exist yet, because the chart creates it in the same sync. The annotation skips the dry run for this object.

## The certificate

The certificate goes in `kube-system`, where k3s runs Traefik, which reads it from there:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-lab
  namespace: kube-system
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  secretName: wildcard-lab-tls
  dnsNames:
    - lab.example.com
    - "*.lab.example.com"
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt-production
```

## Verifying

Watch the certificate become ready, which usually takes a minute or two:

```bash
kubectl -n kube-system get certificate wildcard-lab
kubectl get challenges -A
```

`READY` turns `True` once the certificate is stored in the `wildcard-lab-tls` Secret. While it's `False`, the challenge says why. A missing token permission is the usual cause.

Check what was issued. This reads only the public certificate, not the key:

```bash
kubectl -n kube-system get secret wildcard-lab-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -issuer -ext subjectAltName -enddate
```

The issuer should be Let's Encrypt, and the names should be `lab.example.com` and `*.lab.example.com`.

The certificate exists now, but nothing serves it yet. The [Traefik post](../traefik/) does that, after the [proxy post](../tailscale-proxy/) puts Traefik on the tailnet.
