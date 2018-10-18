#!/usr/bin/expect -f
# exp_internal 1

set host_password [lindex $argv 0]
set guest_image_path [lindex $argv 1]
set snapshot_name [lindex $argv 2]

set fifo_name "trace_fifo"

set timeout 40

set gcc_cmd [list gcc -Werror -Wall -pedantic /mnt/hgfs/qemu_automation/make_big_fifo.c -o make_big_fifo]
eval exec $gcc_cmd

puts "---make big fifo---"
exec ./make_big_fifo $fifo_name 1048576

puts "---cat fifo to should_be_empty.bin---"
set temp_fifo_reader_pid [spawn cat $fifo_name > should_be_empty.bin]

set gcc_cmd2 [list gcc -Werror -Wall -pedantic /mnt/hgfs/qemu_automation/simple_analysis.c -o simple_analysis]
eval exec $gcc_cmd2

spawn cat $fifo_name > simp.bin &
set temp_fifo_reader_id $spawn_id

# Start qemu while:
#   The monitor is redirected to our process' stdin and stdout.
#   /dev/ttyS4 of the guest is redirected to pipe_for_serial.
#   The guest doesn't start running (-S), as we load a snapshot anyway.
puts "---starting qemu---"
spawn ./qemu_mem_tracer/x86_64-softmmu/qemu-system-x86_64 -m 2560 -S \
    -hda $guest_image_path -monitor stdio \
    -serial pty -serial pty -trace file=$fifo_name
set monitor_id $spawn_id


puts "---parsing qemu's message about pseudo-terminals that it opened---"
proc get_pty {monitor_id} {
    expect -i $monitor_id "serial pty: char device redirected to " {
        expect -i $monitor_id -re {^/dev/pts/\d+} {
            return $expect_out(0,string)
        }
    }
}
set guest_stdout_and_stderr_pty [get_pty monitor_id]
set guest_password_prompt_pty [get_pty monitor_id]

spawn cat $guest_stdout_and_stderr_pty
set guest_stdout_and_stderr_reader_id $spawn_id

set password_prompt_reader_pid [spawn cat $guest_password_prompt_pty]
set password_prompt_reader_id $spawn_id

# (required if -nographic was used)
# Switch to monitor interface 
# send "\x01"
# send "c"

puts "\n---loading snapshot---"
send -i $monitor_id "loadvm $snapshot_name\r"
send -i $monitor_id "cont\r"

# run scp to download test_elf
puts "---copying test_elf from host---"

send -i $monitor_id "sendkey ret\r"
# IIUC, the following line doesn't manage to simulate "hitting Enter" in the
# guest, because the guest's /dev/tty is already open when we overwrite
# /dev/tty with a hard link to the file that /dev/ttyS0 points to.
# exec echo > $serial_pty

# wait for the scp connection to be established.
######
# expect -i password_prompt_reader_id "password:"
######
# I didn't manage to make /dev/ttyS1 work, so I redirected both the password
# prompt and stdout to /dev/ttyS0.
# https://stackoverflow.com/questions/52801787/qemu-doesnt-create-a-second-serial-port-ubuntu-x86-64-guest-and-host
expect -i guest_stdout_and_stderr_reader_id "password:"
puts "\n---authenticating (scp)---"

# type the password.
# This works because scp directly opens /dev/tty, which we have overwritten in
# advance, so it is as if scp opens the serial port which is connected to
# guest_password_prompt_pty.
######
# exec echo $host_password > $guest_password_prompt_pty
######
# Dito "didn't manage to make /dev/ttyS1 work..." comment.
exec echo $host_password > $guest_stdout_and_stderr_pty

# the guest would now download elf_test and run it.

puts "\n---expecting test info---"
expect -i $guest_stdout_and_stderr_reader_id -indices -re \
        "-----begin test info-----(.*)-----end test info-----" {
    set test_info [string trim $expect_out(1,string)]
}
exec echo -n "$test_info" > test_info.txt

puts "\n---expecting ready for trace message---"
expect -i $guest_stdout_and_stderr_reader_id "Ready for trace. Press any key to continue."



# We don't need the password prompt reader anymore.
puts "\n---killing and closing password_prompt_reader---"
exec kill -SIGKILL $password_prompt_reader_pid
close -i $password_prompt_reader_id


send -i $monitor_id "set_our_buf_address $test_info\r"


puts "---getting ready to trace---"
send -i $monitor_id "enable_tracing_single_event_optimization\r"
send -i $monitor_id "trace-event guest_mem_before_exec on\r"
spawn ./simple_analysis $fifo_name
set simple_analysis_id $spawn_id
set simple_analysis_pid [exp_pid -i $simple_analysis_id]

exec kill -SIGKILL $temp_fifo_reader_pid

puts "---starting to trace---"
set test_start_time [timestamp]

# Resume the test.
send -i $monitor_id "sendkey ret\r"

# interact -i $monitor_id

expect -i $guest_stdout_and_stderr_reader_id "End running test."
send -i $monitor_id "stop\r"

exec kill -SIGUSR1 $simple_analysis_pid

puts "\n---expecting simple_analysis output---"
expect -i $simple_analysis_id -indices -re {num_of_mem_accesses: (\d+)} {
    set simple_analysis_output $expect_out(1,string)
}

set test_end_time [timestamp]

set test_time [expr $test_end_time - $test_start_time]
exec echo "test_time: $test_time" >> test_info.txt

send -i $monitor_id "get_compiled_analysis_tool_result\r"
# expect -i $monitor_id "compiled analysis tool result: === " {
#     expect -i $monitor_id -re {^\d+} {
#         set analysis_tool_result $expect_out(0,string)
#     }
# }
# exec echo "analysis_tool_result: $analysis_tool_result" >> test_info.txt

puts "\ntest_time: $test_time"
puts "simple_analysis_output: $simple_analysis_output"


puts "\n---end run_qemu_and_test.sh---"


interact -i $monitor_id