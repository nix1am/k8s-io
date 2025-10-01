#!/bin/bash

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Переменные по умолчанию
CLUSTER_NAME="my-cluster"
EXPORT_DIR=""
IMAGES_DIR=""
MANIFESTS_DIR=""
LOGS_DIR=""
SKIP_IMAGES=false
VERBOSE=false
DRY_RUN=false
CHECK_ONLY=false

# Функции для вывода
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

debug() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Функция для показа помощи
show_help() {
    cat << EOF
Использование: $0 [OPTIONS] [CLUSTER_NAME]

Экспорт всей конфигурации Kubernetes кластера

Аргументы:
  CLUSTER_NAME              Имя кластера (по умолчанию: my-cluster)

Опции:
  -h, --help                Показать эту справку
  -c, --check               Проверить зависимости и подключение к кластеру
  -o, --output DIR          Директория для экспорта (по умолчанию: автоматически создаваемая)
  -n, --namespace NS        Экспорт только указанного namespace
  --skip-images             Не скачивать Docker образы
  --dry-run                Показать что будет экспортировано, но не выполнять
  -v, --verbose            Подробный вывод
  --version                Показать версию

Примеры:
  $0                          # Экспорт с именем кластера по умолчанию
  $0 production-cluster       # Экспорт с указанием имени кластера
  $0 --check                 # Проверить зависимости
  $0 --skip-images           # Экспорт только манифестов
  $0 --namespace my-app      # Экспорт только одного namespace
  $0 --output /backup        # Экспорт в указанную директорию
EOF
}

# Парсинг аргументов командной строки
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -c|--check)
                CHECK_ONLY=true
                shift
                ;;
            -o|--output)
                EXPORT_DIR="$2"
                shift 2
                ;;
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --skip-images)
                SKIP_IMAGES=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --version)
                echo "K8s Export Script v1.0.0"
                exit 0
                ;;
            -*)
                error "Неизвестная опция: $1"
                show_help
                exit 1
                ;;
            *)
                CLUSTER_NAME="$1"
                shift
                ;;
        esac
    done

    # Установка директории экспорта по умолчанию
    if [ -z "$EXPORT_DIR" ]; then
        EXPORT_DIR="./k8s-backup-$(date +%Y%m%d-%H%M%S)"
    fi

    IMAGES_DIR="$EXPORT_DIR/images"
    MANIFESTS_DIR="$EXPORT_DIR/manifests"
    LOGS_DIR="$EXPORT_DIR/logs"
}

# Проверка зависимостей
check_dependencies() {
    log "Проверка зависимостей..."
    
    local deps=("kubectl")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        else
            debug "$dep найден: $(which $dep)"
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Отсутствуют обязательные зависимости: ${missing[*]}"
        return 1
    fi

    # Проверка yq (опционально, но рекомендуется)
    if ! command -v yq &> /dev/null; then
        warn "yq не установлен. Будет использован grep для извлечения образов (менее надежно)"
    else
        debug "yq найден: $(yq --version)"
    fi

    # Проверка docker/podman (только если нужно скачивать образы)
    if [ "$SKIP_IMAGES" = false ]; then
        if ! command -v docker &> /dev/null && ! command -v podman &> /dev/null; then
            warn "Docker/Podman не установлен. Образы не будут скачаны."
            SKIP_IMAGES=true
        else
            if command -v docker &> /dev/null; then
                debug "Docker найден: $(docker --version)"
            else
                debug "Podman найден: $(podman --version)"
            fi
        fi
    fi

    return 0
}

# Проверка подключения к кластеру
check_cluster_connection() {
    log "Проверка подключения к кластеру..."
    
    if ! kubectl cluster-info &> /dev/null; then
        error "Не удалось подключиться к кластеру Kubernetes"
        error "Проверьте:"
        error "  1. Настроен ли kubectl на правильный кластер"
        error "  2. Доступен ли кластер"
        error "  3. Не истекли ли токены аутентификации"
        return 1
    fi

    local cluster_name
    cluster_name=$(kubectl config current-context 2>/dev/null || echo "unknown")
    log "Подключение к кластеру: $cluster_name"
    
    # Проверка прав доступа
    log "Проверка прав доступа..."
    if ! kubectl auth can-i get pods --all-namespaces &> /dev/null; then
        warn "Ограниченные права доступа. Некоторые ресурсы могут быть недоступны."
    else
        debug "Права доступа достаточны для полного экспорта"
    fi

    return 0
}

