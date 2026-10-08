I’ll ground the plan in the official subject, evaluation sheet, VM handoff notes, and the two local reference deployments before proposing an evaluator-safe architecture.
The rubric confirms this is deliberately narrower than a production platform: a clean, repeatable Ansible deployment of WordPress, SQL, phpMyAdmin, and a reverse proxy, with persistence and only 22/80/443 exposed. I’m checking the existing project skeleton and a comparable implementation for conventions before finalizing the role and validation design.
**Recommended scope:** build a deliberately small, evaluator-oriented IaC project—not a production platform. The current Scaleway VM is an ideal fresh target: Ubuntu 22.04, 2 vCPU, ~1.9 GiB RAM, SSH only, with Docker absent and UFW inactive. A four-service Compose stack is appropriate; Vault, Redis, monitoring, CI/CD, Kubernetes, and bespoke image builds are unnecessary scope.

**Important repository risk:** Git currently tracks only `.gitignore`; `build/` and all planned implementation files are untracked. The deliverable must be committed to this repository, since the evaluator assesses the checked-out repository—not the preconfigured VM.

```text
Browser
  └─ TCP 80  → Nginx: redirect HTTP to HTTPS / ACME challenge
  └─ TCP 443 → Nginx: TLS termination and routing
                 ├─ /             → WordPress PHP-FPM
                 └─ /phpmyadmin/  → phpMyAdmin

private Compose network
  WordPress ─┐
  phpMyAdmin ├─→ MariaDB
             └─ MariaDB has no published host port

persistent Docker volumes
  cloud1_wordpress_data
  cloud1_mariadb_data
```

Use pinned official images—`nginx`, `wordpress:*-fpm`, `mariadb`, and `phpmyadmin`—with your own Nginx configuration. This complies with the subject’s permission to use official images while clearly not re-deploying the existing Inception images. It also avoids unnecessary custom Dockerfiles and package-install logic. The local Inception project is a good functional reference for the WordPress/MariaDB/Nginx separation and persistent volumes, but Cloud-1 should be smaller and automation-first.

## Proposed repository design

```text
.
├── README.md
├── Makefile
├── ansible.cfg
├── requirements.yml
├── inventories/
│   └── hosts.example.yml
├── group_vars/
│   └── all.example.yml
├── playbooks/
│   └── site.yml
├── roles/
│   ├── common/
│   ├── docker/
│   ├── firewall/
│   ├── secrets/
│   ├── wordpress_stack/
│   └── tls/
└── docs/
    ├── architecture.md
    ├── operations.md
    └── evaluation-checklist.md
```

| Role | Responsibility | Idempotent outcome |
|---|---|---|
| `common` | Apt update, prerequisite packages, optional `deploy` user | Required host state exists without replacing it |
| `docker` | Official Docker repository, Engine, Compose plugin, enabled daemon | Docker starts after every server reboot |
| `firewall` | UFW default-deny inbound; allow TCP 22/80/443 only | Only required public ports remain open |
| `secrets` | Generate missing runtime secret files in `/etc/cloud-1/secrets`, mode `0600` | Existing credentials are never rotated during a normal rerun |
| `wordpress_stack` | Render Compose/Nginx config, create directories, pull/start services | `docker compose up -d --wait` converges the stack |
| `tls` | Domain-dependent TLS issuance/renewal, or explicit self-signed fallback | HTTPS is enabled without committing keys |

The `wordpress_stack` role should keep deployment material at `/opt/cloud-1` and runtime-only secrets at `/etc/cloud-1/secrets`. The repository must contain only examples and non-sensitive values.

## Security and persistence choices

