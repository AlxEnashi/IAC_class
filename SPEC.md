# Demo spec

What the demo builds, how each part behaves, and what "done" means. The code in this folder follows this spec; `README.md` explains how to run it.

Decisions referenced as `Dxx` are in `../docs/decisions.md`.

## 1. Goal

One small API, deployed three ways on one AWS machine:

1. **Terraform** creates the infrastructure (network, machine, CDN).
2. **Ansible** configures the machine and runs the API directly (systemd).
3. **Helm** deploys the same API on k3s, on the same machine.

The public URL (CloudFront, HTTPS) never changes. What answers on port 80 changes (D22).

## 2. Folder layout

```
demo/
  README.md            how to run it in your own AWS account
  SPEC.md              this file
  app/                 the Python API + Dockerfile
  terraform/           infrastructure (root module + local modules)
  ansible/             machine configuration (playbooks + roles)
  helm/phrase-api/     the chart
  scripts/             small helpers (inventory from terraform output)
```

The app also lives in a **private git repo** that Ansible clones (D32). People running the demo push `demo/app/` to their own private repo.

## 3. The app

| Item | Spec |
|---|---|
| Language | Python 3.11 (installed by Ansible as `python3.11` on Amazon Linux 2023) |
| Framework | FastAPI + uvicorn |
| Structure | **One file** (`main.py`), one `APIRouter` with the two routes |
| `GET /` | `{"phrase": "<phrase from config>"}` |
| `GET /health` | `{"status": "ok"}` |
| Config | YAML file, path from `CONFIG_PATH` (default `/etc/phrase-api/config.yaml`), one key: `phrase` |
| Config load | Read **once at startup**. A change needs a restart (Ansible handler / `kubectl rollout restart`, D40) |
| Port | From `PORT` (host: 80, container: 8000) |
| Dockerfile | `python:3.12-slim`, non-root user, port 8000 |

## 4. Terraform

### Resources
- **Network** (module `network`): VPC `10.0.0.0/16`, one public subnet `10.0.1.0/24` in one AZ, internet gateway, route table with `0.0.0.0/0 → IGW` (D14).
- **Compute** (module `compute`):
  - AMI: latest **Amazon Linux 2023 x86_64**, read from the public SSM parameter (data source, no hardcoded ID) (D29).
  - `aws_instance`: `t3.medium` (D17), 20 GB gp3 root volume (Docker image + k3s), IMDSv2 required.
  - `aws_key_pair` from the presenter's local SSH public key.
  - `aws_eip` attached to the instance (D24).
  - Security group:
    - 22 from `my_ip_cidr` only (D15).
    - 80 from the CloudFront origin-facing managed prefix list only (D15).
    - 6443 (Kubernetes API) from `my_ip_cidr` only, so Helm runs from the laptop (O1).
    - All egress.
- **CDN** (module `cdn`): CloudFront distribution (D13, D23).
  - Origin: the EIP's public DNS name, HTTP only, port 80.
  - Viewer: redirect HTTP to HTTPS, default `*.cloudfront.net` certificate.
  - Cache policy **CachingDisabled**, so a phrase change shows immediately.
  - Price class 100 (cheapest).

