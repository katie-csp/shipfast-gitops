# ShipFast GitOps

A minimal Flask API deployed to Kubernetes with Argo CD. **Git is the single source of truth**: you never run `kubectl apply` for app changes — you push to `main`, and the pipeline + Argo CD do the rest.

## Structure

```
shipfast-gitops/
├── app/
│   ├── app.py              # Flask API: GET /status and GET /health
│   └── requirements.txt    # Pinned Python dependencies (Flask, gunicorn)
├── Dockerfile              # Secure multi-stage image build
├── .dockerignore           # Keeps git history, manifests, secrets out of the image
├── .gitignore              # Keeps venvs, caches, .env files out of git
├── k8s/
│   ├── namespace.yaml      # shipfast namespace with Pod Security 'restricted'
│   ├── deployment.yaml     # Runs 2 hardened replicas; holds the image tag CI updates
│   ├── service.yaml        # Stable ClusterIP endpoint for the pods
│   └── kustomization.yaml  # Lists the manifests Argo CD applies
├── argocd/
│   └── application.yaml    # Tells Argo CD to sync k8s/ from this GitHub repo
└── .github/workflows/
    └── ci.yaml             # Builds/pushes image to Docker Hub, commits new tag
```

## What each file does

| File | Purpose |
|---|---|
| `app/app.py` | The API. `GET /status` returns the application name, status and environment. `GET /health` is a lightweight check used by the Kubernetes probes. Errors come back as JSON. |
| `app/requirements.txt` | Exact dependency versions so every build is reproducible. |
| `Dockerfile` | **Stage 1** installs dependencies into a virtualenv. **Stage 2** copies only that venv + `app.py` into a fresh slim image — no pip cache or build leftovers. Runs as non-root UID 10001 with read-only app code, served by gunicorn (not the Flask dev server). |
| `.dockerignore` | Limits the build context so `.git`, `.env` files and manifests never end up in the image. |
| `.gitignore` | Prevents local secrets (`.env`) and junk from being committed. |
| `k8s/namespace.yaml` | Creates the `shipfast` namespace and enforces the Kubernetes *restricted* Pod Security standard, so any non-hardened pod is rejected. |
| `k8s/deployment.yaml` | Deployment of `kkzoo/shipfast-status:<tag>` (2 replicas, zero-downtime rolling updates) with readiness/liveness probes on `/health`, CPU/memory limits, `runAsNonRoot`, read-only root filesystem, all Linux capabilities dropped, no privilege escalation, no service-account token mounted. |
| `k8s/service.yaml` | ClusterIP Service: port 80 → container port 8080. |
| `k8s/kustomization.yaml` | Lists the manifests in this folder that Argo CD applies. |
| `argocd/application.yaml` | Argo CD Application watching `k8s/` on `main`. `automated` sync deploys every commit; `prune` deletes resources removed from git; `selfHeal` reverts any manual `kubectl` edits. |
| `.github/workflows/ci.yaml` | On changes to `app/` or `Dockerfile`: builds the image, pushes `kkzoo/shipfast-status:<git-sha>` (and `:latest`) to Docker Hub, then commits the new tag into the `image:` line of `k8s/deployment.yaml`. That commit is what triggers a deployment. |

## One-time setup

The image is published as **`kkzoo/shipfast-status`** on Docker Hub.

1. **Create a Docker Hub access token** (Docker Hub → Account Settings → Personal access tokens, Read & Write). Do *not* use your password.
2. **Add GitHub secrets** (repo → Settings → Secrets and variables → Actions):
   - `DOCKERHUB_USERNAME` = `kkzoo`
   - `DOCKERHUB_TOKEN` = the access token
3. **Allow the workflow to push** (repo → Settings → Actions → General → Workflow permissions → *Read and write*).
4. **Push this repo**, wait for the first image build, then register the app with Argo CD (the only manual `kubectl` you ever run):
   ```bash
   kubectl apply -f argocd/application.yaml
   ```

> If the GitHub repo is private, add it to Argo CD with `argocd repo add https://github.com/katie-csp/shipfast-gitops.git --username <user> --password <github-token>` — credentials are stored as a Secret in the cluster, never in this repo.

## Publishing the image to Docker Hub manually

Use this for the first release (`1.0`) or to publish a version by hand. After that, CI publishes images automatically.

### 1. Log in securely

```powershell
docker login -u kkzoo
```

When prompted for a password, paste a **Docker Hub personal access token**, not your account password. Docker Desktop stores it in Windows Credential Manager (`"credsStore": "desktop"` in `~/.docker/config.json`), not in a plain-text file.

**Never:**
- put the token in a command (`docker login -p <token>`), because it ends up in your shell history;
- write it into a `Dockerfile`, `.env`, script or any file in this repo;
- bake it into the image with `ARG` or `ENV`.

A token can be scoped (Read & Write only) and revoked on its own without changing your password. If a token is ever exposed, revoke it in Docker Hub immediately.

### 2. Build and tag

```powershell
docker build -t kkzoo/shipfast-status:1.0 .
docker images kkzoo/shipfast-status
```

The image name has three parts: `<docker-hub-user>/<repository>:<tag>`.

### 3. Push

```powershell
docker push kkzoo/shipfast-status:1.0
```

### 4. Verify it can be pulled

Delete the local copy so the pull really comes from Docker Hub, then run what was downloaded:

