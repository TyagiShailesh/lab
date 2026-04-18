# PostgreSQL 18

Installed from the **official PGDG repo**, not Ubuntu apt defaults. Used by DaVinci Resolve on the Mac as a remote project database.

```
Data:    /var/lib/postgresql/18/main/   (boot SSD)
Port:    5432
User:    resolve / <password>
DB:      nas
Auth:    scram-sha-256 from 192.168.1.0/24
Backup:  /nas/media/resolve/backup/   (nightly 3am, 30-day retention)
```

---

## Install

```bash
apt install -y curl ca-certificates
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg
echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list
apt update && apt install -y postgresql-18

# Create resolve user and database
sudo -u postgres createuser -d resolve
sudo -u postgres createdb -O resolve nas

# Allow LAN access
echo "host all all 192.168.1.0/24 scram-sha-256" >> /etc/postgresql/18/main/pg_hba.conf
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" \
  /etc/postgresql/18/main/postgresql.conf
systemctl restart postgresql

# Set resolve user password
sudo -u postgres psql -c "ALTER USER resolve PASSWORD '<password>';"
```

---

## Backup cron

Nightly `pg_dumpall` into `/nas/media/resolve/backup/`. 30-day retention.

```bash
cat > /etc/cron.d/postgres-backup << 'EOF'
# Nightly PostgreSQL backup (on bcachefs pool)
0 3 * * * postgres pg_dumpall -f /nas/media/resolve/backup/resolve_latest.sql && cp /nas/media/resolve/backup/resolve_latest.sql /nas/media/resolve/backup/resolve_$(date +\%Y\%m\%d).sql
# Keep last 30 days
5 3 * * * postgres find /nas/media/resolve/backup -name 'resolve_2*.sql' -mtime +30 -delete
EOF

mkdir -p /nas/media/resolve/backup
chown postgres:postgres /nas/media/resolve/backup
```

---

## Verify

```bash
systemctl status postgresql
sudo -u postgres psql -c "\l"
# From Mac: psql -h 192.168.1.10 -U resolve -d nas
```
