#!/bin/bash
# Phong of Chuc Backup System
# Author : Bui The Phong <buithephong@gmail.com>
# Description: Script to backup files, MySQL/MariaDB, or PostgreSQL databases

# Format log 
log() {
    local message="$1"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message"
}

# Hàm bắn tin nhắn thông báo lên Mattermost
send_mattermost_notification() {
    local status="$1"
    local details="$2"
    local color=""
    local icon=""
    
    if [ "$status" == "success" ]; then
        color="#36a64f"
        icon=":white_check_mark:"
    else
        color="#ff0000"
        icon=":x:"
    fi

    # Chuẩn bị thông tin về host
    local host_info=""
    if [[ "$BACKUP_TYPE" =~ ^(mysql|mariadb|postgresql[0-9]+)$ ]]; then
        host_info="**Database Host:** ${DB_HOST}:${DB_PORT}"
    else
        host_info="**Source Path:** ${BACKUP_SOURCE}"
    fi

    local payload=$(cat <<EOF
{
    "attachments": [{
        "color": "${color}",
        "title": "Backup Report ${icon}",
        "text": "**Backup Type:** ${BACKUP_TYPE}\n**Prefix:** ${BACKUP_PREFIX}\n${host_info}\n**Status:** ${status}\n**Date:** $(date +'%Y-%m-%d %H:%M:%S')\n\n${details}",
        "mrkdwn_in": ["text"]
    }]
}
EOF
)

    if [ -n "$MM_WEBHOOK_URL" ]; then
        curl -s -X POST -H 'Content-Type: application/json' -d "$payload" "$MM_WEBHOOK_URL"
        
        # Log kết quả gửi notification
        if [ $? -eq 0 ]; then
            log "Mattermost notification sent successfully"
        else
            log "Failed to send Mattermost notification"
        fi
    else
        log "Warning: Mattermost webhook URL not set"
    fi
}

# Hàm kiểm tra biến môi trường
check_env_variables() {
    local required_vars=("BACKUP_DESTINATION" "BACKUP_TYPE" "KEEP_BACKUP" "BACKUP_PREFIX")
    
    # Add database-specific required variables if backup type is database
    if [[ "$BACKUP_TYPE" =~ ^(mysql|mariadb|postgresql[0-9]+)$ ]]; then
        required_vars+=("DB_HOST" "DB_USER" "DB_PASSWORD" "DB_PORT")
    else
        required_vars+=("BACKUP_SOURCE")
    fi

    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -ne 0 ]; then
        log "Error: Missing required environment variables: ${missing_vars[*]}"
        exit 1
    fi

    # Hàm detect kiểu backup
    local valid_types=("file" "mysql" "mariadb" "postgresql15" "postgresql16" "postgresql17")
    if [[ ! " ${valid_types[@]} " =~ " ${BACKUP_TYPE} " ]]; then
        log "Error: Invalid BACKUP_TYPE. Must be one of: ${valid_types[*]}"
        exit 1
    fi
}

# Hàm tạo thư mục backup
create_backup_directory() {
    local backup_date=$(date +%Y%m%d)
    local backup_dir=""

    case "$BACKUP_TYPE" in
        file)
            backup_dir="$BACKUP_DESTINATION/files/$backup_date"
            ;;
        mysql|mariadb)
            backup_dir="$BACKUP_DESTINATION/$BACKUP_TYPE/$backup_date"
            ;;
        postgresql*)
            backup_dir="$BACKUP_DESTINATION/$BACKUP_TYPE/$backup_date"
            ;;
    esac

    mkdir -p "$backup_dir"
    if [ $? -ne 0 ]; then
        log "Error: Failed to create backup directory $backup_dir"
        exit 1
    fi

    echo "$backup_dir"
}

# Hàm backup file
backup_files() {
    local backup_dir=$(create_backup_directory)
    local backup_file="$backup_dir/${BACKUP_PREFIX}_files.tar.gz"
    local current_dir=$(pwd)

    log "Starting file backup..."
    log "Source: $BACKUP_SOURCE"
    log "Destination: $backup_file"

    cd "$BACKUP_SOURCE" || exit 1
    tar -czf "$backup_file" .
    local status=$?
    cd "$current_dir" || exit 1

    if [ $status -eq 0 ]; then
        log "File backup completed successfully"
        send_mattermost_notification "success" "File backup completed successfully\nBackup location: $backup_file"
        return 0
    else
        log "Error: File backup failed"
        send_mattermost_notification "failed" "File backup failed"
        return 1
    fi
}

