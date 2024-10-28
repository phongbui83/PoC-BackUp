FROM ubuntu:24.04
LABEL Author="Bui The Phong <buithephong@gmail.com>"
LABEL Description="This is custom Docker Image for Backup Schedule on K8S"
ENV \
    DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Ho_Chi_Minh \
    BACKUP_HOME=/home/backup
RUN \
    sed -i 's/archive.ubuntu.com/mirror.bizflycloud.vn/g' /etc/apt/sources.list.d/ubuntu.sources && \
    apt-get update && \
    apt -y upgrade &&\
    apt -y install \
        software-properties-common \
        zip \
        unzip \
        openssh-client \
        wget \
        curl \
        net-tools \
        zip \
        unzip \
        git \
        rsync \
        gnupg2 \
        lsb-release \
        ca-certificates \
        mariadb-client \
        postgresql-client
RUN \  
    apt install -y tzdata &&\
    ln -fs /usr/share/zoneinfo/${TZ} /etc/localtime &&\
    dpkg-reconfigure -f noninteractive tzdata
RUN \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg &&\
    echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list &&\
    apt update &&\
    apt install -y \
        postgresql-client-15 \
        postgresql-client-16 \
        postgresql-client-17
RUN \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
RUN \
    mkdir -p ${BACKUP_HOME} && \
    chmod 777 ${BACKUP_HOME} && \
    mkdir -p /root/.ssh
RUN echo "Host *\n\
    StrictHostKeyChecking no\n\
    UserKnownHostsFile /dev/null\n\
    LogLevel ERROR" > /root/.ssh/config && \
    chmod 600 /root/.ssh/config
COPY backup.sh /backup.sh
RUN chmod +x /backup.sh
WORKDIR ${BACKUP_HOME}
CMD bash /backup.sh