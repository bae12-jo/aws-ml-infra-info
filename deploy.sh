#!/bin/bash
# Deploy info-app to EC2 via SSM (primary) or SSH (fallback)
# Usage: ./deploy.sh [--no-rebuild]

set -euo pipefail

INSTANCE_ID="i-096b2f7f722312546"
HOST="ubuntu@44.196.79.203"
KEY="$HOME/Downloads/pcluster-test.pem"
REMOTE_DIR="/home/ubuntu/info-app"
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/info-app"
S3_BUCKET="pcluster-gpu-monitoring-804633700004"
REGION="us-east-1"
NO_REBUILD=${1:-""}
ALB_DNS="ml-infra-info-alb-1145223156.us-east-1.elb.amazonaws.com"
DOMAIN="ml-infra.csbailey.people.aws.dev"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $KEY"

echo "=== Uploading to S3 ==="
AWS_PROFILE=bailey-ai aws s3 sync "$LOCAL_DIR/" \
  "s3://$S3_BUCKET/info-app/" --region "$REGION" \
  --exclude ".omc/*" --exclude "*.pyc" --exclude "__pycache__/*"

# ── Deploy via SSM (works even when outbound internet is blocked) ──
echo "=== Deploying via SSM ==="
if NO_REBUILD_FLAG=""; [ "$NO_REBUILD" = "--no-rebuild" ] && NO_REBUILD_FLAG="true"; then
  COMMANDS='["sudo docker restart info-app && echo restarted"]'
else
  COMMANDS="[
    \"/usr/local/bin/aws s3 sync s3://$S3_BUCKET/info-app/ $REMOTE_DIR/ --region $REGION --exclude '.omc/*'\",
    \"cd $REMOTE_DIR && sudo docker rm -f info-app 2>/dev/null || true\",
    \"cd $REMOTE_DIR && sudo docker build --no-cache -t info-app:latest . 2>&1 | tail -3\",
    \"sudo docker run -d --name info-app --restart unless-stopped -p 8000:8000 -e AWS_DEFAULT_REGION=$REGION info-app:latest\",
    \"sleep 5 && curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/info/\"
  ]"
fi

CMD_ID=$(AWS_PROFILE=bailey-ai aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --timeout-seconds 300 \
  --parameters "{\"commands\":$COMMANDS}" \
  --query 'Command.CommandId' --output text 2>/dev/null) || {
  # SSM unavailable — fallback to SSH
  echo "SSM unavailable, trying SSH..."
  scp $SSH_OPTS "$LOCAL_DIR/main.py" "$LOCAL_DIR/requirements.txt" \
    "$LOCAL_DIR/Dockerfile" "$HOST:$REMOTE_DIR/"
  scp $SSH_OPTS "$LOCAL_DIR/templates/index.html" "$HOST:$REMOTE_DIR/templates/"
  if [ "$NO_REBUILD" = "--no-rebuild" ]; then
    ssh $SSH_OPTS $HOST "sudo docker restart info-app"
  else
    ssh $SSH_OPTS $HOST "cd $REMOTE_DIR && \
      sudo docker rm -f info-app 2>/dev/null || true && \
      sudo docker build --no-cache -t info-app:latest . 2>&1 | tail -3 && \
      sudo docker run -d --name info-app --restart unless-stopped -p 8000:8000 \
        -e AWS_DEFAULT_REGION=$REGION info-app:latest"
  fi
  CMD_ID=""
}

if [ -n "$CMD_ID" ]; then
  echo "SSM CMD: $CMD_ID — waiting..."
  sleep 180
  STATUS=$(AWS_PROFILE=bailey-ai aws ssm get-command-invocation \
    --region "$REGION" --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' --output text 2>/dev/null | tail -3)
  echo "$STATUS"
fi

echo "=== Verifying via ALB ==="
sleep 10
ALB_IP=$(dig +short $ALB_DNS | head -1)
HTTP_CODE=$(curl -s --resolve "$DOMAIN:443:$ALB_IP" \
  -o /dev/null -w "%{http_code}" \
  "https://$DOMAIN/info/" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ https://$DOMAIN/info/"
else
  echo "✗ HTTP $HTTP_CODE"
  echo "  Check: aws ssm get-command-invocation --command-id $CMD_ID --instance-id $INSTANCE_ID --region $REGION"
  exit 1
fi
