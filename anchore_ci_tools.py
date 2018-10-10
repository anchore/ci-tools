#!/usr/bin/python

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

ALL_CONTENT_TYPES = ['os', 'npm', 'gem', 'python', 'java']
ALL_REPORT_COMMANDS = {
    'content': 'anchore-cli --json image content',
    'vuln': 'anchore-cli --json image vuln',
    'details': 'anchore-cli --json image get',
    'policy': 'anchore-cli --json evaluate check'
}
ALL_VULN_TYPES = ['all', 'non-os', 'os']


def add_image_analyze(image_name, timeout=300):
    print ('Adding {} to Anchore engine for scanning...'.format(image_name))
    sys.stdout.flush()
    cmd = 'anchore-cli --json image add {}'.format(image_name).split()

    try:
        output = subprocess.check_output(cmd, stderr=subprocess.STDOUT)
    except Exception as error:
        raise Exception ('Failed to add image to anchore engine. Error: {}'.format(error.output))

    img_details = json.loads(output)
    img_digest = img_details[0]['imageDigest']
    print ('Waiting for analysis to complete...')
    sys.stdout.flush()

    start_ts = time.time()
    while not is_image_analyzed(img_digest):
        if time.time() - start_ts >= timeout:
            raise Exception("Analysis timed out after {} seconds".format(timeout))
        time.sleep(10)

    return True


def generate_reports(image_name, content_type=['all'], report_type=['all'], vuln_type='all'):
    if 'all' in content_type:
        content_type = ALL_CONTENT_TYPES

    if 'all' in report_type:
        report_type = ALL_REPORT_COMMANDS.keys()

    # Check that report types are valid
    for type in report_type:
        if type not in ALL_REPORT_COMMANDS.keys():
            raise Exception ('{} is not a valid report type.'.format(type))

    # Check that content types are valid
    for type in content_type:
        if type not in ALL_CONTENT_TYPES:
            raise Exception ('{} is not a valid content report type.'.format(type))

    if vuln_type not in ALL_VULN_TYPES:
        raise Exception ('{} is not a valid vulnerability report type.'.format(type))

    # Copy ALL_REPORT_COMMANDS dictionary but filter on report_type arg.
    active_report_cmds = {k:ALL_REPORT_COMMANDS[k] for k in report_type}

    for report in active_report_cmds.keys():
        if report == 'content':
            for type in content_type:
                file_name = 'image-{}-{}-report.json'.format(report, type)
                cmd = '{} {} {}'.format(ALL_REPORT_COMMANDS[report], image_name, type).split()
                write_log_from_output(cmd, file_name)

        elif report == 'policy':
            file_name = 'image-{}-report.json'.format(report)
            cmd = '{} {} --detail'.format(ALL_REPORT_COMMANDS[report], image_name).split()
            write_log_from_output(cmd, file_name, ignore_exit_code=True)

        elif report == 'vuln':
            file_name = 'image-{}-report.json'.format(report)
            cmd = '{} {} {}'.format(ALL_REPORT_COMMANDS[report], image_name, vuln_type).split()
            write_log_from_output(cmd, file_name)

        else:
            file_name = 'image-{}-report.json'.format(report)
            cmd = '{} {}'.format(ALL_REPORT_COMMANDS[report], image_name).split()
            write_log_from_output(cmd, file_name)

    return True


def get_config(config_file='config.yaml', file_url='https://raw.githubusercontent.com/anchore/anchore-engine/master/scripts/docker-compose/config.yaml'):
    file_path = '/config/' + config_file
    if not os.path.exists('/config'):
        os.makedirs('/config')

    r = requests.get(file_url, stream=True)
    if r.status_code == 200:
        with open(file_path, 'w') as file:
            file.write(r.content)
    else:
        raise Exception ('Failed to download config file {} - response httpcode={} data={}'.format(file_url, r.status_code, r.text))

    return True


def get_image_info(img_digest, engine_url='http://localhost:8228/v1'):
    url = '{}/images/{}'.format(engine_url, img_digest)
    r = requests.get(url, auth=('admin', 'foobar'), verify=False, timeout=20)

    if r.status_code == 200:
        img_info = json.loads(r.text)[0]
        return img_info

    else:
        raise Exception ("Bad response from Anchore Engine - httpcode={} data={}".format(r.status_code, r.text))


def is_engine_running():
    cmd = 'ps aux'.split()
    output = subprocess.check_output(cmd)

    if 'anchore-manager' in output or 'anchore-engine' in output:
        return True
    else:
        return False


def is_image_analyzed(image_digest):
    image_info = get_image_info(image_digest)
    img_status = image_info['analysis_status']
    print ('Analysis status: {}'.format(img_status))
    sys.stdout.flush()

    if img_status == 'analyzed':
        return True
    else:
        return False


def start_anchore_engine():
    if not is_engine_running():
        cmd = 'anchore-manager service start'.split()
        print ('Starting Anchore engine.')
        sys.stdout.flush()
        log_file = open('anchore-engine.log', 'w')

        try:
            subprocess.Popen(cmd, stdout=log_file, stderr=subprocess.STDOUT)

        except Exception as error:
            raise Exception ('Unable to start Anchore engine. Exception: {}'.format(error))

        return True
    else:
        raise Exception ('Anchore engine is already running.')


