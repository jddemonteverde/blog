# Why I Paused Forgejo's Container Registry for My k3s Cluster

*October 4, 2026*

Forgejo already hosts my code and runs my CI, so I planned to push app images to its built-in container registry and have the cluster pull them from there. The plan grew into a second hostname, a rewritten response header, two access tokens, a private account and a sealed pull secret in every app namespace. I paused it and kept a plain registry pod instead.

But most of the complexity isn't Forgejo's fault. It comes from where images get pulled, and any registry inside the cluster runs into it.

Placeholders: `<registry-ip>` is the registry Service's pinned ClusterIP, and `<app>` and `<tag>` name an image.

## The node pulls the image, not the pod

The pod doesn't download its own image; the node does. Before the pod exists, containerd (the container runtime on the node) pulls the image. containerd runs on the node itself, outside the cluster, so two rules apply:

1. It can't use cluster-internal names like `registry.registry.svc`.
2. It only talks HTTPS with a real certificate. To allow plain HTTP you'd need a config file on every node, which I've ruled out.

I ruled it out because I want my manifests to work unchanged on a managed cluster, where I can't edit the nodes.

My registry pod already got around rule 1 with a pinned ClusterIP, since an address needs no DNS. It still spoke plain HTTP, so containerd refused it with `server gave HTTP response to HTTPS client`, and my app sat in `ImagePullBackOff`.

## What Forgejo's registry adds on top

Forgejo's registry runs into the same two rules. On top of them comes its login flow.

A client's first request gets a `401` whose `WWW-Authenticate` header says where to fetch a token, and [Forgejo builds that URL from its `ROOT_URL`](https://codeberg.org/forgejo/forgejo/src/tag/v15.0.9/routers/api/packages/container/container.go#L120). Mine is a name only my tailnet can reach, so a node would be sent to an address it can't open.

Working around that took:

- **A Traefik middleware** that rewrites that header to point at a name the nodes can reach.
- **Two access tokens:** package read and write for CI, read-only for the cluster.
- **A pull secret in every app namespace** to keep the images private, sealed again whenever the token changes.
- **A wider NetworkPolicy**, so BuildKit could push through Traefik instead of straight to the registry.

That's a lot of moving parts for a cluster with one user.

## One exception covers both rules: localhost

containerd treats `localhost` as a special case. The name needs no DNS, and containerd accepts a plain-HTTP registry there without any node config.

So if every node can reach the registry on its own `localhost:5000`, both rules stop mattering. No DNS record, no certificate, no node config.

## What I run instead

The registry pod runs the official [`registry`](https://hub.docker.com/_/registry) image: [`deployment.yaml`](deployment.yaml), [`service.yaml`](service.yaml) and [`pvc.yaml`](pvc.yaml). It runs on one node, so every node gets a small forwarder: a DaemonSet of the official [`haproxy`](https://hub.docker.com/_/haproxy) image that passes its node's `localhost:5000` to the registry Service.

```text
node (containerd) ──HTTP──▶ localhost:5000 ──▶ haproxy on that node ──▶ registry pod
CI (BuildKit)     ──HTTP, in-cluster──────────────────────────────────▶ registry pod
```

The forwarder puts its port on the node with a `hostPort` bound to loopback ([`daemonset-proxy.yaml`](daemonset-proxy.yaml)):

```yaml
ports:
  - name: registry
    containerPort: 5000
    hostPort: 5000
    hostIP: 127.0.0.1
```

> `hostIP` is the line that matters. Without it, the port opens on every address the node has, and an unauthenticated registry ends up on the LAN.

The forwarding itself is a short HAProxy config in TCP mode: [`configmap-proxy.yaml`](configmap-proxy.yaml).

> HAProxy 3.3 and later refuse to start when a frontend and a backend share a name. My first version named both `registry`, and the forwarder crashed on every node.

Deployments then use:

```yaml
image: localhost:5000/<app>:<tag>
```

CI didn't change. BuildKit still pushes to `<registry-ip>:5000/<app>:<tag>` over plain HTTP inside the cluster. The registry doesn't care which name a request used, so both names reach the same image.

Because nodes now come through the forwarders, the registry can finally have a NetworkPolicy. [`networkpolicy.yaml`](networkpolicy.yaml) admits only the forwarders and BuildKit. Before, nodes pulled from it directly, and a pod selector can't match node traffic.

## Checking that a node can pull

On each node:

```bash
curl -sS http://localhost:5000/v2/<app>/tags/list
```

A list of tags means containerd can pull from `localhost:5000` too.

## What I gave up

- **No login.** Anything that reaches the registry can push and pull: programs on the nodes through `localhost:5000`, and CI. For a one-person homelab I accept that.
- **No UI and no automatic cleanup.** Old tags stay until I delete them and run the registry's garbage collection.
- **A forwarder on every node.** A node can pull only while its forwarder runs. The loopback-only `hostPort` also depends on the CNI's port-mapping plugin, which k3s ships.

If I want private images or a UI later, I'll revisit Forgejo's registry. The forwarders could point at Forgejo instead, but the header rewrite, tokens and pull secrets would come back.
