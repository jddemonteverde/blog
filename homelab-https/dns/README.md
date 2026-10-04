# Pointing a Public DNS Record at a Tailnet-Only Address

*October 4, 2026*

My devices need `forgejo.lab.example.com` to resolve to the Tailscale proxy from the [proxy post](../tailscale-proxy/), at home or anywhere else. I do that with one public wildcard record that points at a Tailscale address.

Anyone can look the record up, but only my tailnet can reach the address behind it.

Placeholders: `example.com` is your domain, and `<proxy-ip>` is the proxy's Tailscale address. `<old-hostname>` is a name from before the move.

## Why a public record works for private services

Tailscale addresses come from the `100.64.0.0/10` range, which the internet doesn't route. A public record that points there tells a stranger nothing they can use.

What it buys:

- **Every device resolves it.** Laptops and phones use normal DNS, with no hosts files. Phones don't let you edit one anyway.
- **Nothing extra to run.** No DNS server in the cluster and no split DNS to maintain.
- **One record for every app.** The wildcard covers names I haven't created yet.

The alternative is Tailscale split DNS: send `lab.example.com` queries to a DNS server inside the tailnet. It keeps the names out of public DNS, but that server then has to be up for anything to resolve.

## Why not `.local`

Before this, my apps had `.local` names in `/etc/hosts`. `.local` is reserved for multicast DNS (Bonjour), and macOS treats it that way, even for names in the hosts file. Every lookup stalled:

```bash
curl -o /dev/null -s -w 'dns: %{time_namelookup}s\n' http://<old-hostname>/
```

```text
dns: 5.007s
```

The same request by IP took 12 ms, and every `git fetch` paid those 5 seconds. A name under a real domain avoids the stall entirely: the new name resolves in about 3 ms.

## Creating the record

In the Cloudflare dashboard, open the domain, then **DNS → Records → Add record**:

| Field | Value |
|---|---|
| Type | `A` |
| Name | `*.lab` |
| IPv4 address | `<proxy-ip>` |
| Proxy status | **DNS only** (grey cloud) |

Proxy status matters. A proxied (orange cloud) record sends traffic through Cloudflare's servers, which can't reach a Tailscale address.

This is a one-time step. The proxy keeps its address for as long as its saved identity, the `tailscale-state` Secret, exists.

## Checking it

From anywhere, the name should resolve to the Tailscale address:

```bash
dig +short forgejo.lab.example.com
```

From a device on the tailnet, a request should reach Traefik. Until the [Traefik post](../traefik/) is done, Traefik serves a self-signed certificate, hence `-k`:

```bash
curl -skI https://forgejo.lab.example.com | head -1
```

Any HTTP status line, even a `404`, means the request crossed the tailnet and reached Traefik. With Tailscale turned off on the same device, the request times out.

## What can get in the way

**DNS rebinding protection.** Some home routers drop DNS answers that point at private or CGNAT ranges, as a defense against DNS rebinding attacks. The name then fails to resolve on the home network and works everywhere else. The fix is in the Tailscale admin console under **DNS**: add a public resolver as a global nameserver and turn on overriding local DNS, so tailnet devices stop asking the router.

**Pods resolve the name too.** CoreDNS in the cluster forwards the lookup upstream and also gets `<proxy-ip>`. Pods aren't on the tailnet, so they can't reach it. That matters for Forgejo Actions, which check out code from Forgejo's URL. The [Forgejo post](../forgejo/) handles it with a CoreDNS rewrite.
