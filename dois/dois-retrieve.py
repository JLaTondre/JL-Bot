#!/usr/bin/python3

import getopt
import glob
import os
import re
import requests
import sys
import time
import traceback

from datetime import date
from itertools import chain
from mwclient import Site
from tqdm import tqdm

#
# Configuration
#

if 'WIKI_WORKING_DIR' not in os.environ:
    sys.stderr.write('ERROR: WIKI_WORKING_DIR environment variable not set\n')
    sys.exit(1)

if 'WIKI_CONFIG_DIR' not in os.environ:
    sys.stderr.write('ERROR: WIKI_CONFIG_DIR environment variable not set\n')
    sys.exit(1)

API = 'https://api.crossref.org/prefixes/'

BOTINFO = os.environ['WIKI_CONFIG_DIR'] + '/bot-info.txt'
EMAILINFO = os.environ['WIKI_CONFIG_DIR'] + '/email-info.txt'

#
# Functions
#

def findTarget(text):

    # Find the target of a redirect

    match = re.search(r'^\s*#redirect\s*:?\s*\[\[\s*:?\s*(.+?)\s*(?:\]|(?<!&)#|\n|\|)', text, re.IGNORECASE)
    if match:
        target = match.group(1)
    else:
        target = 'NONE'

    return target


def getEmail(filename):

    # Read in email address

    email = ''

    try:
        with open(filename, 'r') as file:
            for line in file:
                match = re.search(r'^EMAIL = (.+?)\s*$', line)
                if match:
                    email = match.group(1)

        if not email:
            sys.stderr.write('ERROR: email not found\n')
            sys.exit(1)

    except Exception:
        traceback.print_exc()
        sys.exit(1)

    return email


def getStart(filename):

    try:
        with open(filename) as file:
            lastLine = list(file)[-1]
            match = re.search(r'10\.(\d+)\t', lastLine)
            if match:
                prefix = int(match.group(1)) + 1
            else:
                sys.stderr.write('ERROR: prefix not found\n')
                sys.exit(1)

    except Exception:
        traceback.print_exc()
        sys.exit(1)

    return prefix


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


def isValidTitle(title):

    # Does some simple tests to check if valid Wikipedia title

    # check interwiki title
    match = re.search(r'^\w{2}:', crossref, re.IGNORECASE)
    if match:
        return False

    # check invalid characters
    match = re.search(r'[#<>\[\]\|{}_\/]', crossref)
    if match:
        return False

    return True


def queryCrossref(doi, api, email):

    # Retrieve registrant name from Crossref

    try:
        r = requests.get(api + doi + '?mailto=' + email)
    except requests.exceptions.RequestException as e:
        sys.stderr.write('\nERROR: unable to retrieve ' + doi + '\n' + str(e) + '\n')
        sys.exit(1)
    else:

        if r.headers['X-Rate-Limit-Interval'] != '1s':
            print('WARNING: X-Rate-Limit-Interval changed. It is now', r.headers['X-Rate-Limit-Interval'])

        if r.status_code == 404:
            return 'NONE'

        if r.status_code != 200:
            sys.stderr.write('ERROR: Unexpected status code.\n')
            sys.stderr.write('DOI  = ' + str(doi) + '\n')
            sys.stderr.write('Code = ' + str(r.status_code) + '\n')
            sys.exit(1)

        name = r.json()['message']['name']
        prefix = r.json()['message']['prefix']

        if prefix != 'http://id.crossref.org/prefix/' + doi:
            sys.stderr.write('ERROR: requested ' + doi + '\nreceived ' + prefix + '\n')
            sys.exit(1)

        if not name:
            sys.stderr.write('ERROR: name not found for ' + doi + '\n' + r.text + '\n')
            sys.exit(1)

        return name


def queryWikipediaCrossref(title, site):

    # Retrieve target of Crossref name (if redirect)

    if title == 'NONE':
        return 'NONE'

    page = site.pages[title]

    if not page.exists:
        return 'NONE'

    target = findTarget(page.text())

    return target


def queryWikipediaDOI(prefix, site):

    # Retrieve registrant & target from Wikipedia

    page = site.pages[prefix]

    if not page.exists:
        return ('NONE', 'NONE')

    # extract redirect

    target = findTarget(page.text())

    # extract registrant

    match = re.search(r'{{\s*(?:Template\s*:\s*)?(?:R[ _]+from[ _]+DOI[ _]+prefix|R[ _]+from[ _]+DOI)\s*\|\s*registrant\s*=\s*(.+?)\s*[\|\}]', page.text(), re.IGNORECASE)
    if match:
        registrant = match.group(1)
    else:
        match = re.search('registrant', page.text(), re.IGNORECASE)
        if match:
            sys.stderr.write('ERROR: registrant not detected for ' + prefix + '\n')
            sys.exit(1)
        registrant = 'NONE'

    return (registrant, target)

#
# Main
#

resume = False

try:
    arguments, values = getopt.getopt(sys.argv[1:], 'hr:')
except getopt.error as err:
    print (str(err))
    sys.exit(2)

for argument, value in arguments:
    if argument == '-h':
        print('dois-retrieve.py [-h] [-r DATESTAMP')
        print('  where -r = resume file with DATESTAMP')
        sys.exit(0)
    elif argument == '-r':
        resume = value

if resume:
    filename = os.environ['WIKI_WORKING_DIR'] + '/Dois/doi-registrants-' + resume
    option = 'a'
    start = getStart(filename)
else:
    filename = os.environ['WIKI_WORKING_DIR'] + '/Dois/doi-registrants-' + date.today().strftime('%Y%m%d')
    start = 1001
    option = 'w'

# initiate bot

userinfo = getUserInfo(BOTINFO)
email = getEmail(EMAILINFO)

try:
    site = Site('en.wikipedia.org')
    site.login(userinfo['username'], userinfo['password'])
except Exception:
    traceback.print_exc()
    sys.exit(1)

# open file and iterate through prefixes

file = open(filename, option, 1)

for suffix in tqdm(range(start, 40000), leave=False):
    start = time.time()
    prefix = '10.' + str(suffix)
    crossref = queryCrossref(prefix, API, email)
    if isValidTitle(crossref):
        target = queryWikipediaCrossref(crossref, site)
        wikipedia = queryWikipediaDOI(prefix, site)
        end = time.time()
        delta = end - start
        if delta < 1:
            time.sleep(1 - delta)
        file.write('\t'.join((prefix, crossref, wikipedia[0], target, wikipedia[1])) + '\n')
    else:
        file.write('\t'.join((prefix, crossref, 'NONE', 'INVALID', 'NONE')) + '\n')

file.close()

# output is:
# prefix, crossref registrant, wikipedia registrant, crossref target, wikipedia target