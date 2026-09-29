# Setting up k3s on my homelab

*September 22, 2026*

I had an old PC and a laptop collecting dust, so I turned them into a small Kubernetes cluster to host stuff like Forgejo and my portfolio site. This is how I set it up and, more importantly, why I made the choices I did. Writing it down so I don't forget and so I can redo it if I ever nuke the thing.

## The hardware

| Node | Machine | Role |
|---|---|---|
| `node-01` | Old PC (4 CPU, 8 GB RAM, 256 GB SSD) | control plane + etcd |
| `node-02` | Old laptop | worker |

Both run Ubuntu 22.04 and stay on 24/7. k3s version at the time of writing: `v1.36.4+k3s1`.

In the commands below, `<server-ip>` is the PC's LAN IP, `<worker-ip>` is the laptop's, and `<lan-cidr>` is the LAN subnet. Replace them with your own.

## Why k3s

Full Kubernetes (kubeadm) is a lot of moving parts for two old machines. k3s is a single binary that bundles the API server, scheduler, kubelet, containerd, Flannel networking, CoreDNS and Traefik. It uses way less RAM, installs with one command, and is still real Kubernetes. Everything you'd learn on k3s carries over.

## The decisions

### One control plane + one worker, not two control planes

My first thought was "two machines, make them both control planes for redundancy." Turns out that's worse than one.

The cluster state lives in etcd, and etcd needs a *majority* of its members up to keep working. With 2 members, majority = 2, so if either machine reboots, the whole cluster's API goes down. With 1 server + 1 worker, only the server rebooting takes the API down. The worker rebooting just moves pods around.

Real HA starts at 3 control planes (survives losing 1). So for now: PC is the server, laptop is a worker. When I get a third machine, the laptop gets promoted and I'll have 3.

### Embedded etcd instead of SQLite

k3s defaults to SQLite as the datastore, which is fine for a single node but can't be shared with other control planes. Since I do plan to add a third node, I enabled embedded etcd from the start with `--cluster-init`. "Embedded" just means k3s runs etcd inside its own process; you don't install or manage it separately.

The cost is a bit more RAM and a lot of small disk writes. etcd hates spinning disks, but the PC has an SSD, so no problem. If it had been an HDD I'd have stuck with SQLite.

I actually installed without `--cluster-init` the first time. Re-running the installer with the flag added migrated SQLite to etcd automatically. More on that below.

### Storage: local-path for now, NAS later

