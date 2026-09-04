# Runbook

## Доступ

```bash
gcloud container clusters get-credentials boutique \
  --zone europe-central2-a --project <проект>
```

| Что | Как |
|---|---|
| Витрина | `kubectl get svc ingress-nginx-controller -n ingress-nginx` → внешний IP |
| Argo CD | `kubectl port-forward svc/argocd-server -n argocd 8080:443` |
| Grafana | `kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80`, `admin` / `prom-operator` |
| Prometheus | `kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090` |
| Alertmanager | `kubectl port-forward svc/monitoring-kube-prometheus-alertmanager -n monitoring 9093:9093` |

Пароль Argo CD:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Логи

```bash
kubectl -n boutique logs deploy/frontend --tail=100 -f
kubectl -n boutique logs -l app=checkoutservice --tail=200
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=100
```

Логи всех подов собираются также в Cloud Logging. Запрос по приложению:

```
resource.type="k8s_container"
resource.labels.cluster_name="boutique"
resource.labels.namespace_name="boutique"
```

## Проверка состояния

```bash
kubectl get applications -n argocd          # должно быть Synced + Healthy
kubectl get pods -n boutique
kubectl get pvc -n boutique                 # redis-data-redis-cart-0 = Bound
curl -s -o /dev/null -w '%{http_code}\n' http://<IP>/
```

## Типовые ситуации

### Витрина не отвечает, поды Running

Проверить Ingress и политику доступа контроллера к поду:

```bash
kubectl get ingress -n boutique
kubectl get networkpolicy -n boutique | grep from-ingress-controller
```

Политика `frontend` из upstream пропускает трафик только от
`loadgenerator`. Доступ для NGINX Ingress Controller даёт отдельная
политика `frontend-from-ingress-controller`; если её нет, снаружи
приложение недоступно при работающих подах.

### Argo CD показывает OutOfSync и не синхронизирует

```bash
kubectl -n argocd patch app boutique --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
kubectl -n argocd describe app boutique | tail -30
```

После `argocd app rollback` автосинхронизация отключается намеренно.
Включить обратно:

```bash
argocd app set boutique --sync-policy automated --auto-prune --self-heal
```

### Изменение в deploy/argocd не применилось

Манифесты `Application` не синхронизируются самим Argo CD — они
применяются `kubectl` из `bootstrap.sh`. После правки нужно применить их
явно:

```bash
kubectl apply -n argocd -f deploy/argocd/
```

### Корзина пустеет при рестарте пода

Проверить, что Redis развёрнут как StatefulSet с томом:

```bash
kubectl -n boutique get statefulset redis-cart
kubectl -n boutique get pvc
```

Если вместо StatefulSet Deployment — в values не включено
`cartDatabase.inClusterRedis.persistence.enabled`.

### CI падает на go test

Анализатор `vet` в Go 1.25 считает ошибкой неконстантную строку формата.
Типичный случай — `status.Errorf(codes.X, err.Error())`; правильно
`status.Error`.

### Уведомления не приходят

```bash
kubectl -n monitoring get secret alertmanager-boutique
kubectl -n monitoring get alertmanager monitoring-kube-prometheus-alertmanager \
  -o jsonpath='{.spec.configSecret}{"\n"}'
```

Пустой `configSecret` означает, что Alertmanager использует конфигурацию
чарта, а не нашу. Для CI проверить наличие секретов `TELEGRAM_TOKEN` и
`TELEGRAM_CHAT_ID` в репозитории: при пустом `chat_id` шаг завершается
успешно, но сообщение не отправляется.

## Алерты

| Алерт | Условие | Первые действия |
|---|---|---|
| `BoutiquePodNotReady` | Под не в Ready более 5 минут | `kubectl -n boutique describe pod <под>`, затем логи |
| `BoutiqueHighErrorRate` | Более 5% ответов 5xx за 5 минут | `kubectl get pods -n boutique`, искать упавший бэкенд |
| `BoutiqueHighLatency` | p95 выше 1 секунды | Проверить нагрузку и ресурсы подов |

## Проверка персистентности

```bash
# положить товар в корзину через витрину, затем:
kubectl -n boutique delete pod redis-cart-0
kubectl -n boutique wait --for=condition=ready pod/redis-cart-0 --timeout=120s
kubectl -n boutique get pvc     # том тот же
# корзина на месте
```

## Откат версии

```bash
argocd app history boutique
argocd app rollback boutique <номер>
```

Затем привести Git в соответствие:

```bash
git revert <коммит> && git push
```

## Удаление стенда

```bash
PROJECT_ID=<проект> ./scripts/teardown.sh
```

Порядок внутри скрипта существенен. После выполнения проверить, что
списки ресурсов пусты:

```bash
gcloud container clusters list --project <проект>
gcloud compute disks list --project <проект>
gcloud compute forwarding-rules list --project <проект>
gcloud compute addresses list --project <проект>
```
