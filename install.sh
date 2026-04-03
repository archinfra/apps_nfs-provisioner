#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="nfs-provisioner"
APP_VERSION="1.1.0"
WORKDIR="/tmp/${APP_NAME}-installer"
IMAGE_DIR="${WORKDIR}/images"
CHART_DIR="${WORKDIR}/charts"

REGISTRY_ADDR="${REGISTRY_ADDR:-sealos.hub:5000}"
REGISTRY_USER="${REGISTRY_USER:-admin}"
REGISTRY_PASS="${REGISTRY_PASS:-passw0rd}"

OLD_NFS_IMAGE="${REGISTRY_ADDR}/kube4/nfs-subdir-external-provisioner:v4.0.2"
NEW_NFS_IMAGE="${REGISTRY_ADDR}/kube4/nfs-subdir-external-provisioner:v4.0.2"

ACTION="install"
NAME="nfs-subdir-external-provisioner"
NAMESPACE="kube-system"
NFS_SERVER=""
NFS_PATH="/data/nfs-share"
STORAGE_CLASS_NAME="nfs"
STORAGE_CLASS_DEFAULT="true"
REPLICAS="1"
AUTO_YES="false"
DEBUG="false"
HELM_ARGS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() {
  echo -e "${CYAN}[INFO]${NC} $*"
}

success() {
  echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

die() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

section() {
  echo
  echo -e "${BLUE}${BOLD}============================================================${NC}"
  echo -e "${BLUE}${BOLD}$*${NC}"
  echo -e "${BLUE}${BOLD}============================================================${NC}"
}

banner() {
  echo
  echo -e "${GREEN}${BOLD}NFS Provisioner Offline Installer${NC}"
  echo -e "${CYAN}version: ${APP_VERSION}${NC}"
}

usage() {
  cat <<'EOF'
Usage:
  ./nfs-provisioner-installer.run install|uninstall [options] [-- <helm args>]

Commands:
  install                       Install NFS Provisioner
  uninstall                     Uninstall NFS Provisioner

Options:
  --name <name>                 Helm release name, default: nfs-subdir-external-provisioner
  --namespace <ns>              Kubernetes namespace, default: kube-system
  --nfs-server <ip>             NFS server IP or hostname
  --nfs-path <path>             NFS shared path, default: /data/nfs-share
  --replicas <num>              Provisioner replicas, default: 1
  --storage-class-name <name>   StorageClass name, default: nfs
  --storage-class-default       Set StorageClass as default
  --no-default-class            Do not set StorageClass as default
  -y, --yes                     Skip confirmation
  --debug                       Add --debug to helm install
  -h, --help                    Show help

Helm passthrough:
  All arguments after `--` are passed to helm as-is.

Examples:
  ./nfs-provisioner-installer.run install --nfs-server 192.168.10.20
  ./nfs-provisioner-installer.run install --nfs-server 192.168.10.20 --nfs-path /data/nfs-share
  ./nfs-provisioner-installer.run install --nfs-server 192.168.10.20 -- --wait --timeout 5m
EOF
}

parse_args() {
  [[ $# -eq 0 ]] && {
    usage
    exit 0
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      install|uninstall)
        ACTION="$1"
        shift
        ;;
      --name)
        NAME="$2"
        shift 2
        ;;
      --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      --nfs-server)
        NFS_SERVER="$2"
        shift 2
        ;;
      --nfs-path)
        NFS_PATH="$2"
        shift 2
        ;;
      --replicas)
        REPLICAS="$2"
        shift 2
        ;;
      --storage-class-name)
        STORAGE_CLASS_NAME="$2"
        shift 2
        ;;
      --storage-class-default)
        STORAGE_CLASS_DEFAULT="true"
        shift
        ;;
      --no-default-class)
        STORAGE_CLASS_DEFAULT="false"
        shift
        ;;
      -y|--yes)
        AUTO_YES="true"
        shift
        ;;
      --debug)
        DEBUG="true"
        shift
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          HELM_ARGS+=("$1")
          shift
        done
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

prompt_missing_values() {
  [[ "${ACTION}" == "install" ]] || return 0

  if [[ -z "${NFS_SERVER}" ]]; then
    echo -ne "${YELLOW}Please enter the NFS server IP or hostname:${NC} "
    read -r NFS_SERVER
  fi

  if [[ -z "${NFS_SERVER}" ]]; then
    die "NFS server cannot be empty"
  fi

  if [[ -z "${NFS_PATH}" ]]; then
    NFS_PATH="/data/nfs-share"
  fi
}

validate_environment() {
  command -v helm >/dev/null 2>&1 || die "helm command not found"
  command -v kubectl >/dev/null 2>&1 || die "kubectl command not found"
  command -v docker >/dev/null 2>&1 || die "docker command not found"
}

