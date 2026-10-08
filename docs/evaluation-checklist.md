# Evaluation checklist

## Clean deployment

1. Start with a fresh Ubuntu 22.04-like host containing SSH and Python.
2. Connect using the provider-supplied root account.
3. Run `make deploy`.
4. Run `make verify`.

## Website

- Open `https://<cloud1_domain>/`.
- Confirm WordPress navigation and repeated refreshes work.
- Create a post and upload an image.
- Open `/phpmyadmin/` and confirm HTTP Basic Authentication is required.

## Security

From an external machine:

```sh
nmap -Pn -p- <server-address>
```

Only IPv4 TCP 22, 80 and 443 should be reachable. On the server:

```sh
sudo ufw status verbose
cd /opt/cloud-1
sudo docker compose ps
sudo docker compose port mariadb 3306
```

The final command must report no published MariaDB port.

The real provider SSH daemon must remain reachable on the inventory's
`ansible_port`, which defaults to TCP 22. Do not move SSH to port 2222 or place
a honeypot on port 22 for the evaluation deployment. That would violate the
allowed-port list and interfere with the evaluator's required root access.

## Persistence

```sh
sudo docker volume inspect cloud1_wordpress_data
sudo docker volume inspect cloud1_mariadb_data
sudo reboot
```

After reboot, confirm the post, account, and uploaded image still exist.

## Idempotency

Run `make deploy` again. Existing passwords, WordPress state, database data,
and volumes must remain unchanged. Then run `make verify`.

## Orchestration

```sh
cd /opt/cloud-1
sudo docker compose stop wordpress
sudo docker compose start wordpress
sudo docker compose restart nginx
sudo docker compose ps
```

The stack starts in one operation, while individual services remain
independently manageable.