### Inputs (`variables.tf`)
| Variable | Default | Notes |
|---|---|---|
| `region` | `us-east-1` | |
| `project` | `iac-class` | name prefix and tag |
| `instance_type` | `t3.medium` | |
| `my_ip_cidr` | none (required) | e.g. `203.0.113.10/32` |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` | |

Values go in `terraform.tfvars` (not committed; an example file is).

### Outputs
`public_ip`, `public_dns`, `cloudfront_url`, `ssh_command`, `instance_id`.

### State
S3 backend with `use_lockfile = true` (D8, D9). The bucket is created by hand before `init` and passed with `-backend-config=backend.hcl` (not committed; an example file is).

### Versions
Terraform >= 1.10, AWS provider `~> 6.0`.

### Done when
- `terraform apply` succeeds from zero; `terraform plan` right after shows no changes.
- SSH works from `my_ip_cidr` and is refused from anywhere else.
- Port 80 on the EIP is refused directly; reachable only through CloudFront.
- On the machine: `free -h` shows ~4 GB, `nproc` shows 2, instance type is `t3.medium` (D16).
- `terraform destroy` removes everything.

## 5. Ansible

### Inventory
Generated from `terraform output` by `scripts/make-inventory.sh` into `ansible/inventory/hosts.yml` (not committed). User `ec2-user`.

### Playbooks
| Playbook | When | What |
|---|---|---|
| `site.yml` | live, Part 2 | roles `base` + `api` |
| `k3s.yml` | live, end of Part 2 | stop the API, install k3s |
| `helm-prep.yml` | off-screen, before Part 3 (D43) | Docker, build image, import into k3s, fetch kubeconfig |

### Roles
- **base**: `git` with `ansible.builtin.package: state=present` (the demo's bash-vs-module example, D27).
- **api**:
  - Fail early if `deploy_key_path` is not passed (D35).
  - Copy the key from the laptop to `/home/ec2-user/.ssh/deploy_key` (`0600`, `no_log`). The key stays on the host (D35).
  - `ansible.builtin.git` clone of `app_repo_url` at `app_version` with `key_file`.
  - `python3.11` + venv + `pip install -r requirements.txt`.
  - Template `/etc/phrase-api/config.yaml` from `api_phrase`; notifies the restart handler.
  - systemd unit `phrase-api.service`: runs as `ec2-user`, `PORT=80`, `AmbientCapabilities=CAP_NET_BIND_SERVICE` (D30).
  - Handler: restart `phrase-api`.
- **k3s**:
  - Stop and disable `phrase-api`.
  - Install k3s with the official script, guarded by `creates: /usr/local/bin/k3s` (the justified `shell` exception, D27), with `--tls-san <EIP>` so the laptop can reach the API.
  - Traefik (bundled) takes port 80.
- **image** (off-screen): install Docker; `docker build -t phrase-api:1.0` from the cloned repo; `docker save | k3s ctr images import -` (D42). Fetch the kubeconfig to `demo/kubeconfig` (server address set to the EIP).

### Variables
| Variable | Where | Notes |
|---|---|---|
| `app_repo_url` | `group_vars/all.yml` | SSH URL of your private repo |
| `app_version` | `group_vars/all.yml` | branch or tag |
| `api_phrase` | `group_vars/all.yml` | the phrase |
| `deploy_key_path` | **`-e` only** | required, never in a file (D35) |

### Done when
- `site.yml` run twice: second run has `changed=0`.
- `https://<cloudfront>/` returns the phrase; `/health` returns ok.
- Changing `api_phrase` + `--check --diff` shows only the template change; a real run changes the template and runs the handler.
- After `k3s.yml`: `phrase-api` is stopped, `kubectl get nodes` shows `Ready`, CloudFront returns Traefik's 404.

## 6. Helm

### Chart `phrase-api`
- **Deployment**: 1 replica, image `phrase-api:1.0`, `imagePullPolicy: IfNotPresent` (D42), container port 8000, readiness and liveness on `/health`, ConfigMap mounted at `/etc/phrase-api`.
- **Service**: ClusterIP, port 80 → 8000.
- **Ingress**: class `traefik`, no host rule, path `/` (so the CloudFront host header doesn't matter).
- **ConfigMap**: `config.yaml` with `phrase: {{ .Values.phrase | quote }}`.
- No config-checksum annotation: restart is a separate step (D40).

### `values.yaml`
`phrase`, `replicaCount`, `image.repository`, `image.tag`, `image.pullPolicy`, `service.port`.

### Done when
- `helm lint` passes; `helm template` shows the phrase in the ConfigMap.
- After `helm upgrade --install`, CloudFront returns the Helm phrase.
- After editing the phrase, `helm upgrade` + `kubectl rollout restart` → CloudFront returns the new phrase.

## 7. Runbook summary

| Stage | Steps |
|---|---|
| Before class | Create state bucket; deploy key pair + register it on the repo; `terraform apply`; check CloudFront is deployed |
| Part 1 live | Walk files; small change → `plan` → `apply`; SSH checks |
| Part 2 live | `make-inventory.sh`; `ansible all -m ping`; `site.yml`; open URL; change phrase; rerun; `k3s.yml` |
| Off-screen | `helm-prep.yml` |
| Part 3 live | Walk chart; `lint` / `template`; `upgrade --install`; open URL; edit phrase; `upgrade` + `rollout restart` |
| After class | `terraform destroy`; delete the deploy key from the repo and locally |

## 8. Cost (approximate, check current AWS pricing)
- `t3.medium` on demand: about $0.04/hour.
- Elastic IP (public IPv4): about $0.005/hour.
- 20 GB gp3: a few cents per day.
- CloudFront: negligible at demo traffic.
- A few hours of demo and rehearsal costs well under $5. Destroy right after.

## 9. Security notes (say them in class)
- SSH open only to one IP; port 80 only to CloudFront.
- CloudFront → EC2 is plain HTTP (D23).
- The deploy key is read-only, disposable, and deleted after class.
- `terraform.tfvars`, `backend.hcl`, the inventory and any key files are git-ignored.

## 10. Resolved questions
- O1 → **Terraform, Ansible and Helm all run from the laptop.** Port 6443 open to `my_ip_cidr`.
- O2 → `us-east-1`.
- O3 → FastAPI, single file, one router.

## 11. Former open questions (for reference)
- **O1. Where does Helm run?** (a) On the laptop: open 6443 to `my_ip_cidr`, install k3s with `--tls-san <EIP>`, fetch the kubeconfig. Edit `values.yaml` locally, as with Ansible. (b) On the EC2 over SSH, chart copied there by Ansible. No extra port, but editing happens in a remote terminal. **Proposed: (a).**
- **O2. Region default**: `us-east-1`, or the one you normally use?
- **O3. Framework**: FastAPI + uvicorn proposed; Flask is the alternative.
