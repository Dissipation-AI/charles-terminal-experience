# Reference: one session driven with expect, reading each answer before the next command.
expect -c '
set timeout 60
spawn ./console
expect "ops> "
send "alerts\r"; expect -re {(ALERT-[0-9]+)} { set a $expect_out(1,string) }; expect "ops> "
send "trace $a\r"; expect -re {waits on ([a-z]+-[0-9]+)} { set b $expect_out(1,string) }; expect "ops> "
send "logs $b\r"; expect -re {upstream ([a-z]+-[0-9]+)} { set c $expect_out(1,string) }; expect "ops> "
send "ack $a $c\r"; expect "acknowledged"; expect "ops> "
send "quit\r"; expect eof
set fh [open answer.txt w]; puts $fh $c; close $fh' > /dev/null
