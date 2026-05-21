# Innovate Inc. — Cloud Infrastructure Architecture

## Overview

This document describes the cloud infrastructure design for Innovate Inc.'s web application: a Python/Flask REST API backend, React SPA frontend, and PostgreSQL database. The design is built on **AWS**, uses **Amazon EKS** as the compute platform, and is structured to support growth from hundreds to millions of users while maintaining strong security, operational simplicity, and cost efficiency

---

## 1. Cloud Environment Structure

### Recommendation: Three AWS Accounts

| Account            | Purpose |
|--------------------|---------|
| **Management** | Root of the AWS Organization. Billing consolidation, SCPs, IAM Identity Center (SSO). No workloads run here |
| **Non-Production** | Development and staging environments. Developers iterate here freely without risk to live traffic |
| **Production**     | Live customer-facing workloads only. Tightly locked down, all changes go through CI/CD |

### Justification

**Blast radius isolation** is the primary driver. An IAM misconfiguration, runaway cost, or compromised credential in non-production cannot touch production when the two are separate accounts. AWS account boundaries are the strongest isolation primitive available, stronger than VPCs, IAM policies, or resource tags alone

**Billing clarity** follows naturally. Each account produces its own Cost Explorer data, making it straightforward to attribute spend to environments and set per-account budget alerts

**Compliance posture** is simplified. Sensitive user data lives exclusively in the production account. Audit trails (CloudTrail), security tooling (GuardDuty, Security Hub), and data retention policies can be applied to that account with confidence that non-production activity is categorically separate

**Operational simplicity at startup scale.** Three accounts is the minimum viable multi-account setup, enough to get the isolation benefits without the overhead of a full landing zone with dedicated security, logging, and network accounts. Those can be added later as the organisation grows

---

## 2. Network Design

### VPC Architecture

Each environment (non-production, production) gets its own dedicated VPC. The production VPC layout is described below; non-production mirrors it at a smaller scale

```
Production VPC — 10.0.0.0/16 (3 Availability Zones)

  AZ-A                  AZ-B                  AZ-C
  ─────────────────     ─────────────────     ─────────────────
  Public  10.0.0.0/19   Public  10.0.1.0/19   Public  10.0.2.0/19
  Private 10.0.3.0/19   Private 10.0.4.0/19   Private 10.0.5.0/19
  Data    10.0.6.0/19   Data    10.0.7.0/19   Data    10.0.8.0/19
```

**Three subnet tiers per AZ:**

- **Public subnets** — Internet Gateway, Application Load Balancer, NAT Gateways. Nothing else runs here.
- **Private subnets** — EKS worker nodes and pods. Outbound internet via NAT Gateway; no inbound from internet.
- **Data subnets** — RDS only. No route to the internet in either direction. Reachable only from the private subnet tier.

### Network Security

**Perimeter**
- The ALB sits in public subnets and is the only internet-facing entry point. It terminates TLS (ACM certificates) and forwards HTTP/HTTPS to the EKS ingress controller
- Security groups on the ALB allow 443 inbound from `0.0.0.0/0` and nothing else

