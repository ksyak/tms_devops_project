#!/usr/bin/env bash
#
# Разворачивает стенд:
#   PROJECT_ID=<проект> ./scripts/bootstrap.sh
#
# preflight -> бакет под tfstate -> terraform -> kubeconfig -> Argo CD ->
# мониторинг -> NGINX Ingress -> Application -> печать URL. Идемпотентен.
#
# Предварительно требуется:
#   gcloud auth login && gcloud auth application-default login
#   gcloud billing projects link <проект> --billing-account=<ID>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/infra/terraform"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-europe-central2}"
ZONE="${ZONE:-europe-central2-a}"
CLUSTER_NAME="${CLUSTER_NAME:-boutique}"
STATE_BUCKET="${STATE_BUCKET:-${PROJECT_ID}-tfstate}"
APP_NAMESPACE="${APP_NAMESPACE:-boutique}"

# Репозиторий, которому доверяет Workload Identity Federation.
GITHUB_OWNER="${GITHUB_OWNER:-ksyak}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-ksyak/tms_devops_project}"

# Версии чартов зафиксированы для воспроизводимости.
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-4.15.1}"
ARGOCD_VERSION="${ARGOCD_VERSION:-10.7.1}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!   %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mX   %s\033[0m\n' "$*" >&2; exit 1; }

# --- 1. Preflight -----------------------------------------------------------
# Проверки до создания ресурсов.

log "Preflight"

for tool in gcloud terraform kubectl helm; do
  command -v "$tool" >/dev/null 2>&1 || die "не найден $tool — см. docs/prerequisites"
done

[[ -n "${PROJECT_ID}" ]] || die "не задан PROJECT_ID и не выставлен проект в gcloud"

gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q . \
  || die "нет активного аккаунта: gcloud auth login"

gcloud auth application-default print-access-token >/dev/null 2>&1 \
  || die "нет Application Default Credentials: gcloud auth application-default login"

billing_enabled="$(gcloud beta billing projects describe "${PROJECT_ID}" \
  --format='value(billingEnabled)' 2>/dev/null || echo False)"
[[ "${billing_enabled}" == "True" ]] \
  || die "к проекту ${PROJECT_ID} не привязан биллинг"

printf '    проект:  %s\n' "${PROJECT_ID}"
printf '    зона:    %s\n' "${ZONE}"
printf '    кластер: %s\n' "${CLUSTER_NAME}"

# --- 2. Бакет под состояние Terraform --------------------------------------
# Бакет не может быть создан тем же terraform, чьё состояние хранит.

log "Бакет под tfstate: gs://${STATE_BUCKET}"

if gcloud storage buckets describe "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
  echo "    уже существует"
else
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
  # Версионирование для отката состояния.
  gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
fi

# --- 3. Terraform -----------------------------------------------------------

log "Terraform init"

terraform -chdir="${TF_DIR}" init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="prefix=terraform/state"

log "Terraform apply"

terraform -chdir="${TF_DIR}" apply -input=false -auto-approve \
  -var="project_id=${PROJECT_ID}" \
  -var="region=${REGION}" \
  -var="zone=${ZONE}" \
  -var="cluster_name=${CLUSTER_NAME}" \
  -var="github_owner=${GITHUB_OWNER}" \
  -var="github_repository=${GITHUB_REPOSITORY}"

REGISTRY_URL="$(terraform -chdir="${TF_DIR}" output -raw registry_url)"
WIF_PROVIDER="$(terraform -chdir="${TF_DIR}" output -raw wif_provider)"
CI_SA="$(terraform -chdir="${TF_DIR}" output -raw ci_service_account)"

# --- 4. kubeconfig ----------------------------------------------------------
# Получаем на лету, в git не хранится.

log "kubeconfig"

gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --zone "${ZONE}" --project "${PROJECT_ID}"

kubectl cluster-info >/dev/null || die "кластер недоступен"

# --- 5. Argo CD -------------------------------------------------------------

log "Argo CD"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install argocd argo/argo-cd \
  --version "${ARGOCD_VERSION}" \
  --namespace argocd --create-namespace \
  --set configs.params."server\.insecure"=true \
  --wait --timeout 10m

# --- 6. Стек мониторинга ----------------------------------------------------
# Ставится до Ingress: у NGINX включён ServiceMonitor, а его CRD приносит
# prometheus-operator. В обратном порядке установка Ingress падает.

log "Стек мониторинга"

kubectl apply -f "${REPO_ROOT}/deploy/argocd/monitoring.yaml"

kubectl wait --for=condition=established --timeout=10m \
  crd/servicemonitors.monitoring.coreos.com \
  || die "CRD ServiceMonitor не появился — проверьте argocd app get monitoring"

# --- 7. NGINX Ingress -------------------------------------------------------

log "NGINX Ingress Controller"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version "${INGRESS_NGINX_VERSION}" \
  --namespace ingress-nginx --create-namespace \
  --set controller.metrics.enabled=true \
  --set controller.metrics.serviceMonitor.enabled=true \
  --set controller.metrics.serviceMonitor.additionalLabels.release=monitoring \
  --wait --timeout 10m

# --- 8. Регистрация остальных Application ----------------------------------
# Дальше кластер приводит к состоянию из Git только Argo CD.

log "Регистрация Argo CD Application"

kubectl apply -n argocd -f "${REPO_ROOT}/deploy/argocd/"

log "Ожидание синхронизации (может занять несколько минут)"

kubectl wait --for=jsonpath='{.status.health.status}'=Healthy \
  application/boutique -n argocd --timeout=15m \
  || warn "приложение не дошло до Healthy за 15 минут — смотрите argocd app get boutique"

# --- 9. Результат -----------------------------------------------------------

log "Готово"

APP_IP="$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

ARGO_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '<уже сменён>')"

cat <<EOF

  Приложение:   http://${APP_IP:-<LB ещё не получил IP>}/

  Argo CD:      kubectl port-forward svc/argocd-server -n argocd 8080:443
                https://localhost:8080  (admin / ${ARGO_PW})

  Grafana:      kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80
                http://localhost:3000   (admin / prom-operator)

  Registry:     ${REGISTRY_URL}

  Для секретов GitHub Actions:
    GCP_WIF_PROVIDER   ${WIF_PROVIDER}
    GCP_CI_SA          ${CI_SA}

  Удаление стенда: ./scripts/teardown.sh

EOF
