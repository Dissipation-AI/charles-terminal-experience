expect -c '
spawn ./configure
expect "Service name:" { send "billing\r" }
expect "Port" { send "9040\r" }
expect "TLS" { send "y\r" }
expect "Admin email:" { send "ops@example.com\r" }
expect "Write config.json" { send "y\r" }
expect eof' > /dev/null && cat config.json
