# Hệ Thống Backup Tự Động

Giải pháp backup cho cơ sở dữ liệu MySQL, MariaDB, PostgreSQL và File/Folder, chạy trên Kubernetes.

## Tính Năng Chính

✨ **Đa dạng loại backup**:
- MySQL, MariaDB
- PostgreSQL (phiên bản 15/16/17)
- Backup hệ thống File/Folder

🔄 **Tự động hóa**:
- Lập lịch backup với Kubernetes CronJob
- Tự động dọn dẹp backup cũ
- Thông báo kết quả qua Mattermost

🔒 **Bảo mật**:
- Quản lý credential bằng Kubernetes Secrets
- Hỗ trợ private registry

## Yêu Cầu Hệ Thống

- Kubernetes cluster
- Persistent Volume cho lưu trữ backup
- Webhook URL Mattermost
- Thông tin đăng nhập database
- Quyền truy cập Docker registry

## Hướng Dẫn Cài Đặt

### 1. Tạo Namespace
```bash
kubectl create namespace backup
```

### 2. Tạo Secret cho Credentials
```bash
kubectl create secret generic backup \
  --from-literal=db_user=backup \
  --from-literal=db_password=your_password \
  --from-literal=mm_webhook_url=your_mattermost_webhook_url \
  -n backup
```

### 3. Tạo Secret cho Registry
```bash
kubectl create secret docker-registry luvina-registry \
  --docker-server=hub.docker.com \
  --docker-username=your_username \
  --docker-password=your_password \
  -n backup
```

## Cấu Hình Database User

### Cho PostgreSQL
```sql
-- Chạy với user postgres
CREATE USER backup WITH PASSWORD 'your_password';
ALTER USER backup WITH SUPERUSER;
```

### Cho MySQL/MariaDB
```sql
CREATE USER 'backup'@'%' IDENTIFIED BY 'your_password';
GRANT SELECT, SHOW VIEW, PROCESS, LOCK TABLES, SHOW DATABASES, REPLICATION CLIENT 
ON *.* TO 'backup'@'%';
FLUSH PRIVILEGES;
```

## Tạo Job Backup Mới

### 1. Tạo File CronJob (VD: `backup-cronjob.yaml`):

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  namespace: backup
  name: backup-dbredmine-database
  labels:
    app: backup
    component: database
    database: redmine
spec:
  schedule: "0 3 * * *"    # Chạy lúc 3 giờ sáng hàng ngày
  successfulJobsHistoryLimit: 3 # Giữ lại lịch sử 3 job thành công
  failedJobsHistoryLimit: 1 # Giữ lại lịch sử 1 job thất bại
  concurrencyPolicy: Forbid # Không cho phép chạy đồng thời
  jobTemplate:
    spec:
      backoffLimit: 3 # Số lần retry khi job thất bại
      template:
        spec:
          containers:
            - name: backup-dbredmine-database
              image: buithephong/backup:latest
              imagePullPolicy: Always
              resources:
                requests:
                  memory: "256Mi"
                  cpu: "200m"
                limits:
                  memory: "512Mi"
                  cpu: "500m"
              env:
              - name: BACKUP_TYPE
                value: "postgresql17"    # mysql, mariadb, postgresql15/16/17
              - name: BACKUP_PREFIX
                value: "dbredmine"
              - name: KEEP_BACKUP
                value: "7"
              - name: MM_WEBHOOK_URL
                valueFrom:
                  secretKeyRef:
                    name: backup
                    key: mm_webhook_url
              - name: BACKUP_DESTINATION
                value: "/home/backup"
              - name: DB_HOST
                value: "XXX.XXX.XXX.XXX"   # Thay đổi IP server phù hợp
              - name: DB_PORT
                value: "5432"            # 3306 cho MySQL/MariaDB
              - name: DB_USER
                valueFrom:
                  secretKeyRef:
                    name: backup
                    key: db_user
              - name: DB_PASSWORD
                valueFrom:
                  secretKeyRef:
                    name: backup
                    key: db_password                
              volumeMounts:
                - mountPath: /home/backup
                  name: backup
              lifecycle:
                preStop:
                  exec:
                    command: ["/bin/sh", "-c", "sleep 10"]  # Đợi 10s trước khi stop
          restartPolicy: OnFailure
          securityContext:
            runAsUser: 0
            runAsGroup: 0
            fsGroup: 0
          imagePullSecrets:
            - name: registry-token
          volumes:
            - name: backup
              persistentVolumeClaim:
                claimName: backup
          terminationGracePeriodSeconds: 60  # Thời gian chờ pod terminate
```

### 2. Apply CronJob:
```bash
kubectl apply -f backup-cronjob.yaml
```

## Biến Môi Trường

| Biến | Mô tả | Giá trị mẫu |
|------|--------|-------------|
| BACKUP_TYPE | Loại backup | postgresql17, mysql, mariadb |
| BACKUP_PREFIX | Tiền tố file backup | dbredmine |
| KEEP_BACKUP | Số ngày giữ backup | 7 |
| BACKUP_SOURCE | file hoặc thư mục muốn backup phải mount vào k8s | /home/svn |
| BACKUP_DESTINATION | Thư mục lưu backup | /home/backup |
| DB_HOST | Địa chỉ database | 192.168.0.171 |
| DB_PORT | Port database | 5432, 3306 |
| DB_USER | Tên đăng nhập | backup |
| DB_PASSWORD | Mật khẩu | your_password |
| MM_WEBHOOK_URL | URL webhook Mattermost | https://... |

## Cấu Trúc Thư Mục Backup

```plaintext
/home/backup/
├── postgresql17/
│   └── YYYYMMDD/
│       ├── dbredmine_database1.sql.gz
│       └── dbredmine_database2.sql.gz
├── mysql/
│   └── YYYYMMDD/
│       └── dbredmine_database.sql.gz
└── files/
    └── YYYYMMDD/
        └── dbredmine_files.tar.gz
```

## Giám Sát Hệ Thống

### Kiểm Tra Trạng Thái CronJob
```bash
kubectl get cronjob -n backup
```

### Xem Log Job Gần Nhất
```bash
# Lấy tên pod
kubectl get pods -n backup

# Xem log
kubectl logs <pod-name> -n backup
```

### Kiểm Tra File Backup
** Vào NAS79 -> CLOUDDATAMAIN -> backup-backup-pvc-cf50ecb6-6ecb-448a-833c-334d39db9bbf

## Xử Lý Sự Cố

### Các Vấn Đề Thường Gặp

1. **Job không chạy**:
   - Kiểm tra định dạng lịch của CronJob
   - Xác nhận namespace tồn tại
   - Kiểm tra tài nguyên hệ thống

2. **Backup thất bại**:
   - Xác minh thông tin đăng nhập database
   - Kiểm tra quyền của user backup
   - Đảm bảo đủ dung lượng ổ đĩa
   - Kiểm tra kết nối mạng

3. **Không nhận thông báo Mattermost**:
   - Kiểm tra URL webhook
   - Kiểm tra kết nối đến server Mattermost

### Lệnh Debug
```bash
# Xem sự kiện của CronJob
kubectl describe cronjob <cronjob-name> -n backup

# Xem sự kiện của Pod
kubectl describe pod <pod-name> -n backup

# Xem log với timestamp
kubectl logs <pod-name> -n backup --timestamps
```

## Tham Khảo

- [Tài Liệu Kubernetes CronJob](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)
- [Tài Liệu Backup PostgreSQL](https://www.postgresql.org/docs/current/backup.html)
- [Tài Liệu Backup MySQL](https://dev.mysql.com/doc/refman/8.0/en/backup-methods.html)