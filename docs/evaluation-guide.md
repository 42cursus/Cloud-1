# Cloud-1 evaluation guide

This document is the team's preparation and defense runbook. Use it to verify
the submitted repository, deploy to the evaluation instance, present the
architecture, demonstrate every rubric item, and answer the likely technical
questions.

## 1. Read this before scheduling the evaluation

The implementation satisfies the mandatory technical requirements, but these
submission details must be checked manually:

1. **Official repository:** only files in the repository submitted to 42 are
   evaluated. The current Git `origin` may not be the Vogsphere submission
   remote. Ensure the reviewed commit is present on the branch that will
   actually be evaluated.
2. **AUTHORS:** `AUTHORS` currently contains `abelov`. If this is a multi-member
   group, add every required team login before the final submission.
3. **Root access:** the evaluation instance is expected to begin with provider
   root SSH access. Do not depend on the development VM's personal users, and
   do not disable or replace evaluator root access.
4. **Inventory:** `inventories/hosts.yml` is intentionally ignored because it
   contains environment-specific connection data. Create it from
   `inventories/hosts.example.yml` on the controller before deploying.
5. **TLS choice:** an IP-address deployment uses a self-signed certificate. It
   provides encrypted HTTPS but produces a browser trust warning. A publicly
   trusted certificate requires a DNS name that already resolves to the
   instance and `cloud1_tls_mode: letsencrypt`.
6. **Internet access:** the first controller setup downloads Python packages
   and Ansible collections, and the first target deployment downloads Docker
   packages and container images. Do not wait until the final minutes of the
   evaluation to start the deployment.

## 2. Recommended defense order

Start the clean deployment immediately because package and image downloads are
the longest part. Explain the architecture while Ansible is running.

1. Confirm the submitted repository and commit.
2. Connect to the new instance as root and verify the provider access.
3. Create the local inventory and test Ansible connectivity.
4. Start `make deploy`.
5. While it runs, explain Ansible roles, Compose services, networks, volumes,
   secrets, firewall policy, and TLS.
6. Open WordPress and phpMyAdmin.
7. Run `make verify`.
8. Run the deployment again and show `changed=0`.
9. Demonstrate volumes, independent service management, and reboot recovery.
10. Finish with the requirement matrix and answer questions.

The evaluation may stop at the first failed item. Prefer short, deterministic
demonstrations over optional experiments.

## 3. Clean-instance deployment

### 3.1 Confirm the repository

```sh
git status --short
git log -1 --show-signature
git remote -v
cat AUTHORS
```

Expected:

- no uncommitted deployment changes;
- the intended signed commit is checked out;
- the commit exists in the official submitted repository;
- `AUTHORS` contains the required team members.

### 3.2 Establish root access

Connect once manually before running Ansible:

```sh
ssh root@<server-address>
```

This confirms the key, records the host key, and satisfies Ansible's enabled
host-key checking. If a provider reuses an address and SSH reports a changed
host key, verify that the instance was recreated before removing the old entry:

```sh
ssh-keygen -R <server-address>
ssh root@<server-address>
```

Do not change the SSH port, install a honeypot, or disable root access during
the evaluation.

### 3.3 Create the ignored inventory

```sh
make inventory
```

Edit `inventories/hosts.yml`:

```yaml
---
all:
  children:
    cloud1:
      hosts:
        evaluation:
          ansible_host: <server-address>
          ansible_user: root
          cloud1_domain: <server-address-or-domain>
          cloud1_tls_mode: self_signed
```

For a prepared public DNS name:

```yaml
cloud1_domain: cloud1.example.org
cloud1_tls_mode: letsencrypt
cloud1_letsencrypt_email: student@example.com
```

The same inventory group can contain several hosts. Ansible will converge the
members of `cloud1` in parallel using its normal fork behavior.

### 3.4 Prepare the controller and deploy

```sh
make install
make ping
make check
time make deploy
make verify
```

What each command proves:

| Command | Evidence |
|---|---|
| `make install` | Controller dependencies and required Ansible collections are available. |
| `make ping` | SSH, authentication, and remote Python work. |
| `make check` | Both playbooks parse and the roles pass production-profile `ansible-lint`. |
| `make deploy` | The declared host and application state is converged. |
| `make verify` | The running deployment satisfies automated functional and isolation assertions. |

## 4. Architecture to present

```text
Internet
  |
  +-- TCP 22 --------------------------> host SSH
  |
  +-- TCP 80/443 --> Nginx container
                       |
                       +--> WordPress PHP-FPM
                       |
                       +--> phpMyAdmin
                                |
                  internal database network
                                |
                             MariaDB

Persistent named volumes:
  cloud1_wordpress_data
  cloud1_mariadb_data
```

