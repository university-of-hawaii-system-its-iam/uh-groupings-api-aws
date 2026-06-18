#!/usr/bin/env bash
# aws/setup.sh - AWS setup script for UH Groupings API.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly DEFAULT_ENV_FILE="${SCRIPT_DIR}/.env"
readonly ECR_TEMPLATE_PATH="${SCRIPT_DIR}/cloudformation/ecr-repository.yml"
readonly ECS_TEMPLATE_PATH="${SCRIPT_DIR}/cloudformation/ecs-cluster.yml"

ENV_FILE_LOADED=""
AWS_ACCOUNT_ID=""
ECR_REPOSITORY_URI=""
ALB_URL=""

usage() {
    cat <<EOF
Usage: ./aws/setup.sh

Environment Variables:
  ENV_FILE        Path to the env file to load (default: aws/.env)
  AWS_REGION      AWS region to deploy to (default: us-west-2)
  AWS_ENV         Deployment environment (default: sandbox)
                   Options: sandbox, development, test, production
  AWS_PROJECT_ID  AWS project identifier (required)
  PROJECT_NAME    Project display name (defaults to AWS_PROJECT_ID)
  NON_INTERACTIVE Set to any value to skip confirmation prompts
  VPC_ID          Existing VPC ID to use for ECS deployment
  SUBNET_IDS      Comma-separated subnet IDs to use for ECS deployment
  DESIRED_COUNT   Desired ECS task count (default: 2)
EOF
}

log() {
    printf '%s\n' "$1"
}

error() {
    printf 'Error: %s\n' "$1" >&2
}