- Publish ports **80 and 443 only** from Nginx; never publish `3306`, PHP-FPM, or phpMyAdmin.
- Use two internal Compose networks: Nginx ↔ app services, then WordPress/phpMyAdmin ↔ MariaDB. Mark the DB network `internal: true`.
- Protect `/phpmyadmin/` with Nginx HTTP Basic Auth whose password file is generated on the VM, in addition to phpMyAdmin’s normal database login. Use the non-root WordPress database account for normal phpMyAdmin access.
- Store the MariaDB data and WordPress uploads/plugins/themes in named Docker volumes. This directly supports the rubric’s `docker volume inspect` check and survives reboot/container recreation.
- Use health checks for MariaDB and WordPress, `restart: unless-stopped`, and a one-shot `wp-cli` initialization service or an idempotent Ansible command to install WordPress only when it is not already installed.
- Pin image versions or digests; do not rely on `latest`.
- Use a real DNS name, ideally DuckDNS or a team-controlled domain, before enabling Let’s Encrypt. Let Ansible install/operate Certbot on the host and mount its certificates read-only into Nginx. If no domain is available, deploy a clearly documented self-signed fallback; the subject tolerates this, but a valid domain plus automatic TLS is stronger.

## Secrets approach

Do **not** commit `.env`, Docker secret files, private keys, passwords, Ansible Vault passwords, or real inventory files. Avoid making the evaluator depend on a team-only Vault password.

The most portable approach is for Ansible’s `secrets` role to generate random values on the managed host only when a secret file is absent:

```text
/etc/cloud-1/secrets/
├── mariadb_root_password
├── wordpress_db_password
├── wordpress_admin_password
└── phpmyadmin_basic_auth
```

Compose exposes these as Docker secrets, not environment values. Tasks handling them use `no_log: true`. A normal rerun reads the existing files, so it remains idempotent. Administrative credentials can be retrieved locally by an authorized sudo user, never printed by the playbook or committed.

## Deployment workflow

1. On the controller, copy `inventories/hosts.example.yml` to an ignored local inventory and set the target hostname/IP and SSH key.
2. Run `make bootstrap` to install the declared Ansible collection requirements on the controller.
3. Run `make check` for `ansible-playbook --syntax-check`, YAML validation, and `docker compose config` rendering validation.
4. Run `make deploy`, which invokes `ansible-playbook playbooks/site.yml`.
5. Run `make verify`, which checks HTTP→HTTPS redirection, the WordPress home page, the phpMyAdmin route, Compose health, mounted volumes, and listening ports.
6. Re-run `make deploy` unchanged. It must report no meaningful changes and leave the application working.

This follows the useful part of `twagger/cloud-1`: separate common/Docker/application responsibilities and an Ansible entry playbook. Do **not** copy its destructive “down/reset on deploy” pattern: it weakens idempotency and risks persistence. The Transcendence deployment’s separation of runtime configuration from Git and its explicit operations documentation are worth carrying over; its Vault/WAF/multiple-environment machinery is intentionally out of scope.

## Evaluation-specific concern

The evaluation sheet explicitly says the defense stops if the student cannot connect as `root` using their 42 login/email arrangement. Your current practice of disabling root SSH is good operational hardening, but it conflicts with the wording for a newly provisioned evaluation instance.

Make the default project behavior:

- accept the provider’s initial root SSH access for bootstrap;
- create a non-root `deploy` user for normal automation;
- **do not disable root SSH or change evaluator access by default**;
- place any SSH hardening behind an explicit, documented opt-in variable such as `harden_ssh: true`.

Before scheduling evaluation, verify the exact Scaleway/42 root-account workflow on a newly provisioned evaluation VM. The email confirms these resources are temporary and may be deleted one hour after evaluation begins, so the playbook must work from a clean root-accessible target without relying on existing users, Docker state, certificates, or manually copied secrets.

## Acceptance checklist

1. Deploy from a clean Ubuntu 22.04 SSH/Python-only machine.
2. Re-run the same playbook successfully with no secret rotation or data loss.
3. Create a WordPress post and upload an image; reboot the VM; confirm both remain.
4. Stop and start each Compose service independently; confirm Nginx, WordPress, MariaDB, and phpMyAdmin recover.
5. Confirm externally that only 22, 80, and 443 are reachable, and confirm `3306` is absent from `docker ps` published ports.
6. Confirm `docker volume inspect` shows the WordPress and MariaDB volumes.
7. Deploy the same commit to a second fresh VM from a different inventory entry.
8. Demonstrate the role boundaries, secrets handling, persistence, and idempotency during defense.