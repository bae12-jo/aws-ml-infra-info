# AWS ML Infra Info

AMI & container version reference + compatibility checker for AWS GPU clusters (ParallelCluster, HyperPod).

## Live

**https://ml-infra.csbailey.people.aws.dev/info/**

<!-- Add screenshot or demo gif here -->

## What it does

- **AMI & Container Compatibility Check** — Select a platform (ParallelCluster or HyperPod), version, and region. The tool recommends the default AMI, shows the full SW stack (NVIDIA Driver, CUDA, EFA, NCCL, cuDNN, etc.), and flags what needs to be installed post-boot.
- **ParallelCluster & HyperPod Releases** — Latest versions with default AMI IDs per OS.
- **AMI Browser** — pcluster official AMIs + AWS DLAMI versions with SW specs parsed from release notes.
- **Container Browser** — AWS DLC (Deep Learning Containers) and NGC containers with full SW stack (CUDA, cuDNN, NCCL, EFA installer, TransformerEngine, FlashAttention).

## Deploy your own

### Prerequisites

Upload app source to S3:

```bash
S3_BUCKET=your-bucket
aws s3 sync info-app/ s3://$S3_BUCKET/info-app/ --region us-east-1
```

### Deploy stack (HTTP or HTTPS)

```bash
aws cloudformation create-stack \
  --region us-east-1 \
  --stack-name ml-infra \
  --template-body file://infrastructure.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=KeyPairName,ParameterValue=<YOUR_KEYPAIR> \
    ParameterKey=S3Bucket,ParameterValue=$S3_BUCKET \
    ParameterKey=AllowedWebCidr,ParameterValue=<YOUR_IP>/32 \
    ParameterKey=AllowedSSHCidr,ParameterValue=<YOUR_IP>/32
    # For HTTPS: ParameterKey=CertificateArn,ParameterValue=arn:aws:acm:...
```

Wait ~10 min. The `AppURL` stack output has the URL.

### Update app

```bash
bash deploy.sh           # rebuild (required for code/template changes)
bash deploy.sh --no-rebuild  # restart container only
```

### AWS internal accounts (Isengard)

Publicly accessible endpoints without authentication trigger automatic shutdown by Epoxy/DyePack.
Set `AllowedWebCidr` to your IP (`<YOUR_IP>/32`) — not `0.0.0.0/0`.

The stack includes VPC endpoints for SSM and S3 so the instance can pull updates even when outbound internet is restricted.

## Directory structure

```
infrastructure.yaml   CloudFormation — VPC + EC2 + ALB + VPC endpoints
deploy.sh             Deploy script (SSM-first, SSH fallback)
info-app/
  main.py             FastAPI app
  requirements.txt
  Dockerfile
  templates/
    index.html        UI
```