parse_args() {
    if [[ $# -gt 0 ]]; then
        error "Unknown option: $1"
        usage
        exit 1
    fi
}

load_env_file() {
    local env_file="${ENV_FILE:-${DEFAULT_ENV_FILE}}"
    local non_interactive_was_set=false
    local aws_region_was_set=false
    local aws_env_was_set=false
    local aws_project_id_was_set=false
    local project_name_was_set=false
    local desired_count_was_set=false
    local vpc_id_was_set=false
    local subnet_ids_was_set=false

    local original_non_interactive=""
    local original_aws_region=""
    local original_aws_env=""
    local original_aws_project_id=""
    local original_project_name=""
    local original_desired_count=""
    local original_vpc_id=""
    local original_subnet_ids=""

    if [[ ! -f "${env_file}" ]]; then
        return
    fi

    if [[ "${NON_INTERACTIVE+x}" == x ]]; then
        non_interactive_was_set=true
        original_non_interactive="${NON_INTERACTIVE}"
    fi

    if [[ "${AWS_REGION+x}" == x ]]; then
        aws_region_was_set=true
        original_aws_region="${AWS_REGION}"
    fi

    if [[ "${AWS_ENV+x}" == x ]]; then
        aws_env_was_set=true
        original_aws_env="${AWS_ENV}"
    fi

    if [[ "${AWS_PROJECT_ID+x}" == x ]]; then
        aws_project_id_was_set=true
        original_aws_project_id="${AWS_PROJECT_ID}"
    fi

    if [[ "${PROJECT_NAME+x}" == x ]]; then
        project_name_was_set=true
        original_project_name="${PROJECT_NAME}"
    fi

    if [[ "${DESIRED_COUNT+x}" == x ]]; then
        desired_count_was_set=true
        original_desired_count="${DESIRED_COUNT}"
    fi

    if [[ "${VPC_ID+x}" == x ]]; then
        vpc_id_was_set=true
        original_vpc_id="${VPC_ID}"
    fi

    if [[ "${SUBNET_IDS+x}" == x ]]; then
        subnet_ids_was_set=true
        original_subnet_ids="${SUBNET_IDS}"
    fi

    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a

    if [[ "${non_interactive_was_set}" == true ]]; then
        NON_INTERACTIVE="${original_non_interactive}"
    fi

    if [[ "${aws_region_was_set}" == true ]]; then
        AWS_REGION="${original_aws_region}"
    fi

    if [[ "${aws_env_was_set}" == true ]]; then
        AWS_ENV="${original_aws_env}"
    fi

    if [[ "${aws_project_id_was_set}" == true ]]; then
        AWS_PROJECT_ID="${original_aws_project_id}"
    fi

    if [[ "${project_name_was_set}" == true ]]; then
        PROJECT_NAME="${original_project_name}"
    fi

    if [[ "${desired_count_was_set}" == true ]]; then
        DESIRED_COUNT="${original_desired_count}"
    fi

    if [[ "${vpc_id_was_set}" == true ]]; then
        VPC_ID="${original_vpc_id}"
    fi

    if [[ "${subnet_ids_was_set}" == true ]]; then
        SUBNET_IDS="${original_subnet_ids}"
    fi

    ENV_FILE_LOADED="${env_file}"
}

initialize_config() {
    NON_INTERACTIVE="${NON_INTERACTIVE:-}"
    AWS_REGION="${AWS_REGION:-us-west-2}"
    AWS_ENV="${AWS_ENV:-sandbox}"
    AWS_PROJECT_ID="${AWS_PROJECT_ID:-}"
    PROJECT_NAME="${PROJECT_NAME:-${AWS_PROJECT_ID}}"
    DESIRED_COUNT="${DESIRED_COUNT:-2}"
    VPC_ID="${VPC_ID:-}"
    SUBNET_IDS="${SUBNET_IDS:-}"
}

validate_config() {
    if [[ -z "${AWS_PROJECT_ID}" ]]; then
        error "AWS_PROJECT_ID must be set."
        exit 1
    fi
}

check_prerequisites() {
    log "Checking prerequisites..."

    if ! command -v aws >/dev/null 2>&1; then
        error "AWS CLI not installed"
        exit 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        error "Docker not installed"
        exit 1
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        error "OpenSSL not installed"
        exit 1
    fi

    log "✓ Prerequisites met"
    log ""
}

print_configuration() {
    log "=== ${PROJECT_NAME} - AWS Setup ==="
    log ""
    log "Configuration:"
    if [[ -n "${ENV_FILE_LOADED}" ]]; then
        log "  Env File:      ${ENV_FILE_LOADED}"
    fi
    log "  AWS Region:    ${AWS_REGION}"
    log "  Environment:   ${AWS_ENV}"
    log "  Project:       ${AWS_PROJECT_ID}"
    log ""
}

fetch_aws_account_id() {
    AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
    log "AWS Account ID: ${AWS_ACCOUNT_ID}"
    log ""
}

confirm_setup() {
    if [[ -n "${NON_INTERACTIVE}" ]]; then
        return
    fi

    local reply
    read -r -p "Continue with setup? (y/n) " -n 1 reply
    echo

    if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
        log "Setup cancelled."
        exit 1
    fi

    log ""
}

create_ecr_repository() {
    log "Step 1: Creating ECR Repository..."
    aws cloudformation create-stack \
      --stack-name "${AWS_PROJECT_ID}-ecr-${AWS_ENV}" \
      --template-body "file://${ECR_TEMPLATE_PATH}" \
      --parameters \
        "ParameterKey=RepositoryName,ParameterValue=${AWS_PROJECT_ID}" \
        "ParameterKey=Environment,ParameterValue=${AWS_ENV}" \
      --region "${AWS_REGION}"

    log "Waiting for ECR stack creation..."
    aws cloudformation wait stack-create-complete \
      --stack-name "${AWS_PROJECT_ID}-ecr-${AWS_ENV}" \
      --region "${AWS_REGION}"

    ECR_REPOSITORY_URI="$(aws cloudformation describe-stacks \
      --stack-name "${AWS_PROJECT_ID}-ecr-${AWS_ENV}" \
      --query 'Stacks[0].Outputs[?OutputKey==`RepositoryUri`].OutputValue' \
      --output text \
      --region "${AWS_REGION}")"

    log "✓ ECR Repository created: ${ECR_REPOSITORY_URI}"
    log ""
}

build_and_push_image() {
    log "Step 2: Building and pushing initial Docker image..."

    aws ecr get-login-password --region "${AWS_REGION}" | \
      docker login --username AWS --password-stdin "${ECR_REPOSITORY_URI}"

    docker build -t "${AWS_PROJECT_ID}:latest" "${REPO_ROOT}"
    docker tag "${AWS_PROJECT_ID}:latest" "${ECR_REPOSITORY_URI}:latest"
    docker push "${ECR_REPOSITORY_URI}:latest"

    log "✓ Image pushed to ECR"
    log ""
}

create_or_update_secret() {
    local secret_name="$1"
    local secret_value="$2"

    aws secretsmanager create-secret \
      --name "${secret_name}" \
      --secret-string "${secret_value}" \
      --region "${AWS_REGION}" 2>/dev/null || \
      aws secretsmanager update-secret \
        --secret-id "${secret_name}" \
        --secret-string "${secret_value}" \
        --region "${AWS_REGION}"
}

configure_secrets() {
    local grouper_url
    local grouper_username
    local grouper_password
    local db_password
    local jwt_secret

    log "Step 3: Setting up AWS Secrets Manager..."
    log "Please enter your configuration values:"

    read -r -p "Grouper API URL: " grouper_url
    read -r -p "Grouper Username: " grouper_username
    read -r -s -p "Grouper Password: " grouper_password
    echo
    read -r -s -p "Database Password: " db_password
    echo

    jwt_secret="$(openssl rand -base64 32)"

    create_or_update_secret "groupings/api/grouper-url" "${grouper_url}"
    create_or_update_secret "groupings/api/grouper-username" "${grouper_username}"
    create_or_update_secret "groupings/api/grouper-password" "${grouper_password}"
    create_or_update_secret "groupings/api/jwt-secret" "${jwt_secret}"
    create_or_update_secret "groupings/api/db-password" "${db_password}"

    log "✓ Secrets configured"
    log ""
}

collect_network_configuration() {
    log "Step 4: Checking VPC configuration..."

    if [[ -z "${VPC_ID}" ]]; then
        log "Available VPCs:"
        aws ec2 describe-vpcs \
          --query "Vpcs[*].[VpcId,Tags[?Key=='Name'].Value|[0],CidrBlock]" \
          --output table \
          --region "${AWS_REGION}"
        read -r -p "Enter VPC ID to use: " VPC_ID
    else
        log "Using VPC ID from environment: ${VPC_ID}"
    fi

    if [[ -z "${SUBNET_IDS}" ]]; then
        log "Available subnets in VPC ${VPC_ID}:"
        aws ec2 describe-subnets \
          --filters "Name=vpc-id,Values=${VPC_ID}" \
          --query "Subnets[*].[SubnetId,AvailabilityZone,CidrBlock]" \
          --output table \
          --region "${AWS_REGION}"
        read -r -p "Enter Subnet IDs (comma-separated, at least 2): " SUBNET_IDS
    else
        log "Using Subnet IDs from environment: ${SUBNET_IDS}"
    fi

    log ""
}

deploy_ecs_infrastructure() {
    log "Step 5: Creating ECS cluster and service..."

    aws cloudformation create-stack \
      --stack-name "${AWS_PROJECT_ID}-ecs-${AWS_ENV}" \
      --template-body "file://${ECS_TEMPLATE_PATH}" \
      --parameters \
        "ParameterKey=Environment,ParameterValue=${AWS_ENV}" \
        "ParameterKey=VpcId,ParameterValue=${VPC_ID}" \
        "ParameterKey=SubnetIds,ParameterValue=${SUBNET_IDS}" \
        "ParameterKey=ContainerImage,ParameterValue=${ECR_REPOSITORY_URI}:latest" \
        "ParameterKey=DesiredCount,ParameterValue=${DESIRED_COUNT}" \
      --capabilities CAPABILITY_NAMED_IAM \
      --region "${AWS_REGION}"

    log "Waiting for ECS stack creation (this may take 10 minutes)..."
    aws cloudformation wait stack-create-complete \
      --stack-name "${AWS_PROJECT_ID}-ecs-${AWS_ENV}" \
      --region "${AWS_REGION}"

    ALB_URL="$(aws cloudformation describe-stacks \
      --stack-name "${AWS_PROJECT_ID}-ecs-${AWS_ENV}" \
      --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerUrl`].OutputValue' \
      --output text \
      --region "${AWS_REGION}")"

    log "✓ ECS cluster created"
    log "Application URL: ${ALB_URL}"
    log ""
}

print_summary() {
    log "=== Setup Complete ==="
    log ""
    log "Resources created:"
    log "  - ECR Repository: ${ECR_REPOSITORY_URI}"
    log "  - ECS Cluster: ${AWS_PROJECT_ID}-${AWS_ENV}"
    log "  - Application URL: ${ALB_URL}"
    log ""
    log "Next steps:"
    log "  1. Configure GitHub Enterprise connection in AWS Console"
    log "  2. Deploy CodePipeline stack"
    log "  3. Test the application: curl ${ALB_URL}/actuator/health"
    log ""
    log "For detailed instructions, see docs/AWS_SETUP.md"
}

main() {
    parse_args "$@"
    load_env_file
    initialize_config
    validate_config
    print_configuration
    check_prerequisites
    fetch_aws_account_id
    confirm_setup
    create_ecr_repository
    build_and_push_image
    configure_secrets
    collect_network_configuration
    deploy_ecs_infrastructure
    print_summary
}

main "$@"
