# Putting Traefik on My Tailnet with One Unprivileged Tailscale Proxy

*October 4, 2026*

My homelab apps should be reachable from any of my devices over Tailscale. Traefik already routes every app by hostname, so the cluster needs only one way onto the tailnet: a single Tailscale proxy in front of Traefik.

I first planned this with the Tailscale Kubernetes operator, and [that write-up](../tailscale-operator/) is still here. I switched to one hand-made proxy instead, for the reasons below.

Placeholders: `<proxy-ip>` is the proxy's Tailscale address, shown once it joins. The join key is typed at a prompt.

## How it works

```text
my device ──tailnet──► <proxy-ip>   device "lab", tagged tag:k8s-ingress
                          │  one pod, userspace networking
                          ▼  plain TCP forwarding on ports 80 and 443
                       Traefik ──► forgejo, argocd, ...
```

The proxy only forwards TCP. TLS passes through it untouched and ends at Traefik.

## Why I didn't use the Tailscale operator

The operator is the official way to connect a cluster to a tailnet. For a single entry point, in a cluster managed from a public repo, two of its defaults weighed more than its automation:

- **A credential that stays useful.** The operator logs in to Tailscale with an OAuth client that can create join keys, devices and services. Sealed in my public repo, that ciphertext stays in git history forever, and the credential would still work if my sealing key ever leaked. This proxy joins with a single-use key, which is spent the moment it's used.
- **Privileged pods.** Since Tailscale 1.78, the operator's proxies run privileged so they can create `/dev/net/tun`. In userspace mode, Tailscale needs no privileges at all, so this proxy's namespace can enforce the `restricted` Pod Security Standard.
- **Moving parts.** An operator, its custom resources and a ProxyGroup, all to run what is in the end one proxy.

What I gave up, and why it's fine here:

- **Automatic setup and cleanup.** With one proxy, there's little to automate.
- **Redundancy.** One pod restarts in seconds, and Traefik runs on the same node anyway.
- **A Tailscale Service address.** The proxy's own address stays the same for as long as its saved identity exists.
- **Kernel-speed networking.** Userspace networking is slower, which doesn't matter for a homelab.

With many tailnet entry points, or a real need for redundancy, I'd use the operator.

## The tailnet policy

The proxy gets its own tag, and one grant lets my devices reach it on ports 80 and 443:

```json
{
  "tagOwners": {
    "tag:k8s-ingress": ["autogroup:admin"]
  },
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["tag:k8s-ingress"],
      "ip":  ["tcp:80", "tcp:443"]
    }
  ]
}
```

`tag:k8s-ingress` never appears as a source, so the proxy can't open connections to my other devices.

## The single-use key

In the admin console, under **Settings → Keys**, generate an auth key that is:

- **not reusable**, so it's dead after the first login;
- **tagged `tag:k8s-ingress`**, so the proxy joins as that tag;
- **short-lived**, a day or so, because it only has to last until the proxy first starts.

Seal it into the repo:

```bash
read -rs "TS_KEY?Auth key: " && echo && \
kubectl create secret generic tailscale-auth -n tailscale \
  --from-literal=TS_AUTHKEY="$TS_KEY" --dry-run=client -o yaml \
  | kubeseal --format yaml > infra/tailscale-proxy/manifests/secrets/tailscale-auth.yaml
unset TS_KEY
```

`read "VAR?prompt"` is zsh syntax. In bash, use `read -rsp 'Auth key: ' TS_KEY`.

## The proxy

[`deployment.yaml`](deployment.yaml) runs Tailscale's official image as an unprivileged user. Four environment variables do most of the work:

```yaml
- name: TS_USERSPACE
  value: "true"
- name: TS_KUBE_SECRET
  value: tailscale-state
- name: TS_AUTH_ONCE
  value: "true"
- name: TS_SERVE_CONFIG
  value: /config/serve.json
```

- **`TS_USERSPACE`** handles tailnet traffic inside the process, so no network device and no privileges are needed.
- **`TS_KUBE_SECRET`** saves the device's identity in a Secret the proxy manages itself. [`role.yaml`](role.yaml) allows exactly that and nothing else.
- **`TS_AUTH_ONCE`** is the one that's easy to miss. By default the container logs in again on every start, which fails once the single-use key is spent. With it set, the proxy logs in only when it has no saved identity.
- **`TS_SERVE_CONFIG`** points at the forwarding rules in [`configmap.yaml`](configmap.yaml): ports 80 and 443 to Traefik's in-cluster Service, as plain TCP.

The pod runs as a non-root user, with a read-only root filesystem and no capabilities. Its namespace refuses any pod with less.

[`networkpolicy.yaml`](networkpolicy.yaml) lets nothing in the cluster connect to the proxy, because tailnet traffic arrives over the proxy's own outbound connections. Outbound, it reaches DNS, Traefik, the Kubernetes API for its saved identity, the internet, and UDP on my LAN for direct paths to my devices at home.

## Checking it

The proxy appears under **Machines** as `lab`, tagged `tag:k8s-ingress`. Check that it shows **Expiry disabled**, and note its address: that's `<proxy-ip>` in the [DNS post](../dns/).

From a device on the tailnet, check that Traefik answers through it:

```bash
nc -vz -G 3 <proxy-ip> 443    # macOS; on Linux use -w 3
```

After the first login, the single-use key is spent. Its sealed copy can stay in the repo or be deleted, because the `Deployment` marks it optional.
