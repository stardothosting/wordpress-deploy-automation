# WordPress Automation Deploy Script

Automated staging-to-production deploy for WordPress / WooCommerce sites. Handles file sync, database migration, WooCommerce order preservation (legacy CSV and HPOS), Gravity Forms entry backup/restore, URL search-replace, and cache clearing.

## How It Works

1. Pre-flight check confirms WordPress is healthy on staging
2. Maintenance mode is enabled on production
3. Files are rsynced from staging to production (excluding `wp-config.php`, `.htaccess`, etc.)
4. Database is exported from staging and imported to production
5. If WooCommerce is enabled, production orders are exported before the DB push and re-imported after
6. URLs are search-replaced from the staging domain to the production domain
7. Cache plugins are cleared if configured (WP Rocket or FlyingPress)
8. Maintenance mode is disabled
9. Email notification is sent on completion (or on failure at any step)

## Prerequisites

- **SSH keys**: The CI runner (or the machine executing the script) needs key-based SSH access to both staging and production hosts
- **Deploy user**: A non-root user (default: `deploy`) with passwordless sudo on both hosts
- **WP-CLI** installed on both staging and production
- **Remote tools**: `rsync`, `mysqldump`, `mysql`, `gzip`/`gunzip` available on the remote hosts
- **Mail**: `mailx` or equivalent configured on the runner for notifications

### Sudoers example

```
deploy ALL=(ALL) NOPASSWD: /usr/bin/rsync, /usr/bin/mysqldump, /usr/bin/mysql, /usr/local/bin/wp, /usr/bin/php82, /usr/bin/mv, /usr/bin/rm, /usr/bin/find, /usr/bin/bash, /usr/bin/gunzip, /usr/bin/systemctl
```

## Installation

```bash
# Clone to the expected script path
git clone <repo-url> /usr/local/bin/wordpress-deploy

# Create a config for your site (dotfile, hidden by default)
cp config/wordpress/.example config/wordpress/.mysite
# Edit .mysite with your actual values

# Create the temp directory for SQL dumps
mkdir -p /usr/local/bin/wordpress-deploy/sqltmp

# Make the script executable
chmod +x wordpress-deploy.sh
```

## Configuration

Each site gets a dotfile in `config/wordpress/` named after the domain's first segment. For example, `mysite.com` loads `config/wordpress/.mysite`. The dot prefix keeps these files hidden by default on Unix systems and excluded by most web servers.

Every variable supports an environment variable override with a fallback default:

```bash
prod_db_password="${PROD_DB_PASSWORD:-prod_pass}"
```

This means you can either:
- Edit the dotfile directly with real values
- Inject env vars from your CI/CD system and use the dotfile defaults as a template

See `config/wordpress/.example` for the full list of variables.

### Key config flags

| Variable | Default | Purpose |
|---|---|---|
| `woocommerce_enable` | `true` | Enable WooCommerce order-safe push |
| `woocommerce_hpos` | `true` | Use HPOS table-level export instead of legacy CSV |
| `gform_entries` | `true` | Backup and restore Gravity Forms entries |
| `galera_restart` | `false` | Restart MySQL before DB import (Galera clusters) |
| `wprocket` | `false` | Clear WP Rocket cache after deploy |
| `flyingpress` | `false` | Clear FlyingPress cache after deploy |

## Usage

```bash
./wordpress-deploy.sh mysite.com
```

The domain argument is used to derive the config filename and is the only required argument.

## CI/CD Integration

The script takes a single argument and exits non-zero on failure, so it works with any CI system that can run a shell command.

### Woodpecker CI

```yaml
# .woodpecker.yml
pipeline:
  deploy:
    image: alpine
    commands:
      - /usr/local/bin/wordpress-deploy/wordpress-deploy.sh mysite.com
    secrets: [PROD_DB_PASSWORD, STAGING_DB_PASSWORD, PROD_DB_USER, STAGING_DB_USER]
    when:
      branch: main
      event: push
```

Secrets are injected as environment variables automatically. The config dotfile picks them up via the `${VAR:-default}` pattern.

### Jenkins

```groovy
// Jenkinsfile
pipeline {
    agent any
    environment {
        PROD_DB_PASSWORD = credentials('prod-db-password')
        STAGING_DB_PASSWORD = credentials('staging-db-password')
    }
    stages {
        stage('Deploy') {
            steps {
                sh '/usr/local/bin/wordpress-deploy/wordpress-deploy.sh mysite.com'
            }
        }
    }
}
```

### GitHub Actions

```yaml
# .github/workflows/deploy.yml
name: Deploy WordPress
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: self-hosted  # needs SSH access to your servers
    steps:
      - name: Push to production
        env:
          PROD_DB_PASSWORD: ${{ secrets.PROD_DB_PASSWORD }}
          STAGING_DB_PASSWORD: ${{ secrets.STAGING_DB_PASSWORD }}
        run: /usr/local/bin/wordpress-deploy/wordpress-deploy.sh mysite.com
```

### GitLab CI

```yaml
# .gitlab-ci.yml
deploy:
  stage: deploy
  script:
    - /usr/local/bin/wordpress-deploy/wordpress-deploy.sh mysite.com
  variables:
    PROD_DB_PASSWORD: $PROD_DB_PASSWORD
    STAGING_DB_PASSWORD: $STAGING_DB_PASSWORD
  only:
    - main
  tags:
    - shell  # needs a shell runner with SSH access
```

### Gitea Actions / Forgejo

```yaml
# .gitea/workflows/deploy.yml
name: Deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: self-hosted
    steps:
      - name: Push to production
        env:
          PROD_DB_PASSWORD: ${{ secrets.PROD_DB_PASSWORD }}
          STAGING_DB_PASSWORD: ${{ secrets.STAGING_DB_PASSWORD }}
        run: /usr/local/bin/wordpress-deploy/wordpress-deploy.sh mysite.com
```

### Drone CI

```yaml
# .drone.yml
kind: pipeline
type: exec
name: deploy

steps:
  - name: push
    commands:
      - /usr/local/bin/wordpress-deploy/wordpress-deploy.sh mysite.com
    environment:
      PROD_DB_PASSWORD:
        from_secret: prod_db_password
      STAGING_DB_PASSWORD:
        from_secret: staging_db_password

trigger:
  branch:
    - main
  event:
    - push
```

All of these follow the same pattern: inject secrets as env vars, then call the script with the domain. The config dotfile handles the rest.

## Notes

- The script SSH's into staging to initiate the rsync to production, so staging needs outbound SSH access to the production host.
- Production database is backed up (full dump, gzipped) before any changes are made.
- If a step fails, the script exits immediately, sends an email alert, and does **not** disable maintenance mode. This is intentional so you can investigate before the site goes live with a partial deploy.
