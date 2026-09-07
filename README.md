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
| `deploy/monitoring/` | Правила алертинга, дашборд, проба blackbox |
| `deploy/secrets/` | Шаблоны секретов без значений |
| `scripts/` | `bootstrap.sh`, `teardown.sh`, `port-forward.sh` |
| `docs/` | `architecture.md`, `runbook.md` |
| `.github/workflows/` | `ci.yaml`, `cd.yaml` |

## Требования

`gcloud`, `terraform`, `kubectl` с `gke-gcloud-auth-plugin`, `helm`,
`docker`, `envsubst`, `openssl`. Желательно `gh` — без него после полного
удаления некому пересобрать образы. Проект GCP с привязанным биллингом.

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

Наружу опубликовано только приложение — через Ingress с сертификатом
Let's Encrypt:

| Что | Адрес |
|---|---|
| Витрина | `https://<адрес>.nip.io` |

Служебные интерфейсы публичного адреса не имеют. У Prometheus и
Alertmanager нет собственной аутентификации, а веб-интерфейс Alertmanager
позволяет заглушать алерты, поэтому доступ к ним идёт через туннель,
видимый только владельцу kubeconfig:

```bash
./scripts/port-forward.sh start
```

| Что | Адрес |
|---|---|
| Argo CD | `http://localhost:8081` |
| Grafana | `http://localhost:3000` |
| Prometheus | `http://localhost:9090` |
| Alertmanager | `http://localhost:9093` |

Туннели поднимаются автоматически в конце `bootstrap.sh`. Управление —
`./scripts/port-forward.sh status` и `stop`.

Пароли:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

```bash
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
```

Пароль Grafana генерируется при первом развёртывании и печатается в конце
работы `bootstrap.sh`.

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
в git. Секреты кластера создаёт `bootstrap.sh`: пароли генерируются при первом
развёртывании и не перезаписываются при повторных, конфигурация
Alertmanager собирается из шаблона `deploy/secrets/alertmanager.tmpl.yaml`
с подстановкой токена бота из `.env`. Файл `.env` в git не попадает,
образец — `.env.example`.