Only Nginx publishes application ports. WordPress, phpMyAdmin, and MariaDB have
no host port bindings.

### 4.1 Ansible roles

| Role | Responsibility |
|---|---|
| `common` | Validate the OS, install host utilities, and create deployment directories. |
| `docker` | Install Docker Engine and Compose from Docker's official apt repository and enable Docker at boot. |
| `firewall` | Configure UFW deny-by-default and allow the actual SSH port plus HTTP/HTTPS. |
| `secrets` | Generate missing passwords once on the managed host and set their permissions. |
| `tls` | Create a bootstrap self-signed certificate and optionally obtain and renew a Let's Encrypt certificate. |
| `application` | Install the static Compose file, render host-specific configuration, start the stack, initialize WordPress, and wait for health. |

The roles are separated by infrastructure responsibility. Compose remains the
application orchestration boundary, so individual containers are managed with
`docker compose`, rather than duplicating each Compose service in a separate
Ansible role.

Roles can be selected by tag:

```sh
.venv/bin/ansible-playbook playbooks/site.yml --tags firewall
.venv/bin/ansible-playbook playbooks/site.yml --tags application
```

### 4.2 Containers and image choices

| Service | Image type | Reason |
|---|---|---|
| Nginx | Official Alpine image | Small public ingress, TLS termination, redirects, and routing. |
| WordPress | Official PHP-FPM Alpine image | Separates PHP runtime from the public web proxy. |
| MariaDB | Official image | Compatible SQL backend with supported file-based secrets and health check. |
| phpMyAdmin | Official Apache image | Provides the required database administration UI with minimal custom setup. |
| WordPress CLI | Official tools-profile image | Performs one-shot, idempotent WordPress initialization and is not a long-running service. |

The subject permits official images. There are no custom Dockerfiles, so the
Dockerfile cache-order question does not apply. The defense point is that we
avoided unnecessary custom layers, avoided `latest`, and selected Alpine
variants where they fit.

The subject's "one process = one container" requirement is implemented as one
logical service per container. Nginx and Apache may internally use worker
processes, but the database, PHP runtime, reverse proxy, and administration UI
are not combined into one application container.

### 4.3 Static Compose and generated environment

`docker-compose.yml` is committed as a normal readable file. Ansible copies it
unchanged to `/opt/cloud-1/docker-compose.yml`.

Only `/opt/cloud-1/.env` is rendered because values such as the hostname,
selected image tags, and host paths vary by deployment. This file contains no
passwords. Runtime passwords are separate files under
`/etc/cloud-1/secrets`.

### 4.4 Networks and public exposure

The stack uses:

- `cloud1_frontend`: Nginx, WordPress, and phpMyAdmin;
- `cloud1_database`: WordPress, phpMyAdmin, and MariaDB;
- `internal: true` on the database network.

Nginx publishes only IPv4 TCP 80 and 443. The private services do not contain
`ports:` mappings.

UFW protects host listeners such as SSH. Docker-published ports traverse
Docker's forwarding rules, so database privacy does **not** rely on UFW alone.
It relies on the Compose design: MariaDB has no published port and exists only
on the internal network. The verification playbook asserts that MariaDB,
WordPress, and phpMyAdmin all have empty host port bindings.

### 4.5 Nginx routing and Docker DNS

- HTTP redirects to HTTPS.
- `/` serves WordPress.
- `/phpmyadmin` redirects to `/phpmyadmin/`.
- `/phpmyadmin/` requires HTTP Basic Authentication before proxying to
  phpMyAdmin.
- PHP requests are sent to the WordPress PHP-FPM service.

Nginx uses Docker DNS at `127.0.0.11` with a 15-second cache and
`ipv6=off`. Its WordPress and phpMyAdmin upstreams use shared zones and
`resolve`, allowing Nginx to recover when Docker recreates a service at a new
container address without restarting Nginx.

### 4.6 Secrets

The repository contains secret names and paths, not secret values. The
`secrets` role generates:

```text
/etc/cloud-1/secrets/
  mariadb_root_password
  wordpress_db_password
  wordpress_admin_password
  phpmyadmin_basic_auth
  phpmyadmin.htpasswd
```

Generation uses create-if-missing semantics, so a normal rerun does not rotate
credentials. Secret-generating tasks use `no_log: true`. The root-only parent
directory prevents normal host users from traversing to the files.

Compose mounts application password files through `/run/secrets`. Passwords
are not stored in `docker-compose.yml` or the generated `.env`.

