# Подробная инструкция по использованию скрипта экспорта/импорта конфигурации Kubernetes

## Оглавление
1. [Предварительные требования](#предварительные-требования)
2. [Установка зависимостей](#установка-зависимостей)
3. [Настройка скриптов](#настройка-скриптов)
4. [Экспорт конфигурации кластера](#экспорт-конфигурации-кластера)
5. [Импорт конфигурации кластера](#импорт-конфигурации-кластера)
6. [Структура выходных данных](#структура-выходных-данных)
7. [Примеры использования](#примеры-использования)
8. [Устранение неполадок](#устранение-неполадок)

## Предварительные требования

### 1. Проверка доступа к Kubernetes кластеру

```bash
# Проверьте, что kubectl настроен на нужный кластер
kubectl cluster-info

# Проверьте список namespace'ов
kubectl get namespaces

# Проверьте список подов во всех namespace'ах
kubectl get pods --all-namespaces
```

### 2. Проверка доступного места на диске
Убедитесь, что есть достаточно места для хранения образов (обычно требуется 1-10 ГБ в зависимости от размера кластера).

```bash
# Проверка свободного места
df -h

# Рекомендуется минимум 10 ГБ свободного места
```

## Установка зависимостей

### 1. Установка yq (YAML processor)

**Для Linux:**
```bash
# Скачайте последнюю версию yq
wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
chmod +x /usr/local/bin/yq

# Проверка установки
yq --version
```

**Для macOS:**
```bash
# Установка через Homebrew
brew install yq

# Проверка установки
yq --version
```

**Для Windows:**
```bash
# Установка через Chocolatey
choco install yq

# Или через scoop
scoop install yq
```

### 2. Установка Docker или Podman (для работы с образами)

**Docker:**
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install docker.io
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER

# Перелогиньтесь или выполните:
newgrp docker
```

**Podman:**
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install podman

# CentOS/RHEL
sudo yum install podman
```

### 3. Скачивание скриптов

Создайте директорию для работы со скриптами:

```bash
mkdir k8s-backup-scripts
cd k8s-backup-scripts
git clone https://github.com/nix1am/k8s-io.git
```
Сделайте скрипты исполняемыми:

```bash
chmod +x export-k8s-config.sh import-k8s-config.sh
```

## Настройка скриптов

### Проверка конфигурации перед запуском

```bash
# Проверьте, что все зависимости установлены
./export-k8s-config.sh --check

# Проверьте доступ к кластеру
kubectl auth can-i get pods --all-namespaces
kubectl auth can-i get secrets --all-namespaces
```

### Настройка параметров (опционально)

Вы можете отредактировать скрипт, чтобы изменить:

- Список экспортируемых ресурсов
- Количество строк в логах
- Исключить определенные namespace'ы

```bash
# Для исключения системных namespace'ов добавьте в скрипт:
EXCLUDED_NAMESPACES=("kube-system" "kube-public" "kube-node-lease")
```

## Экспорт конфигурации кластера

### Базовое использование

```bash
# Простой экспорт (использует имя кластера из конфигурации kubectl)
./export-k8s-config.sh

# Экспорт с указанием имени кластера
./export-k8s-config.sh my-production-cluster

# Экспорт с указанием конкретного namespace
./export-k8s-config.sh --namespace my-app
```

### Расширенные опции

```bash
# Экспорт только определенных ресурсов
./export-k8s-config.sh --resources deployments,services,configmaps

# Экспорт без скачивания образов (только манифесты)
./export-k8s-config.sh --skip-images

# Экспорт с дополнительными логами
./export-k8s-config.sh --verbose

# Экспорт в указанную директорию
./export-k8s-config.sh --output /path/to/backup
```

### Пример полного экспорта продакшн кластера

```bash
# 1. Проверка доступного места
df -h /home

# 2. Экспорт с именем кластера
./export-k8s-config.sh production-cluster-01

# 3. Мониторинг процесса (в другом терминале)
watch -n 5 'du -sh k8s-backup-* && find k8s-backup-* -name "*.tar" | wc -l'

# 4. Проверка результатов
ls -la k8s-backup-20231201-143022/
```

### Что происходит во время экспорта:

1. **Проверка зависимостей** - kubectl, yq, docker/podman
2. **Создание структуры директорий**
3. **Экспорт манифестов**:
   - Namespace'ы
   - Workload'ы (Deployments, StatefulSets, etc.)
   - Сервисы и сетевые политики
   - Конфигурации (ConfigMaps, Secrets)
   - RBAC ресурсы
4. **Извлечение образов** из манифестов
5. **Скачивание образов** в .tar файлы
6. **Экспорт логов** подов
7. **Создание документации**

## Импорт конфигурации кластера

### Подготовка целевого кластера

```bash
# Проверка целевого кластера
kubectl cluster-info
kubectl get nodes

# Убедитесь, что есть достаточно ресурсов
kubectl top nodes
```

### Восстановление конфигурации

```bash
# Базовое восстановление
./import-k8s-config.sh ./k8s-backup-20231201-143022

# Восстановление только манифестов (без образов)
./import-k8s-config.sh --skip-images ./k8s-backup-20231201-143022

# Восстановление с предварительным просмотром
./import-k8s-config.sh --dry-run ./k8s-backup-20231201-143022

# Восстановление определенных namespace'ов
./import-k8s-config.sh --namespace my-app ./k8s-backup-20231201-143022
```

### Пошаговое восстановление

```bash
# 1. Только загрузка образов
./import-k8s-config.sh --images-only ./k8s-backup-20231201-143022

# 2. Только манифесты (после загрузки образов)
./import-k8s-config.sh --manifests-only ./k8s-backup-20231201-143022

# 3. Проверка развернутых ресурсов
kubectl get all --all-namespaces
kubectl get pvc --all-namespaces
```

### Восстановление вручную (если нужно)

```bash
# 1. Загрузка образов
for image in ./k8s-backup-20231201-143022/images/*.tar; do
    echo "Загрузка: $image"
    docker load -i "$image"
done

# 2. Применение манифестов
kubectl apply -f ./k8s-backup-20231201-143022/manifests/namespaces/
kubectl apply -f ./k8s-backup-20231201-143022/manifests/ --recursive
```

## Структура выходных данных

```
k8s-backup-20231201-143022/
├── README.md                      # Документация бэкапа
├── cluster-info.txt              # Информация о кластере
├── version.txt                   # Версии Kubernetes
├── all-images.txt               # Список всех образов
├── manifests/                   # YAML манифесты
│   ├── namespaces/              # Ресурсы по namespace'ам
│   │   ├── default/
│   │   │   ├── deployments/
│   │   │   ├── services/
│   │   │   ├── configmaps/
│   │   │   └── secrets/
│   │   ├── kube-system/
│   │   └── my-app/
│   ├── clusterroles/            # Кластерные роли
│   ├── storageclasses/          # Storage classes
│   ├── persistentvolumes/       # PV
│   └── customresourcedefinitions/ # CRD
├── images/                      # Docker образы
│   ├── nginx_1.25-alpine.tar
│   ├── postgres_15.3.tar
│   └── redis_7.0.11.tar
└── logs/                        # Логи подов
    ├── default/
    │   ├── nginx-pod.log
    │   └── postgres-pod.log
    └── kube-system/
        ├── coredns-pod.log
        └── metrics-server-pod.log
```

## Примеры использования

### Пример 1: Миграция между кластерами

```bash
# На исходном кластере
./export-k8s-config.sh old-cluster

# Копируем бэкап на новую машину
rsync -avz k8s-backup-20231201-143022/ user@new-server:/backups/

# На целевом кластере
./import-k8s-config.sh /backups/k8s-backup-20231201-143022
```

### Пример 2: Бэкап для version control

```bash
# Экспорт без образов (только манифесты)
./export-k8s-config.sh --skip-images my-cluster

# Добавление в git
cd k8s-backup-20231201-143022
git init
git add .
git commit -m "K8s configuration backup $(date)"

# Отправка в удаленный репозиторий
git remote add origin https://github.com/my-org/k8s-config.git
git push -u origin main
```

### Пример 3: Восстановление конкретного приложения

```bash
# Экспорт только нужного namespace
kubectl get ns my-app || ./export-k8s-config.sh --namespace my-app

# Восстановление только этого namespace
./import-k8s-config.sh --namespace my-app ./k8s-backup-20231201-143022
```

## Устранение неполадок

### Частые проблемы и решения

**Проблема**: `Error: unable to retrieve cluster-info`
```bash
# Решение: Проверьте конфигурацию kubectl
kubectl config current-context
kubectl config get-contexts
kubectl config use-context правильный-контекст
```

**Проблема**: `yq: command not found`
```bash
# Решение: Установите yq
wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
chmod +x /usr/local/bin/yq
```

**Проблема**: `Permission denied` при скачивании образов
```bash
# Решение: Добавьте пользователя в группу docker
sudo usermod -aG docker $USER
newgrp docker
```

**Проблема**: Не хватает места на диске
```bash
# Решение: Экспорт без образов или очистка места
./export-k8s-config.sh --skip-images
# или
docker system prune -a
```

**Проблема**: Ошибки при применении манифестов
```bash
# Решение: Применяйте ресурсы в правильном порядке
kubectl apply -f manifests/namespaces/
kubectl apply -f manifests/storageclasses/
kubectl apply -f manifests/ --recursive
```

### Логи и отладка

```bash
# Включение подробного вывода
./export-k8s-config.sh --verbose 2>&1 | tee backup.log

# Просмотр логов в реальном времени
tail -f backup.log

# Проверка конкретного ресурса
kubectl get deployment my-app -o yaml > debug.yaml
```

### Валидация бэкапа

```bash
# Проверка структуры бэкапа
tree k8s-backup-20231201-143022/

# Проверка целостности YAML файлов
find k8s-backup-20231201-143022/ -name "*.yaml" -exec yq eval '.' {} > /dev/null \;

# Проверка образов
docker images | grep -f k8s-backup-20231201-143022/all-images.txt
```
