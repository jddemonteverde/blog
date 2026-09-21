# Homelab server security

This is how I secure my Ubuntu servers at home before they run anything
important. There are two parts, and they need to be done in this order:

1. **SSH** — only my key can log in. No passwords, no root.
2. **Firewall** — block everything inbound except what the server needs.

The order matters. The firewall only allows SSH from the LAN, so SSH has to
be working properly first. Otherwise a mistake means fixing it at the
physical console.

## Folders

```
.
├── README.md         <- you are here
├── ssh/
│   ├── README.md          step-by-step guide
│   └── 00-hardening.conf  the sshd config to install
└── firewall/
    ├── README.md          guide and flag reference
    └── firewall.sh        the script that sets up UFW
```

Each folder has its own `README.md` that walks through the steps. Start with
`ssh/README.md`, then `firewall/README.md`.

## Why I did this

When I first checked my server, UFW was off and SSH accepted passwords on
both its LAN IPv4 and a public IPv6 address. The router happened to block
inbound IPv6, but I didn't want the server to depend on that. These two
changes are the baseline everything else builds on.

## Quick version

If you've done this before and just need the commands:

```bash
# --- SSH (from your workstation) ---
ssh-keygen -t ed25519 -a 100 -C "admin@homelab"
ssh-copy-id -i ~/.ssh/id_ed25519.pub admin@<server-ip>
ssh admin@<server-ip>          # must log in with the key, not a password

# --- SSH (on the server, inside the ssh/ folder) ---
#     edit 00-hardening.conf first: set AllowUsers and ListenAddress
sudo install -m 644 -o root -g root 00-hardening.conf /etc/ssh/sshd_config.d/00-hardening.conf
sudo sshd -t && sudo systemctl reload ssh

# --- Firewall (on the server, inside the firewall/ folder) ---
sudo ./firewall.sh --dry-run
sudo ./firewall.sh --server      # or --agent, or --no-k3s
```

After each step, open a **new** SSH session to make sure you still get in
before closing the one you kept as a safety net.

## What's not here

These come after the baseline and aren't covered in this repo yet:

- Remote access over VPN (Tailscale or WireGuard) instead of LAN-only SSH
- Exposing apps publicly: Cloudflare Tunnel vs port-forwarding 80/443
- fail2ban, sysctl hardening, removing unused services
- k3s install flags, Pod Security Standards, NetworkPolicies

## A note on what's safe to publish

Everything in here is config and scripts. There are no keys, tokens, or
passwords. If you fork this, keep it that way — never commit
`~/.ssh/id_*`, `authorized_keys`, or a k3s node token.
