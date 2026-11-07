# Ecosyste.ms Proxy

Homepage and deployment scripts for [proxy.ecosyste.ms](https://proxy.ecosyste.ms/), a package download cache with optional release cooldowns. The proxy server is maintained separately in [git-pkgs/proxy](https://github.com/git-pkgs/proxy).

`public/` contains the static homepage, package manager configuration examples, and assets. `proxy.yaml` defines the cooldown profiles for the proxy server; `install.sh` only installs the homepage and its Nginx routes.

## Configuration

Install the Ruby dependencies with the version in `.ruby-version`:

```sh
RBENV_VERSION=$(cat .ruby-version) /opt/homebrew/bin/rbenv exec bundle install
```

Copy the example and edit it for your deployment:

```sh
cp config.env.example config.env
chmod 600 config.env
```

`config.env` is ignored by Git. Both commands also accept an external config file through `PROXY_CONFIG`, so you can keep deployment details outside the checkout.

| Setting | Used for |
| --- | --- |
| `PROXY_SSH_TARGET` | SSH user and host for the stats command |
| `PROXY_APP` | Dokku app name |
| `PROXY_PAGE_DIR` | Homepage directory on the server |
| `PROXY_NGINX_CONFIG` | Nginx include file for the homepage routes |
| `PROXY_BACKUP_DIR` | Directory for timestamped installation backups |
| `PROXY_FILE_OWNER` | Owner of the installed Nginx include |
| `PROXY_FILE_GROUP` | Group of the installed Nginx include |

## Stats and installation

Run the stats script to read cache totals and per-ecosystem figures over SSH. It loads the config with `dotenv` and requires SSH access to the configured Dokku app.

```sh
bundle exec ruby stats.rb
PROXY_CONFIG=/path/to/proxy.env bundle exec ruby stats.rb
```

Run the installer on the Dokku host, with permission to write the configured paths and set the configured ownership. The homepage directory and Nginx include must already exist.

```sh
PROXY_CONFIG=/path/to/proxy.env sh install.sh
```

The installer backs up the current files, copies `public/`, renders `nginx.conf` with the configured homepage path, and rebuilds the Dokku proxy config. If the rebuild fails, it restores the previous homepage files and Nginx include.

`nginx.conf` is a template and must be rendered by the installer before use. Its routes serve the homepage and assets while blocking access to the listed management endpoints.

## Tests

The Ruby tests use Test::Unit and replace SSH and Dokku with local test commands. The homepage tests use Node's built-in test runner.

```sh
RBENV_VERSION=$(cat .ruby-version) /opt/homebrew/bin/rbenv exec bundle exec ruby -I. -e 'Dir.glob("test_*.rb").sort.each { |file| require_relative file }'
node --test test_homepage.mjs
shellcheck install.sh
```

Code is licensed under AGPL-3.0-or-later. See [LICENSE](LICENSE) for the terms.
