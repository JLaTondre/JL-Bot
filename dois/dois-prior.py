#!/usr/bin/python3

# This 'recreates' the prior version from the Wikipedia pages incase file lost

import csv
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

STORAGE = os.environ['WIKI_WORKING_DIR'] + '/Dois/doi-registrants-prior'
BOTINFO = os.environ['WIKI_CONFIG_DIR'] + '/bot-info.txt'

#
# Functions
#

def extractRecords(contents):

    # extract the doi information from the page contents
    # prefix, crossref registrant, wikipedia registrant, crossref target, wikipedia target

    records = []

    for line in contents.splitlines():

        prefix = ''
        crossrefRegistrant = ''
        wikipediaRegistrant = ''
        crossrefTarget = ''
        wikipediaTarget = ''

        # two possible patterns

        match = re.search(r'^{{JCW-DOI-prefix\|(.+?)\|(.+?)\|(.+?)\|4=Crossref = \[\[(.+?)\]\]<br/>Wikipedia = \[\[(.+?)\]\]', line)
        if match:
            prefix = match.group(1)
            crossrefRegistrant = match.group(2)
            wikipediaRegistrant = match.group(3)
            crossrefTarget = match.group(4)
            wikipediaTarget = match.group(5)
        else:
            match = re.search(r'^{{JCW-DOI-prefix\|(.+?)\|(.+?)\|(.+?)\|(.+?)}}', line)
            if match:
                prefix = match.group(1)
                crossrefRegistrant = match.group(2)
                wikipediaRegistrant = match.group(3)
                crossrefTarget = 'NONE'
                wikipediaTarget = match.group(4)

        # if either pattern found

        if (prefix):

            if crossrefRegistrant == '-':
                crossrefRegistrant = 'NONE'

            if wikipediaRegistrant == '-':
                wikipediaRegistrant = 'NONE'

            if crossrefTarget == '-':
                crossrefTarget = 'NONE'

            if wikipediaTarget == '-':
                wikipediaTarget = 'NONE'

            if crossrefTarget.startswith(':'):
                crossrefTarget = crossrefTarget[1:]

            if wikipediaTarget.startswith(':'):
                wikipediaTarget = wikipediaTarget[1:]

            records.append((prefix, crossrefRegistrant, wikipediaRegistrant, crossrefTarget, wikipediaTarget))

    return records


def getPages(site):

    # find pages from summary page

    title = 'User:JL-Bot/DOI'
    page = site.pages[title]

    pages = []

    for line in page.text().splitlines():
        match = re.search(r'^\* \[\[User:JL-Bot/DOI/\d+.\d+\|(\d+.\d+)\]\]$', line)
        if match:
            pages.append(match.group(1))

    return pages


def getUserInfo(filename):

    # read in bot userinfo

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


def retrievePage(doi):

    # retrieve contents of Wikipedia page

    title = 'User:JL-Bot/DOI/' + doi
    page = site.pages[title]

    return page.text()


def writeRecords(file, records):

    # write the records to output file

    for record in records:
        file.write('\t'.join(record) + '\n')

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

# find pages and iterate through them

pages = getPages(site)

try:
    file = open(STORAGE, 'w')
    for page in pages:
        print('Precessing', page, '...')
        contents = retrievePage(page)
        records = extractRecords(contents)
        writeRecords(file, records)

except Exception:
    traceback.print_exc()
    sys.exit(1)
