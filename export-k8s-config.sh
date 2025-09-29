#!/bin/bash

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Переменные
CLUSTER_NAME=${1:-"my-cluster"}
EXPORT_DIR="./k8s-backup-$(date +%Y%m%d-%H%M%S)"
IMAGES_DIR="$EXPORT_DIR/images"
MANIFESTS_DIR="$EXPORT_DIR/manifests"
LOGS_DIR="$EXPORT_DIR/logs"

# Создание директорий
mkdir -p "$EXPORT_DIR" "$IMAGES_DIR" "$MANIFESTS_DIR" "$LOGS_DIR"

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Функция для экспорта ресурсов
export_resource() {
    local resource_type=$1
    local namespace=${2:-}
    local ns_flag=""
    
    if [[ -n "$namespace" && "$namespace" != "all" ]]; then
        ns_flag="-n $namespace"
    fi
    
    log "Экспорт $resource_type..."
    
    # Получаем список ресурсов
    local resources=$(kubectl get $resource_type $ns_flag -o name 2>/dev/null | cut -d'/' -f2 || true)
    
    if [[ -z "$resources" ]]; then
        warn "Ресурсы $resource_type не найдены"
        return 0
    fi
    
    # Создаем поддиректорию для ресурса
    local resource_dir="$MANIFESTS_DIR/$resource_type"
    if [[ -n "$namespace" && "$namespace" != "all" ]]; then
        resource_dir="$MANIFESTS_DIR/namespaces/$namespace/$resource_type"
    fi
    mkdir -p "$resource_dir"
    
    # Экспортируем каждый ресурс
    for resource in $resources; do
        local output_file="$resource_dir/$resource.yaml"
        kubectl get $resource_type $resource $ns_flag -o yaml > "$output_file"
        
        # Очищаем служебные поля
        yq eval 'del(.metadata.creationTimestamp, .metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .status)' -i "$output_file" 2>/dev/null || true
    done
    
    log "Экспортировано $(echo $resources | wc -w) $resource_type"
}

# Функция для извлечения образов из манифеста
extract_images_from_manifest() {
    local manifest_file=$1
    local images_file=$2
    
    # Ищем образы в различных полях
    grep -hE 'image:\s+.+' "$manifest_file" | sed 's/^[[:space:]]*image:[[:space:]]*//' | sort -u >> "$images_file"
    grep -hE 'repository:\s+.+' "$manifest_file" | sed 's/^[[:space:]]*repository:[[:space:]]*//' | sort -u >> "$images_file"
}

# Функция для скачивания образов
download_image() {
    local image=$1
    local safe_name=$(echo "$image" | tr '/:' '_')
    local output_file="$IMAGES_DIR/${safe_name}.tar"
    
    if [[ -f "$output_file" ]]; then
        warn "Образ $image уже скачан"
        return 0
    fi
    
    log "Скачивание образа: $image"
    
    if command -v docker &> /dev/null; then
        docker pull "$image" && docker save "$image" -o "$output_file" && \
        log "Образ $image сохранен в $output_file"
    elif command -v podman &> /dev/null; then
        podman pull "$image" && podman save "$image" -o "$output_file" && \
        log "Образ $image сохранен в $output_file"
    else
        warn "Docker/Podman не установлен, пропускаем скачивание образов"
        return 1
    fi
}

