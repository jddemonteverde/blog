# Private HTTPS for My Homelab over Tailscale

*October 4, 2026*

I want my homelab's web apps, Forgejo first, reachable from my laptop and phone wherever I am, over HTTPS with real certificates, and without opening anything to the internet. This series is how I'm setting that up on my two-node k3s cluster, one piece per post.

The short version: one public wildcard DNS name, one Let's Encrypt wildcard certificate, and one fixed Tailscale address in front of Traefik.

## How the pieces fit

```text
laptop / phone on my tailnet
   │  https://forgejo.lab.example.com
   │  public DNS: *.lab.example.com → <proxy-ip>   (a Tailscale address)
   ▼
Tailscale proxy "lab"  ── one unprivileged pod, tagged tag:k8s-ingress
   ▼
Traefik :443  ── wildcard certificate for *.lab.example.com (Let's Encrypt)
   ├─ forgejo.lab.example.com
   └─ <app>.lab.example.com
   ▲
pods and CI jobs  ── CoreDNS sends forgejo.lab.example.com straight to Traefik
```

- **Private:** the DNS record is public, but `<proxy-ip>` only answers devices on my tailnet that my access policy allows.
- **Trusted everywhere:** browsers, `git` and Docker accept the certificate with no setup on my devices.
- **One step per new app:** an Ingress with a `*.lab.example.com` host. No new record, certificate or Tailscale change.

## The posts, in order

1. **[Let's Encrypt](lets-encrypt/):** a wildcard certificate from cert-manager, proven through Cloudflare DNS.
2. **[Tailscale proxy](tailscale-proxy/):** one unprivileged proxy that puts Traefik on the tailnet. I evaluated the [Tailscale operator](tailscale-operator/) first; that post stays for comparison, and the proxy post explains why I didn't use it.
3. **[DNS](dns/):** a public wildcard record that points at that address.
4. **[Traefik](traefik/):** the wildcard certificate as the default for every Ingress.
5. **[Forgejo](forgejo/):** moving an app to its new name without breaking CI.

Each step can be checked before the next one starts. The DNS record needs the address from step 2, and Traefik can't serve the certificate before step 1 issues it.

## Before you start

- **A domain with its DNS on Cloudflare.** The free plan is enough. Services go under a subdomain, `lab.example.com`, which leaves the bare domain free for anything public later.
- **Admin access to the Tailscale account**, to edit the policy file and generate a single-use join key.
- **k3s managed by Argo CD, with Sealed Secrets.** See [`../k3s-homelab/`](../k3s-homelab/) and [its Sealed Secrets post](../k3s-homelab/sealed-secrets/). Two secrets in this series go through it.

Placeholders used across the series:

- `example.com`: your domain.
- `<proxy-ip>`: the Tailscale proxy's address, from the proxy post.
- `<app>`: any app behind Traefik.
- `<old-hostname>`: the name an app used before the move.

## Why not Tailscale's own certificates

Tailscale can issue certificates for its `ts.net` names without any domain. Two things ruled it out for me:

- **Every app becomes its own tailnet device**, each with a name under the tailnet's domain.
- **CI can't reach those names.** Pods aren't on the tailnet, so Forgejo Actions jobs couldn't check out code from a `ts.net` URL without extra plumbing.

With my own domain, pods resolve the same name to Traefik inside the cluster and still get a valid certificate.

## Folders

```text
.
├── README.md             <- you are here
├── lets-encrypt/         cert-manager, issuers, wildcard certificate
├── tailscale-proxy/      one unprivileged proxy in front of Traefik, and why not the operator
├── tailscale-operator/   the operator alternative I evaluated first (not used)
├── dns/                  the wildcard record
├── traefik/              default certificate and HTTP-to-HTTPS redirect
└── forgejo/              Ingress, CoreDNS rewrite, ROOT_URL
```

Files next to each README are the manifests as they go into my GitOps repo, [homelab33](https://github.com/jddemonteverde/homelab33), with my domain and addresses replaced by placeholders.