**Node layer**
- Worker nodes live in private subnets. Their security group allows inbound only from the ALB security group (on the ingress port) and from the EKS control plane
- All pod-to-pod traffic within the cluster is governed by Kubernetes NetworkPolicies (enforced via the VPC CNI's network policy support). By default all inter-namespace traffic is denied; explicit policies open only what is needed

**Data layer**
- RDS security group allows inbound PostgreSQL (5432) only from the node security group. No other source is permitted
- Data subnets have no NAT Gateway route, even if a node were compromised, it could not initiate outbound connections to the database subnet from the internet

**Additional controls**
- VPC Flow Logs enabled, shipped to CloudWatch Logs and S3 for analysis
- AWS WAF attached to the ALB with managed rule groups (OWASP Top 10, known bad inputs)
- GuardDuty enabled at the organisation level for threat detection across all accounts
- All inter-service traffic inside the cluster uses TLS where supported; secrets (DB credentials, API keys) are stored in AWS Secrets Manager and injected into pods via the External Secrets Operator

---

## 3. Compute Platform

### EKS Cluster Design

One EKS cluster per environment. EKS manages the control plane; worker nodes run in private subnets

**Kubernetes version:** Always the latest available stable release, upgraded on a rolling basis before end-of-support

**Node strategy — two tiers:**

| Tier        | Type                                                           | Purpose |
|-------------|----------------------------------------------------------------|---------|
| System      | Managed node group, Graviton On-Demand (`m7g.medium`) | Runs `kube-system`, Karpenter, monitoring. Stable, never interrupted |
| Application | Karpenter-managed, Graviton + x86 Spot with On-Demand fallback | Runs all application workloads. Scales to zero when idle; expands within seconds when load arrives |

**Karpenter** handles all application node provisioning. Two NodePools are defined:

- `arm64` (weight 100) — Graviton instances (`c`/`m`/`r` families, gen 6+). Preferred for cost and performance
- `x86` (weight 50) — Intel/AMD instances, same families. Fallback when arm64 Spot capacity is unavailable

Both pools use Spot-first capacity with automatic On-Demand fallback, and consolidate underutilised nodes automatically

### Application Deployment

**Backend (Flask API)**
- Deployed as a Kubernetes `Deployment` with a `HorizontalPodAutoscaler` targeting 60% CPU utilisation
- Minimum 2 replicas (one per AZ) for availability; scales up as traffic grows
- Exposed internally via a `ClusterIP` service; the ALB ingress routes `/api/*` to it
- `PodDisruptionBudget` set to `minAvailable: 1` to protect against simultaneous Spot interruptions during scale-down

**Frontend (React SPA)**
- Static assets built at CI time and served from **Amazon CloudFront + S3**. This keeps serving load off the cluster entirely, provides global CDN distribution, and costs a fraction of running an nginx pod for static files
- CloudFront sits in front of both the S3 origin (SPA assets) and the ALB origin (API). A single domain serves both; `/api/*` routes to the ALB, everything else to S3

**Ingress**
- AWS Load Balancer Controller creates and manages an ALB from `Ingress` resources in the cluster
- TLS termination at the ALB; backend communication over HTTP within the VPC

### Containerisation

**Image building**
- Multi-arch builds (`linux/amd64`, `linux/arm64`) using `docker buildx` in the CI pipeline. This ensures images run natively on both x86 and Graviton nodes without emulation overhead
- Images are tagged with the Git commit SHA. `latest` is never used in Kubernetes manifests

**Registry**
- **Amazon ECR** (private) in each account. The production account's ECR is separate from non-production, a pipeline promotion step pushes the validated image across accounts
- ECR image scanning (Trivy-based) runs on every push. Critical vulnerabilities block promotion to production
- ECR lifecycle policies retain the last 30 images per repository and expire untagged images after 7 days

**Deployment process**
- GitOps via **ArgoCD** running inside the cluster. The cluster's desired state is defined in a Git repository; ArgoCD reconciles continuously
- Developers open a pull request → CI runs tests, builds and scans the image, pushes to ECR → on merge, CI updates the image tag in the GitOps repo → ArgoCD detects the change and rolls out a new `RollingUpdate` deployment
- Rollbacks are a `git revert`, ArgoCD reconciles back to the previous image tag within seconds

---

## 4. Database

### Recommendation: Amazon RDS for PostgreSQL (Multi-AZ)

**Justification**

RDS is the right choice for a startup on PostgreSQL. It eliminates operational overhead (patching, replication setup, backup management, failover scripting) so the team can focus on the application. The managed service provides enterprise-grade HA and DR capabilities that would take significant engineering effort to replicate on self-managed PostgreSQL

Aurora PostgreSQL is not recommended at this stage. It is more expensive, and its advantages (storage auto-scaling beyond 64TB, faster failover, global database) are not relevant at Innovate Inc.'s current scale. Migrating from RDS to Aurora later is straightforward if scale demands it

### Instance Sizing

Start with `db.t4g.medium` (Graviton, 2 vCPU, 4GB RAM) in Multi-AZ mode. This is sufficient for hundreds to low thousands of daily users and costs ~$60/month. Vertical scaling requires a maintenance window but no application changes

### High Availability

- **Multi-AZ deployment** — RDS maintains a synchronous standby replica in a second AZ. Failover is automatic and typically completes in 60–120 seconds; the application reconnects via the unchanged DNS endpoint
- **Read replicas** — add one or more read replicas as read traffic grows to offload reporting queries and analytics from the primary

### Backups and Disaster Recovery

| Mechanism         | Configuration                                                  | Recovery |
|-------------------|----------------------------------------------------------------|----------|
| Automated backups | 7-day retention, daily snapshot + continuous transaction logs  | Point-in-time recovery to any second within the retention window |
| Manual snapshots | Taken before every major schema migration                       | Restore to a known-good state before the migration |
| Cross-region snapshot copy | Daily copy to `eu-west-1` (if primary is `eu-west-2`) | Full region failure recovery; RTO ~30 min, RPO ~24h |

**Encryption** — RDS storage encrypted at rest with a customer-managed KMS key. In-transit encryption enforced via `rds.force_ssl=1` parameter group setting; the application's connection string requires SSL

**Credentials** — database password stored in AWS Secrets Manager with automatic rotation every 30 days. The External Secrets Operator syncs the secret into the cluster as a Kubernetes `Secret`, mounted as an environment variable in the backend pods. No credentials in code or container images

---

## 5. CI/CD Pipeline Summary

```
Developer PR
    │
    ▼
GitHub Actions
    ├── Unit tests (pytest / jest)
    ├── docker buildx (amd64 + arm64)
    ├── ECR push (non-prod account)
    ├── ECR image scan (block on critical CVEs)
    └── Integration tests against non-prod cluster
    │
    ▼  (merge to main)
Promote image to prod ECR
    │
    ▼
Update image tag in GitOps repo
    │
    ▼
ArgoCD (production cluster)
    └── RollingUpdate deployment
        └── Automatic rollback on health check failure
```

---

## 6. High-Level Architecture Diagram

See [`diagram.svg`](./diagram.svg) in this folder.

The diagram illustrates:
- The three-account AWS Organisation structure
- Production VPC with public / private / data subnet tiers across three AZs
- CloudFront distribution in front of both S3 (SPA) and ALB (API)
- EKS cluster with system and application node tiers
- RDS Multi-AZ in isolated data subnets
- CI/CD flow from developer commit to live deployment

---

## 7. Cost Considerations

| Component         | Approach                              | Est. starting cost/month |
|-------------------|---------------------------------------|--------------------------|
| EKS control plane | 1 cluster                             | ~$73                     |
| System nodes      | 2× `m7g.medium` On-Demand             | ~$50                     |
| App nodes         | Karpenter Spot (scales to 0 at night) | ~$20–80                  |
| RDS               | `db.t4g.medium` Multi-AZ              | ~$60                     |
| ALB               | Per-hour + LCU                        | ~$20                     |
| CloudFront + S3   | Low traffic tier                      | ~$5                      |
| NAT Gateways      | 3× (one per AZ)                       | ~$100                    |
| **Total**         |                                       | **~$330–400/month**      |

NAT Gateways are the dominant cost at low scale. If budget is a concern, a single NAT Gateway (sacrificing AZ redundancy for egress) reduces this to ~$35/month

---

## 8. Growth Path

The architecture is designed to scale without redesign:

- **Compute** — Karpenter adds nodes within 60 seconds; HPA scales pods before nodes are needed. No manual intervention required up to hundreds of nodes
- **Database** — add read replicas for read scaling; migrate to Aurora PostgreSQL for storage beyond 64TB or sub-second failover requirements
- **Frontend** — CloudFront scales globally with zero configuration changes
- **Accounts** — add a dedicated `security` account (centralised logging, SIEM) and a `network` account (Transit Gateway, shared VPCs) as the team and compliance requirements grow
- **Multi-region** — the ALB + CloudFront + RDS cross-region replica foundation is already in place; active-passive multi-region can be enabled without re-architecting