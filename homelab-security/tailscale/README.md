# Remote SSH over Tailscale

*September 29, 2026*

This is how I reach my homelab server from anywhere without opening a
single port on my router. At home I still SSH in over the LAN. Away from
home I go through Tailscale. Both routes end up at the same SSH server,
with the same key and the same hardening from `../ssh/`.

```
At home  ->  LAN        ->  <server-ip>:22     ->  sshd
Away     ->  Tailscale  ->  <tailscale-ip>:22  ->  the same sshd
```

Nothing in this guide removes or changes the LAN route. If Tailscale is
ever down, LAN SSH keeps working.

## Why regular SSH and not Tailscale SSH

Tailscale has a built-in SSH feature that logs you in with your Tailscale
identity instead of a key. I turned it off and kept my normal `sshd`:

- **Two locks instead of one.** To get in, you need to be on my tailnet
  *and* have my SSH key. With Tailscale SSH, anyone who got into my
  Tailscale account would be straight in.
- **The hardening stays in charge.** Keys only, no root, `AllowUsers`,
  `MaxAuthTries`. All of that keeps applying to the Tailscale route.
- **One SSH setup, not two.** Same server, same key, same logs.

## Before you start

Do `../ssh/` and `../firewall/` first. This guide builds on the
`00-hardening.conf` from the SSH part.

**Keep a second SSH session open the whole time**, same as before. Don't
close it until the tests at the end pass.

Replace these in the commands below:

- `admin` with your username on the server
- `<server-ip>` with your server's LAN IP
- `<tailscale-ip>` with your server's Tailscale IP (step 1 shows it)
- `homelab` with your server's machine name in Tailscale

## 1. Install Tailscale on the server

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4
```

`tailscale up` prints a login link. Open it and sign in with the account
you'll use on your laptop. `tailscale ip -4` prints the server's Tailscale
IP. It stays the same for as long as the machine is on your tailnet.

## 2. Turn off Tailscale SSH, turn on auto-updates

```bash
sudo tailscale set --ssh=false
sudo tailscale set --auto-update
```

- `--ssh=false` turns off Tailscale's own SSH feature. When it's on,
  Tailscale takes over port 22 on the Tailscale IP and your `sshd` never
  sees those connections. This does **not** touch your normal SSH server.
- `--auto-update` keeps Tailscale patched. Ubuntu's unattended-upgrades
  only installs Ubuntu's security updates, not packages from Tailscale's
  repo.

## 3. Write the access policy

In the Tailscale admin console, go to **Access controls** and open the JSON
editor. Mine looks like this:

```json
{
    "tagOwners": {
        "tag:homelab": ["autogroup:admin"]
    },
    "acls": [
        {
            "action": "accept",
            "src":    ["autogroup:admin"],
            "dst":    ["autogroup:admin:*"]
        }
    ],
    "ssh":    [],
    "grants": [
        {
            "src": ["autogroup:member"],
            "dst": ["tag:homelab"],
            "ip":  ["tcp:22"]
        }
    ]
}
```

What each part does:

- **`tagOwners`** declares the `tag:homelab` tag. Tailscale won't let you
  put a tag on a machine until it's declared here. Only an admin can use it.
- **The grant** lets my own devices reach anything tagged `tag:homelab` on
  port 22, and nothing else. k3s listens on 6443 and 10250 on every
  interface, but the tailnet can't reach them.
- **The `acls` rule** lets my own devices (laptop, desktop) keep reaching
  each other. Leave it out if you don't need that. The server isn't
  covered by it once it's tagged (next step), so it doesn't open anything
  extra on the server.
- **`"ssh": []`**: no Tailscale SSH rules, because we're not using it.

If you're replacing Tailscale's default policy, know that the default lets
every device reach every other device on every port. This one is much
stricter.

Save the policy **before** the next step.

## 4. Tag the server and turn off key expiry

In the admin console, go to **Machines** → `homelab` → **⋯** →
**Edit ACL tags** and add `tag:homelab`.

Then **⋯** → **Disable key expiry**.

- **Why tag it:** a tagged machine belongs to the tailnet, not to your user.
  The grant from step 3 now applies to it, and the server can't open
  connections to your other devices. If the server were ever broken into,
  it couldn't use Tailscale to reach your laptop.
- **Why turn off key expiry:** Tailscale keys expire after 180 days by
  default. When the server's key expires, it drops off the tailnet. If
  you're away from home when that happens, you have no way in. I expected
  tagging to turn off expiry by itself, but for me it didn't, so check that
  the machine shows **Expiry disabled**.

On the server, check the tag took effect:

```bash
tailscale status --json | grep -A2 '"Tags"'
```

It should list `tag:homelab`.

## 5. Make sshd listen on the Tailscale IP too

The `ListenAddress` line in `00-hardening.conf` limits sshd to the LAN IP,
so right now it ignores anything that arrives over Tailscale.

### Let sshd bind to the Tailscale IP even at boot

```bash
echo 'net.ipv4.ip_nonlocal_bind = 1' | sudo tee /etc/sysctl.d/60-nonlocal-bind.conf
sudo sysctl --system
```

At boot, sshd usually starts before Tailscale has its IP. Normally sshd
would then skip that address, and the Tailscale route would be dead until
you restarted sshd. This setting lets sshd claim the address before it
exists.

### Add the second ListenAddress

```bash
sudo sed -i '/^ListenAddress <server-ip>$/a ListenAddress <tailscale-ip>' /etc/ssh/sshd_config.d/00-hardening.conf
grep ListenAddress /etc/ssh/sshd_config.d/00-hardening.conf
```

You should see exactly:

```
ListenAddress <server-ip>
ListenAddress <tailscale-ip>
```

The LAN line stays first and untouched.

### Test and restart

```bash
sudo sshd -t && sudo systemctl restart ssh
ss -tlnp | grep ':22 '
```

`sshd -t` catches typos before they can lock you out. Restarting doesn't
drop sessions that are already open. You should see two listening lines,
one for each address.

## 6. Open the firewall on the Tailscale interface

```bash
sudo ufw status numbered
sudo ufw allow in on tailscale0 to any port 22 proto tcp comment 'SSH via Tailscale'
```

The firewall from `../firewall/` only allows SSH from the LAN.
Tailscale usually adds its own iptables rules ahead of UFW's, so its
traffic gets through anyway, but I don't want to depend on that. This adds
a rule. It doesn't change the LAN rule.

## 7. Set up your laptop

Install the Tailscale app and sign in with the **same account** as the
server.

Then add two entries to `~/.ssh/config`, one for each route:

```
Host homelab-lan
    HostName <server-ip>
    User admin

