# SSH hardening

*September 21, 2026*

This is how I lock down SSH on my Ubuntu servers so the only way in is with
my private key. No passwords, no root login, only my user.

What's in this folder:

| File | What it is |
|---|---|
| `00-hardening.conf` | The sshd config drop-in. Copy it to the server. |
| `README.md` | This guide. |

## Before you start

**Keep a second SSH session open (or the physical console) the whole time.**
If you make a mistake, that session is how you fix it. Don't close it until
the last step confirms you can still log in.

In the commands below, replace:

- `admin` with your username on the server
- `<server-ip>` with your server's LAN IP

## 1. Make a key on your workstation

Do this on your laptop or desktop, **not** on the server.

```bash
ssh-keygen -t ed25519 -a 100 -C "admin@homelab"
```

Press Enter to accept the default path (`~/.ssh/id_ed25519`) and set a
passphrase. I use ed25519 instead of RSA because it's smaller, faster, and
has no settings to get wrong.

## 2. Put the public key on the server

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub admin@<server-ip>
```

It asks for your password one last time and adds the key to
`~/.ssh/authorized_keys` on the server.

No `ssh-copy-id` (Windows without Git Bash)? Use this instead:

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh admin@<server-ip> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

## 3. Check that key login works BEFORE turning passwords off

Open a **new** terminal:

```bash
ssh -i ~/.ssh/id_ed25519 admin@<server-ip>
```

It should ask for your key passphrase (if you set one), not your account
password. If it still asks for the account password, stop and check on the
server:

```bash
ls -la ~/.ssh               # .ssh must be 700, authorized_keys must be 600
cat ~/.ssh/authorized_keys  # your public key should be in here
```

Don't go past this step until key login works.

## 4. Edit and install the config

Open `00-hardening.conf` and change the two lines marked `CHANGE ME`:

- `AllowUsers admin` → your username
- `ListenAddress <server-ip>` → your server's LAN IP

Then copy it into place. Run this from inside this folder on the server:

```bash
sudo install -m 644 -o root -g root 00-hardening.conf /etc/ssh/sshd_config.d/00-hardening.conf
```

## 5. Test the config and reload

```bash
sudo sshd -t && echo "config OK"
```

If it prints anything other than `config OK`, fix that first. Then:

```bash
sudo systemctl reload ssh
```

`reload` keeps your current sessions alive. On Ubuntu the service is called
`ssh`, not `sshd`.

## 6. Confirm the settings took effect

```bash
sudo sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication|allowusers|x11forwarding|maxauthtries) '
```

You should see:

```
permitrootlogin no
pubkeyauthentication yes
passwordauthentication no
x11forwarding no
maxauthtries 3
allowusers admin
```

If `passwordauthentication` still says `yes`, the file is sorting after
`50-cloud-init.conf`. Make sure the filename starts with `00-`.

Now open one more **new** session from your workstation and confirm the key
still logs you in. Then prove passwords are really off:

```bash
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password admin@<server-ip>
# expected: Permission denied (publickey).
```

Only now is it safe to close your safety-net session.

## 7. Back up your key

If you lose the private key, you lose SSH access and have to go to the
physical console. Put a copy in a password manager or on an encrypted drive.
Adding a second key (from another laptop, for example) to `authorized_keys`
is a good idea too.

## Copying files between servers after this

Once passwords are off, `scp` from one server to another fails with
`Permission denied (publickey)` unless the source server has its own key.

On the server you'll copy **from**:

```bash
ssh-keygen -t ed25519 -a 100 -C "admin@server-a"
cat ~/.ssh/id_ed25519.pub
```

On the server you'll copy **to**, paste that line into
`~/.ssh/authorized_keys`.

If you saved the key somewhere other than `~/.ssh/id_ed25519`, ssh won't
find it on its own. Either pass `-i /path/to/key` every time, or tell ssh
once in `~/.ssh/config`:

```
Host server-b <server-b-ip>
    HostName <server-b-ip>
    User admin
    IdentityFile ~/path/to/key
    IdentitiesOnly yes
```

After that, `ssh server-b` and `scp file server-b:~/` just work.

The same file works on your workstation too. `~/.ssh/config` is the same on
macOS and Linux (on a Mac that's `/Users/<you>/.ssh/config`). If it doesn't
exist yet:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/config && chmod 600 ~/.ssh/config
```

### macOS: remember the passphrase

Add these two lines to the host block on a Mac and you'll only type the
key's passphrase once:

```
Host server <server-ip>
    HostName <server-ip>
    User admin
    IdentityFile ~/path/to/key
    IdentitiesOnly yes
    AddKeysToAgent yes
    UseKeychain yes
```

`AddKeysToAgent` loads the key into `ssh-agent` on first use, so later
connections don't ask again until you log out or reboot. `UseKeychain`
stores the passphrase in the macOS Keychain, so even after a reboot the
first connection just works.

What gets stored where:

- The **passphrase** goes into the login Keychain
  (`~/Library/Keychains/login.keychain-db`). It's encrypted with your
  macOS login password and only unlocked while you're logged in.
- The **private key itself stays in the file** you made. Keychain never
  holds it. Anyone who gets the file still needs the passphrase.

This is the same place Safari and Wi-Fi keep their passwords. It's fine for
a homelab. If you ever want to forget it:

```bash
ssh-add --delete ~/path/to/key               # unload from the agent
security delete-generic-password -l "SSH: ~/path/to/key" 2>/dev/null
```

## If the host key changed

If you reuse an IP for a new machine, ssh will refuse to connect and warn
that the host key changed. That's expected. Remove the old entry and connect
again:

```bash
ssh-keygen -R <server-ip>
```

## Rollback

Locked out? Log in at the physical console and:

```bash
sudo rm /etc/ssh/sshd_config.d/00-hardening.conf
sudo systemctl reload ssh
```

That puts SSH back to the Ubuntu default with password login on.