# Основная функция
main() {
    log "Начало экспорта конфигурации кластера: $CLUSTER_NAME"
    log "Директория экспорта: $EXPORT_DIR"
    
    # Создаем файл с информацией о кластере
    kubectl cluster-info > "$EXPORT_DIR/cluster-info.txt" 2>/dev/null || true
    kubectl version > "$EXPORT_DIR/version.txt" 2>/dev/null || true
    
    # Экспортируем namespace'ы
    log "Экспорт namespaces..."
    kubectl get namespaces -o name | cut -d'/' -f2 | while read ns; do
        mkdir -p "$MANIFESTS_DIR/namespaces/$ns"
        kubectl get namespace "$ns" -o yaml > "$MANIFESTS_DIR/namespaces/$ns/namespace.yaml"
        yq eval 'del(.metadata.creationTimestamp, .metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .status)' -i "$MANIFESTS_DIR/namespaces/$ns/namespace.yaml" 2>/dev/null || true
    done
    
    # Список ресурсов для экспорта (кластерные)
    CLUSTER_RESOURCES=(
        "storageclasses"
        "persistentvolumes"
        "clusterroles"
        "clusterrolebindings"
        "customresourcedefinitions"
        "validatingwebhookconfigurations"
        "mutatingwebhookconfigurations"
        "nodes"
        "persistentvolumeclaims"
    )
    
    # Список ресурсов для экспорта (namespace-scoped)
    NAMESPACED_RESOURCES=(
        "pods"
        "deployments"
        "statefulsets"
        "daemonsets"
        "replicasets"
        "services"
        "configmaps"
        "secrets"
        "serviceaccounts"
        "roles"
        "rolebindings"
        "ingresses"
        "networkpolicies"
        "poddisruptionbudgets"
        "horizontalpodautoscalers"
        "verticalpodautoscalers"
        "jobs"
        "cronjobs"
    )
    
    # Экспорт кластерных ресурсов
    for resource in "${CLUSTER_RESOURCES[@]}"; do
        export_resource "$resource"
    done
    
    # Экспорт namespace-scoped ресурсов
    kubectl get namespaces -o name | cut -d'/' -f2 | while read ns; do
        log "Экспорт ресурсов в namespace: $ns"
        for resource in "${NAMESPACED_RESOURCES[@]}"; do
            export_resource "$resource" "$ns"
        done
    done
    
    # Собираем все образы
    log "Сбор информации об образах..."
    local images_file="$EXPORT_DIR/all-images.txt"
    touch "$images_file"
    
    find "$MANIFESTS_DIR" -name "*.yaml" -type f | while read file; do
        extract_images_from_manifest "$file" "$images_file"
    done
    
    # Убираем дубликаты и пустые строки
    sort -u "$images_file" -o "$images_file"
    sed -i '/^$/d' "$images_file"
    
    # Скачиваем образы
    if [[ -s "$images_file" ]]; then
        log "Найдено образов: $(wc -l < "$images_file")"
        log "Начинаем скачивание образов..."
        
        while IFS= read -r image; do
            if [[ -n "$image" ]]; then
                download_image "$image" || true
            fi
        done < "$images_file"
    else
        warn "Образы не найдены"
    fi
    
    # Экспортируем логи (опционально)
    log "Экспорт логов (последние 100 строк)..."
    kubectl get namespaces -o name | cut -d'/' -f2 | while read ns; do
        kubectl get pods -n "$ns" -o name | cut -d'/' -f2 | while read pod; do
            mkdir -p "$LOGS_DIR/$ns"
            kubectl logs -n "$ns" "$pod" --tail=100 > "$LOGS_DIR/$ns/$pod.log" 2>/dev/null || true
        done
    done
    
    # Создаем README файл
    cat > "$EXPORT_DIR/README.md" << EOF
# Kubernetes Cluster Backup

- **Cluster**: $CLUSTER_NAME
- **Export Date**: $(date)
- **Kubectl Version**: $(kubectl version --short 2>/dev/null || echo "unknown")

## Структура директорий:

- \`manifests/\` - YAML манифесты ресурсов
  - \`namespaces/\` - ресурсы сгруппированы по namespace'ам
  - ресурсы кластерного уровня
- \`images/\` - Docker образы в формате .tar
- \`logs/\` - логи подов (последние 100 строк)
- \`all-images.txt\` - список всех используемых образов

## Восстановление:

1. Восстановить namespaces: \`kubectl apply -f manifests/namespaces/\`
2. Восстановить кластерные ресурсы: \`kubectl apply -f manifests/\`
3. Загрузить образы: \`for img in images/*.tar; do docker load -i \$img; done\`
4. Восстановить workload'ы: \`kubectl apply -f manifests/namespaces/\`

EOF
    
    log "Экспорт завершен!"
    log "Результаты сохранены в: $EXPORT_DIR"
    log "Общий размер: $(du -sh "$EXPORT_DIR" | cut -f1)"
}

# Проверка зависимостей
check_dependencies() {
    local deps=("kubectl" "yq")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Отсутствуют зависимости: ${missing[*]}"
        error "Установите их перед запуском скрипта"
        exit 1
    fi
}

# Обработка сигналов
trap 'error "Скрипт прерван"; exit 1' INT TERM

# Запуск
check_dependencies
main