# Функция проверки (только проверка без экспорта)
check_only() {
    log "=== ПРОВЕРКА СИСТЕМЫ ==="
    
    if ! check_dependencies; then
        error "Проверка зависимостей не пройдена"
        return 1
    fi
    
    if ! check_cluster_connection; then
        error "Проверка подключения к кластеру не пройдена"
        return 1
    fi
    
    # Проверка доступных ресурсов
    log "Проверка доступных ресурсов в кластере..."
    local namespaces_count
    namespaces_count=$(kubectl get namespaces --no-headers 2>/dev/null | wc -l || echo "0")
    log "Найдено namespace'ов: $namespaces_count"
    
    local nodes_count
    nodes_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
    log "Найдено узлов: $nodes_count"
    
    # Проверка места на диске
    local available_space
    available_space=$(df . | awk 'NR==2 {print $4}')
    log "Доступное место в текущей директории: $available_space"
    
    if [ "$available_space" -lt 1048576 ]; then  # Меньше 1GB
        warn "Мало свободного места. Рекомендуется минимум 1GB для экспорта."
    fi
    
    log "=== ПРОВЕРКА ЗАВЕРШЕНА УСПЕШНО ==="
    log "Все зависимости удовлетворены"
    log "Подключение к кластеру работает"
    log "Система готова к экспорту"
    
    return 0
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
    local resources
    resources=$(kubectl get $resource_type $ns_flag -o name 2>/dev/null | cut -d'/' -f2 || true)
    
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
    local count=0
    for resource in $resources; do
        local output_file="$resource_dir/$resource.yaml"
        if [ "$DRY_RUN" = true ]; then
            debug "DRY RUN: Экспорт $resource_type/$resource"
        else
            kubectl get $resource_type $resource $ns_flag -o yaml > "$output_file"
            
            # Очищаем служебные поля если установлен yq
            if command -v yq &> /dev/null; then
                yq eval 'del(.metadata.creationTimestamp, .metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .status)' -i "$output_file" 2>/dev/null || true
            fi
        fi
        ((count++))
    done
    
    log "Экспортировано $count $resource_type"
}

# Функция для извлечения образов из манифеста
extract_images_from_manifest() {
    local manifest_file=$1
    local images_file=$2
    
    if command -v yq &> /dev/null; then
        # Используем yq для надежного извлечения
        yq eval '.. | select(has("image")) | .image' "$manifest_file" 2>/dev/null | grep -v null >> "$images_file" || true
    else
        # Fallback на grep (менее надежно)
        grep -hE 'image:\s+.+' "$manifest_file" | sed 's/^[[:space:]]*image:[[:space:]]*//' | sort -u >> "$images_file" || true
    fi
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
    
    if [ "$DRY_RUN" = true ]; then
        debug "DRY RUN: Скачивание образа $image"
        return 0
    fi
    
    if command -v docker &> /dev/null; then
        if docker pull "$image" && docker save "$image" -o "$output_file"; then
            log "Образ $image сохранен в $output_file"
        else
            warn "Не удалось скачать образ: $image"
            return 1
        fi
    elif command -v podman &> /dev/null; then
        if podman pull "$image" && podman save "$image" -o "$output_file"; then
            log "Образ $image сохранен в $output_file"
        else
            warn "Не удалось скачать образ: $image"
            return 1
        fi
    else
        warn "Docker/Podman не установлен, пропускаем скачивание образов"
        return 1
    fi
}

