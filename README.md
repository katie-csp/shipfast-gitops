# ShipFast GitOps

A minimal Flask status API (`kkzoo/shipfast-status`) deployed to Kubernetes with Argo CD. **Git is the single source of truth**: application and configuration changes are made by pushing to `main`, never by running `kubectl` against the app.

## Contents

1. [Structure](#structure)
2. [Setup](#setup)
3. [Security decisions](#security-decisions)
4. [Validate the configuration](#validate-the-configuration-before-pushing)
5. [Verify the deployment](#verify-the-deployment)
6. [Troubleshooting](#troubleshooting)
7. [How GitOps handles changes](#how-gitops-handles-changes)
8. [Verification record](#verification-record)

## Structure

```
shipfast-gitops/
├── app/
│   ├── app.py              # Flask API: GET /status and GET /health
│   └── requirements.txt    # Pinned dependencies (Flask, gunicorn)
├── Dockerfile              # Secure multi-stage image build
├── .dockerignore           # Allow-list: only app code enters the image
├── .gitignore              # Keeps venvs, caches, .env files out of git
├── k8s/                    # ← everything Argo CD deploys
│   ├── namespace.yaml      # shipfast namespace, Pod Security "restricted"
│   ├── deployment.yaml     # 2 hardened replicas; holds the image tag
│   ├── service.yaml        # ClusterIP: port 80 → 8080
│   └── kustomization.yaml  # Lists the manifests above
├── argocd/
│   └── application.yaml    # Argo CD Application (applied once, kept outside k8s/)
└── .github/workflows/
    └── ci.yaml             # Build → push to Docker Hub → commit new image tag
```

| File | Purpose |
|---|---|
| `app/app.py` | `GET /status` returns the application name, status and environment as JSON. `GET /health` is a lightweight check for probes. 404/405/500 errors return JSON without exposing internals. |
| `app/requirements.txt` | Exact dependency versions, so every build is reproducible. |
| `Dockerfile` | Builder stage installs dependencies into a virtualenv; the runtime stage copies only that and `app.py`. Runs gunicorn as non-root UID 10001, with a `HEALTHCHECK` on `/health`. |
| `.dockerignore` | Ignores everything except `app/app.py` and `app/requirements.txt`, so new files (secrets, notes) are excluded by default. |
| `k8s/namespace.yaml` | Creates `shipfast` and enforces the *restricted* Pod Security standard. |
| `k8s/deployment.yaml` | 2 replicas, zero-downtime rolling updates, probes, resource limits, non-root security settings. The `image:` line is the deployed version. |
| `k8s/service.yaml` | Stable in-cluster address `shipfast-status.shipfast.svc.cluster.local:80`. |
| `k8s/kustomization.yaml` | The list of manifests Argo CD applies from `k8s/`. |
| `argocd/application.yaml` | Syncs `k8s/` from `main` to the `shipfast` namespace with automated sync, prune and self-heal. |
| `.github/workflows/ci.yaml` | On changes to `app/` or `Dockerfile`: builds, pushes `kkzoo/shipfast-status:<git-sha>`, and commits that tag into `k8s/deployment.yaml`. |

## Setup

Commands are for PowerShell on Windows. Use `curl.exe`, not `curl` (an alias for `Invoke-WebRequest` in Windows PowerShell 5.1).

**Prerequisites:** Docker Desktop, `kubectl`, a cluster with Argo CD installed (here: kind cluster `kind-shipfast`, Argo CD v3.5.5), and a Docker Hub account.

### 1. Test locally

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r app\requirements.txt
python app\app.py                          # http://localhost:8080/status
```

### 2. Build, push and verify the image

```powershell
docker login -u kkzoo                      # paste a Docker Hub access token at the prompt
docker build -t kkzoo/shipfast-status:1.0 .
docker push kkzoo/shipfast-status:1.0

# Prove it pulls from Docker Hub
docker rmi kkzoo/shipfast-status:1.0
docker pull kkzoo/shipfast-status:1.0
```

The image name has three parts: `<docker-hub-user>/<repository>:<tag>`. Never re-push a different build under an existing tag; publish a new version instead.

### 3. Configure GitHub Actions (for automated releases)

1. Docker Hub → Account Settings → **Personal access tokens** → create a token with **Read & Write**.
2. GitHub repo → Settings → Secrets and variables → **Actions** → add:
   - `DOCKERHUB_USERNAME` = `kkzoo`
   - `DOCKERHUB_TOKEN` = the token
3. GitHub repo → Settings → Actions → General → Workflow permissions → **Read and write** (so CI can commit the new image tag).

### 4. Push to GitHub

```powershell
git add .
git commit -m "Describe the change"
git push origin main
```

### 5. Register the app with Argo CD (once)

This is the only manual `kubectl apply` in the project. After this, Argo CD deploys whatever is in git.

```powershell
kubectl config current-context             # kind-shipfast
kubectl -n argocd get pods                 # all Running
kubectl apply -f argocd/application.yaml
kubectl -n argocd get application shipfast-status   # wait for Synced / Healthy
```

> **Private repo?** Register credentials with the Argo CD CLI or UI (`argocd repo add https://github.com/katie-csp/shipfast-gitops.git --username <user> --password <github-token>`). They are stored as a Secret in the cluster, never in this repo.

### Optional: Argo CD web UI

```powershell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" |
  ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
kubectl -n argocd port-forward svc/argocd-server 8443:443
# Open https://localhost:8443, log in as admin, then change the password
```

## Security decisions

### Credentials
| Decision | Reason |
|---|---|
| Docker Hub **access token**, never the account password | Scoped to Read & Write and revocable on its own. |
| `docker login -u kkzoo` with an interactive prompt, never `-p <token>` | The token doesn't end up in shell history. |
| Docker Desktop credential store (`"credsStore": "desktop"`) | The token lives in Windows Credential Manager, not in a plain-text `config.json`. |
| CI uses **GitHub Actions secrets** | Credentials never appear in the repo or its history, and are hidden in CI logs. |
| No `ARG`/`ENV` secrets in the Dockerfile | Anything passed that way can be read back from the image. |
| `.gitignore` and allow-list `.dockerignore` | Local `.env` files can't be committed or copied into the image. |
| Public repo and image | Argo CD and the cluster need no credentials at all. |

### Image (`Dockerfile`)
| Decision | Reason |
|---|---|
| Base pinned by version **and** digest (`python:3.12.15-slim-bookworm@sha256:…`) | Builds are reproducible; a retagged upstream image can't sneak in. |
| Multi-stage build | Build leftovers and the pip cache never reach the final image. |
| `slim` base, pip removed from the app's virtualenv | Smaller image with fewer tools for an attacker. The final image is ~7 MB on top of the base. |
| Non-root user UID 10001, no login shell | A compromised process has no root privileges. |
| `app.py` owned by root, mode `0444` | The app can't modify its own code. |
| gunicorn, not the Flask dev server | Production-grade server; the dev server's debugger is never exposed. |
| `HEALTHCHECK` via Python `urllib` | Works without installing curl. |

### Kubernetes (`k8s/`)
| Decision | Reason |
|---|---|
| Namespace label `pod-security.kubernetes.io/enforce: restricted` | The cluster **rejects** any pod in `shipfast` that isn't hardened, even if a manifest is later weakened. |
| `runAsNonRoot`, `runAsUser: 10001` | Matches the image user; Kubernetes refuses to start the container as root. |
| `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` | No setuid tricks and no Linux capabilities. |
| `readOnlyRootFilesystem: true` with a 64 Mi `/tmp` emptyDir | Only gunicorn's scratch folder is writable. |
| `seccompProfile: RuntimeDefault` | Blocks unusual system calls. |
| `automountServiceAccountToken: false` | The app doesn't call the Kubernetes API, so it gets no token to steal. |
| Requests 50m/96Mi, limits 250m/192Mi | Guaranteed scheduling and a ceiling on runaway usage (measured ~52 MiB in use). |
| `ClusterIP` Service | Not exposed outside the cluster by default. |

### GitOps (`argocd/`)
| Decision | Reason |
|---|---|
| `selfHeal: true` | Manual changes (drift) are reverted automatically. |
| `prune: true` + `PruneLast` | Removing a file from git removes the resource, after everything else is healthy. |
| Application kept outside `k8s/` | Argo CD can't delete or modify its own definition through a sync. |

## Validate the configuration (before pushing)

```powershell
# Dockerfile lint (BuildKit build checks)
docker build --check .

# Build and run with the same restrictions Kubernetes applies
docker build -t kkzoo/shipfast-status:test .
docker run -d --name sf-test -p 8080:8080 --read-only --tmpfs /tmp `
  --cap-drop ALL --security-opt no-new-privileges kkzoo/shipfast-status:test
curl.exe http://localhost:8080/status
curl.exe http://localhost:8080/health
docker inspect --format "{{.State.Health.Status}}" sf-test   # healthy after ~10s
docker exec sf-test id                                        # uid=10001(app)
docker rm -f sf-test

# Kubernetes manifests: render, then validate against the API server (changes nothing)
kubectl kustomize k8s
kubectl apply --dry-run=server -f k8s/namespace.yaml
kubectl apply --dry-run=server -f argocd/application.yaml

# Confirm Argo CD can reach the repo
kubectl -n argocd exec deploy/argocd-repo-server -- git ls-remote https://github.com/katie-csp/shipfast-gitops.git

# Make sure nothing secret is staged
git diff --cached --name-only
```

> A server dry run of the whole `k8s/` folder reports `namespaces "shipfast" not found` for the Deployment and Service on a fresh cluster. This is expected: in a dry run the namespace is never actually created.

## Verify the deployment

### Argo CD is synced and healthy

```powershell
kubectl -n argocd get application shipfast-status
# NAME              SYNC STATUS   HEALTH STATUS
# shipfast-status   Synced        Healthy

# Deployed git commit (should equal: git rev-parse origin/main)
kubectl -n argocd get application shipfast-status -o jsonpath="{.status.sync.revision}"
kubectl -n argocd get application shipfast-status -o jsonpath="{.status.operationState.message}"
```

### Both pods are ready

```powershell
kubectl -n shipfast rollout status deploy/shipfast-status
kubectl -n shipfast get deploy shipfast-status       # READY 2/2
kubectl -n shipfast get pods -o wide                 # 2 pods, 1/1 Running, 0 restarts
```

### The Service has endpoints

```powershell
kubectl -n shipfast get svc shipfast-status
kubectl -n shipfast get endpointslices -l kubernetes.io/service-name=shipfast-status
# Expect two pod IPs, both ready=true
```

### /status returns JSON

```powershell
# From your machine
kubectl -n shipfast port-forward svc/shipfast-status 8080:80
curl.exe -i http://localhost:8080/status    # in a second terminal
# HTTP/1.1 200 OK, Content-Type: application/json
# {"application":"shipfast-status","environment":"production","status":"running"}
curl.exe http://localhost:8080/health       # {"status":"healthy"}

# From inside the cluster, through Service DNS
kubectl run sf-curl -n default --restart=Never --image=curlimages/curl:8.10.1 -- `
  -s http://shipfast-status.shipfast.svc.cluster.local/status
kubectl -n default wait --for=jsonpath="{.status.phase}"=Succeeded pod/sf-curl --timeout=90s
kubectl -n default logs sf-curl
kubectl -n default delete pod sf-curl
```

The test pod runs in `default` because the `restricted` policy in `shipfast` would reject it.

### Self-heal works

```powershell
kubectl -n shipfast scale deploy/shipfast-status --replicas=5
kubectl -n shipfast get deploy shipfast-status -w     # returns to 2 within seconds; Ctrl+C to stop
```

## Troubleshooting

| Symptom | Commands | Common cause / fix |
|---|---|---|
| App `OutOfSync` or `Unknown` | `kubectl -n argocd describe application shipfast-status`<br>`kubectl -n argocd get application shipfast-status -o jsonpath="{.status.conditions}"` | Wrong `repoURL`/`path`/branch, or `main` not pushed. Force a re-read of git: `kubectl -n argocd annotate application shipfast-status argocd.argoproj.io/refresh=hard --overwrite` |
| Sync fails | `kubectl -n argocd get application shipfast-status -o jsonpath="{.status.operationState.message}"`<br>`kubectl -n argocd logs deploy/argocd-repo-server --tail=50`<br>`kubectl -n argocd logs statefulset/argocd-application-controller --tail=50` | Invalid YAML (run `kubectl kustomize k8s`), or the repo is unreachable. |
| `Progressing` / `Degraded` | `kubectl -n shipfast get events --sort-by=.lastTimestamp`<br>`kubectl -n shipfast describe deploy shipfast-status` | Pods failing to start; see below. |
| Pods not created at all | `kubectl -n shipfast describe rs`<br>`kubectl -n shipfast get events` | Look for `violates PodSecurity "restricted"`: a security setting was removed from `deployment.yaml`. |
| `ImagePullBackOff` / `ErrImagePull` | `kubectl -n shipfast describe pod <pod>` | The tag isn't on Docker Hub (`docker pull kkzoo/shipfast-status:<tag>`), or there's a typo in `image:`. |
| `CrashLoopBackOff` | `kubectl -n shipfast logs <pod>`<br>`kubectl -n shipfast logs <pod> --previous` | App error at startup. Reproduce with `docker run` locally. |
| Running but `0/1` READY | `kubectl -n shipfast describe pod <pod>` (Events: `Readiness probe failed`) | `/health` not answering on port 8080. |
| `OOMKilled` | `kubectl -n shipfast describe pod <pod>` (Last State) | Raise `limits.memory` in `deployment.yaml` **via git**. |
| Service has no endpoints | `kubectl -n shipfast get endpointslices -l kubernetes.io/service-name=shipfast-status`<br>`kubectl -n shipfast get pods --show-labels` | Selector doesn't match pod labels, or no pod is ready. |
| port-forward fails / `curl` refused | `kubectl -n shipfast get svc,pods` | Port 8080 already in use locally; use `18080:80` instead. |
| CI run fails at "Log in to Docker Hub" | GitHub → Actions → the failed run | `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` secrets missing or the token was revoked. |
| CI fails at "Update image tag" (push rejected) | GitHub → Actions → the failed run | Workflow permissions aren't set to *Read and write*. |
| Change pushed but not deployed | `git log origin/main -1`<br>`kubectl -n argocd get application shipfast-status -o jsonpath="{.status.sync.revision}"` | Argo CD polls about every 3 minutes; refresh as above. For app code, check CI committed a new tag. |

## How GitOps handles changes

```
 developer                  GitHub Actions                       Argo CD
 ─────────                  ──────────────                       ───────
 edit app/ ─► push main ─► build image ─► push :<sha> ─►
                           commit "image: …:<sha>" to k8s/ ─► detects new commit
                                                              ─► applies k8s/ to cluster
                                                              ─► rolling update, 2 pods always ready
```

| Change | How |
|---|---|
| **New application version** | Edit `app/`, push to `main`. CI builds `kkzoo/shipfast-status:<sha>` and commits the tag; Argo CD rolls it out. |
| **Manual release** (e.g. `1.1`) | `docker build`/`push` the new tag, edit `image:` in `k8s/deployment.yaml`, commit, push. |
| **Configuration** (replicas, env vars, limits, probes) | Edit `k8s/*.yaml`, commit, push. |
| **New resource** | Add the file to `k8s/` and list it in `kustomization.yaml`. |
| **Remove a resource** | Delete it from `k8s/` and `kustomization.yaml`; `prune` removes it from the cluster. |
| **Rollback** | `git revert <deploy commit>` and push. The previous image tag is redeployed. |
| **Manual `kubectl` change** | Reverted by `selfHeal` within seconds. Don't use `kubectl apply/edit/scale/set image` on `shipfast`. |

**Why version tags matter:** a unique tag (`1.0`, or a git SHA) always means one exact build. Changing it is a change in git, which is what triggers Argo CD to deploy, and git history becomes the record of what ran when. Re-pushing `latest` changes nothing in git, so nothing would redeploy, and you couldn't tell which build was running.

## Verification record

Checks run on **2026-10-14** against cluster `kind-shipfast` (Kubernetes v1.37.0, Argo CD v3.5.5), git commit `57539ce`:

| Check | Result |
|---|---|
| `docker build --check` | ✅ No warnings |
| Hardened `docker run` (read-only, no capabilities): `/status`, `/health`, 404 handler, `HEALTHCHECK`, UID | ✅ 200 JSON, 200, 404 JSON, `healthy`, `uid=10001` |
| `kubectl kustomize k8s` and server dry run (Namespace, Deployment, Service, Application) | ✅ Accepted |
| Secret scan of committed files | ✅ No credentials |
| `docker push` → `docker rmi` → `docker pull` of `kkzoo/shipfast-status:1.0` | ✅ Digest `sha256:97b05671…0592d` |
| Argo CD repo-server reaches GitHub | ✅ |
| Application status | ✅ `Synced` / `Healthy`, revision `57539ce`, "successfully synced (all tasks run)" |
| Pods | ✅ 2/2 ready, image `kkzoo/shipfast-status:1.0`, 0 restarts, admitted under `restricted` Pod Security |
| Service endpoints | ✅ 2 endpoints, both `ready=true` |
| `/status` via port-forward and via in-cluster Service DNS | ✅ `200 application/json`, `{"application":"shipfast-status","environment":"production","status":"running"}` |
| Self-heal: `kubectl scale --replicas=5` | ✅ Reverted to 2 in ~3s |
| GitHub Actions run for `57539ce` | ❌ Failed at "Log in to Docker Hub": repository secrets not yet configured (see [Setup step 3](#3-configure-github-actions-for-automated-releases)). The image was published manually, so the deployment was unaffected. |
