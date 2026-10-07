# Architecture

## Request path

```text
Internet
  -> UFW: IPv4 TCP 22, 80 and 443 only
  -> Nginx
       -> WordPress PHP-FPM
       -> phpMyAdmin
  -> internal database network
       -> MariaDB
```

Nginx joins only the frontend network. WordPress and phpMyAdmin join both the
frontend and database networks. MariaDB joins only the internal database
network and does not publish port 3306. The host firewall and Nginx ingress are
IPv4-only; the deployment does not create IPv6 listeners or UFW rules.

## Compose configuration

The repository contains the complete static `docker-compose.yml`. Ansible
copies it unchanged to `/opt/cloud-1` and renders only `/opt/cloud-1/.env`,
which supplies the selected image tags, hostname, application metadata, and
host paths. This keeps the orchestration directly readable while retaining
inventory-specific deployment values.

## Persistence

The Compose project creates `cloud1_wordpress_data` and
`cloud1_mariadb_data`. Container replacement, Compose reconciliation, and host
reboots do not remove these volumes. Destructive volume removal is deliberately
not exposed as a normal Make target.

## Secrets

The `secrets` role generates passwords directly on each managed host. It uses
create-if-missing operations, so an ordinary Ansible rerun cannot rotate
credentials. Compose mounts the files as secrets; password values do not appear
in the repository, static Compose file, or generated environment file. The secrets directory is root-only
(`0700`). WordPress-readable files use mode `0644` because the official Debian
and Alpine images use different numeric `www-data` IDs; they remain inaccessible
to host users through the root-only parent directory and are mounted read-only
inside their containers.

## TLS

Every deployment starts with a host-specific self-signed certificate so Nginx
can start without external dependencies. In `letsencrypt` mode, Certbot obtains
a certificate through the webroot challenge. A deploy hook copies renewed
material into the Nginx-mounted TLS directory and reloads Nginx.

## Idempotency

Ansible modules declare package, file, service, firewall, certificate, and
Compose state. WordPress initialization checks `wp core is-installed` before
making changes. Runtime secrets use create-if-missing semantics. No normal task
executes `docker compose down`, deletes a volume, or recreates the database.

## Multi-host deployment

The playbooks target the `cloud1` inventory group. Each listed server receives
its own local secrets and persistent volumes. Ansible can converge multiple
members of that group in parallel without changing the playbooks.
