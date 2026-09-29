# Firewall

*September 21, 2026*

This is the host firewall I run on my Ubuntu servers. It uses UFW, blocks
everything coming in by default, and only opens what the server actually
needs. It's written for k3s nodes but works on a plain server too.

What's in this folder:

| File | What it is |
|---|---|
| `firewall.sh` | The script. Run it once per server. |
| `README.md` | This guide. |

## Before you start

**Do the SSH setup in `../ssh/` first.** The firewall only allows SSH from
the LAN, so if SSH isn't working right and you lock yourself out, you're
fixing it at the console.

**Keep a second SSH session open (or the physical console)** while the
script runs. It resets all UFW rules, so a wrong setting means that open
session is your only way back in.

## What it opens

| From | Port | Why |
|---|---|---|
| your LAN | 22/tcp (rate-limited) | SSH. Blocks an IP after 6 failed tries in 30 s. |
| your LAN | 6443/tcp | k3s API for `kubectl`. Server nodes only. |
| `10.42.0.0/16` | any | k3s pod network |
| `10.43.0.0/16` | any | k3s service network |
| your LAN | 10250/tcp | kubelet, so `kubectl logs` / `exec` work across nodes |
| your LAN | 8472/udp | flannel VXLAN, the tunnel pods use to talk across nodes |
| your LAN | 51820/udp | flannel WireGuard, if you switch to the encrypted backend |
| your LAN | 2379-2380/tcp | etcd, server nodes only (for HA setups) |
| anyone | 80, 443/tcp | Only with `--public-web` |
| everything else | — | **blocked** |

Outbound is allowed. Forwarded traffic is blocked by default; k3s adds its
own iptables rules for pod traffic, which work alongside UFW.

## How to run it

Copy this folder to the server, then:

```bash
cd firewall
sudo ./firewall.sh --dry-run    # prints what it would do, changes nothing
sudo ./firewall.sh              # applies it (asks before enabling)
```

The script prints a summary of what it's about to do and asks
`Continue? [y/N]` before touching anything.

Pick the right flags for the server:

| Server | Command |
|---|---|
| k3s server (control plane) | `sudo ./firewall.sh --server` (this is the default) |
| k3s agent (worker) | `sudo ./firewall.sh --agent` |
| Not running k3s | `sudo ./firewall.sh --no-k3s` |

Other flags:

| Flag | What it does |
|---|---|
| `--public-web` | Also open 80 and 443 to the internet. Only if you port-forward to the ingress. |
| `--ssh-port 2222` | If sshd listens on a port other than 22. |
| `--lan 10.0.0.0/24` | If your LAN isn't `192.168.1.0/24`. |
| `--nodes 10.0.0.0/28` | Limit the node-to-node ports to a smaller range than the LAN. |
| `--dry-run` | Print the commands, change nothing. |
| `--yes` | Skip the confirmation prompt. |

The defaults live at the top of the script under `Defaults` if you'd rather
change them there than pass flags each time.

## Multi-node clusters

When you add a node, run the script on **every** node, not just the new one.
The existing nodes need the node-to-node rules too, or pods on different
nodes won't be able to reach each other. Do the server first, then the
workers.

## After it runs

Open a **new** SSH session from your workstation and make sure you still get
in. Only then close the safety-net session.

Useful checks:

```bash
sudo ufw status verbose        # the rule set
ss -tlnp                       # what's listening
sudo tail -f /var/log/ufw.log  # blocked packets
```

## Running it again

The script is safe to re-run. It wipes the rules and re-applies the same set,
so if you change a flag or a default, just run it again. Note that this also
removes any rules you added by hand with `ufw allow`.

## Rollback

```bash
sudo ufw disable
```

Everything is open again, same as before you ran the script.
