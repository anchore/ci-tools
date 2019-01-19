#!/usr/bin/python3

import argparse
import json
import os
import requests
import subprocess
import sys
import time

global ALL_CONTENT_TYPES
global ALL_REPORT_COMMANDS
global ALL_VULN_TYPES

ALL_CONTENT_TYPES = ['os', 'python', 'java', 'gem', 'npm']
ALL_REPORT_COMMANDS = {
    'content': 'anchore-cli --json image content',
    'vuln': 'anchore-cli --json image vuln',
    'details': 'anchore-cli --json image get',
    'policy': 'anchore-cli --json evaluate check'
}
ALL_VULN_TYPES = ['all', 'non-os', 'os']


def add_image(image_name):
    print ("Adding {} to anchore engine for scanning.".format(image_name), flush=True)
    cmd = 'anchore-cli --json image add {}'.format(image_name).split()

    try:
        output = subprocess.check_output(cmd, stderr=subprocess.STDOUT)
        output = output.decode('utf-8')
    except Exception as error:
        output = error.output
        output = output.decode('utf-8')
        raise Exception ("Failed to add image to anchore engine. Error: {}".format(output))

    img_details = json.loads(output)
    img_digest = img_details[0]['imageDigest']

    return img_digest


def generate_reports(image_name, content_type=['all'], report_type=['all'], vuln_type='all', report_directory="anchore-reports"):
    if 'all' in content_type:
        content_type = ALL_CONTENT_TYPES

    if 'all' in report_type:
        report_type = ALL_REPORT_COMMANDS.keys()

    for type in report_type:
        if type not in ALL_REPORT_COMMANDS.keys():
            raise Exception ("{} is not a valid report type.".format(type))

    for type in content_type:
        if type not in ALL_CONTENT_TYPES:
            raise Exception ("{} is not a valid content report type.".format(type))

    if vuln_type not in ALL_VULN_TYPES:
        raise Exception ("{} is not a valid vulnerability report type.".format(type))

    report_dir = report_directory
    if not os.path.exists(report_dir):
        os.makedirs(report_dir)

    # Copy ALL_REPORT_COMMANDS dictionary but filter on report_type arg.
    active_report_cmds = {k:ALL_REPORT_COMMANDS[k] for k in report_type}

    # loop through active_report_cmds dict and run specified commands for all report_types
    # generate log files from output of run commands
    for report in active_report_cmds.keys():
        if report == 'content':
            for type in content_type:
                file_name = '{}/image-{}-{}-report.json'.format(report_dir, report, type)
                cmd = '{} {} {}'.format(ALL_REPORT_COMMANDS[report], image_name, type).split()
                write_log_from_output(cmd, file_name)

        elif report == 'policy':
            file_name = '{}/image-{}-report.json'.format(report_dir, report)
            cmd = '{} {} --detail'.format(ALL_REPORT_COMMANDS[report], image_name).split()
            write_log_from_output(cmd, file_name, ignore_exit_code=True)

        elif report == 'vuln':
            file_name = '{}/image-{}-report.json'.format(report_dir, report)
            cmd = '{} {} {}'.format(ALL_REPORT_COMMANDS[report], image_name, vuln_type).split()
            write_log_from_output(cmd, file_name)

        else:
            file_name = '{}/image-{}-report.json'.format(report_dir, report)
            cmd = '{} {}'.format(ALL_REPORT_COMMANDS[report], image_name).split()
            write_log_from_output(cmd, file_name)

    return True


def get_config(config_path='/config/config.yaml', config_url='https://raw.githubusercontent.com/anchore/anchore-engine/v0.3.0/scripts/docker-compose/config.yaml'):
    conf_dir = os.path.dirname(config_path)
    if not os.path.exists(conf_dir):
        os.makedirs(conf_dir)

    with requests.get(config_url, stream=True) as r:
        if r.status_code == 200:
            with open(config_path, 'wb') as file:
                file.write(r.content)
        else:
            raise Exception ("Failed to download config file {} - response httpcode={} data={}".format(config_url, r.status_code, r.text))

    return True


def get_image_info(img_digest, user='admin', pw='foobar', engine_url='http://localhost:8228/v1/images'):
    url = '{}/{}'.format(engine_url, img_digest)
    r = requests.get(url, auth=(user, pw), verify=False, timeout=20)

    if r.status_code == 200:
        img_info = json.loads(r.text)[0]
        return img_info
    else:
        raise Exception ("Bad response from Anchore Engine - httpcode={} data={}".format(r.status_code, r.text))

    return True


