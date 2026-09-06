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

# --- 0. Локальные настройки из .env -----------------------------------------
# Файл лежит вне git (.gitignore), образец — .env.example. Держит внешние
# секреты и параметры стенда, чтобы не передавать их в командной строке.
# Переменные, заданные явно при запуске, приоритетнее файла.

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"

if [[ -f "${ENV_FILE}" ]]; then
  while IFS='=' read -r key value; do
    key="${key//[[:space:]]/}"
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    # Windows-переносы строк ломают значение молча.
    value="${value%$'\r'}"
    # Снимаем кавычки, если значение обёрнуто.
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    # Явно переданное в командной строке не перетираем.
    [[ -n "${!key:-}" ]] && continue
    export "${key}=${value}"
  done < "${ENV_FILE}"
fi

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

for tool in gcloud terraform kubectl helm envsubst openssl; do
  command -v "$tool" >/dev/null 2>&1 || die "не найден $tool — см. docs/prerequisites"
done

# Токен бота — единственный секрет, который нельзя ни сгенерировать, ни взять
# из облака: он внешний. Проверяем до создания ресурсов, а не на 20-й минуте.
if [[ -z "${TELEGRAM_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  if ! kubectl get secret alertmanager-boutique -n monitoring >/dev/null 2>&1; then
    die "не заданы TELEGRAM_TOKEN и TELEGRAM_CHAT_ID.
    Уведомления — требование задания, без них Alertmanager не поднимется.
    Запуск:
      PROJECT_ID=<проект> TELEGRAM_TOKEN=<токен> TELEGRAM_CHAT_ID=<id> ./scripts/bootstrap.sh"
  fi
fi

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

# --- 3a. Восстановление IAM-ресурсов после предыдущего teardown -------------
# GCP удаляет пулы Workload Identity и сервисные аккаунты "мягко": объект
# переходит в состояние DELETED, но ID остаётся зарезервированным 30 дней.
# Без этой обработки цикл teardown -> bootstrap падает с
#   Error 409: Requested entity already exists
# Логика: существует и удалён -> восстановить; существует, но нет в состоянии
# terraform -> импортировать. Нет вовсе -> terraform создаст сам.

# В root-модуле name_prefix = var.cluster_name, поэтому выводим отсюда же.
NAME_PREFIX="${NAME_PREFIX:-${CLUSTER_NAME}}"
WIF_POOL_ID="${WIF_POOL_ID:-${NAME_PREFIX}-gh-pool}"
WIF_PROVIDER_ID="${WIF_PROVIDER_ID:-${NAME_PREFIX}-gh-provider}"
CI_SA_EMAIL="${NAME_PREFIX}-ci@${PROJECT_ID}.iam.gserviceaccount.com"

ADDR_POOL='module.wif.google_iam_workload_identity_pool.github'
ADDR_PROVIDER='module.wif.google_iam_workload_identity_pool_provider.github'
ADDR_SA='module.wif.google_service_account.ci'

tf_vars=(
  -var "project_id=${PROJECT_ID}"
  -var "region=${REGION}"
  -var "zone=${ZONE}"
  -var "cluster_name=${CLUSTER_NAME}"
  -var "github_owner=${GITHUB_OWNER}"
  -var "github_repository=${GITHUB_REPOSITORY}"
)

in_state() { terraform -chdir="${TF_DIR}" state show "$1" >/dev/null 2>&1; }

tf_import() {
  terraform -chdir="${TF_DIR}" import -input=false "${tf_vars[@]}" "$1" "$2" >/dev/null
}

# undelete в GCP асинхронный: команда возвращает handle операции, а объект
# становится доступен через несколько секунд. Без ожидания import падает с
# "Cannot import non-existent remote object".
pool_state_now() {
  gcloud iam workload-identity-pools describe "${WIF_POOL_ID}" \
    --location=global --project="${PROJECT_ID}" \
    --format='value(state)' 2>/dev/null || true
}

provider_state_now() {
  gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER_ID}" \
    --workload-identity-pool="${WIF_POOL_ID}" --location=global \
    --project="${PROJECT_ID}" --format='value(state)' 2>/dev/null || true
}

wait_active() {  # $1 — функция опроса состояния, $2 — что ждём (для лога)
  local i state
  for i in $(seq 1 60); do
    state="$($1)"
    [[ "${state}" == "ACTIVE" ]] && return 0
    sleep 5
  done
  warn "$2 не перешёл в ACTIVE за 5 минут (последнее состояние: ${state:-нет})"
  return 1
}

log "Проверка IAM-ресурсов (Workload Identity Federation)"

pool_state="$(gcloud iam workload-identity-pools describe "${WIF_POOL_ID}" \
  --location=global --project="${PROJECT_ID}" \
  --format='value(state)' 2>/dev/null || true)"

if [[ -z "${pool_state}" ]]; then
  echo "    пул ${WIF_POOL_ID}: отсутствует, создаст terraform"
else
  if [[ "${pool_state}" == "DELETED" ]]; then
    warn "пул ${WIF_POOL_ID} в soft-delete — восстанавливаю"
    gcloud iam workload-identity-pools undelete "${WIF_POOL_ID}" \
      --location=global --project="${PROJECT_ID}" --quiet >/dev/null
    wait_active pool_state_now "пул ${WIF_POOL_ID}" \
      || die "не удалось восстановить пул — запустите скрипт повторно"
    echo "    пул ${WIF_POOL_ID}: восстановлен"
  fi

  if in_state "${ADDR_POOL}"; then
    echo "    пул ${WIF_POOL_ID}: уже в состоянии terraform"
  else
    echo "    пул ${WIF_POOL_ID}: импортирую в состояние terraform"
    tf_import "${ADDR_POOL}" "${WIF_POOL_ID}"
  fi

  provider_state="$(gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER_ID}" \
    --workload-identity-pool="${WIF_POOL_ID}" --location=global \
    --project="${PROJECT_ID}" --format='value(state)' 2>/dev/null || true)"

  if [[ -z "${provider_state}" ]]; then
    echo "    провайдер ${WIF_PROVIDER_ID}: отсутствует, создаст terraform"
  else
    if [[ "${provider_state}" == "DELETED" ]]; then
      warn "провайдер ${WIF_PROVIDER_ID} в soft-delete — восстанавливаю"
      gcloud iam workload-identity-pools providers undelete "${WIF_PROVIDER_ID}" \
        --workload-identity-pool="${WIF_POOL_ID}" --location=global \
        --project="${PROJECT_ID}" --quiet >/dev/null
      wait_active provider_state_now "провайдер ${WIF_PROVIDER_ID}" \
        || die "не удалось восстановить провайдера — запустите скрипт повторно"
      echo "    провайдер ${WIF_PROVIDER_ID}: восстановлен"
    fi

    if in_state "${ADDR_PROVIDER}"; then
      echo "    провайдер ${WIF_PROVIDER_ID}: уже в состоянии terraform"
    else
      echo "    провайдер ${WIF_PROVIDER_ID}: импортирую в состояние terraform"
      tf_import "${ADDR_PROVIDER}" "${WIF_POOL_ID}/${WIF_PROVIDER_ID}"
    fi
  fi
