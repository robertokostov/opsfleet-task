# EKS + Karpenter — Infrastructure POC

This repository provisions a production-ready EKS cluster on AWS with:

- A dedicated VPC (3 AZs, public + private subnets, per-AZ NAT gateways)
- EKS 1.36.1 with core add-ons (VPC-CNI, CoreDNS, kube-proxy, EKS Pod Identity Agent)
- A small system-only managed node group (Graviton On-Demand) for kube-system and Karpenter itself
- Karpenter with two NodePools — one for **x86 (amd64)** and one for **Graviton (arm64)**
- Spot-first capacity strategy with automatic On-Demand fallback
- SQS-based Spot interruption handling wired to EventBridge

---

## Prerequisites

| Tool      | Minimum version |
|-----------|-----------------|
| Terraform | 1.15            |
| AWS CLI   | 2.x             |
| kubectl   | 2.4+            |
| Helm      | 3.x             |

Your AWS credentials must have permissions to create IAM roles, EKS clusters, EC2 resources, SQS queues, and EventBridge rules

---

## Quick start

```bash
# 1. Clone and enter the repo
git clone <repo-url>
cd terraform

# 2. Configure variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars, at minimum set aws_region and cluster_name.

# 3. Initialise providers
terraform init

# 4. Review the plan
terraform plan

# 5. Apply (takes ~15 minutes)
terraform apply
```

After a successful apply Terraform prints a `configure_kubectl` output. Run it to update your local kubeconfig:

```bash
aws eks update-kubeconfig --region eu-west-1 --name startup-eks
```

Verify the system nodes are ready:

```bash
kubectl get nodes -L kubernetes.io/arch,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
```

---

## Repository layout

```
terraform/
├── README.md                # This README file
├── main.tf                  # Root — wires modules together
├── variables.tf             # All input variables with defaults
├── outputs.tf               # Useful outputs (cluster name, kubeconfig command)
├── providers.tf             # AWS / Helm / kubectl provider config
├── versions.tf              # Provider and Terraform version constraints
├── terraform.tfvars.example # Copy to terraform.tfvars and fill in
│
├── modules/
│   ├── vpc/                 # Dedicated VPC, subnets, NAT gateways, route tables
│   ├── eks/                 # EKS control plane, OIDC, add-ons, system node group
│   └── karpenter/           # IAM, SQS, EventBridge, Helm chart, EC2NodeClass, NodePools
│
└── examples/
    └── deploy-flexible.yaml # No pin, Karpenter picks cheapest (prefers Graviton)
```

---

## How Karpenter works in this setup

Two **NodePools** are deployed after Karpenter installs:

| NodePool | Architecture      | Preferred capacity | Weight  |
|----------|-------------------|--------------------|---------|
| `arm64`  | Graviton (arm64)  | Spot → On-Demand   | **100** |
| `x86`    | Intel/AMD (amd64) | Spot → On-Demand   | 50      |

Both pools reference a single **EC2NodeClass** (`default`) that:
- Uses the AL2023 AMI family (automatically selects the right AMI per architecture)
- Tags subnets and security groups with `karpenter.sh/discovery: <cluster-name>`
- Enforces IMDSv2 (`httpTokens: required`)
- Provisions a 50 GiB encrypted gp3 root volume

When a pod is pending and no suitable node exists, Karpenter selects a NodePool, picks the cheapest compatible instance type (usually a Graviton Spot), and has a node ready in ~60–90 seconds

---

## Developer guide — targeting specific hardware

### Run on Graviton (arm64 / best price-performance)

```yaml
# examples/deploy-arm64.yaml
nodeSelector:
  kubernetes.io/arch: arm64
```

Your container image **must** support `linux/arm64`. Build multi-arch images with:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t <your-registry>/my-app:latest \
  --push .
```

Apply the example:

```bash
kubectl apply -f examples/deploy-arm64.yaml
kubectl get pods -o wide   # NODE column will show a Graviton instance
kubectl get nodes -L kubernetes.io/arch
```

### Run on x86 (amd64)

Use this when you have a binary-only x86 image or a dependency that doesn't support arm64 yet

```yaml
# examples/deploy-x86.yaml
nodeSelector:
  kubernetes.io/arch: amd64
```

```bash
kubectl apply -f examples/deploy-x86.yaml
```

### Let Karpenter decide (cheapest available)

Don't set a `nodeSelector`. Karpenter will prefer the arm64 NodePool (weight 100) and pick the cheapest Spot instance across all Graviton families. Your image must be a multi-arch manifest

```bash
kubectl apply -f examples/deploy-flexible.yaml
```

### Watch Karpenter in action

```bash
# Stream Karpenter controller logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f

# Watch nodes appear as pods are scheduled
kubectl get nodes -w

# See which NodePool and instance type each node belongs to
kubectl get nodes \
  -L karpenter.sh/nodepool \
  -L kubernetes.io/arch \
  -L karpenter.sh/capacity-type \
  -L node.kubernetes.io/instance-type
```

### Force a specific Spot/On-Demand type

Add a second `matchExpression` alongside the arch selector:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]   # pin to On-Demand for critical workloads
```

---

## Spot interruption handling

Karpenter watches an SQS queue for EC2 Spot interruption warnings (2-minute notice). When a warning arrives it:

1. Cordons the affected node (no new pods scheduled there)
2. Launches a replacement node
3. Drains the interrupted node — pods migrate automatically

For stateful workloads use `PodDisruptionBudgets` to control how many pods can be disrupted simultaneously:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: my-app
```

---

## Tear down

Remove Karpenter-managed nodes first, then destroy Terraform resources:

```bash
kubectl delete --all nodeclaim
kubectl delete --all nodepool
kubectl delete --all ec2nodeclass

terraform destroy
```

---

## Notes and known considerations

- **Public API endpoint** — `endpoint_public_access = true` is set for convenience during the POC. Flip it to `false` and add a VPN or bastion once you're past the demo phase
- **State backend** — the POC uses local state. For a team, add an S3 backend with DynamoDB locking before sharing the repo
- **Spot availability** — Spot capacity varies by region and AZ. The NodePools allow a wide range of instance families so Karpenter can find capacity even during tight periods
- **Multi-arch images** — the most common issue when moving to Graviton is discovering that an image is amd64-only. Check with `docker manifest inspect <image>` before deploying to the arm64 NodePool