### 4.7 Persistence and restart behavior

- `cloud1_wordpress_data` stores WordPress files, uploads, themes, and plugins.
- `cloud1_mariadb_data` stores the SQL database.
- Docker is enabled through systemd.
- Long-running containers use `restart: unless-stopped`.

Normal deployment never runs `docker compose down`, removes volumes, rotates
secrets, or reinstalls WordPress.

### 4.8 TLS

The bootstrap certificate allows HTTPS to start without depending on DNS.

- `self_signed`: encrypted traffic, but browsers show a trust warning;
- `letsencrypt`: requires a public DNS name and contact email, obtains the
  certificate with a webroot challenge, installs a renewal hook, and enables
  HSTS.

Do not claim that a self-signed certificate provides public identity
validation. It provides encryption only.

## 5. Mandatory requirement matrix

| Requirement | Implementation and evidence | Status |
|---|---|---|
| Fully automated deployment | `playbooks/site.yml`, roles, and `make deploy` | PASS |
| Functional WordPress site | WordPress PHP-FPM behind Nginx; verified by HTTP response containing `wp-content` | PASS |
| Automatic restart after reboot | Docker enabled at boot; `restart: unless-stopped` | PASS |
| Data preserved after reboot | Named WordPress and MariaDB volumes; reboot test already performed | PASS |
| Deploy several servers in parallel | Inventory group `cloud1`; per-host local secrets and volumes | PASS |
| Fresh Ubuntu 22.04-like host | Installs prerequisites, Docker repository, Engine, Compose, UFW, and configuration | PASS |
| SSH and Python are the only target assumptions | Ansible uses remote Python and bootstraps the remaining packages | PASS |
| Separate communicating containers | Nginx, WordPress, MariaDB, phpMyAdmin; CLI is one-shot | PASS |
| Secure public access | Only Nginx publishes application ports; private database network | PASS |
| WordPress components installed | WordPress, MariaDB, phpMyAdmin, and Nginx | PASS |
| `docker-compose.yml` present | Static root-level Compose file | PASS |
| SQL works with WordPress and phpMyAdmin | WordPress page and authenticated phpMyAdmin endpoint are verified | PASS |
| TLS when possible | Self-signed default and optional Let's Encrypt mode | PASS |
| URL-dependent routing | HTTP-to-HTTPS, WordPress root, protected phpMyAdmin path | PASS |
| Only ports 22/80/443 external | UFW rules, Nginx bindings, no private service bindings; confirm externally with `nmap` | PASS, manual scan required |
| Relevant Ansible roles | Six roles split by infrastructure responsibility | PASS |
| Portable to a fresh instance | No fixed development-user path or committed target inventory | PASS |
| Official images allowed | Versioned official images used for every service | PASS |
| Idempotent installation | Second full deployment reports `changed=0` | PASS |
| No hard-coded secrets | Remote generation, ignored inventory, tracked-file credential scan | PASS |
| Mounted storage inspectable | Two named volumes visible with `docker volume inspect` | PASS |
| Whole stack starts together | `docker compose up` through the Ansible Compose module | PASS |
| Services restart individually | Standard `docker compose restart <service>` operations | PASS |

## 6. Live demonstration commands

### 6.1 Website

Open:

```text
https://<cloud1-domain>/
https://<cloud1-domain>/phpmyadmin/
```

Demonstrate:

1. WordPress loads and remains stable across refreshes.
2. Pages and posts work.
3. An uploaded image loads.
4. phpMyAdmin first requests HTTP Basic Authentication.
5. phpMyAdmin can then log in to MariaDB with the WordPress database user.

Retrieve credentials only when needed:

```sh
sudo cat /etc/cloud-1/secrets/wordpress_admin_password
sudo cat /etc/cloud-1/secrets/phpmyadmin_basic_auth
sudo cat /etc/cloud-1/secrets/wordpress_db_password
```

Avoid displaying passwords longer than necessary.

### 6.2 Container separation and orchestration

```sh
cd /opt/cloud-1
sudo docker compose ps
sudo docker network inspect cloud1_frontend
sudo docker network inspect cloud1_database
```

Restart individual services:

```sh
sudo docker compose restart wordpress
sudo docker compose restart nginx
sudo docker compose ps
```

Do not use `down -v`, `docker system prune`, or any command that removes the
evaluation data.

### 6.3 Firewall and exposure

On the server:

```sh
sudo ufw status verbose
sudo ss -lnt
sudo docker inspect --format '{{json .HostConfig.PortBindings}}' \
  cloud1-nginx cloud1-wordpress cloud1-phpmyadmin cloud1-mariadb
```

