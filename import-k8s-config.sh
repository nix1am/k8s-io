#!/bin/bash

set -e

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

BACKUP_DIR=${1:-"./k8s-backup"}
IMAGES_DIR="$BACKUP_DIR/images"
MANIFESTS_DIR="$BACKUP_DIR/manifests"

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Функция для загрузки образов
load_images() {
    if [[ -d "$IMAGES_DIR" ]]; then
        log "Загрузка Docker образов..."
        for image_file in "$IMAGES_DIR"/*.tar; do
            if [[ -f "$image_file" ]]; then
                log "Загрузка: $(basename "$image_file")"
                docker load -i "$image_file" || podman load -i "$image_file" || warn "Не удалось загрузить $image_file"
            fi
        done
    else
        warn "Директория с образами не найдена: $IMAGES_DIR"
    fi
}

# Функция для применения манифестов
apply_manifests() {
    if [[ -d "$MANIFESTS_DIR" ]]; then
        log "Применение манифестов..."
        
        # Сначала namespaces
        if [[ -d "$MANIFESTS_DIR/namespaces" ]]; then
            log "Применение namespaces..."
            kubectl apply -f "$MANIFESTS_DIR/namespaces" --recursive
        fi
        
        # Затем кластерные ресурсы (исключая namespaces)
        log "Применение кластерных ресурсов..."
        find "$MANIFESTS_DIR" -maxdepth 1 -name "*.yaml" -type f | while read file; do
            kubectl apply -f "$file"
        done
        
        for dir in "$MANIFESTS_DIR"/*/; do
            if [[ "$dir" != "$MANIFESTS_DIR/namespaces/" && -d "$dir" ]]; then
                kubectl apply -f "$dir" --recursive
            fi
        done
        
        # Затем ресурсы в namespaces
        if [[ -d "$MANIFESTS_DIR/namespaces" ]]; then
            log "Применение ресурсов в namespaces..."
            kubectl apply -f "$MANIFESTS_DIR/namespaces" --recursive
        fi
    else
        warn "Директория с манифестами не найдена: $MANIFESTS_DIR"
    fi
}

main() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo "Директория бэкапа не найдена: $BACKUP_DIR"
        exit 1
    fi
    
    log "Восстановление из директории: $BACKUP_DIR"
    
    # Загружаем образы
    load_images
    
    # Применяем манифесты
    apply_manifests
    
    log "Восстановление завершено!"
}

main