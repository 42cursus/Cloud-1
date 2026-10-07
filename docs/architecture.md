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

Nginx uses Docker's embedded DNS resolver at `127.0.0.11`, with a 15-second
cache validity and IPv6 DNS queries disabled. The WordPress FastCGI and
phpMyAdmin HTTP upstreams use shared zones and `resolve`, so Nginx follows a
service when Docker recreates its container with a different address.

## SSH honeypot concept

A possible production hardening design would move the real SSH daemon to TCP
2222 and place an isolated SSH honeypot on TCP 22. The administrative endpoint
would remain key-only and could be restricted to trusted source addresses,
while the honeypot would record unauthenticated scanning and credential attacks.
The honeypot must not receive host credentials, privileged container access,
the Docker socket, or application volumes.

This design is intentionally **not implemented** for Cloud-1:

- The subject permits only public TCP ports 22, 80 and 443. Opening 2222 would
  violate that requirement.
- The evaluator must connect to the real server as root through the expected
  provider access. Presenting a honeypot on port 22 could obstruct or mislead
  the evaluation and may stop the defense.
- Changing the SSH endpoint during automated provisioning creates an avoidable
  lockout risk on short-lived evaluation instances.

If this repository is adapted for a non-evaluation environment, the design
should be a separate, explicitly enabled hardening profile. It must open and
test port 2222 before changing `sshd`, verify a new administrative connection
before closing the old endpoint, and deploy the honeypot with strict isolation.
It must never alter the default evaluation deployment.

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
in the repository, static Compose file, or generated environment file. The
secrets directory is root-only (`0700`). WordPress-readable files use mode
`0644` because the official Debian and Alpine images use different numeric
`www-data` IDs; they remain inaccessible to host users through the root-only
parent directory and are mounted read-only inside their containers.

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
