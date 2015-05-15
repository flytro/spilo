#!/bin/bash

PATH=$PATH:/usr/lib/postgresql/${PGVERSION}/bin
WALE_ENV_DIR=/home/postgres/etc/wal-e.d/env

BACKUP_INTERVAL=300

function write_postgres_yaml
{
  aws_private_ip=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
  cat >> postgres.yml <<__EOF__
loop_wait: 10
etcd:
  scope: $SCOPE
  ttl: 30
  host: 127.0.0.1:8080
postgresql:
  name: postgresql_${HOSTNAME}
  listen: 0.0.0.0:5432
  connect_address: ${aws_private_ip}:5432
  data_dir: $PGDATA
  replication:
    username: standby
    password: standby
    network: 0.0.0.0/0
  superuser:
    password: zalando
  admin:
    username: admin
    password: admin
  parameters:
    archive_mode: "on"
    wal_level: hot_standby
    archive_command: "envdir ${WALE_ENV_DIR} wal-e --aws-instance-profile wal-push \"%p\" -p 1"
    max_wal_senders: 5
    wal_keep_segments: 8
    archive_timeout: 1800s
    max_replication_slots: 5
    hot_standby: "on"
  recovery_conf:
    restore_command: "envdir ${WALE_ENV_DIR} wal-e --aws-instance-profile wal-fetch \"%f\" \"%p\" -p 1"
__EOF__
}

function write_archive_command_environment
{
  mkdir -p ${WALE_ENV_DIR}
  echo "s3://${WAL_S3_BUCKET}/spilo/${SCOPE}/wal/" > ${WALE_ENV_DIR}/WALE_S3_PREFIX
}

# get governor code
git clone https://github.com/zalando/governor.git

write_postgres_yaml

write_archive_command_environment

# start etcd proxy
# for the -proxy on TDB the url of the etcd cluster
[ "$DEBUG" -eq 1 ] && exec /bin/bash

# resurrect etcd if it's gone
(
  while true
  do
    etcd -name "proxy-$SCOPE" -proxy on -bind-addr 127.0.0.1:8080 --data-dir=etcd -discovery-srv $ETCD_DISCOVERY_URL
  done
) &

# run wal-e s3 backup periodically
# XXX: for debugging purposes, it's running every 5 minutes
(
  RETRY=1
  while true
  do
    sleep 5

    CURRENT_TS=$(date +%s)
    pg_isready >/dev/null 2>&2 || continue
    IN_RECOVERY=$(psql -tqAc "select pg_is_in_recovery()")

    [[ $IN_RECOVERY != "f" ]] && echo "still in recovery" && continue
    # get the time since the last backup
    LAST_BACKUP_TS=$(envdir ${WALE_ENV_DIR} wal-e --aws-instance-profile  backup-list LATEST 2>/dev/null|tail -n1|awk '{print $2}'|xargs date +%s --date)
    ELAPSED_TIME=$((CURRENT_TS-LAST_BACKUP_TS))
    ([[ $RETRY != 0 ]] || [[ $ELAPSED_TIME -lt $BACKUP_INTERVAL ]]) && continue
    # leave only 2 base backups before creating a new one
    envdir ${WALE_ENV_DIR} wal-e --aws-instance-profile delete --confirm retain 2
    # push a new base backup
    echo "producing a new backup at $(date)"
    envdir ${WALE_ENV_DIR} wal-e --aws-instance-profile backup-push ${PGDATA}
    RETRY=$?
  done
) &

exec governor/governor.py "/home/postgres/postgres.yml"