From another machine:

```sh
nmap -Pn -p- <server-address>
```

If a full scan would take too long, first verify the expected and sensitive
ports explicitly:

```sh
nmap -Pn -p 22,80,443,3306,9000,8080 <server-address>
```

Expected public TCP ports:

```text
22
80
443
```

Do not temporarily publish MariaDB to demonstrate Docker's UFW behavior.
Explain it using the Compose file and inspection output.

### 6.4 Volumes and persistence

```sh
sudo docker volume ls
sudo docker volume inspect cloud1_wordpress_data
sudo docker volume inspect cloud1_mariadb_data
```

For the strongest demonstration:

1. Create a uniquely named post.
2. Upload an image.
3. Record that they are visible.
4. Reboot:

   ```sh
   sudo reboot
   ```

5. Reconnect to confirm the VM is available. From the Ansible controller, wait
   for the containers to become healthy and run:

   ```sh
   make verify
   ```

6. Show that the post and image still exist.

### 6.5 Idempotency

Run the exact same deployment again:

```sh
make deploy
```

Expected recap:

```text
failed=0
changed=0
```

Then:

```sh
make verify
```

Idempotency means repeated convergence produces the same intended state
without unnecessary changes. It does not mean the first deployment performs no
changes.

## 7. Technical questions to prepare

### What is infrastructure as code?

Infrastructure as code represents the intended infrastructure and
configuration in version-controlled files. The same reviewed code can create
the same class of deployment on another compatible machine.

### What is idempotency?

An idempotent operation can be applied repeatedly without changing an already
correct system. Examples here include `apt state: present`, create-if-missing
secrets, certificate modules, file templates, service state, and the
`wp core is-installed` guard.

### Why both Ansible and Docker Compose?

Ansible configures the host: packages, Docker, firewall, secrets, TLS files,
and deployment configuration. Compose declares and operates the application
services, networks, volumes, dependencies, and restart policies. Combining
everything into either shell scripts or Compose alone would blur those
responsibilities.

### Why not reuse the Inception images?

The subject explicitly requires a new automated deployment rather than simply
copying the prior Inception images. Official images reduce custom build code
and allow the project to focus on remote provisioning, orchestration,
persistence, and security.

### Why not use Vault?

Vault would add initialization, unsealing, persistence, policies, recovery,
and its own availability requirements. Cloud-1 only requires avoiding
hard-coded secrets. Generating random files once on each managed host is
sufficient, portable, and easier to defend.

### Why use a static Compose file rather than a Jinja template?

The orchestration structure does not vary by host and should remain directly
readable. Only environment-specific values vary, so Ansible renders a small
`.env` file rather than templating the entire Compose document.

### Why named volumes?

Named volumes are independent of container lifecycles, portable across
container recreation, and directly inspectable with Docker commands, which is
an explicit evaluation point.

### Why is MariaDB not protected only by UFW?

Docker-published traffic uses Docker's forwarding and NAT rules. The primary
control is not publishing MariaDB at all. MariaDB has no host port binding and
is attached only to the internal database network. UFW separately protects
host listeners such as SSH.

### Why dynamic Nginx DNS resolution?

Docker may assign a different address when it recreates a service. Static
resolution at Nginx startup could leave stale upstream addresses. Docker DNS,
short resolver caching, shared upstream zones, and `resolve` let Nginx follow
the recreated WordPress and phpMyAdmin containers.

### How does multi-server deployment work?

Add several hosts beneath the `cloud1` inventory group. Ansible runs the same
roles for each host in parallel. Each server receives independent local
secrets, volumes, and application state. This is parallel deployment, not a
shared-database cluster or load-balanced WordPress installation.

### Why `restart: unless-stopped`?

It restores normally running services after Docker or host restart while
respecting an administrator's explicit decision to stop a service.

### How was AI used?

Use an honest answer:

> AI assisted with initial research, repetitive Ansible structure, review
> ideas, and test cases. The team checked the subject and evaluation sheet,
> rejected unnecessary complexity, changed the design where suggestions were
> inappropriate, tested the result on the VM, and remains responsible for
> every technical decision and command.

Do not claim independent authorship of generated sections, and do not rely on
AI to answer questions during the defense.

## 8. Points that require extra attention

### Official submission is the highest procedural risk

The evaluator checks the official submitted repository, not the current
working directory or an unrelated GitHub branch. Before scheduling:

```sh
git status --short
git log --oneline --decorate -5
git remote -v
```

Clone the official repository into a separate directory and confirm the
expected files and commit are present.

### Update `AUTHORS` for the complete team