def is_engine_running():
    cmd = 'ps aux'.split()
    output = subprocess.check_output(cmd)
    output = output.decode('utf-8')

    if 'anchore-manager' in output or 'twistd' in output:
        return True
    else:
        return False


def is_image_analyzed(image_digest, user='admin', pw='foobar'):
    image_info = get_image_info(image_digest, user=user, pw=pw)
    img_status = image_info['analysis_status']

    if img_status == 'analyzed':
        return True, img_status
    if img_status == 'analysis_failed':
        parsed_image_info = json.dumps(image_info, indent=2)
        raise Exception("Image analysis failed. Image details:\n{}".format(parsed_image_info))
    else:
        return False, img_status


def is_service_available(url, user='admin', pw='foobar'):
    try:
        r = requests.get(url, auth=(user, pw), verify=False, timeout=10)
        if r.status_code == 200:
            status = "ready"
            return True, status
        else:
            status = "not_ready"
            return False, status
    except Exception as err:
        status = "not_ready"
        return False, status


def print_status_message(last_status, status):
    if not status == last_status:
        print ('\n\tStatus: {}'.format(status), end='', flush=True)
    else:
        print ('.', end='', flush=True)

    return True


def setup_parser():
    content_type_choices = [type for type in ALL_CONTENT_TYPES]
    content_type_choices.append('all')
    report_type_choices = [type for type in ALL_REPORT_COMMANDS.keys()]
    report_type_choices.append('all')
    vuln_type_choices = ALL_VULN_TYPES

    parser = argparse.ArgumentParser(description='A tool that automates various anchore engine functions for CI pipelines. Intended to be run directly on the anchore/anchore-engine container.')
    parser.add_argument('-a', '--analyze', action='store_true', help='Specify if you want image to be analyzed by anchore engine.')
    parser.add_argument('-r', '--report', action='store_true', help='Generate reports on analyzed image.')
    parser.add_argument('-s', '--setup', action='store_true', help='Sets up & starts anchore engine on running container.')
    parser.add_argument('-w','--wait', action='store_true', help='Wait for anchore engine to start up.')
    parser.add_argument('--image', help='Specify the image name. REQUIRED for analyze and report options.')
    parser.add_argument('--timeout', default=300, type=int, help='Set custom timeout (in seconds) for image analysis and/or engine setup.')
    parser.add_argument('--content', nargs='+', choices=content_type_choices, default='all', help='Specify what content reports to generate. Can pass multiple options. Ignored if --type content not specified. Available options are: [{}]'.format(', '.join(content_type_choices)), metavar='')
    parser.add_argument('--type', nargs='+', choices=report_type_choices, default='all', help='Specify what report types to generate. Can pass multiple options. Available options are: [{}]'.format(', '.join(report_type_choices)), metavar='')
    parser.add_argument('--vuln', choices=vuln_type_choices, default='all', help='Specify what vulnerability reports to generate. Available options are: [{}] '.format(', '.join(vuln_type_choices)), metavar='')

    return parser


def start_anchore_engine():
    if not is_engine_running():
        cmd = 'anchore-manager service start --all'.split()
        print ("Starting anchore engine...", flush=True)
        log_file = open('anchore-engine.log', 'w')

        try:
            subprocess.Popen(cmd, stdout=log_file, stderr=subprocess.STDOUT)
        except Exception as error:
            raise Exception ("Unable to start anchore engine. Exception: {}".format(error))

        return True
    else:
        raise Exception ("Anchore engine is already running.")


def wait_engine_available(health_check_urls=[], timeout=300, user='admin', pw='foobar'):
    start_ts = time.time()
    last_status = str()

    for url in health_check_urls:
        is_available = False
        while not is_available:
            if time.time() - start_ts >= timeout:
                raise Exception("Timed out after {} seconds.".format(timeout))
            is_available, status = is_service_available(url=url, user=user, pw=pw)
            if is_available:
                break
            print_status_message(last_status, status)
            last_status = status
            time.sleep(10)

    print ("\n\nAnchore engine is available!\n", flush=True)

    return True