# Hàm backup MySQL/MariaDB
backup_mysql_mariadb() {
    local backup_dir=$(create_backup_directory)
    local status=0
    local failed_dbs=()
    local success_dbs=()

    log "Starting $BACKUP_TYPE backup..."
    log "Database Host: $DB_HOST"
    log "Database Port: $DB_PORT"

    # Tạo file config tạm thời
    local mysql_config=$(mktemp)
    cat > "$mysql_config" <<EOF
[client]
host=$DB_HOST
user=$DB_USER
password=$DB_PASSWORD
port=$DB_PORT
EOF

    # Liệt kê danh sách database
    local databases=$(mysql --defaults-file="$mysql_config" -N -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "^(information_schema|performance_schema|mysql|sys)$")

    for db in $databases; do
        log "Backing up database: $db"
        local backup_file="$backup_dir/${BACKUP_PREFIX}_${db}.sql.gz"
        
        mysqldump --defaults-file="$mysql_config" --single-transaction "$db" 2>/dev/null | gzip > "$backup_file"
        if [ $? -eq 0 ]; then
            success_dbs+=("$db")
            log "Successfully backed up $db"
        else
            failed_dbs+=("$db")
            log "Failed to backup $db"
            status=1
        fi
    done

    # Xoá file config tạm thời
    rm -f "$mysql_config"

    local details="Successfully backed up: ${success_dbs[*]}"
    if [ ${#failed_dbs[@]} -ne 0 ]; then
        details+="\nFailed to backup: ${failed_dbs[*]}"
    fi

    if [ $status -eq 0 ]; then
        send_mattermost_notification "success" "$details"
    else
        send_mattermost_notification "failed" "$details"
    fi

    return $status
}

# Hàm backup PostgreSQL
backup_postgresql() {
    local backup_dir=$(create_backup_directory)
    local status=0
    local failed_dbs=()
    local success_dbs=()

    log "Starting PostgreSQL backup..."
    log "Database Host: $DB_HOST"
    log "Database Port: $DB_PORT"
    log "Using pg_dump command"

    # Lấy danh sách database
    log "Getting list of databases..."
    local databases=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "postgres" -t -A -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1', 'postgres') AND datistemplate = false;")
    local psql_exit_code=$?

    if [ $psql_exit_code -ne 0 ] || [ -z "$databases" ]; then
        log "Error: Could not get list of databases. Exit code: $psql_exit_code"
        log "Testing connection..."
        PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "postgres" -c "\l" || true
        send_mattermost_notification "failed" "Could not get list of databases from PostgreSQL server\nHost: $DB_HOST:$DB_PORT\nUser: $DB_USER"
        return 1
    fi

    log "Found databases: $databases"

    # Tạo temp file để lưu error output
    local error_log=$(mktemp)

    # Vòng lặp backup từng database
    echo "$databases" | while read -r db; do
        if [ -n "$db" ]; then
            log "Backing up database: $db"
            local backup_file="$backup_dir/${BACKUP_PREFIX}_${db}.sql.gz"
            
            # Debug
            PGPASSWORD="$DB_PASSWORD" pg_dump \
                -h "$DB_HOST" \
                -p "$DB_PORT" \
                -U "$DB_USER" \
                -Fp \
                --clean \
                --no-owner \
                --no-acl \
                "$db" 2>"$error_log" | gzip > "$backup_file"

            local dump_status=${PIPESTATUS[0]}
            if [ $dump_status -eq 0 ]; then
                success_dbs+=("$db")
                log "Successfully backed up $db to $backup_file"
            else
                failed_dbs+=("$db")
                # Xuất log lỗi
                log "Failed to backup $db with exit code $dump_status"
                log "Error detail: $(cat "$error_log")"
                status=1
            fi
        fi
    done

    # Xoá file log lỗi
    rm -f "$error_log"

    # Vẫn là debug
    if ! command -v pg_dump &> /dev/null; then
        log "Error: pg_dump command not found"
        log "Available pg_dump versions:"
        ls -l /usr/bin/pg_dump* || true
    else
        log "pg_dump command location: $(which pg_dump)"
        log "pg_dump version:"
        pg_dump --version
    fi

    # Debug tiếp
    log "Testing pg_dump connection to first database..."
    local test_db=$(echo "$databases" | head -n1)
    PGPASSWORD="$DB_PASSWORD" pg_dump \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        -d "$test_db" \
        --schema-only \
        --no-owner \
        --no-acl \
        2>"$error_log" > /dev/null

    if [ $? -ne 0 ]; then
        log "pg_dump connection test failed:"
        log "$(cat "$error_log")"
    else
        log "pg_dump connection test successful"
    fi

    local details="Backup Attempt Summary:\n"
    details+="Successfully backed up: ${success_dbs[*]}\n"
    details+="Failed to backup: ${failed_dbs[*]}\n"
    details+="Backup Directory: $backup_dir\n"
    details+="pg_dump version: $(pg_dump --version)"

    if [ $status -eq 0 ]; then
        send_mattermost_notification "success" "$details"
    else
        send_mattermost_notification "failed" "$details"
    fi

    return $status
}

# Hàm xoá backup cũ
cleanup_old_backups() {
    log "Cleaning up old backups..."
    local backup_base_dir=""

    case "$BACKUP_TYPE" in
        file)
            backup_base_dir="$BACKUP_DESTINATION/files"
            ;;
        mysql|mariadb)
            backup_base_dir="$BACKUP_DESTINATION/$BACKUP_TYPE"
            ;;
        postgresql*)
            backup_base_dir="$BACKUP_DESTINATION/$BACKUP_TYPE"
            ;;
    esac

    if [ -d "$backup_base_dir" ]; then
        # Giữ lại số lượng backup mới nhất
        local backup_count=$(ls -1 "$backup_base_dir" | wc -l)
        if [ "$backup_count" -gt "$KEEP_BACKUP" ]; then
            cd "$backup_base_dir" || exit 1
            ls -1t | tail -n +$((KEEP_BACKUP + 1)) | xargs rm -rf
            log "Cleaned up old backups. Keeping $KEEP_BACKUP most recent backups."
        fi
    fi
}

# Hàm main
main() {
    log "Starting backup process..."
    check_env_variables
    local status=0

    case "$BACKUP_TYPE" in
        file)
            backup_files
            status=$?
            ;;
        mysql|mariadb)
            backup_mysql_mariadb
            status=$?
            ;;
        postgresql*)
            backup_postgresql
            status=$?
            ;;
    esac

    if [ $status -eq 0 ]; then
        cleanup_old_backups
        log "Backup process completed successfully"
    else
        log "Backup process failed"
    fi

    return $status
}

# Chạy hàm main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