The evaluation form includes a missing-author-file failure flag. Confirm the
format expected by the campus and include all required logins.

### Use the provider root account on the fresh evaluation VM

The evaluation instructions are strict about root access. Do not demonstrate
only the development `abelov` account. The example inventory intentionally
uses `ansible_user: root`.

### The local inventory is not submitted

This is intentional security hygiene, but it means the inventory must be
created before deployment. Verify its address, SSH user, hostname, and TLS mode.

### Host key checking is enabled

Manually SSH to the new instance before `make ping`. A stale key from a reused
address will otherwise stop Ansible.

### Self-signed TLS causes a browser warning

This is expected for an IP-only deployment. Accept the certificate warning for
the demonstration, or prepare DNS and test Let's Encrypt before the defense.
Do not switch TLS modes for the first time during the evaluation.

### Docker image and package downloads take time

Start deployment immediately. Avoid changing image tags or deleting cached
controller dependencies immediately before the evaluation.

### Do not expose debugging ports

Never add host mappings for 3306, 9000, phpMyAdmin, or a development service.
The verification playbook will reject host bindings on all private services.

### Do not run destructive cleanup

Avoid:

```sh
docker compose down -v
docker volume rm ...
docker system prune --volumes
```

These commands would destroy the evidence for persistence.

### Be ready to defend the role boundary

The Ansible roles are divided by infrastructure responsibility, while Compose
owns the individual application services. Show that host concerns can be
selected by Ansible tags and containers can be independently restarted through
Compose.

### phpMyAdmin uses the official Apache variant

This is a deliberate simplicity trade-off. The public ingress is still Nginx;
the phpMyAdmin container is not host-published and can only be reached through
the protected Nginx route.

## 9. Fast troubleshooting

### Ansible cannot connect

```sh
ssh root@<server-address>
make ping
```

Check the address, user, key, SSH port, and host key.

### A deployment task fails

Rerun the same playbook after correcting the cause:

```sh
make deploy
```

The deployment is designed to resume safely.

### A container is unhealthy

```sh
cd /opt/cloud-1
sudo docker compose ps
sudo docker compose logs --tail=100 <service>
```

Check MariaDB first, then WordPress, phpMyAdmin, and Nginx.

### HTTP works but HTTPS fails

```sh
sudo ls -l /etc/cloud-1/tls
sudo docker compose logs --tail=100 nginx
sudo docker exec cloud1-nginx nginx -T
```

### WordPress cannot reach MariaDB

```sh
sudo docker compose ps
sudo docker compose logs --tail=100 mariadb wordpress
sudo docker network inspect cloud1_database
```

Do not print database passwords into logs or paste them into public channels.

### Port 80 or 443 is already in use

```sh
sudo ss -lntp
```

Stop or reconfigure the conflicting host service. Do not change the required
public ports to avoid the conflict.

## 10. One-minute project summary

> Cloud-1 uses Ansible to turn a fresh Ubuntu-like SSH/Python host into a
> persistent WordPress deployment. Ansible installs Docker and UFW, generates
> host-local secrets, prepares TLS, and converges a static Compose stack.
> Nginx is the only public application service on ports 80 and 443. WordPress,
> phpMyAdmin, and MariaDB remain private on Docker networks, with the database
> network marked internal. WordPress and database state live in named volumes,
> Docker and the containers restart after reboot, and repeated deployment is
> idempotent. The verification playbook checks the website, protected
> phpMyAdmin route, private port bindings, Nginx configuration, dynamic Docker
> DNS, and persistent volumes.

## 11. Final pre-evaluation checklist

- [ ] All team members can explain every role and service.
- [ ] `AUTHORS` contains every required login.
- [ ] The intended commit is in the official submitted repository.
- [ ] The official repository was cloned and checked independently.
- [ ] Root SSH access to the evaluation VM works.
- [ ] The VM address or DNS name is known.
- [ ] `inventories/hosts.yml` was created and reviewed.
- [ ] `make install`, `make ping`, and `make check` pass.
- [ ] A clean deployment completes.
- [ ] `make verify` passes.
- [ ] A second deployment reports `changed=0`.
- [ ] WordPress login credentials are available.
- [ ] phpMyAdmin Basic Auth and database credentials are available.
- [ ] Only TCP 22, 80, and 443 are reachable externally.
- [ ] WordPress, phpMyAdmin, and MariaDB have no host port bindings.
- [ ] Both named volumes are present.
- [ ] A post and uploaded image survive a reboot.
- [ ] No secret or local inventory is committed.
- [ ] No destructive cleanup command will be used during the defense.
- [ ] The team can explain its AI use and the decisions it changed or rejected.