def wait_image_analyzed(image_digest, timeout=300, user='admin', pw='foobar'):
    print ('Waiting for analysis to complete...', flush=True)
    last_img_status = str()
    is_analyzed = False
    start_ts = time.time()

    while not is_analyzed:
        if time.time() - start_ts >= timeout:
            raise Exception("Timed out after {} seconds.".format(timeout))
        is_analyzed, img_status = is_image_analyzed(image_digest, user=user, pw=pw)
        print_status_message(last_img_status, img_status)
        if is_analyzed:
            break
        last_img_status = img_status
        time.sleep(10)

    print ("\n\nAnalysis completed!\n", flush=True)

    return True


def write_log_from_output(command, file_name, ignore_exit_code=False):
    try:
        output = subprocess.check_output(command)
        output = output.decode('utf-8')
        with open(file_name, 'w') as file:
            file.write(output)

    except Exception as error:
        output = error.output
        output = output.decode('utf-8')
        if not ignore_exit_code:
            print ('Failed to generate {}. Exception: {} \n {}'.format(file_name, error, output), flush=True)
            return False
        else:
            with open(file_name, 'w') as file:
                file.write(output)

    print ('Successfully generated {}.'.format(file_name), flush=True)

    return True


### MAIN PROGRAM STARTS HERE ###
def main(arg_parser):
    parser = arg_parser

    # setup vars for arguments passed to script
    args = parser.parse_args()
    analyze_image = args.analyze
    content_type = args.content
    generate_report = args.report
    image_name = args.image
    report_type = args.type
    setup_engine = args.setup
    timeout = args.timeout
    vuln_type = args.vuln
    wait_engine = args.wait

    if len(sys.argv) <= 1 :
        parser.print_help()
        raise Exception ("\n\nERROR - Must specify at least one option.")

    if wait_engine and (setup_engine or image_name or generate_report or analyze_image):
        parser.print_help()
        raise Exception ("\n\nERROR - The --wait option is standalone. Cannot be used with any other options.")

    if setup_engine and (image_name or generate_report or analyze_image):
        parser.print_help()
        raise Exception ("\n\nERROR - Cannot analyze image or generate reports until engine is setup.")

    if (generate_report or analyze_image) and not image_name:
        parser.print_help()
        raise Exception ("\n\nERROR - Cannot analyze image or generate a report without specifying an image name.")

    if image_name and not (generate_report or analyze_image):
        parser.print_help()
        raise Exception ("\n\nERROR - Must specify an action to perform on image. Plase include --report or --analyze")

    anchore_env_vars = {
        "ANCHORE_HOST_ID" : "localhost",
        "ANCHORE_ENDPOINT_HOSTNAME" : "localhost",
        "ANCHORE_CLI_USER" : "admin",
        "ANCHORE_CLI_PASS" : "foobar",
        "ANCHORE_CLI_SSL_VERIFY" : "n"
    }

    # set default anchore cli environment variables if they aren't already set
    for var in anchore_env_vars.keys():
        if var not in os.environ:
            os.environ[var] = anchore_env_vars[var]

    anchore_user = os.environ["ANCHORE_CLI_USER"]
    anchore_pw = os.environ["ANCHORE_CLI_PASS"]

    if wait_engine:
        wait_engine_available(health_check_urls=['http://localhost:8228/health', 'http://localhost:8228/v1/system/feeds'], timeout=timeout, user=anchore_user, pw=anchore_pw)

    elif setup_engine:
        get_config()
        start_anchore_engine()
        wait_engine_available(health_check_urls=['http://localhost:8228/health', 'http://localhost:8228/v1/system/feeds'], timeout=timeout, user=anchore_user, pw=anchore_pw)

    elif image_name:
        if analyze_image:
            img_digest = add_image(image_name)
            wait_image_analyzed(img_digest, timeout, user=anchore_user, pw=anchore_pw)
        if generate_report:
            generate_reports(image_name, content_type, report_type, vuln_type)
            print ("\n")

    else:
        parser.print_help()
        raise Exception ('\n\nError processing command arguments for {}.'.format(sys.argv[0]))


if __name__ == '__main__':
    try:
        arg_parser = setup_parser()
        main(arg_parser)

    except Exception as error:
        print ('\n\nERROR executing script - Exception: {}'.format(error))
        sys.exit(1)
