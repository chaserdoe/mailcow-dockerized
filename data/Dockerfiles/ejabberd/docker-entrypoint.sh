#!/bin/bash
set -e

until dig +short mailcow.email > /dev/null; do
  echo "Waiting for DNS..."
  sleep 1
done

until nc phpfpm 9001 -z; do
  echo "Waiting for PHP on port 9001..."
  sleep 3
done

until nc phpfpm 9002 -z; do
  echo "Waiting for PHP on port 9002..."
  sleep 3
done

# Wait for MySQL to warm-up
while ! mysqladmin status --socket=/var/run/mysqld/mysqld.sock -u${DBUSER} -p${DBPASS} --silent; do
  echo "Waiting for database to come up..."
  sleep 2
done

# We dont want to give global write access to ejabberd in this directory
chown -R root:root /var/www/authentication

[ ! -f /sqlite/sqlite.db ] && cp /sqlite/sqlite_template.db /sqlite/sqlite.db

[ ! -d /ejabberd_ssl ] && mkdir /ejabberd_ssl
cp /ssl/cert.pem /ejabberd_ssl/cert.pem
cp /ssl/key.pem /ejabberd_ssl/key.pem

# Write access to upload directory and log file for authenticator
touch /var/www/authentication/auth.log
chown -R ejabberd:ejabberd /var/www/upload \
  /var/www/authentication/auth.log \
  /sqlite \
  /ejabberd_ssl

# ACL file for vhosts, hosts file for vhosts
touch /ejabberd/ejabberd_acl.yml \
  /ejabberd/ejabberd_hosts.yml \
  /ejabberd/ejabberd_macros.yml
chmod 644 /ejabberd/ejabberd_acl.yml \
  /ejabberd/ejabberd_hosts.yml \
  /ejabberd/ejabberd_macros.yml
chown 82:82 /ejabberd/ejabberd_acl.yml \
  /ejabberd/ejabberd_hosts.yml
chown 82:82 /ejabberd

cat <<EOF > /ejabberd/ejabberd_api.yml
# Autogenerated by mailcow
api_permissions:
  "Reload by mailcow":
    who:
      - ip: "${IPV4_NETWORK}.0/24"
    what:
      - "reload_config"
      - "restart"
      - "list_certificates"
      - "list_cluster"
      - "join_cluster"
      - "leave_cluster"
      - "backup"
      - "status"
      - "stats"
      - "muc_online_rooms"
EOF

cat <<EOF > /ejabberd/ejabberd_macros.yml
# Autogenerated by mailcow
define_macro:
  'MAILCOW_HOSTNAME': "${MAILCOW_HOSTNAME}"
  'EJABBERD_HTTPS': ${XMPP_HTTPS_PORT}
EOF

# Set open_basedir
sed -i 's/;open_basedir =/open_basedir = \/var\/www\/authentication/g' /etc/php7/php.ini

sed -i "s/__DBUSER__/${DBUSER}/g" /var/www/authentication/vendor/leesherwood/ejabberd-php-auth/src/CommandExecutors/mailcowCommandExecutor.php
sed -i "s/__DBPASS__/${DBPASS}/g" /var/www/authentication/vendor/leesherwood/ejabberd-php-auth/src/CommandExecutors/mailcowCommandExecutor.php
sed -i "s/__DBNAME__/${DBNAME}/g" /var/www/authentication/vendor/leesherwood/ejabberd-php-auth/src/CommandExecutors/mailcowCommandExecutor.php

# Run hooks
for file in /hooks/*; do
  if [ -x "${file}" ]; then
    echo "Running hook ${file}"
    "${file}"
  fi
done

alias ejabberdctl="su-exec ejabberd /home/ejabberd/bin/ejabberdctl --node ejabberd@${MAILCOW_HOSTNAME}"

if [[ -z "$(mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} -B -e 'SELECT domain FROM domain WHERE xmpp = 1')" ]]; then
  echo "No XMPP host configured, sleeping the sleep of the righteous, waiting for someone to wake me up..."
  exec su-exec ejabberd tini -g -- sleep 365d
fi

exec su-exec ejabberd tini -g -- /home/ejabberd/bin/ejabberdctl --node ejabberd@${MAILCOW_HOSTNAME} foreground
