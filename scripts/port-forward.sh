#!/usr/bin/env bash
#
# Пробрасывает порты к сервисам стенда, чтобы не публиковать их наружу.
#
#   ./scripts/port-forward.sh start    поднять все проброски (по умолчанию)
#   ./scripts/port-forward.sh stop     остановить
#   ./scripts/port-forward.sh status   что сейчас работает
#
# Проброски живут в фоне, PID'ы пишутся в .port-forward/. Туннель существует,
# пока запущен процесс: наружу ничего не публикуется, облачный балансировщик
# не создаётся и не тарифицируется.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${REPO_ROOT}/.port-forward"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!   %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mX   %s\033[0m\n' "$*" >&2; exit 1; }

# имя|namespace|сервис|локальный порт|порт сервиса|схема
FORWARDS=(
  "Argo CD|argocd|svc/argocd-server|8081|80|http"
  "Grafana|monitoring|svc/monitoring-grafana|3000|80|http"
  "Prometheus|monitoring|svc/monitoring-kube-prometheus-prometheus|9090|9090|http"
  "Alertmanager|monitoring|svc/monitoring-kube-prometheus-alertmanager|9093|9093|http"
)

port_busy() {  # $1 — порт
  # Проброска слушает локально, поэтому проверяем именно listen-сокеты.
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":$1 "
  else
    netstat -an 2>/dev/null | grep -qE "[:.]$1[[:space:]].*LISTEN"
  fi
}

wait_endpoints() {  # $1 — namespace, $2 — имя сервиса, $3 — попыток (по 2 сек)
  local i
  for i in $(seq 1 "${3:-60}"); do
    if [[ -n "$(kubectl get endpoints "$2" -n "$1" \
                -o jsonpath='{.subsets[*].addresses[0].ip}' 2>/dev/null)" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

stop_all() {
  if [[ ! -d "${RUN_DIR}" ]]; then
    echo "    проброски не запускались"
    return 0
  fi
  local f pid port
  for f in "${RUN_DIR}"/*.pid; do
    [[ -e "${f}" ]] || continue
    port="$(basename "${f}" .pid)"
    pid="$(cat "${f}" 2>/dev/null || true)"
    # Сначала надзорный цикл, иначе он поднимет туннель обратно.
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
    fi
    # Затем сам kubectl: он дочерний процесс и не умирает вместе с циклом.
    pkill -f "port-forward.*${port}:" 2>/dev/null || true
    echo "    остановлен туннель на порт ${port}"
    rm -f "${f}"
  done
}

status_all() {
  local entry name ns svc local_port _ scheme pid_file pid
  for entry in "${FORWARDS[@]}"; do
    IFS='|' read -r name ns svc local_port _ scheme <<< "${entry}"
    pid_file="${RUN_DIR}/${local_port}.pid"
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      printf '    %-14s %s://localhost:%s\n' "${name}" "${scheme}" "${local_port}"
    else
      printf '    %-14s не запущен\n' "${name}"
    fi
  done
}

start_all() {
  command -v kubectl >/dev/null 2>&1 || die "не найден kubectl"
  kubectl cluster-info >/dev/null 2>&1 \
    || die "кластер недоступен: gcloud container clusters get-credentials ..."

  mkdir -p "${RUN_DIR}"

  local entry name ns svc local_port remote_port scheme pid
  for entry in "${FORWARDS[@]}"; do
    IFS='|' read -r name ns svc local_port remote_port scheme <<< "${entry}"

    # Сервиса может не быть: мониторинг ещё синхронизируется или отключён.
    if ! kubectl get "${svc}" -n "${ns}" >/dev/null 2>&1; then
      warn "${name}: ${svc} в namespace ${ns} не найден — пропускаю"
      continue
    fi

    # kubectl port-forward требует ЖИВОЙ под за сервисом: если под ещё
    # Pending или не прошёл readiness, туннель падает сразу после старта
    # ("pod is not running" / "lost connection to pod"). Ждём endpoints.
    if ! wait_endpoints "${ns}" "${svc#svc/}"; then
      warn "${name}: за ${svc} нет готовых подов — пропускаю"
      continue
    fi

    # Уже поднято этим же скриптом — не плодим дубликаты.
    pid="$(cat "${RUN_DIR}/${local_port}.pid" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      echo "    ${name}: уже проброшен на ${local_port}"
      continue
    fi

    if port_busy "${local_port}"; then
      warn "${name}: порт ${local_port} занят другим процессом — пропускаю"
      continue
    fi

    # kubectl port-forward привязан к конкретному поду и умирает вместе с ним:
    # при перезапуске пода, вытеснении spot-ноды или обновлении Deployment
    # туннель молча пропадает. Поэтому запускаем его под надзором — цикл
    # поднимает проброску заново, пока его самого не остановят.
    (
      while true; do
        kubectl port-forward -n "${ns}" "${svc}" "${local_port}:${remote_port}" \
          >>"${RUN_DIR}/${local_port}.log" 2>&1
        echo "--- туннель разорван, поднимаю заново $(date +%T)" \
          >>"${RUN_DIR}/${local_port}.log"
        sleep 3
      done
    ) &
    echo $! > "${RUN_DIR}/${local_port}.pid"
    echo "    ${name}: ${scheme}://localhost:${local_port}"
  done

  # Проверяем, что порт действительно начал слушаться.
  sleep 3
  local entry_check name_c ns_c svc_c port_c
  for entry_check in "${FORWARDS[@]}"; do
    IFS='|' read -r name_c ns_c svc_c port_c _ _ <<< "${entry_check}"
    [[ -f "${RUN_DIR}/${port_c}.pid" ]] || continue
    port_busy "${port_c}" \
      || warn "${name_c}: порт ${port_c} не слушается, смотрите ${RUN_DIR}/${port_c}.log"
  done
}

case "${1:-start}" in
  start)
    log "Проброска портов"
    start_all
    cat <<EOF

  Туннели работают в фоне. Остановить:
    ./scripts/port-forward.sh stop

  Пароль Grafana:
    kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d

  Пароль Argo CD (admin):
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

EOF
    ;;
  stop)
    log "Остановка проброски"
    stop_all
    ;;
  status)
    log "Состояние проброски"
    status_all
    ;;
  *)
    die "использование: $0 [start|stop|status]"
    ;;
esac
