#!/usr/bin/python3

import csv
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

#
# Functions
#

def determinePage(doi):

    # Find page for a given suffix

    if len(doi) == 7:
        page = doi[:4] + '000'
    elif len(doi) == 8:
        page = doi[:5] + '000'
    else:
        sys.stderr.write('ERROR: unknown doi length: ' + doi + '\n')
        sys.exit(1)

    return page


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


def formatLine(line):

    # Create a table row from the line
    # line is:
    # prefix, crossref registrant, wikipedia registrant, crossref target, wikipedia target

    result = '{{JCW-DOI-prefix'
    result += '|' + line[0]

    # Crossref registrant

    if line[1] == 'NONE':
        result += '|-'
    else:
        result += '|' + line[1]

    # Wikipedia registrant

    if line[2] == 'NONE':
        result += '|-'
    else:
        result += '|' + line[2]

    # Target

    if line[3] == 'NONE' and line[4] == 'NONE':
        result += '|-'
    elif line[3] == 'NONE':
        result += '|' + line[4]
    elif line[4] == 'NONE':
        result += '|' + line[3]
    elif line[3] != line[4]:
        result += '|4=Crossref = [[' + line[3] + ']]<br/>'
        result += 'Wikipedia = [[' + line[4] + ']]'
    else:
        result += '|' + line[3]

    result += '}}\n'

    return result


def isValid(line):

    # check line is not all NONE

    if (    line[1] == 'NONE'
        and line[2] == 'NONE'
        and line[3] == 'NONE'
        and line[4] == 'NONE'
    ):
        return False

    return True


def savePage(site, doi, content):

    # save content to wikipedia page

    page = 'User:JL-Bot/DOI/' + doi

    print('Saving', page, '...')

    text = '{{JCW-DOI-prefix-top}}\n'
    text += content
    text += '{{JCW-DOI-prefix-bottom}}\n'

    page = site.pages[page]
    page.save(text, 'DOI prefix registrant listing')

    return


def saveSummary(site, listing):

    # save a summary page listing all subpages

    page = 'User:JL-Bot/DOI'

    print('Saving', page, '...')

    text = 'These pages are listing of Crossref registrants:\n'
    for doi in listing:
        text += '* [[User:JL-Bot/DOI/' + doi + '|' + doi + ']]\n'

    page = site.pages[page]
    page.save(text, 'DOI prefix registrant listing')

    return

#
# Main
#

# initiate bot

userinfo = getUserInfo(BOTINFO)

try:
    site = Site('en.wikipedia.org')
    site.login(userinfo['username'], userinfo['password'])
except Exception:
    traceback.print_exc()
    sys.exit(1)

# iterate through input file

files = glob.glob(os.environ['WIKI_WORKING_DIR'] + '/Dois/doi-registrants-*')
filename = files[-1]

print('FILE =', filename)

current = '10.1000'
output = ''
pages = []

try:
    with open(filename, 'r') as file:
        lines = csv.reader(file, delimiter='\t')
        for line in lines:
            if isValid(line):
                page = determinePage(line[0])
                if page != current:
                    savePage(site, current, output)
                    pages.append(current)
                    current = page
                    output = ''
                output += formatLine(line)

    pages.append(current)
    savePage(site, current, output)
    saveSummary(site, pages)

except Exception:
    traceback.print_exc()
    sys.exit(1)
