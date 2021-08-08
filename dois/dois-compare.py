#!/usr/bin/python3

import calendar
import csv
import getopt
import glob
import os
import re
import sys
import traceback

from mwclient import Site

#
# Configuration
#

if 'WIKI_WORKING_DIR' not in os.environ:
    sys.stderr.write('ERROR: WIKI_WORKING_DIR environment variable not set\n')
    sys.exit(1)

if 'WIKI_CONFIG_DIR' not in os.environ:
    sys.stderr.write('ERROR: WIKI_CONFIG_DIR environment variable not set\n')
    sys.exit(1)

BOTINFO = os.environ['WIKI_CONFIG_DIR'] + '/bot-info.txt'
PAGE = 'User:JL-Bot/DOI/Deltas'

#
# Functions
#

def extractDate(filename):

    # Extract the date from the file name

    match = re.search(r'^.*doi-registrants-(\d{4})(\d{2})(\d{2})$', filename)
    if match:
        year = match.group(1)
        month = calendar.month_abbr[int(match.group(2))]
        day = match.group(3)
        date = day + ' ' + month + ' ' + year
    else:
        sys.exit('ERROR: Could not parse date from ' + filename)

    return date


def getUserInfo(filename):

    # Read in bot userinfo

    userinfo = {}

    try:
        with open(filename, 'r') as file:
            for line in file:
                match = re.search(r'^USERNAME = (.+?)\s*$', line)
                if match:
                    userinfo['username'] = match.group(1)
                match = re.search(r'^PASSWORD = (.+?)\s*$', line)
                if match:
                    userinfo['password'] = match.group(1)

        if 'username' not in userinfo:
            sys.stderr.write('ERROR: username not found\n')
            sys.exit(1)

        if 'password' not in userinfo:
            sys.stderr.write('ERROR: password not found\n')
            sys.exit(1)

    except Exception:
        traceback.print_exc()
        sys.exit(1)

    return userinfo

#
# Main
#

output = False

try:
    arguments, values = getopt.getopt(sys.argv[1:], 'hp')
except getopt.error as err:
    print(str(err))
    sys.exit(2)

for argument, value in arguments:
    if argument == '-h':
        print('dois-compare.py [-hp]')
        print('  where -p = print result (instead of saving to Wikipedia)')
        sys.exit(0)
    elif argument == '-p':
        output = True

# find lastest two files

files = glob.glob(os.environ['WIKI_WORKING_DIR'] + '/Dois/doi-registrants-*')

currentFile = sorted(files)[-1]
priorFile = sorted(files)[-2]

print('Comparing', os.path.basename(currentFile), 'with', os.path.basename(priorFile), '...')

# iterate through files

previous = {}
current = {}

try:
    with open(priorFile, 'r') as file:
        lines = csv.reader(file, delimiter='\t')
        for line in lines:
            previous[line[0]] = line[1]

    with open(currentFile, 'r') as file:
        lines = csv.reader(file, delimiter='\t')
        for line in lines:
            current[line[0]] = line[1]

except Exception:
    traceback.print_exc()
    sys.exit(1)

# compare the two

results = []

for prefix in current:
    if prefix not in previous:
        if current[prefix] != 'NONE':
            results.append('| [[' + prefix + ']] || NONE || [[' + current[prefix] + ']]')
    elif current[prefix] != previous[prefix]:
        if previous[prefix] == 'NONE':
            results.append('| [[' + prefix + ']] || NONE || [[' + current[prefix] + ']]')
        else:
            results.append('| [[' + prefix + ']] || [[' + previous[prefix] + ']] || [[' + current[prefix] + ']]')

for prefix in previous:
    if prefix not in current:
        results.append('| [[' + prefix + ']] || [[' + previous[prefix] + ']] || NONE ([https://api.crossref.org/prefixes/' + prefix + ' validate]) ')

# output results

if output:
    print('\n\n'.join(results))
else:

    # initiate bot

    userinfo = getUserInfo(BOTINFO)

    try:
        site = Site('en.wikipedia.org')
        site.login(userinfo['username'], userinfo['password'])
    except Exception:
        traceback.print_exc()
        sys.exit(1)

    currentDate = extractDate(currentFile)
    priorDate = extractDate(priorFile)

    output = 'This page list differences in the CrossRef registrants between the prior and current results:\n'
    output += '{| class="wikitable sortable"\n|-\n'
    output += '! DOI !! Prior (' + priorDate + ') || Current (' + currentDate + ')\n|-\n'
    output += '\n|-\n'.join(results)
    output += '\n|}'

    print('Saving', PAGE, '...')
    page = site.pages[PAGE]
    page.save(output, 'DOI prefix registrant comparison')