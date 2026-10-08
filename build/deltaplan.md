## Recommended scope

Build a **small, portable Ansible deployment around Docker Compose**. The goal is not to recreate the complexity of Transcendence or `twagger/cloud-1`; it is to satisfy every subject and evaluation requirement predictably on a fresh Ubuntu 22.04 VM.

I reviewed the subject, evaluation sheet, Scaleway email, your Inception deployment, the relevant Transcendence deployment patterns, `twagger/cloud-1`, and the current VM. The VM is a suitable clean target: **Ubuntu 22.04, 2 vCPU, 1.9 GiB RAM, Docker absent, UFW inactive, only SSH listening**.

### In scope

- Ansible controller configuration and inventory
- Host preparation
- Docker Engine and Compose plugin installation
- Firewall configuration
- Docker Compose deployment
- Nginx reverse proxy
- WordPress with PHP-FPM
- MariaDB
- phpMyAdmin
- Persistent WordPress and database volumes
- TLS when a domain is available
- Runtime secret generation
- Automatic recovery after VM reboot
- Deployment to multiple inventory hosts
- Idempotency and evaluation checks
- Documentation and simple Makefile commands

### Deliberately out of scope

- Vault
- Redis
- cAdvisor, Prometheus, Grafana
- Kubernetes or Docker Swarm
- CI/CD deployment pipelines
- Multiple environments and release directories
- Custom container images unless actually needed
- ModSecurity/WAF
- Automated cloud-instance creation
- Production-grade database backups or high availability

Those additions increase failure modes but do not improve the mandatory score.
Vault in particular would introduce initialization, unsealing, persistence, policy, and recovery questions that this project does not require.

---

## Proposed architecture

```text
Internet
   |
   | TCP 22, 80, 443 only
   |
Host firewall: UFW
   |
   +-- SSH :22
   |
   +-- Nginx container :80/:443
          |
          +-- /                 -> WordPress PHP-FPM
          |
          +-- /phpmyadmin/      -> phpMyAdmin
                                      |
Application networks                 |
          |                          |
          +---------- MariaDB <------+
                     |
              persistent volume
```

Recommended containers:

| Container | Purpose | Publicly exposed |
|---|---|---|
| `nginx` | TLS termination, HTTP redirect and request routing | `80`, `443` |
| `wordpress` | WordPress application and PHP-FPM | No |
| `mariadb` | SQL database | No |
| `phpmyadmin` | Database administration UI | No; accessed through Nginx |

Use **pinned official images** rather than rebuilding the Inception images:

- `nginx:<pinned-alpine-version>`
- `wordpress:<pinned-php-fpm-alpine-version>`
- `mariadb:<pinned-version>`
- `phpmyadmin:<pinned-version>`

The subject explicitly permits official images. This also demonstrates that Cloud-1 is a new automated deployment rather than simply copying the Inception images.

For phpMyAdmin, the simplest reliable design is its Apache image behind Nginx.
If the team wants the strictest interpretation of one runtime process per container,
use its FPM variant, but that requires more complicated static-file sharing with Nginx.
The Apache variant is proportionate to the project and still keeps phpMyAdmin isolated from WordPress and MariaDB.

---

## Compose design

### Networks

Use two networks:

```text
frontend:
  nginx
  wordpress
  phpmyadmin

database:
  wordpress
  phpmyadmin
  mariadb
  internal: true
```

Nginx must not join the database network. MariaDB must not publish `3306` to the host.

### Volumes

Use named Docker volumes:

```text
cloud1_wordpress_data
cloud1_mariadb_data
```

WordPress files, including uploaded images, plugins, and themes, live in the WordPress volume. MariaDB state lives in the database volume.

Named volumes are preferable here because the evaluator explicitly asks whether an administrator can inspect the volumes using Docker commands:

```sh
docker volume ls
docker volume inspect cloud1_wordpress_data
docker volume inspect cloud1_mariadb_data
```

### Recovery

Each long-running service should use:

```yaml
restart: unless-stopped
```

Docker itself must be enabled through systemd:

```text
systemctl enable --now docker
```

The stack then returns automatically after a host reboot without needing cron or a custom reboot script.

### Health and startup order

Add health checks for at least:

- MariaDB accepting connections
- WordPress PHP-FPM accepting requests
- Nginx returning a successful HTTP response

Use health-based dependencies where Compose supports them. Do not rely only on fixed sleeps.

WordPress initialization should be idempotent:

1. Wait for MariaDB.
2. Check whether WordPress is already installed.
3. Download/configure/install only when absent.
4. Create the administrator only on the initial installation.
5. Start PHP-FPM in the foreground.

A one-shot WP-CLI initialization container is cleaner than embedding installation logic into the long-running WordPress container, but either design is acceptable if it is reliable and understandable to the team.

---

## Ansible structure

