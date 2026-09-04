# Online Boutique в Managed Kubernetes

Микросервисное приложение из одиннадцати сервисов, развёрнутое в GKE.
Инфраструктура описана Terraform, упаковка — Helm, доставка — Argo CD,
мониторинг — Prometheus и Grafana, уведомления — Telegram.

Копия `GoogleCloudPlatform/microservices-demo`.

## Содержимое

| Каталог | Назначение |
|---|---|
| `src/` | Исходники микросервисов |
| `infra/terraform/` | VPC, GKE, Artifact Registry, Workload Identity Federation |
| `deploy/helm/onlineboutique/` | Helm chart приложения |
| `deploy/argocd/` | Application для Argo CD |
| `deploy/monitoring/` | Правила алертинга, конфигурация Alertmanager |
| `scripts/` | `bootstrap.sh`, `teardown.sh` |
| `docs/` | `architecture.md`, `runbook.md` |
| `.github/workflows/` | `ci.yaml`, `cd.yaml` |

## Требования

`gcloud`, `terraform`, `kubectl` с `gke-gcloud-auth-plugin`, `helm`,
`docker`, `kubeseal`. Проект GCP с привязанным биллингом.

## Локальный запуск

```bash
docker compose up -d
curl -f http://localhost:8080/_healthz
```

Витрина на `http://localhost:8080`. По умолчанию используются
опубликованные образы; чтобы запустить собранные пайплайном, задайте
переменные:

```bash
REGISTRY=europe-central2-docker.pkg.dev/<проект>/boutique TAG=<sha> docker compose up -d
```

## Развёртывание

Аутентификация выполняется вручную, автоматизировать её нельзя:

```bash
gcloud auth login && gcloud auth application-default login
gcloud billing projects link <проект> --billing-account=<ID>
```

Дальше одной командой:

```bash
PROJECT_ID=<проект> ./scripts/bootstrap.sh
```

Скрипт выполняет проверки окружения, создаёт бакет под состояние Terraform,
применяет Terraform, получает kubeconfig, разворачивает Argo CD, стек
мониторинга и NGINX Ingress, регистрирует Application, дожидается готовности
и печатает адреса. Повторный запуск идемпотентен.

## Сборка и доставка

Пуш в любую ветку запускает CI: hadolint, `helm lint`, `terraform fmt` и
`validate`, `go test` и `dotnet test`, сборка одиннадцати образов,
публикация их в Artifact Registry с тегом, равным git sha, и публикация
Helm chart в OCI-репозиторий. Результат приходит в Telegram.

Пуш в `main` после успешного CI запускает CD: он обновляет `images.tag`
в `deploy/helm/onlineboutique/values-prod.yaml` и коммитит изменение.
Кластер приводит к состоянию из Git только Argo CD; доступа к кластеру у
пайплайнов нет.

## Откат

```bash
argocd app set boutique --sync-policy none      # иначе откат отклоняется
argocd app history boutique
argocd app rollback boutique <номер ревизии>
```

Argo CD не выполняет откат при включённой автосинхронизации: она сразу
вернула бы состояние из Git. После отката приложение остаётся `OutOfSync`
— кластер на старой версии, Git на новой.

Вернуть соответствие можно двумя способами. Включить автосинхронизацию
обратно, и тогда кластер догонит Git:

```bash
argocd app set boutique --sync-policy automated --auto-prune --self-heal
```

Либо откатить сам Git, если проблема в выкаченной версии:

```bash
git revert <коммит> && git push
```

## Доступ к интерфейсам

Витрина и мониторинг опубликованы через Ingress с сертификатами
Let's Encrypt:

| Что | Адрес |
|---|---|
| Витрина | `https://<адрес>.nip.io` |
| Grafana | `https://grafana.<адрес>.nip.io` |
| Prometheus | `https://prometheus.<адрес>.nip.io` |
| Alertmanager | `https://alertmanager.<адрес>.nip.io` |

Prometheus и Alertmanager не имеют собственной аутентификации, поэтому
закрыты basic auth на уровне Ingress. Пароли хранятся в SealedSecret.

Argo CD наружу не публикуется:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Пароль Argo CD:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Удаление

```bash
./scripts/teardown.sh
```

Скрипт снимает Argo CD, Service типа LoadBalancer и PersistentVolumeClaim
до `terraform destroy`: эти ресурсы создаёт Kubernetes, в состоянии
Terraform их нет, и при обратном порядке в проекте остаются
тарифицируемые диски и правила переадресации. В конце выводятся
контрольные списки ресурсов.

## Секреты

В репозитории секретов нет. Пайплайны обращаются к GCP через Workload
Identity Federation, ключи сервисных аккаунтов не создаются. Kubeconfig
получается через `gcloud container clusters get-credentials` и не хранится
в git. Конфигурация Alertmanager содержит токен бота и хранится как
SealedSecret — расшифровать её может только контроллер в кластере.
