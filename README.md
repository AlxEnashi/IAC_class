# IaC class demo: Terraform, Ansible and Helm

One small API, deployed three ways on one AWS machine:

1. **Terraform** creates the network, the machine and a CloudFront URL (HTTPS).
2. **Ansible** configures the machine and runs the API with systemd.
3. **Helm** deploys the same API on k3s (lightweight Kubernetes) on the same machine.

The public URL never changes; what answers on port 80 does.

```
 laptop ──terraform──▶ AWS: VPC ─ subnet ─ EC2 (t3.medium, Amazon Linux 2023) ◀── CloudFront (HTTPS)
        ──ansible────▶ EC2: git, Python, API on :80   ──then──▶ k3s (Traefik on :80)
        ──helm───────▶ k3s API (:6443): phrase-api chart
```

Design details and acceptance criteria are in [`SPEC.md`](SPEC.md).

> **Cost:** this creates billable AWS resources (roughly $0.05 per hour). Run `terraform destroy` when you finish.

## Layout

| Folder | Content |
|---|---|
| `app/` | The API: `main.py`, `requirements.txt`, `Dockerfile` |
| `terraform/` | Root module + modules `network`, `compute`, `cdn` |
| `ansible/` | Playbooks `site.yml`, `k3s.yml`, `helm-prep.yml` and their roles |
| `helm/phrase-api/` | The chart |
| `scripts/` | `make-inventory.sh`: Ansible inventory from Terraform outputs |

## Prerequisites

On your laptop:
- An AWS account and the AWS CLI with credentials that can create VPC, EC2, CloudFront and S3 resources.
- Terraform >= 1.10
- Ansible (ansible-core >= 2.15)
- Helm 3 and kubectl
- An SSH key pair (default `~/.ssh/id_ed25519`): Terraform installs its public key on the machine, and you and Ansible log in with it

## 0. One-time setup

### State bucket
Terraform keeps its state in S3. **Terraform does not create the state bucket**: it must exist before `terraform init`, so create it once by hand.

> **Tip:** bucket names are global across **all** AWS accounts, not per account. A generic name (`demo-terraform-state-bucket`) is probably taken by someone else, and `init` fails with a confusing region error. Put your account ID (or a random suffix) in the name.

```bash
BUCKET=tf-state-$(aws sts get-caller-identity --query Account --output text)
aws s3api create-bucket --bucket $BUCKET --region us-east-1
aws s3api put-bucket-versioning --bucket $BUCKET \
  --versioning-configuration Status=Enabled
echo $BUCKET   # put this name in backend.hcl
```

### Config files
```bash
cd terraform
cp backend.hcl.example backend.hcl            # set your bucket name
cp terraform.tfvars.example terraform.tfvars  # set my_ip_cidr
curl -s https://checkip.amazonaws.com         # your IP; add /32
```

Ansible clones this public repo (over HTTPS, no key) on the machine and runs the app from its `app/` folder. If you change the app, push it to your own fork and set `app_repo_url` in `ansible/group_vars/all.yml`.

## 1. Terraform

Still in `terraform/`. Terraform does **not** read `backend.hcl` by itself; always pass it:

```bash
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
terraform output
```

CloudFront takes a few minutes to deploy after `apply`.

**Check it:**
```bash
ssh ec2-user@$(terraform output -raw public_ip)
free -h      # ~4 GB
nproc        # 2
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-type   # t3.medium
```

From your laptop, port 80 on the public IP is closed (only CloudFront can reach it):
```bash
curl -m 5 http://$(terraform output -raw public_ip)   # times out
```

**Try a change:** add a tag in `terraform/main.tf` or a rule in `modules/compute/main.tf`, then `terraform plan` and `terraform apply`. Only that change is applied.

## 2. Ansible

Run everything from `ansible/` (it picks up `ansible.cfg`).

```bash
../scripts/make-inventory.sh       # SSH_PRIVATE_KEY=... if your key isn't ~/.ssh/id_ed25519
cd ../ansible
ansible all -m ping

ansible-playbook site.yml
```

**Check it:**
```bash
URL=$(terraform -chdir=../terraform output -raw cloudfront_url)
curl $URL/          # {"phrase":"Hello from Ansible"}
curl $URL/health    # {"status":"ok"}
```

**Change the phrase:** edit `api_phrase` in `group_vars/all.yml`, then:
```bash
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
curl $URL/
```
Only the config template changes and the restart handler runs. Run it once more: `changed=0`.

**Hand port 80 to k3s:**
```bash
ansible-playbook k3s.yml
curl $URL/          # 404 page not found (Traefik, nothing deployed yet)
```

## 3. Helm

Prepare the machine: build the image, import it into k3s, and fetch a kubeconfig to `demo/kubeconfig`.

```bash
ansible-playbook helm-prep.yml
cd ..
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes   # Ready
```

```bash
helm lint helm/phrase-api
helm template phrase-api helm/phrase-api      # see the phrase in the ConfigMap
helm upgrade --install phrase-api helm/phrase-api
curl $URL/          # {"phrase":"Hello from Helm"}
```

**Change the phrase:** edit `phrase` in `helm/phrase-api/values.yaml`, then:
```bash
helm upgrade phrase-api helm/phrase-api
kubectl rollout restart deployment/phrase-api   # the app reads its config at startup
kubectl rollout status deployment/phrase-api
curl $URL/
```

## Teardown

```bash
terraform -chdir=terraform destroy
rm -f kubeconfig ansible/inventory/hosts.yml
```

Keep or delete the state bucket.

## Troubleshooting

| Problem | Fix |
|---|---|
| `terraform init` asks for a bucket name | You ran it without `-backend-config=backend.hcl`. |
| `init`: `IllegalLocationConstraintException` | The bucket name belongs to another account (or another region). Use a unique name, then `init -reconfigure -backend-config=backend.hcl`. |
| SSH or kubectl times out | Your public IP changed. Update `my_ip_cidr`, run `terraform apply`. |
| CloudFront returns 502/504 | Nothing is listening on port 80 yet, or CloudFront is still deploying. |
| `site.yml` fails on the git task | Check `app_repo_url` (HTTPS URL of a public repo) and `app_version`. |
| Security group rule limit error | The CloudFront prefix list counts as many rules; ask AWS for a higher "rules per security group" quota. |
| `kubectl`: certificate error | k3s was installed before the public IP was known; uninstall (`/usr/local/bin/k3s-uninstall.sh`) and re-run `k3s.yml`. |

## Notes
- `host_key_checking` is off in `ansible.cfg` because the machine is new each time. Don't copy that to real projects.
- CloudFront → EC2 traffic is plain HTTP; only the viewer side is HTTPS.
- The repo is public, so cloning needs no secret. A private repo would need a read-only deploy key on the machine (e.g. read from SSM).