```text
cloud-1/
├── Makefile
├── README.md
├── ansible.cfg
├── requirements.yml
├── inventories/
│   ├── hosts.example.yml
│   └── hosts.yml                 # ignored
├── group_vars/
│   ├── all/
│   │   ├── main.yml
│   │   └── vault.yml            # ignored or encrypted
│   └── all.example.yml
├── playbooks/
│   ├── site.yml
│   └── verify.yml
├── roles/
│   ├── common/
│   ├── docker/
│   ├── firewall/
│   ├── secrets/
│   ├── application/
│   └── tls/
├── templates/
│   └── optional shared templates
└── docs/
    ├── architecture.md
    ├── deployment.md
    └── evaluation-checklist.md
```

### `common` role

- Validate Ubuntu/Debian-compatible host
- Install required host packages
- Set basic ownership and permissions
- Create `/opt/cloud-1`
- Optionally create a deployment user
- Leave provider/evaluator SSH access intact by default

### `docker` role

- Add Docker’s official apt repository and signing key
- Install:
  - `docker-ce`
  - `docker-ce-cli`
  - `containerd.io`
  - `docker-buildx-plugin`
  - `docker-compose-plugin`
- Enable and start Docker
- Optionally add the deployment user to the Docker group

Avoid `shell` commands where an Ansible module exists. Do not remove and reinstall Docker on every run, change Docker socket ownership, or destructively clean images and volumes.

### `firewall` role

Configure UFW:

```text
default deny incoming
default allow outgoing
allow 22/tcp
allow 80/tcp
allow 443/tcp
enable
```

The role must allow SSH before enabling UFW.

Remember that Docker-published ports can bypass conventional UFW expectations. The safest design is still to publish only Nginx ports in Compose. MariaDB and application ports must never have host `ports:` mappings.

### `secrets` role

Generate secrets on the remote host only when missing:

```text
/etc/cloud-1/secrets/
├── mariadb_root_password
├── wordpress_db_password
├── wordpress_admin_password
└── phpmyadmin_basic_auth
```

Requirements:

- Directory mode `0700`
- Files mode `0600`
- Owned by root
- Random values generated once
- Existing values retained during subsequent deployments
- Secret-related tasks use `no_log: true`
- No secret values registered into verbose output
- No generated secrets copied back into Git

Docker Compose can mount these files as Docker secrets.

This is simpler and more portable than HashiCorp Vault. Ansible Vault may still be used for optional externally supplied values such as a DNS API token, but deployment should not require a private team-only vault password just to generate a working site during evaluation.

### `application` role

- Create `/opt/cloud-1`
- Render `compose.yml`
- Render Nginx configuration
- Render a non-secret `.env` where needed
- Copy WordPress initialization scripts
- Pull pinned images
- Validate Compose configuration
- Run `docker compose up -d`
- Wait for health checks
- Perform an HTTP verification

Do not execute `docker compose down` during every deployment. That is unnecessary downtime and undermines the idempotency demonstration.

### `tls` role

Support two explicit modes:

```yaml
tls_mode: letsencrypt
# or
tls_mode: self_signed
```

For the strongest evaluation:

1. Register a DuckDNS or team-controlled domain.
2. Point it to the current VM.
3. Use Let’s Encrypt.
4. Configure automatic renewal.
5. Redirect HTTP to HTTPS.

Because Scaleway evaluation instances may receive a different address, the hostname must be configurable through inventory variables. If DNS cannot be updated in time, deploy a documented self-signed certificate instead of making the whole deployment fail.

---

## Inventory and multi-server deployment

Example inventory:

```yaml
all:
  children:
    cloud1:
      hosts:
        cloud1-primary:
          ansible_host: 203.0.113.10
          ansible_user: root
          cloud1_hostname: cloud1.example.org

        cloud1-secondary:
          ansible_host: 203.0.113.20
          ansible_user: root
          cloud1_hostname: cloud1-secondary.example.org
```

The main playbook should target the group:

```yaml
- name: Deploy Cloud-1
  hosts: cloud1
  become: true
  roles:
    - common
    - docker
    - firewall
    - secrets
    - application
    - tls
```

Ansible will then deploy to both servers in parallel according to its configured forks. Nothing should contain the Scaleway IP, `abelov`, or a fixed `/home/abelov` path.

---

## Root and evaluation access

This is the most important operational caveat.

The subject/evaluation wording requires the team to demonstrate access through the provider’s **root account associated with the student login/email**. A freshly provisioned evaluation instance is likely to start with only root SSH access.

Therefore:

- The inventory must support `ansible_user: root`.
- Initial deployment must not depend on `abelov` or any pre-existing personal user.
- Do not disable root SSH as part of the default playbook.
- Do not replace or delete the provider-installed root authorized keys.
- A non-root deployment user may be created, but it must be optional.
- Put SSH hardening behind a disabled-by-default variable:

```yaml
cloud1_harden_ssh: false
```

Your current development VM can keep personal accounts,
but the final clean-instance test must begin exactly as the evaluation VM will:
root SSH, Python, and otherwise minimal Ubuntu 22.04.

---

## Suggested Makefile interface

```make
make install       # install controller-side Ansible requirements
make syntax        # syntax-check playbooks
make lint          # ansible-lint and YAML lint
make ping          # test inventory connectivity
make deploy        # deploy all inventory hosts
make verify        # run post-deployment verification
make check         # syntax + lint + deployment assertions
make logs          # documented helper for a selected host
```