print_plan() {
  section "Deployment Plan"
  echo "Action                : ${ACTION}"
  echo "Release Name          : ${NAME}"
  echo "Namespace             : ${NAMESPACE}"
  if [[ "${ACTION}" == "install" ]]; then
    echo "NFS Server            : ${NFS_SERVER}"
    echo "NFS Path              : ${NFS_PATH}"
    echo "Replicas              : ${REPLICAS}"
    echo "StorageClass Name     : ${STORAGE_CLASS_NAME}"
    echo "Default StorageClass  : ${STORAGE_CLASS_DEFAULT}"
  fi
  if [[ ${#HELM_ARGS[@]} -gt 0 ]]; then
    echo "Extra Helm Args       : ${HELM_ARGS[*]}"
  else
    echo "Extra Helm Args       : <none>"
  fi
}

confirm_plan() {
  [[ "${AUTO_YES}" == "true" ]] && return 0
  print_plan
  echo
  echo -ne "${YELLOW}Continue? [y/N]:${NC} "
  read -r answer
  [[ "${answer}" =~ ^[Yy]$ ]] || die "Canceled"
}

docker_login() {
  log "Logging into registry ${REGISTRY_ADDR}"
  if echo "${REGISTRY_PASS}" | docker login "${REGISTRY_ADDR}" -u "${REGISTRY_USER}" --password-stdin >/dev/null 2>&1; then
    success "Registry login succeeded"
  else
    warn "Registry login failed, continuing anyway"
  fi
}

extract_payload() {
  section "Extract Payload"

  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}" "${IMAGE_DIR}" "${CHART_DIR}"

  local payload_line
  payload_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR + 1; exit }' "$0")"
  [[ -n "${payload_line}" ]] || die "Payload marker not found"

  log "Extracting payload into ${WORKDIR}"
  tail -n +"${payload_line}" "$0" | tar -xz -C "${WORKDIR}" >/dev/null 2>&1 || die "Failed to extract payload"

  [[ -d "${CHART_DIR}/nfs-subdir-external-provisioner" ]] || die "Chart directory is missing"
  success "Payload extracted"
}

ensure_namespace() {
  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    log "Namespace ${NAMESPACE} already exists"
    return
  fi

  log "Creating namespace ${NAMESPACE}"
  kubectl create namespace "${NAMESPACE}" >/dev/null
  success "Namespace created"
}

load_images() {
  section "Prepare Images"

  docker_login

  shopt -s nullglob
  local image_tars=("${IMAGE_DIR}"/*.tar)
  shopt -u nullglob

  if [[ ${#image_tars[@]} -eq 0 ]]; then
    warn "No offline image tar files were found"
    return 0
  fi

  local image_tar
  for image_tar in "${image_tars[@]}"; do
    log "Loading $(basename "${image_tar}")"
    docker load -i "${image_tar}" >/dev/null 2>&1 || warn "docker load failed for $(basename "${image_tar}")"
  done

  if [[ "${OLD_NFS_IMAGE}" != "${NEW_NFS_IMAGE}" ]]; then
    log "Retagging ${OLD_NFS_IMAGE} -> ${NEW_NFS_IMAGE}"
    docker tag "${OLD_NFS_IMAGE}" "${NEW_NFS_IMAGE}" >/dev/null 2>&1 || warn "docker tag failed"
  fi

  log "Pushing ${NEW_NFS_IMAGE}"
  docker push "${NEW_NFS_IMAGE}" >/dev/null 2>&1 || warn "docker push failed for ${NEW_NFS_IMAGE}"
  success "Image preparation completed"
}

install_provisioner() {
  section "Install NFS Provisioner"

  ensure_namespace

  local chart_path="${CHART_DIR}/nfs-subdir-external-provisioner"
  local -a cmd=(
    helm upgrade --install "${NAME}" "${chart_path}"
    -n "${NAMESPACE}"
    --create-namespace
    --set "nfs.server=${NFS_SERVER}"
    --set "nfs.path=${NFS_PATH}"
    --set "replicaCount=${REPLICAS}"
    --set "storageClass.name=${STORAGE_CLASS_NAME}"
    --set "storageClass.defaultClass=${STORAGE_CLASS_DEFAULT}"
  )

  if [[ "${DEBUG}" == "true" ]]; then
    cmd+=(--debug)
  fi

  if [[ ${#HELM_ARGS[@]} -gt 0 ]]; then
    cmd+=("${HELM_ARGS[@]}")
  fi

  log "Running Helm install"
  printf '  %q' "${cmd[@]}"
  printf '\n'

  "${cmd[@]}"
  success "NFS Provisioner installed successfully"
}

uninstall_provisioner() {
  section "Uninstall NFS Provisioner"

  local -a cmd=(helm uninstall "${NAME}" -n "${NAMESPACE}")
  if [[ ${#HELM_ARGS[@]} -gt 0 ]]; then
    cmd+=("${HELM_ARGS[@]}")
  fi

  log "Running Helm uninstall"
  printf '  %q' "${cmd[@]}"
  printf '\n'

  "${cmd[@]}" || warn "Helm uninstall reported an issue, please verify cluster resources manually"
  success "Uninstall finished"
}

show_post_install_info() {
  section "Next Steps"
  cat <<EOF
kubectl get pods -n ${NAMESPACE}
kubectl get storageclass

Quick PVC test:
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  storageClassName: ${STORAGE_CLASS_NAME}
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
YAML
EOF
}

cleanup() {
  rm -rf "${WORKDIR}" >/dev/null 2>&1 || true
}

main() {
  trap cleanup EXIT

  banner
  parse_args "$@"
  prompt_missing_values
  validate_environment
  confirm_plan

  if [[ "${ACTION}" == "install" ]]; then
    extract_payload
    load_images
    install_provisioner
    show_post_install_info
  else
    uninstall_provisioner
  fi
}

main "$@"

exit 0

__PAYLOAD_BELOW__
