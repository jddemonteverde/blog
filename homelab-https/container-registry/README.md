# Why I Paused Forgejo's Container Registry for My k3s Cluster

*October 4, 2026*

Forgejo already hosts my code and runs my CI, so I planned to push app images to its built-in container registry and have the cluster pull them from there. The plan grew into a second hostname, a rewritten response header, two access tokens, a private account and a sealed pull secret in every app namespace. I paused it and kept a plain registry pod instead.

But most of the complexity isn't Forgejo's fault. It comes from where images get pulled, and any registry inside the cluster runs into it.

Placeholders: `example.com` is your domain, `<traefik-ip>` is the ClusterIP of Traefik's Service, and `<registry-ip>` is the registry Service's pinned ClusterIP. `<app>` and `<tag>` name an image.

## The node pulls the image, not the pod

The pod doesn't download its own image; the node does. Before the pod exists, containerd (the container runtime on the node) pulls the image. containerd runs on the node itself, outside the cluster, so two rules apply:

1. It can't use cluster-internal names like `registry.registry.svc`.
2. It only talks HTTPS with a real certificate. To allow plain HTTP you'd need a config file on every node, which I've ruled out.

I ruled it out because I want my manifests to work unchanged on a managed cluster, where I can't edit the nodes.

My registry pod already got around rule 1 with a pinned ClusterIP, since an address needs no DNS. It still spoke plain HTTP, so containerd refused it with `server gave HTTP response to HTTPS client`, and my app sat in `ImagePullBackOff`.

## What Forgejo's registry adds on top

Forgejo's registry needs the same reachable name and certificate as any other registry. The extra work comes from its login flow.

A client's first request gets a `401` whose `WWW-Authenticate` header says where to fetch a token, and [Forgejo builds that URL from its `ROOT_URL`](https://codeberg.org/forgejo/forgejo/src/tag/v15.0.9/routers/api/packages/container/container.go#L120). Mine is a name only my tailnet can reach, so a node would be sent to an address it can't open.

Working around that took:

- **A Traefik middleware** that rewrites that header to point at a name the nodes can reach.
- **Two access tokens:** package read and write for CI, read-only for the cluster.
- **A pull secret in every app namespace** to keep the images private, sealed again whenever the token changes.
- **A wider NetworkPolicy**, so BuildKit could push through Traefik instead of straight to the registry.

That's a lot of moving parts for a cluster with one user.

## What I run instead

The registry pod runs the official [`registry`](https://hub.docker.com/_/registry) image: [`deployment.yaml`](deployment.yaml), [`service.yaml`](service.yaml) and [`pvc.yaml`](pvc.yaml). It only needed a name the nodes can reach over HTTPS:

```text
node (containerd) ──HTTPS──▶ registry.lab.example.com ──▶ Traefik (wildcard cert) ──▶ registry pod
CI (BuildKit)     ──HTTP, in-cluster──────────────────────────────────────────────▶ registry pod
```

Three pieces make that work:

1. **A public DNS record that points at a ClusterIP.** In Cloudflare, `registry.lab` is an A record for `<traefik-ip>`, DNS only. It takes precedence over the `*.lab` wildcard for that one name.
2. **Traefik's ClusterIP, pinned** so the record can't go stale if the Service is ever recreated. In k3s's `HelmChartConfig` for Traefik:

   ```yaml
   service:
     spec:
       type: ClusterIP
       clusterIP: <traefik-ip>
   ```

   Use the address the Service already has. A live Service's ClusterIP can't change, so any other value makes the chart upgrade fail.
3. **An Ingress for the registry** that routes only `/v2`, the registry API: [`ingress.yaml`](ingress.yaml). Traefik serves the [wildcard certificate](../traefik/) for every name, so it needs no `tls:` section.

> The record works because kube-proxy routes ClusterIPs on every node, including connections that start on the node itself. Anywhere else, the address leads nowhere.

Deployments then use the new name:

```yaml
image: registry.lab.example.com/<app>:<tag>
```

CI didn't change. BuildKit still pushes to `<registry-ip>:5000/<app>:<tag>` over plain HTTP inside the cluster. The registry doesn't care which name a request used, so both names reach the same image.

Because nodes now come through Traefik, the registry can finally have a NetworkPolicy. [`networkpolicy.yaml`](networkpolicy.yaml) admits only Traefik and BuildKit. Before, nodes pulled from it directly, and a pod selector can't match node traffic.

## Checking that a node can pull

On a node:

```bash
getent ahostsv4 registry.lab.example.com
curl -sS https://registry.lab.example.com/v2/<app>/tags/list
```

The first should print `<traefik-ip>`. The second should list the image's tags without a certificate error, which means containerd can pull too.

## What I gave up

- **No login.** Anything that can reach the registry can push and pull. Only my cluster and tailnet can reach it, and for a one-person homelab I accept that.
- **No UI and no automatic cleanup.** Old tags stay until I delete them and run the registry's garbage collection.
- **A dependency on DNS outside git.** Some routers and Pi-hole setups drop answers that contain private addresses, as DNS rebinding protection. On a node, `getent ahostsv4 10-43-0-1.sslip.io` should print `10.43.0.1` before you rely on this.

If I want private images or a UI later, I'll go back to Forgejo's registry. The DNS record and the pinned Traefik address stay; the Ingress would point at Forgejo, and the header rewrite, tokens and pull secrets would come back.