# Основная функция экспорта
main_export() {
    log "Начало экспорта конфигурации кластера: $CLUSTER_NAME"
    log "Директория экспорта: $EXPORT_DIR"
    
    if [ "$DRY_RUN" = true ]; then
        warn "РЕЖИМ ПРЕДПРОСМОТРА - файлы не будут созданы"
    else
        # Создаем директории
        mkdir -p "$EXPORT_DIR" "$IMAGES_DIR" "$MANIFESTS_DIR" "$LOGS_DIR"
    fi
    
    # Создаем файл с информацией о кластере
    if [ "$DRY_RUN" = false ]; then
        kubectl cluster-info > "$EXPORT_DIR/cluster-info.txt" 2>/dev/null || true
        kubectl version > "$EXPORT_DIR/version.txt" 2>/dev/null || true
    fi
    
    # Определяем namespace'ы для экспорта
    local namespaces
    if [ -n "$NAMESPACE" ]; then
        namespaces=("$NAMESPACE")
        log "Экспорт только namespace: $NAMESPACE"
    else
        namespaces=($(kubectl get namespaces -o name | cut -d'/' -f2))
        log "Экспорт всех namespace'ов: ${#namespaces[@]}"
    fi
    
    # Экспортируем namespace'ы
    log "Экспорт namespaces..."
    for ns in "${namespaces[@]}"; do
        if [ "$DRY_RUN" = true ]; then
            debug "DRY RUN: Экспорт namespace $ns"
        else
            mkdir -p "$MANIFESTS_DIR/namespaces/$ns"
            kubectl get namespace "$ns" -o yaml > "$MANIFESTS_DIR/namespaces/$ns/namespace.yaml"
            if command -v yq &> /dev/null; then
                yq eval 'del(.metadata.creationTimestamp, .metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .status)' -i "$MANIFESTS_DIR/namespaces/$ns/namespace.yaml" 2>/dev/null || true
            fi
        fi
    done
    
    # Список ресурсов для экспорта
    local cluster_resources=(
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
    
    local namespaced_resources=(
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
        "jobs"
        "cronjobs"
    )
    
    # Экспорт кластерных ресурсов
    for resource in "${cluster_resources[@]}"; do
        export_resource "$resource"
    done
    
    # Экспорт namespace-scoped ресурсов
    for ns in "${namespaces[@]}"; do
        log "Экспорт ресурсов в namespace: $ns"
        for resource in "${namespaced_resources[@]}"; do
            export_resource "$resource" "$ns"
        done
    done
    
    # Собираем все образы
    if [ "$SKIP_IMAGES" = false ]; then
        log "Сбор информации об образах..."
        local images_file="$EXPORT_DIR/all-images.txt"
        
        if [ "$DRY_RUN" = false ]; then
            touch "$images_file"
            find "$MANIFESTS_DIR" -name "*.yaml" -type f | while read -r file; do
                extract_images_from_manifest "$file" "$images_file"
            done
            
            # Убираем дубликаты и пустые строки
            sort -u "$images_file" -o "$images_file"
            sed -i '/^$/d' "$images_file"
        fi
        
        # Скачиваем образы
        if [ -s "$images_file" ] || [ "$DRY_RUN" = true ]; then
            local image_count=0
            if [ "$DRY_RUN" = false ]; then
                image_count=$(wc -l < "$images_file")
            fi
            log "Найдено образов: $image_count"
            
            if [ "$image_count" -gt 0 ] || [ "$DRY_RUN" = true ]; then
                log "Начинаем скачивание образов..."
                
                if [ "$DRY_RUN" = false ]; then
                    while IFS= read -r image; do
                        if [[ -n "$image" ]]; then
                            download_image "$image" || true
                        fi
                    done < "$images_file"
                fi
            fi
        else
            warn "Образы не найдены"
        fi
    else
        log "Пропуск скачивания образов (--skip-images)"
    fi
    
    # Экспортируем логи (опционально)
    if [ "$DRY_RUN" = false ]; then
        log "Экспорт логов (последние 100 строк)..."
        for ns in "${namespaces[@]}"; do
            kubectl get pods -n "$ns" -o name 2>/dev/null | cut -d'/' -f2 | while read -r pod; do
                mkdir -p "$LOGS_DIR/$ns"
                kubectl logs -n "$ns" "$pod" --tail=100 > "$LOGS_DIR/$ns/$pod.log" 2>/dev/null || true
            done
        done
    fi
    
    # Создаем README файл
    if [ "$DRY_RUN" = false ]; then
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
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log "ПРЕДПРОСМОТР ЗАВЕРШЕН - файлы не создавались"
    else
        log "Экспорт завершен!"
        log "Результаты сохранены в: $EXPORT_DIR"
        log "Общий размер: $(du -sh "$EXPORT_DIR" | cut -f1)"
    fi
}

# Обработка сигналов
trap 'error "Скрипт прерван"; exit 1' INT TERM

# Главная функция
main() {
    parse_arguments "$@"
    
    if [ "$CHECK_ONLY" = true ]; then
        check_only
        exit $?
    fi
    
    if ! check_dependencies; then
        error "Проверка зависимостей не пройдена"
        exit 1
    fi
    
    if ! check_cluster_connection; then
        error "Нет подключения к кластеру Kubernetes"
        error "Проверьте настройки kubectl и доступность кластера"
        exit 1
    fi
    
    main_export
}

# Запуск скрипта
main "$@"