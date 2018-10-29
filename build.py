import subprocess
import shutil
import os
import os.path
import argparse

BUILD_QEMU_SCRIPT_NAME = 'config_and_make_qemu_with_GMBEOO.py'
MAKE_BIG_FIFO_SOURCE_NAME = 'make_big_fifo.c'
QEMU_MEM_TRACER_SCRIPT_NAME = 'memory_tracer.py'
MAKE_BIG_FIFO_NAME = os.path.splitext(MAKE_BIG_FIFO_SOURCE_NAME)[0]
TESTS_DIR_NAME = 'tests'
BUILD_AND_RUN_TESTS_SCRIPT_REL_PATH = os.path.join(TESTS_DIR_NAME,
                                                   'build_and_run_tests.py')
# Note that this script removes this directory upon starting.
OUTPUT_DIR_NAME = 'tracer_bin'

def execute_cmd_in_dir(cmd, dir_path='.'):
    print(f'executing cmd (in {dir_path}): {cmd}')
    subprocess.run(cmd, shell=True, check=True, cwd=dir_path)

# def get_current_branch_name(repo_path):
#     return subprocess.run('git rev-parse --abbrev-ref HEAD', shell=True,
#                           check=True, cwd=repo_path,
#                           capture_output=True).stdout.strip().decode()

parser = argparse.ArgumentParser(
    formatter_class=argparse.RawDescriptionHelpFormatter,
    description='Build qemu_mem_tracer.\n\n'
                'Run `python3.7 memory_tracer.py -h` for help about arguments '
                'that both memory_tracer.py and this script receive.')
parser.add_argument('qemu_with_GMBEOO_path', type=str)
parser.add_argument('--enable-debug', dest='debug_flag',
                    action='store_const',
                    const='--enable-debug', default='--disable-debug',
                    help='If specified, --enable-debug is passed to the '
                         'configure script of qemu_with_GMBEOO, instead of '
                         '--disable-debug (the default).')
parser.add_argument('--dont_compile_qemu', action='store_true',
                    help='If specified, this script doesn\'t build '
                         'qemu_with_GMBEOO.')
parser.add_argument('--run_tests', action='store_true',
                    help='If specified, this script doesn\'t run tests (that '
                         'check whether qemu_mem_tracer works as '
                         'expected).')
parser.add_argument('--guest_image_path', type=str)
parser.add_argument('--snapshot_name', type=str)
parser.add_argument('--host_password', type=str)
args = parser.parse_args()

this_script_path = os.path.realpath(__file__)
this_script_location = os.path.split(this_script_path)[0]
this_script_location_dir_name = os.path.split(this_script_location)[-1]
if this_script_location_dir_name != 'qemu_mem_tracer':
    print(f'Attention:\n'
          f'This script assumes that other scripts in qemu_mem_tracer '
          f'are in the same folder as this script (i.e. in the folder '
          f'"{this_script_location}").\n'
          f'However, "{this_script_location_dir_name}" != "qemu_mem_tracer".\n'
          f'Enter "y" if you wish to proceed anyway.')
    while True:
        user_input = input()
        if user_input == 'y':
            break

output_dir_path = os.path.join(this_script_location, OUTPUT_DIR_NAME)
shutil.rmtree(output_dir_path, ignore_errors=True)
os.mkdir(output_dir_path)

make_big_fifo_bin_path = os.path.join(output_dir_path, MAKE_BIG_FIFO_NAME)
compile_make_big_fifo_cmd = (f'gcc -Werror -Wall -pedantic '
                             f'{MAKE_BIG_FIFO_SOURCE_NAME} '
                             f'-o {make_big_fifo_bin_path}')
execute_cmd_in_dir(compile_make_big_fifo_cmd, this_script_location)

if not args.dont_compile_qemu:
    build_qemu_script_path = os.path.join(this_script_location,
                                          BUILD_QEMU_SCRIPT_NAME)
    build_qemu_cmd = (f'python3.7 {BUILD_QEMU_SCRIPT_NAME} '
                      f'{args.qemu_with_GMBEOO_path} {args.debug_flag}')
    execute_cmd_in_dir(build_qemu_cmd, this_script_location)

if args.run_tests:
    for arg_name in ('guest_image_path', 'snapshot_name', 'host_password'):
        if getattr(args, arg_name) is None:
            raise RuntimeError(f'--run_tests was specified, but '
                               f'--{arg_name} was not specified.')
    build_and_run_tests_script_path = os.path.join(
        this_script_location, BUILD_AND_RUN_TESTS_SCRIPT_REL_PATH)
    qemu_mem_tracer_script_path = os.path.join(
        this_script_location, QEMU_MEM_TRACER_SCRIPT_NAME)
    
    execute_cmd_in_dir(f'python3.7 {build_and_run_tests_script_path} '
                       f'{qemu_mem_tracer_script_path} '
                       f'{args.qemu_with_GMBEOO_path} '
                       f'{args.guest_image_path} '
                       f'{args.snapshot_name} '
                       f'{args.host_password}')