The actual deployment remains Ansible, not shell scripts hidden behind Make.

---

## Implementation phases

### Phase 1 — Repository foundation

- Add Ansible configuration and inventory examples.
- Define variables and supported operating-system assumptions.
- Add Makefile entry points.
- Extend `.gitignore` for inventories, secret files, certificates, and vault-password files.

**Exit condition:** Ansible can connect to the current VM and gather facts.

### Phase 2 — Host bootstrap

- Implement `common`, `docker`, and `firewall`.
- Install Docker and Compose from Docker’s official repository.
- Enable Docker at boot.
- Open only 22, 80, and 443.

**Exit condition:** a fresh VM becomes a secured Docker host from one playbook invocation.

### Phase 3 — Application stack

- Add Compose, Nginx, WordPress, MariaDB, and phpMyAdmin.
- Add networks, volumes, secrets, health checks, and restart policies.
- Install WordPress automatically.

**Exit condition:** the site and phpMyAdmin are reachable through Nginx while MariaDB remains private.

### Phase 4 — TLS

- Add domain variable and certificate mode.
- Configure Let’s Encrypt where possible.
- Add self-signed fallback.
- Redirect port 80 to 443.

**Exit condition:** HTTPS works after deployment without manual certificate copying.

### Phase 5 — Idempotency and persistence

- Run the playbook twice.
- Confirm the second execution does not rotate secrets or recreate data.
- Create a post, user, and uploaded image.
- Reboot the VM.
- Confirm all content remains.

**Exit condition:** repeated deployment and reboot preserve the site.

### Phase 6 — Clean-host test

Test against a newly provisioned or reset Ubuntu 22.04 machine with:

- SSH daemon
- Python
- Root access
- No Docker
- No team users
- No manually installed certificates
- No manually copied secrets

**Exit condition:** the repository alone can reproduce the deployment.

### Phase 7 — Defense preparation

Prepare commands and explanations for:

- Ansible roles
- Idempotency
- Declarative versus imperative provisioning
- Docker networks
- Why MariaDB is not publicly exposed
- Secret lifecycle
- Volume persistence
- Container restart behavior
- Multi-host deployment
- TLS renewal
- Difference between Cloud-1 and Inception

---

## Evaluation verification plan

Run these checks before scheduling the defense.

### Functionality

```sh
curl -I http://cloud1.example.org
curl -Ik https://cloud1.example.org
curl -Ik https://cloud1.example.org/phpmyadmin/
```

Create a post, account, comment, and image upload. Refresh repeatedly and navigate through WordPress.

### Exposure

From another machine:

```sh
nmap -Pn -p- <server-ip>
```

Expected public TCP ports:

```text
22
80
443
```

On the server:

```sh
sudo ss -lntp
docker compose ps
```

There must be no host mapping for `3306`, PHP-FPM, or phpMyAdmin.

### Persistence

```sh
docker volume ls
docker volume inspect cloud1_wordpress_data
docker volume inspect cloud1_mariadb_data
sudo reboot
```

After reboot, verify the previously created article, user, and uploaded image.

### Orchestration

```sh
docker compose stop wordpress
docker compose start wordpress

docker compose restart nginx
docker compose ps
```

The entire stack must start with one command, but each service must also be independently manageable.

### Idempotency

Run:

```sh
ansible-playbook playbooks/site.yml
ansible-playbook playbooks/site.yml
```

The second run should report mostly `ok`, with no secret rotation, volume deletion, WordPress reinstall, or unnecessary service restart.

### Multi-server support

Add a second temporary host to the same inventory and deploy both:

```sh
ansible-playbook playbooks/site.yml --limit cloud1
```

Each server should receive an independent database, WordPress volume, and locally generated secrets.

---

## What to reuse from the references

**From your Inception project:**

- Nginx/WordPress/MariaDB service boundaries
- WordPress initialization concepts
- Persistent application and database storage
- Internal Docker networking

Do not copy fixed `/home/abelov/data` paths, handcrafted images merely for the sake of rebuilding them, or hard-coded domain configuration.

**From `twagger/cloud-1`:**

- Clear Ansible entry playbook
- Role organization
- Inventory-driven multi-host deployment
- Separation of host setup from application deployment

Do not copy its destructive reset/down behavior, Docker socket ownership changes, mandatory custom administrative user, Redis/cAdvisor extras, or historical Ansible patterns where modern modules are available.

**From Transcendence:**

- Runtime secrets outside Git
- Runtime secrets outside Git
- Explicit deployment validation
- Clear operator documentation
- Pinned deployment configuration
- Separate public ingress from private services

Do not copy Vault, WAF, multiple Compose profiles, complex release paths, migration tooling, or production edge architecture.

## Final recommendation

The best submission is a **four-container WordPress stack deployed by six small Ansible roles**, with remote-generated secrets, named volumes, private database networking, UFW, configurable TLS, and root-compatible clean-machine bootstrap.

The project’s technical difficulty should be concentrated in three things the evaluator directly measures: **idempotency, portability, and persistence**. Everything else should remain intentionally simple.