Host homelab-ts
    HostName <tailscale-ip>
    User admin
```

If your key isn't at the default path, add the `IdentityFile` and
`IdentitiesOnly` lines from `../ssh/README.md` to both entries.

I use the same key for both routes. sshd checks the key, not which network
you came in on. I thought about a separate key just for Tailscale, but both
routes come from the same laptop, so it wouldn't add much.

The first time you run `ssh homelab-ts`, ssh asks you to trust the host.
It's a new address for a server ssh already knows. Before typing `yes`,
compare the fingerprint with the one on the server:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

## 8. Test it

**At home**, both should work:

```bash
ssh homelab-lan
ssh homelab-ts
```

**Only port 22 is open over Tailscale.** This should fail or time out:

```bash
nc -vz -G 3 <tailscale-ip> 6443    # macOS; on Linux use -w 3
```

A normal `ping` to the Tailscale IP fails too. That's expected. Use
`tailscale ping homelab` to check the connection.

**Reboot test.** Run `sudo reboot` on the server, wait a minute or two,
then try both routes again. If `homelab-ts` fails after a reboot, the
`ip_nonlocal_bind` setting from step 5 isn't in place.

**Away test.** Put your laptop on your phone's hotspot:

```bash
ssh homelab-ts     # works
ssh homelab-lan    # fails, as expected: your LAN isn't reachable from outside
```

## Security checklist

What this setup gets you:

- **Nothing is open to the internet.** No port forwarding on the router,
  and no Tailscale Funnel or Serve. Traffic between your laptop and the
  server goes through Tailscale's encrypted tunnel, usually straight
  between the two machines.
- **Only port 22 reaches the server over Tailscale.**
- **The server can't start connections to your other devices.**
- **Two locks:** tailnet membership plus your SSH key.

What's still up to you:

- **Turn on 2FA for the account you sign in to Tailscale with** (Google,
  GitHub, whichever). Anyone who can sign in as you can add a device to
  your tailnet. After that, only your SSH key is left in the way.
- **Remove devices you don't use** under Machines. Every device signed in
  with your account can reach the server's port 22.
- **Put a passphrase on your SSH key.** Your laptop holds both locks now.
  Check with `ssh-keygen -y -f ~/.ssh/id_ed25519`. If it prints the
  public key without asking for a passphrase, add one with
  `ssh-keygen -p -f ~/.ssh/id_ed25519`. The key stays the same, so the
  server doesn't need any changes.
- **Optional:** Settings → Device management → **Manually approve new
  devices**. Then a new device can't join your tailnet until you approve
  it.

## Day to day

```
At home:  ssh homelab-lan
Away:     ssh homelab-ts
```

Don't:

- forward port 22 on your router
- use `tailscale funnel`, which puts a service on the public internet

## Rollback

To remove the Tailscale route and leave LAN SSH exactly as it was:

```bash
sudo sed -i '/^ListenAddress <tailscale-ip>$/d' /etc/ssh/sshd_config.d/00-hardening.conf
sudo sshd -t && sudo systemctl restart ssh
sudo ufw delete allow in on tailscale0 to any port 22 proto tcp
sudo rm /etc/sysctl.d/60-nonlocal-bind.conf && sudo sysctl -w net.ipv4.ip_nonlocal_bind=0
sudo tailscale down
```

Then delete the machine under **Machines** in the admin console if you're
done with Tailscale for good.