fi

# Сервисный аккаунт тоже переживает destroy и даёт 409 при повторном создании.
if gcloud iam service-accounts describe "${CI_SA_EMAIL}" \
     --project="${PROJECT_ID}" >/dev/null 2>&1; then
  if in_state "${ADDR_SA}"; then
    echo "    сервисный аккаунт ${CI_SA_EMAIL}: уже в состоянии terraform"
  else
    echo "    сервисный аккаунт ${CI_SA_EMAIL}: импортирую в состояние terraform"
    tf_import "${ADDR_SA}" "projects/${PROJECT_ID}/serviceAccounts/${CI_SA_EMAIL}"
  fi
else
  echo "    сервисный аккаунт ${CI_SA_EMAIL}: отсутствует, создаст terraform"
fi

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
INGRESS_IP="$(terraform -chdir="${TF_DIR}" output -raw ingress_ip)"

# Домена у стенда нет, а Let's Encrypt не выдаёт сертификат на IP.
# nip.io резолвит <адрес>.nip.io в сам адрес — получаем валидное имя.
# Адрес зарезервирован в terraform, поэтому известен ДО установки Ingress
# и все манифесты рендерятся сразу, без второго прохода.
export INGRESS_HOST="${INGRESS_IP}.nip.io"
printf '    ingress: %s\n' "${INGRESS_HOST}"