Containers are throwaway. Anything that needs to survive a restart (Forgejo's git repos, its database) has to go on a persistent volume. k3s ships with `local-path`, which just uses a directory on the node's disk under `/var/lib/rancher/k3s/storage/`. Simple, fast, but the pod is tied to that node.

That's fine for now. When I get a NAS I'll add the `nfs-subdir-external-provisioner` chart so volumes live on the NAS and pods can move between nodes. Longhorn is overkill for two nodes.

### Firewall stays on

ufw was already active on both machines and I didn't want to turn it off. So I opened only the ports k3s needs instead.

## Server setup (the PC)

### 1. Update

```bash
sudo apt update && sudo apt upgrade -y
```

Get kernel updates and reboots done before the cluster exists, not after.

### 2. Firewall

```bash
sudo ufw allow 6443/tcp                  # Kubernetes API
sudo ufw allow 10250/tcp                 # kubelet (logs, exec, metrics)
sudo ufw allow 8472/udp                  # Flannel VXLAN, pod traffic between nodes
sudo ufw allow from 10.42.0.0/16 to any  # pod network
sudo ufw allow from 10.43.0.0/16 to any  # service network
sudo ufw reload
```

`10.42.0.0/16` and `10.43.0.0/16` are the k3s default pod and service CIDRs. Without these, pods can't talk to each other and `kubectl logs` breaks.

### 3. Install k3s

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --node-ip <server-ip> \
  --write-kubeconfig-mode 644
```

- `server`: this node runs the control plane.
- `--cluster-init`: use embedded etcd instead of SQLite (see above).
- `--node-ip`: the machine has both an IPv4 and a public IPv6 address. Pinning it makes sure the cluster advertises the LAN IPv4 so other nodes join over that.
- `--write-kubeconfig-mode 644`: lets my normal user read the kubeconfig so `kubectl` works without sudo. Fine on a personal box.

If you already installed without `--cluster-init`, just run the same command again with it added. The installer rewrites the systemd unit and restarts k3s, and k3s migrates the SQLite data into etcd on startup. Pass *all* your flags again because it replaces the unit file, it doesn't append. Takes about a minute of API downtime.

### 4. Check it

```bash
sudo systemctl status k3s --no-pager
kubectl get nodes -o wide
kubectl get pods -A
```

Node should be `Ready` with roles `control-plane,etcd`. All pods in `kube-system` (coredns, traefik, local-path-provisioner, metrics-server) should be `Running` after a minute or two.

### 5. kubectl without env vars

```bash
mkdir -p ~/.kube
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
chmod 600 ~/.kube/config
```

`kubectl`, Helm, k9s etc. all look in `~/.kube/config` by default.

### 6. Grab the join token

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

Workers use this to authenticate. Treat it like a password.

## Worker setup (the laptop)

### 1. Hostname

```bash
sudo hostnamectl set-hostname node-02
```

Node names must be unique and come from the hostname. Set it *before* installing. Renaming later means deleting and re-joining the node.

### 2. Update

```bash
sudo apt update && sudo apt upgrade -y
```

### 3. Stop the lid from suspending it

```bash
sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/^#\?HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
sudo systemctl restart systemd-logind
```

Ubuntu suspends on lid close by default. A suspended node goes `NotReady` and Kubernetes starts evicting its pods after 5 minutes. This is the number one "why does my laptop node keep dropping" issue.

Also worth giving the laptop a DHCP reservation in the router so its IP doesn't change.

### 4. Firewall

Check first:

```bash
sudo ufw status numbered
```

If active, open what's needed. No 6443 here, the worker doesn't run the API.

```bash
sudo ufw allow from <lan-cidr> to any port 10250 proto tcp
sudo ufw allow from <lan-cidr> to any port 8472 proto udp
sudo ufw allow from 10.42.0.0/16 to any
sudo ufw allow from 10.43.0.0/16 to any
sudo ufw reload
```

`ufw allow` is safe to re-run. It skips rules that already exist.

### 5. Install k3s as an agent

```bash
curl -sfL https://get.k3s.io | \
  K3S_URL=https://<server-ip>:6443 \
  K3S_TOKEN=<token from the server> \
  sh -s - agent --node-ip <worker-ip>
```

Setting `K3S_URL` is what flips the installer into agent mode. It installs a `k3s-agent` service that only runs kubelet, containerd and Flannel. No API server, no etcd.

### 6. Verify from the server

```bash
kubectl get nodes -o wide
```

The laptop shows up `Ready` within about 30 seconds. Then check that pods on the worker can actually reach things on the server:

```bash
kubectl run nettest --image=busybox --restart=Never \
  --overrides='{"spec":{"nodeName":"node-02"}}' -- sleep 300
kubectl exec nettest -- nslookup kubernetes.default
kubectl delete pod nettest
```

This forces a pod onto the laptop and has it resolve a service name through CoreDNS on the server. If it works, the VXLAN tunnel and service network are both fine. If it times out, check the 8472/udp rule first.

### 7. Label it (cosmetic)

```bash
kubectl label node node-02 node-role.kubernetes.io/worker=worker
```

Just makes `kubectl get nodes` show `worker` instead of `<none>` under ROLES.

## Where I ended up

```
NAME      STATUS   ROLES                VERSION        INTERNAL-IP
node-01   Ready    control-plane,etcd   v1.36.4+k3s1   <server-ip>
node-02   Ready    worker               v1.36.4+k3s1   <worker-ip>
```

## Next steps

- **Third node.** When it arrives, install it as a server pointed at the PC:
  ```bash
  curl -sfL https://get.k3s.io | K3S_TOKEN=<token> sh -s - server \
    --server https://<server-ip>:6443
  ```
  Then uninstall the agent on the laptop (`sudo /usr/local/bin/k3s-agent-uninstall.sh`) and reinstall it the same way. Three control planes, actual HA.
- **NAS + NFS storage** for Forgejo and anything else with data I care about.
- **Exposing the portfolio site.** Probably Cloudflare Tunnel rather than port forwarding, so nothing on the home network is open to the internet.
- **Forgejo.**

## Useful stuff

- Server logs: `sudo journalctl -u k3s -f`
- Worker logs: `sudo journalctl -u k3s-agent -f`
- Uninstall server: `sudo /usr/local/bin/k3s-uninstall.sh`
- Uninstall worker: `sudo /usr/local/bin/k3s-agent-uninstall.sh`
- k3s docs: https://docs.k3s.io
