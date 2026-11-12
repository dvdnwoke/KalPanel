# KalPanel 0.0.7

Light hosting control panel for Ubuntu, written in Zig. It creates users, domains, and mailboxes, serves one PHP site and one Node site through nginx, and turns a domain on with a Let's Encrypt certificate.

This release is a command-line tool. There is no web interface yet.

## Install

Download the static **x86_64 Linux** binary (Ubuntu, Arch, and other glibc or musl systems):

[kalpanel-0.0.7-x86_64-linux.tar.gz](https://github.com/dvdnwoke/KalPanel/releases/download/v0.0.7/kalpanel-0.0.7-x86_64-linux.tar.gz)

```bash
curl -L -o kalpanel-0.0.7-x86_64-linux.tar.gz \
  https://github.com/dvdnwoke/KalPanel/releases/download/v0.0.7/kalpanel-0.0.7-x86_64-linux.tar.gz
tar -xzf kalpanel-0.0.7-x86_64-linux.tar.gz
sudo install -m 755 kalpanel /usr/local/bin/kalpanel
kalpanel version
```

`kalpanel version` prints `kalpanel 0.0.7`.

```text
04ee3b1a697dba6acb981224001c862de95e6259e205e9ee27a1eeae4955240c  kalpanel-0.0.7-x86_64-linux.tar.gz
```

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
kalpanel --db /var/lib/kalpanel.sqlite user list
kalpanel --db /var/lib/kalpanel.sqlite user suspend admin
kalpanel --db /var/lib/kalpanel.sqlite user delete bob
kalpanel --db /var/lib/kalpanel.sqlite domain list
kalpanel --db /var/lib/kalpanel.sqlite domain list admin
kalpanel --db /var/lib/kalpanel.sqlite domain suspend example.com
kalpanel --db /var/lib/kalpanel.sqlite domain delete example.com
kalpanel --db /var/lib/kalpanel.sqlite email list example.com
kalpanel --db /var/lib/kalpanel.sqlite email suspend alice@example.com
kalpanel --db /var/lib/kalpanel.sqlite email delete alice@example.com
kalpanel --db /var/lib/kalpanel.sqlite uninstall
```

Suspend only hides a site. Delete removes it.

`user list` prints every account. `domain list` prints every domain, and `domain list USER` prints only that user's. `email list DOMAIN` prints the mailboxes on that domain. None of these print a password.

`email delete` removes one mailbox. `domain delete` removes that site, its public folder, its certificate files, and its mailboxes. `user delete` does that for every domain the user owns, then removes the account and the home directory. Another user's site is not touched. `uninstall` still only removes packages this program installed.

Deleting a user does not ask which reseller created them. The database never stored that, and the other commands are already operator commands: whoever can run `kalpanel` can suspend. List and delete follow that, instead of inventing an owner column for this step. There is no confirmation prompt. The tests delete one side and check the other side is still there.

The panel account is an ordinary Unix user in the `users` group. It is not added to Ubuntu's `admin` or `sudo` group. `admin` is a valid account name.

Roles are `admin`, `reseller`, and `user`. An admin can create anyone. A reseller can create only a normal user (`--actor NAME`). A normal user cannot create accounts.

```bash
sudo kalpanel --db /var/lib/kalpanel.sqlite user create alice --role user --actor admin --domain --php
```

## Tests

`zig build test` is part of the project. GitHub runs that same command on every push.

It covers hosting (PHP, Node, mail, suspend, list, delete, the package ledger, Let's Encrypt) and the property tests in `src/fuzz.zig`. Those throw random account names, domain names, and mailbox addresses at the validators, and check that every combination of features installs only that feature's packages. A name the validator accepts has to match the grammar. A name like `..` or `-bad.com` must be rejected, because those strings are written into filesystem paths and nginx config.