def verify_anchore_engine_available(user='admin', pw='foobar', timeout=300, health_url="http://localhost:8228/health", test_url="http://localhost:8228/v1/system/feeds"):
    done = False
    start_ts = time.time()
    while not done:
        try:
            r = requests.get(health_url, verify=False, timeout=10)
            if r.status_code == 200:
                done = True
            else:
                print ("Anchore engine not up yet - response httpcode={} data={}".format(r.status_code, r.text))
                sys.stdout.flush()
        except Exception as err:
            print ("Anchore engine not up yet - exception: {}".format(err))
            sys.stdout.flush()
        time.sleep(5)
        if time.time() - start_ts >= timeout:
            raise Exception("Timed out after {} seconds".format(timeout))

    done=False
    while not done:
        try:
            r = requests.get(test_url, auth=(user, pw), verify=False, timeout=10)
            if r.status_code == 200:
                done = True
            else:
                print ("Anchore engine not up yet - response httpcode={} data={}".format(r.status_code, r.text))
                sys.stdout.flush()
        except Exception as err:
            print ("Anchore engine not up yet - exception: {}".format(err))
            sys.stdout.flush()
        time.sleep(5)
        if time.time() - start_ts >= timeout:
            raise Exception("Timed out after {} seconds".format(timeout))

    return(True)


def write_log_from_output(command, file_name, ignore_exit_code=False):
    try:
        output = subprocess.check_output(command)
        with open(file_name, 'w') as file:
            file.write(output)

    except Exception as error:
        if not ignore_exit_code:
            print ('Failed to generate {}. Exception: {} \n {}'.format(file_name, error, error.output))
            sys.stdout.flush()
            return False
        else:
            with open(file_name, 'w') as file:
                file.write(error.output)

    print ('Successfully generated {}.'.format(file_name))
    sys.stdout.flush()
    return True


### MAIN PROGRAM STARTS HERE ###
def main(analyze_image=None, content_type=None, generate_report=None, image_name=None, report_type=None, setup_engine=None, timeout=None, vuln_type=None):
    if setup_engine:
        get_config()
        start_anchore_engine()
        verify_anchore_engine_available(timeout=timeout)
        print ('Anchore engine is ready!')

    elif image_name:
        if analyze_image:
            add_image_analyze(image_name, timeout)
        if generate_report:
            generate_reports(image_name, content_type, report_type, vuln_type)

    else:
        parser.print_help()
        print ('\n\nError processing command arguments for {}.'.format(sys.argv[0]))
        sys.exit(1)


if __name__ == '__main__':

    content_type_choices = [type for type in ALL_CONTENT_TYPES]
    content_type_choices.append('all')
    report_type_choices = [type for type in ALL_REPORT_COMMANDS.keys()]
    report_type_choices.append('all')
    vuln_type_choices = ALL_VULN_TYPES

    parser = argparse.ArgumentParser(description='A tool that automates various Anchore Engine functions for CI pipelines. Intended to be run directly on the anchore/anchore-engine container.')
    parser.add_argument('-a', '--analyze', action='store_true', help='Specify if you want image to be analyzed by anchore engine.')
    parser.add_argument('-r', '--report', action='store_true', help='Generate reports on analyzed image.')
    parser.add_argument('-s', '--setup', action='store_true', help='Sets up & starts anchore engine on running container.')
    parser.add_argument('--image', help='Specify the image name. REQUIRED for analyze and report options.')
    parser.add_argument('--timeout', default=300, type=int, help='Set custom timeout (in seconds) for image analysis and/or engine setup.')
    parser.add_argument('--content', nargs='+', choices=content_type_choices, default='all', help='Specify what content reports to generate. Can pass multiple options. Ignored if --type content not specified. Available options are: [{}]'.format(', '.join(content_type_choices)), metavar='')
    parser.add_argument('--type', nargs='+', choices=report_type_choices, default='all', help='Specify what report types to generate. Can pass multiple options. Available options are: [{}]'.format(', '.join(report_type_choices)), metavar='')
    parser.add_argument('--vuln', choices=vuln_type_choices, default='all', help='Specify what vulnerability reports to generate. Available options are: [{}] '.format(', '.join(vuln_type_choices)), metavar='')

    args = parser.parse_args()
    analyze_image = args.analyze
    content_type = args.content
    generate_report = args.report
    image_name = args.image
    report_type = args.type
    setup_engine = args.setup
    timeout = args.timeout
    vuln_type = args.vuln

    if len(sys.argv) <= 1 :
        parser.print_help()
        print ("\n\nERROR - Must specify at least one option.")
        sys.exit(1)

    if setup_engine and (image_name or generate_report or analyze_image):
        parser.print_help()
        print ("\n\nERROR - Cannot analyze image or generate reports until engine is setup.")
        sys.exit(1)

    if (generate_report or analyze_image) and not image_name:
        parser.print_help()
        print ("\n\nERROR - Cannot analyze image or generate a report without specifying an image name.")
        sys.exit(1)

    if image_name and not (generate_report or analyze_image):
        parser.print_help()
        print ("\n\nERROR - Must specify an action to perform on image. Plase include --report or --analyze")
        sys.exit(1)

    try:
        main(analyze_image, content_type, generate_report, image_name, report_type, setup_engine, timeout, vuln_type)

    except Exception as error:
        print ('\n\nERROR executing script - Exception: {}'.format(error))
        sys.exit(1)
