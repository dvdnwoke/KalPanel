# KalPanel 0.0.5

Light hosting control panel for Ubuntu, written in Zig. It creates users, domains, and mailboxes, serves one PHP site and one Node site through nginx, and turns a domain on with a Let's Encrypt certificate.

This release is a command-line tool. There is no web interface yet.

## Install

Download the static **x86_64 Linux** binary (Ubuntu, Arch, and other glibc or musl systems):

[kalpanel-0.0.5-x86_64-linux.tar.gz](https://github.com/dvdnwoke/KalPanel/releases/download/v0.0.5/kalpanel-0.0.5-x86_64-linux.tar.gz)

```bash
curl -L -o kalpanel-0.0.5-x86_64-linux.tar.gz \
  https://github.com/dvdnwoke/KalPanel/releases/download/v0.0.5/kalpanel-0.0.5-x86_64-linux.tar.gz
tar -xzf kalpanel-0.0.5-x86_64-linux.tar.gz
sudo install -m 755 kalpanel /usr/local/bin/kalpanel
kalpanel version
```

`kalpanel version` prints `kalpanel 0.0.5`.

Build from source instead if you have Zig 0.17 or newer:

```bash
git clone https://github.com/dvdnwoke/KalPanel.git
cd KalPanel
zig build -Doptimize=ReleaseSafe
sudo install -m 755 zig-out/bin/kalpanel /usr/local/bin/kalpanel
```

## What you need

- Ubuntu, and root. `setup` uses `apt`.
- A DNS A record for the domain, pointed at this server, before asking for a certificate.
- These ports open: **80** and **443** for sites, **25**, **587**, and **993** for mail.

KalPanel installs a package only when a non-suspended user actually uses that feature, and only if it is not already installed. `uninstall` removes just those packages.

| Feature | Program | Packages |
|---|---|---|
| domain | nginx | nginx, certbot |
| php | php 8.3 only | php8.3-cli, php8.3-fpm |
| node | `/usr/bin/node` only | nodejs |
| email | postfix | postfix, dovecot-imapd |

Apache, Exim, and any other PHP or Node version are not used.

## First site

```bash
sudo kalpanel --db /var/lib/kalpanel.sqlite user create admin --role admin --domain --email --php --node
sudo kalpanel --db /var/lib/kalpanel.sqlite setup
sudo kalpanel --db /var/lib/kalpanel.sqlite domain create admin example.com --runtime php
sudo kalpanel --db /var/lib/kalpanel.sqlite domain create admin app.example.com --runtime node
```

Put the site in the public folder:

- PHP: `/home/admin/domains/example.com/public/index.php`
- Node: `/home/admin/domains/app.example.com/public/server.js`

nginx listens on port 80. PHP 8.3 goes through `unix:/run/php/php8.3-fpm.sock`. Node is the distro `/usr/bin/node` binary, proxied from port 80 to `127.0.0.1:20000` (the next Node domain gets the next port). The app reads `PORT`.

After the A record is live and port 80 answers, issue the certificate:

```bash
sudo kalpanel --db /var/lib/kalpanel.sqlite domain tls example.com admin@example.com
```

That runs certbot (HTTP-01, webroot in the public folder), switches the site to **https://example.com** on port 443, and keeps port 80 for the challenge plus a redirect. Repeat for each domain. Renew with:

```bash
sudo kalpanel --db /var/lib/kalpanel.sqlite domain renew
```

certbot's own timer also renews `/etc/letsencrypt`. A deploy hook reloads nginx, postfix, and dovecot.

## Mail and Outlook

```bash
sudo kalpanel --db /var/lib/kalpanel.sqlite email create alice@example.com
```

The password is printed once. Only a Dovecot `{SHA256}` hash is stored.

| Outlook setting | Value |
|---|---|
| IMAP | the hostname, port **993**, SSL/TLS |
| SMTP | the hostname, port **587**, STARTTLS |
| Username | the full address, `alice@example.com` |

The mail certificate is the first active Let's Encrypt domain, in alphabetical order. Issue `domain tls` for the hostname Outlook will use. Until then Dovecot uses Ubuntu's snakeoil certificate and Outlook will warn.

## Other commands

```bash
kalpanel version
kalpanel --db /var/lib/kalpanel.sqlite user suspend admin
kalpanel --db /var/lib/kalpanel.sqlite domain suspend example.com
kalpanel --db /var/lib/kalpanel.sqlite email suspend alice@example.com
kalpanel --db /var/lib/kalpanel.sqlite uninstall
```

Suspend removes that user, site, or mailbox from nginx, the Node unit, and the mail maps. `uninstall` does not delete users, sites, or the database.

Roles are `admin`, `reseller`, and `user`. An admin can create anyone. A reseller can create only a normal user (`--actor NAME`). A normal user cannot create accounts.

```bash
sudo kalpanel --db /var/lib/kalpanel.sqlite user create alice --role user --actor admin --domain --php
```

## Tests

```bash
zig build test
```
