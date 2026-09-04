#!/usr/bin/env bash
#
# Сносит стенд:
#   PROJECT_ID=<проект> ./scripts/teardown.sh
#
# LoadBalancer'ы и PersistentVolume'ы создаёт Kubernetes, в стейте Terraform
# их нет. При destroy в первую очередь кластер исчезает вместе с
# контроллерами, а forwarding rules, адреса и диски остаются и
# тарифицируются. Поэтому сначала снимается то, что создал Kubernetes.
#
# Проект общий с другими задачами, ресурсы удаляются адресно.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/infra/terraform"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-europe-central2}"
ZONE="${ZONE:-europe-central2-a}"
CLUSTER_NAME="${CLUSTER_NAME:-boutique}"
STATE_BUCKET="${STATE_BUCKET:-${PROJECT_ID}-tfstate}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!   %s\033[0m\n' "$*"; }

[[ -n "${PROJECT_ID}" ]] || { echo "не задан PROJECT_ID" >&2; exit 1; }

log "Будет удалён стенд в проекте ${PROJECT_ID}"
read -r -p "    Подтвердите ввод имени кластера [${CLUSTER_NAME}]: " confirm
[[ "${confirm}" == "${CLUSTER_NAME}" ]] || { echo "отменено"; exit 1; }

# --- 1. Ресурсы, созданные Kubernetes --------------------------------------

if gcloud container clusters describe "${CLUSTER_NAME}" \
     --zone "${ZONE}" --project "${PROJECT_ID}" >/dev/null 2>&1; then

  log "Подключаюсь к кластеру"
  gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --zone "${ZONE}" --project "${PROJECT_ID}"

  log "Отключаю Argo CD"
  kubectl delete applications.argoproj.io --all -n argocd --ignore-not-found --timeout=5m || true
  helm uninstall argocd -n argocd 2>/dev/null || true

  log "Удаляю Service типа LoadBalancer"
  kubectl get svc --all-namespaces \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    | while read -r ns name; do
        [[ -n "${ns}" ]] || continue
        echo "    ${ns}/${name}"
        kubectl delete svc "${name}" -n "${ns}" --ignore-not-found --timeout=3m || true
      done

  log "Удаляю PersistentVolumeClaim"
  kubectl delete pvc --all --all-namespaces --ignore-not-found --timeout=5m || true

  log "Жду освобождения LB и дисков"
  sleep 45
else
  warn "кластер ${CLUSTER_NAME} не найден — пропускаю очистку внутри Kubernetes"
fi

# --- 2. Инфраструктура ------------------------------------------------------

log "Terraform destroy"

if [[ -d "${TF_DIR}/.terraform" ]] || gcloud storage ls "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
  terraform -chdir="${TF_DIR}" init -input=false -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="prefix=terraform/state"

  terraform -chdir="${TF_DIR}" destroy -input=false -auto-approve \
    -var="project_id=${PROJECT_ID}" \
    -var="region=${REGION}" \
    -var="zone=${ZONE}" \
    -var="cluster_name=${CLUSTER_NAME}" \
    -var="github_owner=${GITHUB_OWNER:-ksyak}" \
    -var="github_repository=${GITHUB_REPOSITORY:-ksyak/tms_devops_project}"
else
  warn "состояние Terraform не найдено — пропускаю destroy"
fi

# --- 3. Бакет состояния -----------------------------------------------------
# Последним: до этого он нужен самому destroy.

log "Бакет состояния gs://${STATE_BUCKET}"
gcloud storage rm -r "gs://${STATE_BUCKET}" 2>/dev/null || warn "бакет уже отсутствует"

# --- 4. Контроль ------------------------------------------------------------


log "Контрольная проверка — списки должны быть пусты"

echo "--- кластеры ---"
gcloud container clusters list --project "${PROJECT_ID}" 2>/dev/null || true
echo "--- диски ---"
gcloud compute disks list --project "${PROJECT_ID}" --filter="zone:(${ZONE})" 2>/dev/null || true
echo "--- forwarding rules ---"
gcloud compute forwarding-rules list --project "${PROJECT_ID}" 2>/dev/null || true
echo "--- внешние адреса ---"
gcloud compute addresses list --project "${PROJECT_ID}" 2>/dev/null || true
echo "--- Artifact Registry ---"
gcloud artifacts repositories list --project "${PROJECT_ID}" --location "${REGION}" 2>/dev/null || true

cat <<EOF

  Teardown завершён.

  Непустые списки выше означают осиротевшие ресурсы — удалить вручную.
  Проект ${PROJECT_ID} используется и под другие задачи, часть ресурсов
  в консоли может относиться к ним.

EOF
