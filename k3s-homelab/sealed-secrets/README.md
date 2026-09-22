# Sealed Secrets: keeping secrets in a public GitOps repo

My homelab cluster is managed from a public GitHub repo ([homelab33](https://github.com/jddemonteverde/homelab33)). Argo CD watches `main` and applies whatever is there, so every file I commit is both live in the cluster and visible to the whole internet. That's fine for Deployments and Ingresses. It is not fine for Forgejo's `SECRET_KEY`, database passwords, or anything else that has to reach a pod as a Kubernetes `Secret`.

This is how I solved that with Sealed Secrets: what it is, why I picked it over the alternatives, how the controller gets installed through Argo CD, and the exact commands I use to turn a plaintext value into something I can commit.

## The problem

A Kubernetes `Secret` is not secret. The `data:` field is base64, which is encoding, not encryption. Committing one is the same as committing the password. Creating the Secret by hand with `kubectl` doesn't work either: it isn't reproducible when I rebuild the cluster, and it's exactly the kind of "changed the cluster outside git" that I set the repo up to avoid.

What I wanted:

- secrets defined in git, next to the app that uses them
- encrypted, so the public repo leaks nothing
- decryption that happens only inside the cluster, with no key on my laptop to protect

## How Sealed Secrets works

Two pieces:

1. **A controller in the cluster.** On first start it generates an RSA key pair and stores it as a `Secret` in `kube-system`. The private key never leaves the cluster.
2. **`kubeseal`, a CLI on my laptop.** It takes a normal `Secret` manifest, fetches the controller's *public* certificate, and encrypts every value. The output is a `SealedSecret` custom resource.

I commit the `SealedSecret`. Argo CD applies it. The controller sees it, decrypts it with the private key, and creates the real `Secret` with the same name in the same namespace. The pod reads that `Secret` like any other and never knows it was sealed.

```
laptop                                     cluster
──────                                     ───────
plaintext Secret (stdin only)
      │
      ▼
kubeseal ──── fetch public cert ─────────▶ sealed-secrets-controller
      │                                            │  (holds the private key)
      ▼                                            │
SealedSecret ──▶ git ──▶ Argo CD ──▶ apply ──▶ controller decrypts
                                                   │
                                                   ▼
                                            Secret ──▶ pod (secretKeyRef)
```

The encryption is hybrid: every value gets its own random AES-256-GCM key, and that key is wrapped with the controller's RSA public key (OAEP, SHA-256). By default a sealed value is also bound to the namespace and name of the Secret it's meant for ("strict" scope), so nobody can take a ciphertext meant for `forgejo/forgejo-security` and unseal it as `default/oops`.

## Why Sealed Secrets and not something else

- **SOPS + age.** Also encrypts files in git, but decryption happens where the manifests are rendered. The age private key has to be available to Argo CD's repo server through a plugin (KSOPS, helm-secrets) and to anyone who needs to read or edit a secret locally. That's one more key to protect and one more moving part in Argo. Sealed Secrets keeps the private key in exactly one place.
- **External Secrets Operator.** Pulls secrets from Vault, AWS Secrets Manager, 1Password and friends. Great when you already run one of those. I don't, and standing up Vault to hold three passwords is silly.
- **Secrets by hand.** Works until you rebuild the cluster and can't remember what was in them. Also breaks the "everything is in git" rule.

Sealed Secrets is one controller, one CLI, no external service, and the thing in git is genuinely safe to publish. Good enough for a homelab, and plenty of people run it in production.

## Installing the controller (through Argo CD)

Nothing in my cluster is installed by hand except the two bootstrap Applications, so the controller is installed like everything else: an Argo CD `Application` that pulls the upstream Helm chart. The three files are in this folder; in the real repo they live at `infra/sealed-secrets/`.

```
.
├── README.md            <- you are here
├── application.yaml     Argo CD Application: chart + values
├── values.yaml          the one Helm value I override
└── kustomization.yaml   lists application.yaml so the parent picks it up
```

### `application.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sealed-secrets
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://bitnami.github.io/sealed-secrets
      chart: sealed-secrets
      targetRevision: 2.20.0
      helm:
        releaseName: sealed-secrets
        valueFiles:
          - $values/infra/sealed-secrets/values.yaml
    - repoURL: https://github.com/jddemonteverde/homelab33.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Things worth knowing:

- **Two sources.** The first is the Helm chart, pinned to `2.20.0` (controller `0.40.0`). The second is my own repo, checked out only so the chart can read `values.yaml` from it through `$values/...`. Values stay in git as a normal file instead of being inlined in the Application.
- **`finalizers`.** When this Application is deleted, Argo CD deletes everything it created before removing the Application itself. Without it you'd orphan the controller.
- **`kube-system`.** That's where `kubeseal` looks for the controller by default. It can live anywhere, but then every `kubeseal` call needs `--controller-namespace`.
- **`prune` + `selfHeal`.** Resources that disappear from the chart output get deleted; manual `kubectl edit` drift gets reverted.

### `values.yaml`

```yaml
fullnameOverride: sealed-secrets-controller
```

The chart names its resources after the Helm release (`sealed-secrets`). `kubeseal` looks for a Service called `sealed-secrets-controller`. Overriding the name means `kubeseal` works with no flags at all.

### `kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - application.yaml
```

The parent `infra/kustomization.yaml` lists `- sealed-secrets`, Kustomize descends into the folder, and this file says the folder holds one object. Enabling or disabling the whole component is one line in the parent.

### Turn it on

Add the folder to `infra/kustomization.yaml`, commit, push:

```bash
printf '  - sealed-secrets\n' >> infra/kustomization.yaml
kubectl kustomize infra >/dev/null && echo OK
git add infra/kustomization.yaml
git commit -m "chore(sealed-secrets): enable controller"
git push origin main
```

Argo CD polls every three minutes. Then:

```bash
kubectl -n argocd get application sealed-secrets              # Synced / Healthy
kubectl -n kube-system get deploy sealed-secrets-controller   # 1/1
kubectl get crd sealedsecrets.bitnami.com
```

## Back up the private key. Now.

The controller generated its key pair on first start, and it exists in exactly one place: a `Secret` in `kube-system`. If the cluster dies and the key goes with it, every `SealedSecret` in git becomes garbage. There is no recovery. So the first thing to do after the controller is up:

```bash
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > ~/Documents/sealed-secrets-key-backup.yaml
```

Put it in a password manager or on an encrypted disk. Not in the repo, obviously.

The controller mints a **new** key every 30 days and keeps the old ones, so old sealed secrets keep working and new ones use the newest key. The label selector above grabs all of them; re-run the backup every so often. To restore on a rebuilt cluster, `kubectl apply` the backup before the controller starts (or restart the controller afterwards). It finds existing keys by that label.

## `kubeseal` on the laptop

```bash
brew install kubeseal
kubeseal --version
```

That's all. It reads the same kubeconfig as `kubectl`, so if `kubectl get nodes` works, `kubeseal` works. CLI and controller versions don't have to match; I sealed with `kubeseal` 0.36 against controller 0.40 and it just worked.

### You don't need a copy of the public key

This confused me, because none of the commands below fetch a certificate. `kubeseal` does it implicitly every time it runs without `--cert`: it looks up the `sealed-secrets-controller` Service in `kube-system` and calls, through the API server's service proxy,

```
/api/v1/namespaces/kube-system/services/http:sealed-secrets-controller:/proxy/v1/cert.pem
```

then uses the cert in memory and throws it away. Nothing is written to disk. `kubeseal --fetch-cert` prints exactly what it would fetch.

A saved copy is only useful when you're away from the LAN (the cluster isn't reachable, so the implicit fetch fails) or to let someone seal without kubeconfig access. It's a public cert, so it's safe to keep anywhere:

```bash
kubeseal --fetch-cert > ~/Documents/sealed-secrets-cert.pem
# later, offline:
kubeseal --cert ~/Documents/sealed-secrets-cert.pem --format yaml < secret.yaml
```

## Sealing a secret

The example is real. Forgejo needs a `SECRET_KEY`; skip its web installer without providing one and it silently falls back to a hardcoded default. Mine comes from a `Secret` called `forgejo-security` in the `forgejo` namespace.

### 1. Generate and seal in one pipe

```bash
kubectl create secret generic forgejo-security -n forgejo \
  --from-literal=SECRET_KEY="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > apps/forgejo/manifests/secrets/forgejo-security.yaml
```

Every part matters:

- `openssl rand -hex 32` makes a 64-character random string. I never see it, and it never lands in shell history (only the literal text `$(openssl rand -hex 32)` does).
- `kubectl create secret ... --dry-run=client -o yaml` only *prints* a Secret manifest; it doesn't talk to the cluster. Forget `--dry-run=client` and you've just created a real, unencrypted Secret in the cluster.
- The pipe means the plaintext manifest exists only in memory between the two commands. Only `kubeseal`'s encrypted output is redirected to a file.

If the value is a password you have to type, keep it off the command line, because zsh saves it in `~/.zsh_history`:

```bash
read -s PW           # type it, nothing is echoed
kubectl create secret generic myapp-db -n myapp \
  --from-literal=PASSWORD="$PW" --dry-run=client -o yaml \
  | kubeseal --format yaml > apps/myapp/manifests/secrets/myapp-db.yaml
unset PW
```

`--from-file=KEY=/path/outside/the/repo` works too.

### 2. Look at what you got

```bash
cat apps/forgejo/manifests/secrets/forgejo-security.yaml
```

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: forgejo-security
  namespace: forgejo
spec:
  encryptedData:
    SECRET_KEY: AgB4k...   # long base64 blob
  template:
    metadata:
      name: forgejo-security
      namespace: forgejo
```

`kind: SealedSecret`, values under `encryptedData`, and no `data:` or `stringData:` anywhere. `template` is what the controller uses to build the real Secret. `kubeseal` prints a leading `---` that I strip so the file looks like the rest of the repo.

### 3. Validate

```bash
kubeseal --validate < apps/forgejo/manifests/secrets/forgejo-security.yaml
```

This sends the sealed file to the controller, which test-decrypts it and answers OK. Nothing is stored. It catches "sealed against the wrong cluster" before it reaches git.

### 4. Wire it in

Sealed secrets live next to the app, one per file, in `apps/<app>/manifests/secrets/`:

```yaml
# apps/forgejo/manifests/secrets/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - forgejo-security.yaml
```

The app's `manifests/kustomization.yaml` lists `- secrets`. The workload references the Secret by name, never by value:

```yaml
# apps/forgejo/manifests/deployment.yaml (excerpt)
env:
  - name: GITEA__security__SECRET_KEY
    valueFrom:
      secretKeyRef:
        name: forgejo-security
        key: SECRET_KEY
```

### 5. Check, commit, push

```bash
kubectl kustomize apps/forgejo/manifests >/dev/null && echo OK
grep -rn 'kind: Secret$' apps infra bootstrap    # must print nothing
git add apps/forgejo/manifests
git commit -m "feat(forgejo): add sealed SECRET_KEY"
git push origin main
```

Commit the `SealedSecret` and the Deployment that uses it **together**. Push the Deployment alone and the pod sits in `CreateContainerConfigError` until the Secret exists. Not fatal (it recovers by itself once the Secret appears), but pointless downtime.

### 6. Watch it land

```bash
kubectl -n forgejo get sealedsecret forgejo-security   # SYNCED True
kubectl -n forgejo get secret forgejo-security         # created by the controller
kubectl -n forgejo rollout status deploy/forgejo
```

Don't `kubectl get secret -o yaml` and paste the output anywhere. That's the plaintext again.

## Day-two stuff

- **Changing a value.** Re-run the pipe (it replaces the file, so include every key), or add/replace a single key with `... | kubeseal --format yaml --merge-into apps/forgejo/manifests/secrets/forgejo-security.yaml`. The controller updates the Secret, but pods only read env vars at startup, so they need a restart. In GitOps that's a change to the pod template (bump an annotation), not `kubectl rollout restart`.
- **Renaming, or moving to another namespace.** Strict scope means the old ciphertext won't decrypt under the new identity. Re-seal.
- **Plaintext got committed.** Rotate the value and re-seal. Rewriting git history doesn't un-publish anything.
- **Key rotation.** Automatic every 30 days, old keys kept. Re-run the backup command.

## Uninstalling leaves two things behind

I removed and reinstalled the controller once. Unlisting `- sealed-secrets` from `infra/kustomization.yaml` and pushing made Argo CD prune the Application and cascade-delete the Deployment, Services and RBAC. Two objects survived, because Argo CD only cascade-deletes resources that carry its tracking annotation, and neither of these does:

- the `sealedsecrets.bitnami.com` CRD
- the controller's key `Secret` in `kube-system` (the controller created it, not the chart)

Both are harmless to leave. The key surviving is actually a feature: reinstall the controller and it picks the existing key back up, so previously sealed secrets keep working. For a genuinely clean slate:

```bash
kubectl -n kube-system delete secret -l sealedsecrets.bitnami.com/sealed-secrets-key
kubectl delete crd sealedsecrets.bitnami.com
```

Deleting the key makes every existing `SealedSecret` undecryptable. Make sure that's what you want.

## A note on what's safe to publish

| Thing | Safe in a public repo? |
|---|---|
| `SealedSecret` manifests (`encryptedData`) | Yes, that's the whole point |
| The controller's public cert (`kubeseal --fetch-cert`) | Yes, it can only encrypt |
| The three Argo CD files in this folder | Yes |
| The key backup (`sealed-secrets-key*`) | **Never** |
| A plain `Secret`, `--dry-run` output, or `kubectl get secret -o yaml` | **Never** |

## Useful stuff

- Project: https://github.com/bitnami-labs/sealed-secrets
- Helm chart: https://github.com/bitnami-labs/sealed-secrets/tree/main/helm/sealed-secrets
- Controller logs: `kubectl -n kube-system logs deploy/sealed-secrets-controller`
- Every sealed secret in the cluster: `kubectl get sealedsecrets -A`
- The repo this comes from: https://github.com/jddemonteverde/homelab33
