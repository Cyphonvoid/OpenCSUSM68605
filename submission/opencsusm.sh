#!/usr/bin/env bash
# CS 446 - OpenCSUSM
# Usage: bash opencsusm.sh <1-8>
set -euo pipefail
export MSYS_NO_PATHCONV=1
export AWS_PAGER=""

# ---- choices ----
LANE="cpu"
LANE_WHY="cpu: new-account G quota is 0 and approval takes hours to days"
REGION="us-east-1"
INSTANCE_TYPE="c7i-flex.large"
MODEL="qwen2.5:0.5b"
PORT=11434
DISK_GB=10
NAME="opencsusm"
KEY_NAME="$NAME"
KEY_FILE="$HOME/.ssh/$NAME.pem"
SG_NAME="$NAME-sg"
AMI_PARAM="/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
G_QUOTA="L-DB2E81BA"
STD_QUOTA="L-1216C47A"
MIN_VCPU=2

aws() { command aws --region "$REGION" "$@"; }

SSH_OPTS=(-i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

for c in aws ssh curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "missing: $c" >&2; exit 1; }
done

find_instances() {
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$NAME" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

running_dns() {
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$NAME" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].PublicDnsName' --output text
}

need_dns() {
  DNS="$(running_dns)"
  if [ -z "$DNS" ] || [ "$(echo "$DNS" | wc -w)" -ne 1 ]; then
    echo "no single running $NAME instance found" >&2
    exit 1
  fi
}

show_quota() {
  aws service-quotas get-service-quota --service-code ec2 --quota-code "$1" \
    --query '{quota:Quota.QuotaName,value:Quota.Value}' --output table 2>/dev/null \
  || aws service-quotas get-aws-default-service-quota --service-code ec2 --quota-code "$1" \
    --query '{quota:Quota.QuotaName,value:Quota.Value}' --output table
}

quota_value() {
  aws service-quotas get-service-quota --service-code ec2 --quota-code "$1" \
    --query 'Quota.Value' --output text 2>/dev/null \
  || aws service-quotas get-aws-default-service-quota --service-code ec2 --quota-code "$1" \
    --query 'Quota.Value' --output text
}

stage1() {
  echo "== stage 1: quota + live price =="
  echo "lane: $LANE ($LANE_WHY)"
  aws sts get-caller-identity --output table
  show_quota "$G_QUOTA"
  show_quota "$STD_QUOTA"
  local v
  v="$(quota_value "$STD_QUOTA")"
  echo "standard vCPU quota: $v (need $MIN_VCPU for $INSTANCE_TYPE)"
  local price
  price="$(aws pricing get-products --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=$INSTANCE_TYPE" \
              "Type=TERM_MATCH,Field=location,Value=US East (N. Virginia)" \
              "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
              "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
              "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
              "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
    --query 'PriceList[0]' --output text 2>/dev/null \
    | grep -o '"USD":"[0-9.]*"' | head -1 | cut -d'"' -f4 || true)"
  echo "$INSTANCE_TYPE on-demand price: ${price:-unavailable} USD/hr"
  if ! awk -v v="$v" -v m="$MIN_VCPU" 'BEGIN{exit !(v+0>=m+0)}'; then
    echo "quota too low for $INSTANCE_TYPE" >&2
    exit 1
  fi
}

stage2() {
  echo "== stage 2: launch =="
  [ -z "$(find_instances)" ] || { echo "an $NAME instance already exists" >&2; exit 1; }
  if [ -n "$(aws ec2 describe-key-pairs --filters "Name=key-name,Values=$KEY_NAME" --query 'KeyPairs[].KeyName' --output text)" ]; then
    echo "key pair $KEY_NAME already exists in AWS; run stage 8 first" >&2; exit 1
  fi
  [ ! -e "$KEY_FILE" ] || { echo "$KEY_FILE already exists; run stage 8 first" >&2; exit 1; }

  local vpc az subnet myip sg ami iid
  vpc="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
  [ "$vpc" != "None" ] && [ -n "$vpc" ] || { echo "no default VPC in $REGION" >&2; exit 1; }
  az="$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
        --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
        --query 'InstanceTypeOfferings[0].Location' --output text)"
  [ "$az" != "None" ] && [ -n "$az" ] || { echo "$INSTANCE_TYPE not offered in $REGION" >&2; exit 1; }
  subnet="$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$vpc" "Name=availability-zone,Values=$az" "Name=default-for-az,Values=true" \
        --query 'Subnets[0].SubnetId' --output text)"
  [ "$subnet" != "None" ] && [ -n "$subnet" ] || { echo "no default subnet in $az" >&2; exit 1; }

  myip="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
  [ -n "$myip" ] || { echo "could not detect public IP" >&2; exit 1; }

  mkdir -p "$HOME/.ssh"
  ( umask 077; aws ec2 create-key-pair --key-name "$KEY_NAME" --query KeyMaterial --output text > "$KEY_FILE" )
  chmod 600 "$KEY_FILE"
  echo "key pair: $KEY_NAME  file: $KEY_FILE"

  sg="$(aws ec2 create-security-group --group-name "$SG_NAME" --description "$NAME ssh only" \
        --vpc-id "$vpc" --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$NAME}]" \
        --query GroupId --output text)"
  aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 22 --cidr "$myip/32" --output text >/dev/null
  echo "security group: $sg  (22 from $myip/32 only)"

  ami="$(aws ssm get-parameter --name "$AMI_PARAM" --query Parameter.Value --output text)"
  echo "ami: $ami"

  iid="$(aws ec2 run-instances --image-id "$ami" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
        --network-interfaces "DeviceIndex=0,AssociatePublicIpAddress=true,SubnetId=$subnet,Groups=$sg" \
        --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$DISK_GB,VolumeType=gp3,DeleteOnTermination=true}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=$NAME},{Key=Name,Value=$NAME}]" \
                             "ResourceType=volume,Tags=[{Key=Project,Value=$NAME}]" \
        --query 'Instances[0].InstanceId' --output text)"
  echo "instance: $iid"
  aws ec2 wait instance-running --instance-ids "$iid"
  need_dns
  echo "ssh -i $KEY_FILE ubuntu@$DNS"
}

