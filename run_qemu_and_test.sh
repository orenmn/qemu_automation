#!/usr/bin/expect -f
# exp_internal 1

set timeout 40

set host_password [lindex $argv 0]
set guest_image_path [lindex $argv 1]
set snapshot_name [lindex $argv 2]

set make_big_fifo_source_path "/mnt/hgfs/qemu_automation/make_big_fifo.c"
set simple_analysis_source_path "/mnt/hgfs/qemu_automation/simple_analysis.c"
set dummy_fifo_reader_path "/mnt/hgfs/qemu_automation/dummy_fifo_reader.bash"

set fifo_name "trace_fifo"
set fifo_name "trace_fifo_[timestamp]"

set gcc_cmd [list gcc -Werror -Wall -pedantic $make_big_fifo_source_path -o make_big_fifo]
eval exec $gcc_cmd

puts "---create big fifo---"
exec ./make_big_fifo $fifo_name 1048576
puts "---done creating big fifo $fifo_name---"

puts "---spawn a temp reader of $fifo_name to read the mapping of trace events---"
set temp_fifo_reader_pid [spawn $dummy_fifo_reader_path $fifo_name "trace_events_mapping"]
set temp_fifo_reader_id $spawn_id

set gcc_cmd2 [list gcc -Werror -Wall -pedantic $simple_analysis_source_path -o simple_analysis]
eval exec $gcc_cmd2

# Start qemu while:
#   The monitor is redirected to our process' stdin and stdout.
#   /dev/ttyS0 of the guest is redirected to pipe_for_serial.
#   The guest doesn't start running (-S), as we load a snapshot anyway.
puts "---starting qemu---"
spawn ./qemu_mem_tracer/x86_64-softmmu/qemu-system-x86_64 -m 2560 -S \
    -hda $guest_image_path -monitor stdio \
    -serial pty -serial pty -trace file=$fifo_name
    # -serial pty -serial pty -trace file=my_trace_file
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
send -i $monitor_id "enable_tracing_single_event_optimization 2\r"
send -i $monitor_id "trace-event guest_mem_before_exec on\r"
set simple_analysis_pid [spawn ./simple_analysis $fifo_name $test_info]
set simple_analysis_id $spawn_id

puts "\n---killing and closing temp_fifo_reader---"
exec kill -SIGKILL $temp_fifo_reader_pid
close -i $temp_fifo_reader_id


puts "---starting to trace---"
set test_start_time [timestamp]

# Resume the test.
send -i $monitor_id "sendkey ret\r"

expect -i $guest_stdout_and_stderr_reader_id "End running test."
send -i $monitor_id "stop\r"
set test_end_time [timestamp]

sleep 1

exec kill -SIGUSR1 $simple_analysis_pid

expect -i $simple_analysis_id -indices -re {num_of_mem_accesses: (\d+)} {
    set simple_analysis_output $expect_out(1,string)
}


set test_time [expr $test_end_time - $test_start_time]
exec echo "test_time: $test_time" >> test_info.txt

send -i $monitor_id "print_trace_results\r"

puts "\ntest_time: $test_time"
puts "simple_analysis_output: $simple_analysis_output"


puts "\n---end run_qemu_and_test.sh---"


exec rm $fifo_name

interact -i $monitor_id
