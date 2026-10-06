# Cloud-1

Automated deployment of a persistent WordPress stack to fresh Ubuntu or Debian
servers. Ansible installs and configures Docker, the host firewall, runtime
secrets, TLS, and a four-service Docker Compose application.

## Architecture

- Nginx is the only public application container and publishes TCP 80/443.
- WordPress runs separately with PHP-FPM.
- phpMyAdmin is available at `/phpmyadmin/` behind HTTP Basic Authentication.
- MariaDB is attached only to an internal Docker network and has no host port.
- WordPress and MariaDB data use named Docker volumes.
- Docker and all long-running containers restart automatically after reboot.
- Runtime passwords are generated once on each managed server and never
  committed to Git.

See [docs/architecture.md](docs/architecture.md) for the complete design.

## Controller prerequisites

- Python 3 with the `venv` module
- SSH access to the target
- The target's SSH host key verified in `known_hosts`

The target requires only an Ubuntu/Debian-like installation with SSH and
Python. A fresh evaluation host can be deployed directly through its root
account. The playbook does not disable or replace root SSH access.

## Deployment

```sh
make install
make inventory
```

Edit the ignored `inventories/hosts.yml`:

```yaml
all:
  children:
    cloud1:
      hosts:
        evaluation:
          ansible_host: 203.0.113.10
          ansible_user: root
          cloud1_domain: cloud1.example.org
          cloud1_tls_mode: self_signed
```

For a public DNS hostname, use:

```yaml
cloud1_tls_mode: letsencrypt
cloud1_letsencrypt_email: student@example.com
```

The DNS record must already resolve to the target. Deploy and verify:

```sh
make check
make ping
make deploy
make verify
```

`make idempotency` converges the same host twice and then runs the verification
playbook.

## Credentials

Secrets are generated on the managed server under `/etc/cloud-1/secrets`.
Retrieve credentials through an authorized sudo session:

```sh
sudo cat /etc/cloud-1/secrets/wordpress_admin_password
sudo cat /etc/cloud-1/secrets/phpmyadmin_basic_auth
```

The WordPress administrator is `cloud1_admin`. The phpMyAdmin HTTP Basic
Authentication user is `cloud1`. phpMyAdmin then accepts the WordPress database
user `wordpress` with the password stored in `wordpress_db_password`.

## Operations

```sh
cd /opt/cloud-1
sudo docker compose ps
sudo docker compose logs
sudo docker compose restart nginx
sudo docker volume inspect cloud1_wordpress_data
sudo docker volume inspect cloud1_mariadb_data
```

Normal playbook runs never delete volumes or rotate existing secrets.
