expect -c '
set timeout 30
spawn ./setup
expect "Database name: " { send "orders\r" }
expect -re {one-time code: ([A-Z0-9]+)} { set code $expect_out(1,string) }
expect "Code: " { send "$code\r" }
expect "Replicas" { send "3\r" }
expect "backups" { send "y\r" }
expect -re {Free backup windows: ([0-9:]+)} { set w $expect_out(1,string) }
expect "Backup window: " { send "$w\r" }
expect "Create it" { send "y\r" }
expect eof' > /dev/null