# --- 3b. Рендеринг манифестов Argo CD ---------------------------------------
# В файлах deploy/argocd лежит плейсхолдер ${INGRESS_HOST}. Подставляем
# фактический адрес во временный каталог: сами файлы в git не трогаем,
# иначе каждый цикл создавал бы коммит с новым IP.

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${RENDER_DIR}"' EXIT

for f in "${REPO_ROOT}"/deploy/argocd/*.yaml; do
  # Явный список переменных: остальные ${...} в файлах остаются как есть.
  envsubst '${INGRESS_HOST}' < "${f}" > "${RENDER_DIR}/$(basename "${f}")"
done

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

# --- 5a. Секреты кластера ---------------------------------------------------
# Секретов нет ни в git, ни в файлах рядом с проектом: пароли генерируются при
# первом разворачивании, токен бота приходит из переменной окружения. Поэтому
# стенд поднимается в любом чистом проекте одной командой.
#
# Идемпотентность: существующие секреты не перезаписываются, иначе пароли
# менялись бы при каждом запуске.

log "Секреты кластера"

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null

ensure_secret() {  # $1 — имя, дальше аргументы для kubectl create secret generic
  local name="$1"; shift
  if kubectl get secret "${name}" -n monitoring >/dev/null 2>&1; then
    echo "    ${name}: уже существует"
    return 0
  fi
  kubectl create secret generic "${name}" -n monitoring "$@" >/dev/null
  echo "    ${name}: создан"
}

# Пароль Grafana. Генерируем, если не задан снаружи.
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)}"
ensure_secret grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="${GRAFANA_PASSWORD}"

# Конфиг Alertmanager с токеном бота.
if [[ -n "${TELEGRAM_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  AM_CONFIG="$(mktemp)"
  TELEGRAM_TOKEN="${TELEGRAM_TOKEN}" TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}" \
    envsubst '${TELEGRAM_TOKEN} ${TELEGRAM_CHAT_ID}' \
    < "${REPO_ROOT}/deploy/secrets/alertmanager.tmpl.yaml" > "${AM_CONFIG}"

  # Этот секрет обновляем всегда: токен мог смениться, а генерации здесь нет.
  kubectl create secret generic alertmanager-boutique -n monitoring \
    --from-file=alertmanager.yaml="${AM_CONFIG}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -f "${AM_CONFIG}"
  echo "    alertmanager-boutique: настроен"
elif kubectl get secret alertmanager-boutique -n monitoring >/dev/null 2>&1; then
  echo "    alertmanager-boutique: оставлен прежним (TELEGRAM_* не заданы)"
else
  die "не заданы TELEGRAM_TOKEN и TELEGRAM_CHAT_ID — Alertmanager не поднимется.
    Запустите так:
      PROJECT_ID=${PROJECT_ID} TELEGRAM_TOKEN=<токен> TELEGRAM_CHAT_ID=<id> ./scripts/bootstrap.sh"
fi

log "Стек мониторинга"

kubectl apply -f "${RENDER_DIR}/monitoring.yaml"

# Argo создаёт CRD не мгновенно: сначала он клонирует чарт и начинает sync.
# kubectl wait не умеет ждать ПОЯВЛЕНИЯ объекта — при отсутствии CRD он сразу
# падает с NotFound. Поэтому сначала ждём появления в цикле.
echo "    жду появления CRD ServiceMonitor (Argo синхронизирует чарт)"

crd_ready=false
for _ in $(seq 1 120); do   # до 10 минут
  if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    crd_ready=true
    break
  fi
  sleep 5
done

if [[ "${crd_ready}" != true ]]; then
  warn "состояние Application monitoring:"
  kubectl -n argocd get application monitoring \
    -o jsonpath='{.status.sync.status} / {.status.health.status}{"\n"}{.status.conditions}{"\n"}' 2>/dev/null || true
  die "CRD ServiceMonitor не появился за 10 минут — проверьте: argocd app get monitoring"
fi

# Появился — теперь ждём, пока API-сервер его зарегистрирует.
kubectl wait --for=condition=established --timeout=5m \
  crd/servicemonitors.monitoring.coreos.com \
  || die "CRD ServiceMonitor не перешёл в Established"

echo "    CRD ServiceMonitor готов"

# --- 7. NGINX Ingress -------------------------------------------------------

log "NGINX Ingress Controller"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx   --version "${INGRESS_NGINX_VERSION}"   --namespace ingress-nginx --create-namespace   --set controller.service.loadBalancerIP="${INGRESS_IP}"   --set controller.metrics.enabled=true   --set controller.metrics.serviceMonitor.enabled=true   --set controller.metrics.serviceMonitor.additionalLabels.release=monitoring   --wait --timeout 10m

# --- 8. Регистрация остальных Application ----------------------------------
# Дальше кластер приводит к состоянию из Git только Argo CD.

log "Регистрация Argo CD Application"

kubectl apply -n argocd -f "${RENDER_DIR}/" >/dev/null

# --- 8a. Параметры Application, зависящие от окружения ----------------------
# Значения, которые нельзя зафиксировать в git: адрес меняется при каждом
# разворачивании, наличие образов зависит от того, отработал ли уже CI.
# Параметры Application перекрывают value-файлы из репозитория.

params=()
add_param() { params+=("{\"name\":\"$1\",\"value\":\"$2\"}"); }
apply_params() {  # $1 — имя Application
  local joined; joined="$(IFS=,; echo "${params[*]}")"
  kubectl patch application "$1" -n argocd --type=merge \
    -p "{\"spec\":{\"source\":{\"helm\":{\"parameters\":[${joined}]}}}}" >/dev/null
}

log "Параметры Application"

# --- приложение ---
params=()
add_param ingress.host "${INGRESS_HOST}"

# Teardown удаляет Artifact Registry вместе с образами. При разворачивании с
# нуля тег из values-prod.yaml указывает на несуществующий образ и все поды
# встают в ImagePullBackOff. Чтобы одна команда давала рабочий стенд без
# ожидания CI, при пустом реестре берём публичные образы upstream. После
# первой успешной сборки CD пропишет свой тег, и Argo переключится сам.
if [[ -z "$(gcloud artifacts docker images list "${REGISTRY_URL}" \
             --limit=1 --format='value(package)' 2>/dev/null)" ]]; then
  warn "Artifact Registry пуст — поднимаемся на публичных образах upstream"
  warn "после первой успешной сборки CI/CD переключит стенд на ваши образы"
  add_param images.repository "us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo"
  add_param images.tag ""
else
  echo "    в реестре есть образы — используются они"
fi
apply_params boutique
echo "    boutique: параметры применены"


log "Ожидание синхронизации (может занять несколько минут)"

kubectl wait --for=jsonpath='{.status.health.status}'=Healthy \
  application/boutique -n argocd --timeout=15m \
  || warn "приложение не дошло до Healthy за 15 минут — смотрите argocd app get boutique"

# --- 9. Результат -----------------------------------------------------------

log "Готово"

ARGO_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '<уже сменён>')"

GRAFANA_PW="$(kubectl get secret grafana-admin -n monitoring \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo '<см. секрет>')"

APP_IP="$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

# Балансировщик должен получить зарезервированный адрес. Расхождение значит,
# что GKE выдал случайный IP и имена nip.io указывают не туда.
if [[ -n "${APP_IP}" && "${APP_IP}" != "${INGRESS_IP}" ]]; then
  warn "IP балансировщика (${APP_IP}) не совпал с зарезервированным (${INGRESS_IP})"
  warn "сертификаты и Ingress-хосты работать не будут — проверьте квоту на адреса"
fi

# Служебные интерфейсы наружу не публикуются — поднимаем туннели.
"${REPO_ROOT}/scripts/port-forward.sh" start

cat <<EOF

  ПУБЛИЧНО (через Ingress):

  Приложение:   https://${INGRESS_HOST}/

  ЛОКАЛЬНО (только через port-forward, наружу не смотрит):

  Argo CD:      http://localhost:8081   (admin / ${ARGO_PW})
  Grafana:      http://localhost:3000   (admin / ${GRAFANA_PW})
  Prometheus:   http://localhost:9090
  Alertmanager: http://localhost:9093

  Управление туннелями:
    ./scripts/port-forward.sh status
    ./scripts/port-forward.sh stop

  Registry:     ${REGISTRY_URL}
EOF

cat <<EOF

  Для секретов GitHub Actions:
    GCP_WIF_PROVIDER   ${WIF_PROVIDER}
    GCP_CI_SA          ${CI_SA}

  Удаление стенда: ./scripts/teardown.sh

EOF