wait_ssh() {
  local i
  for i in $(seq 1 30); do
    if ssh "${SSH_OPTS[@]}" "ubuntu@$DNS" true 2>/dev/null; then return 0; fi
    sleep 10
  done
  echo "ssh not reachable" >&2
  exit 1
}

stage3() {
  echo "== stage 3: install ollama =="
  need_dns
  wait_ssh
  ssh "${SSH_OPTS[@]}" "ubuntu@$DNS" \
    "sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl zstd && curl -fsSL https://ollama.com/install.sh | sh && ollama --version"
}

stage4() {
  echo "== stage 4: pull model =="
  need_dns
  ssh "${SSH_OPTS[@]}" "ubuntu@$DNS" \
    "for i in \$(seq 1 30); do curl -sf localhost:$PORT >/dev/null && break; sleep 2; done; ollama pull $MODEL && ollama list && systemctl is-active ollama && curl -s localhost:$PORT"
  echo
}

stage5() {
  echo "== stage 5: copy tunnel command below (run in a SECOND terminal and leave it running) =="
  need_dns
  echo "ssh -i $KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -N -L $PORT:localhost:$PORT ubuntu@$DNS"
}

stage6() {
  echo "== stage 6: curl through the tunnel =="
  local out body
  body="{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"I am John\"}], \"max_tokens\": 20, \"temperature\": 0}"
  echo
  echo "--- live curl command (sent through the tunnel) ---"
  echo "curl -sS localhost:$PORT/v1/chat/completions \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -d '$body'"
  out="$(curl -sS --max-time 180 "localhost:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$body")" \
    || { echo "curl failed; is the tunnel running?" >&2; exit 1; }
  echo
  echo "--- live LLM response (from $MODEL) ---"
  echo "$out"
  echo
  echo "$out" | grep -q "John" || { echo "reply does not contain John" >&2; exit 1; }
}

stage7() {
  echo "== stage 7: stop =="
  local ids
  ids="$(find_instances)"
  [ -n "$ids" ] || { echo "no $NAME instance found" >&2; exit 1; }
  # shellcheck disable=SC2086
  aws ec2 stop-instances --instance-ids $ids --query 'StoppingInstances[].[InstanceId,CurrentState.Name]' --output text
  # shellcheck disable=SC2086
  aws ec2 wait instance-stopped --instance-ids $ids
  aws ec2 describe-instances --instance-ids $ids --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text
}

stage8() {
  echo "== stage 8: delete =="
  local ids sgs i
  ids="$(find_instances)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $ids --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output text
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids $ids
  fi
  aws ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null 2>&1 || true
  rm -f "$KEY_FILE"
  sgs="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" --query 'SecurityGroups[].GroupId' --output text)"
  for sg in $sgs; do
    for i in $(seq 1 18); do
      if aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1; then break; fi
      sleep 10
    done
  done
  echo "-- proof (empty output below means everything is gone) --"
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output text
  aws ec2 describe-volumes --filters "Name=tag:Project,Values=$NAME" \
    --query 'Volumes[].VolumeId' --output text
  aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[].GroupId' --output text
  aws ec2 describe-key-pairs --filters "Name=key-name,Values=$KEY_NAME" \
    --query 'KeyPairs[].KeyName' --output text
  ls "$KEY_FILE" 2>/dev/null || true
}

case "${1:-}" in
  1) stage1 ;;
  2) stage2 ;;
  3) stage3 ;;
  4) stage4 ;;
  5) stage5 ;;
  6) stage6 ;;
  7) stage7 ;;
  8) stage8 ;;
  *) echo "usage: bash $0 <1-8>" >&2; exit 1 ;;
esac