```powershell
docker rmi kkzoo/shipfast-status:1.0
docker pull kkzoo/shipfast-status:1.0
docker run -d --name sf-verify -p 8080:8080 kkzoo/shipfast-status:1.0
curl.exe http://localhost:8080/status
curl.exe http://localhost:8080/health
docker rm -f sf-verify
```

You can also check the repository page at https://hub.docker.com/r/kkzoo/shipfast-status.

### Why version tags matter

- **You know exactly what's running.** `1.0` always means the same build. `latest` is just a moving label that points to whatever was pushed most recently.
- **Kubernetes only redeploys when the tag changes.** If the manifest says `latest` and you push a new `latest`, nothing in git changes, so Argo CD has nothing to sync and running pods keep the old image. A new tag such as `1.1` is a change in git, so it triggers a rollout.
- **Rollbacks are one line.** To go back, set the `image:` tag in `k8s/deployment.yaml` back to the previous version and commit.
- **Git history doubles as an audit trail.** Every deploy is a commit that names the exact image version.

**Tagging conventions:**
- **Semantic versions** (`1.0`, `1.1`, `2.0`) are for releases people refer to.
- **Git commit IDs** (what CI pushes) link each image to the exact code that built it.

Never re-push a different build under an existing version tag. Publish a new version instead.

## The GitOps flow

```
edit app/app.py ─► git push ─► GitHub Actions builds & pushes image:<sha>
                                         │
                                         ▼
                       commits image tag <sha> to k8s/deployment.yaml
                                         │
                                         ▼
                 Argo CD detects the commit ─► syncs cluster to match git
```

- **App change?** Edit `app/`, push. CI ships it.
- **Config change (replicas, limits, env)?** Edit `k8s/`, push. Argo CD applies it.
- **Rollback?** `git revert` the deploy commit and push.
- **Manual `kubectl edit`?** Argo CD's `selfHeal` reverts it — git always wins.

## Run locally

```bash
pip install -r app/requirements.txt
python app/app.py
curl http://localhost:8080/status

# or with Docker
docker build -t kkzoo/shipfast-status:dev .
docker run --rm -p 8080:8080 kkzoo/shipfast-status:dev
```

## Argo CD: configure and verify

`argocd/application.yaml` is kept **outside** `k8s/`. Argo CD only syncs `k8s/`, so it never manages (or prunes) its own definition. This is the only file you ever apply with `kubectl`.

| Setting | Value | Why |
|---|---|---|
| `repoURL` | `https://github.com/katie-csp/shipfast-gitops.git` | Public repo, so no credentials are needed |
| `targetRevision` | `main` | Every commit to `main` is deployed |
| `path` | `k8s` | Folder holding `kustomization.yaml` and the manifests |
| `destination.namespace` | `shipfast` | Matches `k8s/namespace.yaml` |
| `automated.prune` | `true` | Resources deleted from git are deleted from the cluster |
| `automated.selfHeal` | `true` | Manual `kubectl` changes are reverted to match git |
| `retry` | 5 attempts, 10s → 3m backoff | Rides out temporary failures (e.g. image not pushed yet) |
| `finalizers` | `resources-finalizer…` | Deleting the Application also removes what it deployed |

### 1. Register the application (once)

```powershell
kubectl config current-context             # should be kind-shipfast
kubectl -n argocd get pods                 # Argo CD components Running
kubectl apply -f argocd/application.yaml
```

### 2. Verify the sync

```powershell
# Expect SYNC STATUS = Synced and HEALTH STATUS = Healthy
kubectl -n argocd get application shipfast-status

# Which git commit is deployed, plus any sync errors
kubectl -n argocd get application shipfast-status -o jsonpath="{.status.sync.revision}"
kubectl -n argocd get application shipfast-status -o jsonpath="{.status.operationState.message}"

# The workloads Argo CD created
kubectl -n shipfast get deploy,rs,pods,svc
kubectl -n shipfast rollout status deploy/shipfast-status

# Call the API through the Service
kubectl -n shipfast port-forward svc/shipfast-status 8080:80
curl.exe http://localhost:8080/status     # in a second terminal
curl.exe http://localhost:8080/health
```

### 3. Optional: Argo CD web UI

```powershell
# Initial admin password (printed only to your terminal; change it after first login)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" |
  ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }

kubectl -n argocd port-forward svc/argocd-server 8443:443
# Open https://localhost:8443 and log in as admin
```

### 4. Prove that git is the source of truth

```powershell
kubectl -n shipfast scale deploy/shipfast-status --replicas=5
kubectl -n shipfast get deploy shipfast-status -w   # selfHeal returns it to 2 within seconds
```

Argo CD checks git about every 3 minutes. To check right away, run:
`kubectl -n argocd annotate application shipfast-status argocd.argoproj.io/refresh=normal --overwrite`
(This only re-reads git; it does not deploy anything git doesn't already say.)

### Making changes

| Change | How |
|---|---|
| New app version | Edit `app/`, push to `main`. CI builds the image and commits the new tag; Argo CD deploys it. |
| Replicas, env vars, limits | Edit `k8s/*.yaml`, push to `main`. |
| Manual release | Push the image, change the `image:` tag in `k8s/deployment.yaml`, commit and push. |
| Rollback | `git revert <deploy commit>` and push. |

Never use `kubectl apply/edit/scale/set image` on `shipfast` resources; selfHeal will undo it.
