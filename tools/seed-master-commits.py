#!/usr/bin/env python3

import sys
import subprocess
import argparse
import requests


def get_linear_commits(repo_path):
    """
    Returns the most recent sequence of commits
    that have a linear ancestry, ordered from oldest to newest
    """
    command_args = [
        "git",
        "rev-list",
        "--parents",
        "origin/master",
    ]

    command_string = " ".join(command_args)
    print("Command:", command_string)
    output = subprocess.check_output(command_args, cwd=repo_path)

    linear_commits = []
    for line in output.decode('utf-8').splitlines():
        stripped = line.strip()
        splitted = stripped.split()
        if len(splitted) > 2:
            print("First merge commit: " + str(splitted))
            break
        else:
            linear_commits.append(splitted[0])

    return list(reversed(linear_commits))


def upload_commits(auth_token, commits):
    url = 'http://localhost:3001/api/populate-master-commits'

    headers_dict = {
        'content-type': 'application/json',
        'token': auth_token,
    }

    r = requests.post(url, verify=False, json=commits, headers=headers_dict)
    print(r.json())
    print(r.status_code)


def parse_args():
    parser = argparse.ArgumentParser(description='Fetch master commits')
    parser.add_argument('--repo-path', dest='repo_path', required=True, help='PyTorch repo path')
    parser.add_argument('--token', dest='token', required=True, help='GitHub auth token')

    return parser.parse_args()


if __name__ == "__main__":

    options = parse_args()
    linear_commits = get_linear_commits(options.repo_path)
    print("Count:", len(linear_commits))

    upload_commits(options.token, linear_commits)
