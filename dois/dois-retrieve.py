#!/usr/bin/python3

from enum import unique
import os
import re
import requests
import sys
import time
import traceback

from collections import defaultdict
from datetime import date
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

APIMEMBERS = 'https://api.crossref.org/members/'
APIPREFIXES = 'https://api.crossref.org/prefixes/'
BLOCKSIZE = 500             # API supports 1000, but fails to return all results at that size

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


def isValidPrefix(prefix, registrant):

    # Ignore invalid (test) prefixes returned by Crossref members API

    if not re.search(r'^10.\d{4,5}$', prefix):
        return False

    if re.search(r'^10.[89]\d{4}$', prefix):
        return False

    if (
        registrant == 'Derg Test Account' or
        registrant == 'Service Provider test account' or
        registrant == 'Test accounts'
    ):
        return False

    return True


def isValidTitle(title):

    # Does some simple tests to check if valid Wikipedia title

    # check interwiki title
    if re.search(r'^\w{2}:', title, re.IGNORECASE):
        return False

    # check invalid characters
    if re.search(r'[#<>\[\]\|{}_\/]', title):
        return False

    return True


def queryCrossref(email, apiMembers, apiPrefixes, blocksize):

    # Retrieve registrant names from Crossref by first calling the members API
    # and then using the prefixes API to resolve any ambiguities

    print('Retrieving Crossref members ...')

    members = queryCrossrefMembers(email, apiMembers, blocksize)

    print('Resolving Crossref ambiguities ...')

    results = {}

    start = 0
    for prefix in tqdm(members, leave=None):
        unique = set(members[prefix])
        if len(unique) > 1:
            end = time.time()
            delta = end - start
            if delta < 1:
                time.sleep(1 - delta)
            registrant = queryCrossrefPrefixes(prefix, email, apiPrefixes)
            start = time.time()
        else:
            registrant = members[prefix][0]

        if isValidPrefix(prefix, registrant):
            order = prefix.replace('10.', '')
            results[order] = (prefix, registrant)

    return results


def queryCrossrefMembers(email, api, blocksize):

    # Retrieve registrant names from Crossref via the members API

    results = defaultdict(list)

    offset = 0
    total = 1

    while offset < total:

        start = time.time()

        url = api + '?rows=1000&offset=' + str(offset) + '&mailto=' + email

        try:
            r = requests.get(url)
        except requests.exceptions.RequestException as e:
            sys.stderr.write('ERROR: Unable to retrieve URL.\n')
            sys.stderr.write('URL = ' + url + '\n')
            sys.stderr.write('Exception = ' + str(e) + '\n')
            sys.exit(1)
        else:

            if r.headers['X-Rate-Limit-Interval'] != '1s':
                print('WARNING: X-Rate-Limit-Interval changed. It is now', r.headers['X-Rate-Limit-Interval'])

            if r.status_code == 404:
                sys.stderr.write('ERROR: 404 status code')
                sys.stderr.write('URL = ' + url + '\n')
                sys.exit(1)

            if r.status_code != 200:
                sys.stderr.write('ERROR: Unexpected status code.\n')
                sys.stderr.write('URL  = ' + url + '\n')
                sys.stderr.write('Code = ' + str(r.status_code) + '\n')
                sys.exit(1)

            total = r.json()['message']['total-results']

            for item in r.json()['message']['items']:
                name = item['primary-name']
                prefixes = item['prefixes']
                for prefix in prefixes:
                    results[prefix].append(name)

            end = time.time()
            delta = end - start
            if delta < 1:
                time.sleep(1 - delta)

            offset += blocksize

    return results


def queryCrossrefPrefixes(doi, email, api):

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

        if prefix != 'https://id.crossref.org/prefix/' + doi:
            sys.stderr.write('ERROR: requested ' + doi + '\nreceived ' + prefix + '\n')
            sys.exit(1)

        if not name:
            sys.stderr.write('ERROR: name not found for ' + doi + '\n' + r.text + '\n')
            sys.exit(1)

        return name


def queryWikipediaCrossref(title, site):

    # Retrieve target of Crossref name (if redirect)

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

userinfo = getUserInfo(BOTINFO)
email = getEmail(EMAILINFO)

try:
    site = Site('en.wikipedia.org')
    site.login(userinfo['username'], userinfo['password'])
except Exception:
    traceback.print_exc()
    sys.exit(1)

crossref = queryCrossref(email, APIMEMBERS, APIPREFIXES, BLOCKSIZE)

filename = os.environ['WIKI_WORKING_DIR'] + '/Dois/doi-registrants-' + date.today().strftime('%Y%m%d')
file = open(filename, 'w', 1)

print('Retrieving Wikipedia data ...')

for order in tqdm(sorted(crossref, key=int), leave=None):

    prefix = crossref[order][0]
    registrant = crossref[order][1]

    if isValidTitle(registrant):
        target = queryWikipediaCrossref(registrant, site)
        wikipedia = queryWikipediaDOI(prefix, site)
        file.write('\t'.join((prefix, registrant, wikipedia[0], target, wikipedia[1])) + '\n')
    else:
        file.write('\t'.join((prefix, registrant, 'NONE', 'INVALID', 'NONE')) + '\n')

file.close()

# output is:
# prefix, crossref registrant, wikipedia registrant, crossref target, wikipedia target