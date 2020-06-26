# JL-Bot

This repository contains the source code for:
https://en.wikipedia.org/wiki/User:JL-Bot

The bot is primarily implemented using Perl, but some new tasks use Python.

The repository contains all of the custom code associated with the bot. The scripts utilize a number of standard packages, but all of these can be found via normal package managers. The Citations tasks also requires sqlite3.

The scripts require two configuration variables to be set:
* WIKI_CONFIG_DIR = location of configuration files
* WIKI_WORKING_DIR = location of where results are to be output

There are two configuration files required:
* bot-info.txt = Wikipedia login information for the bot. The format is seperate `<keyword> = <value>` lines with the keywords being USERNAME and PASSWORD.
* email-info.txt = Email address required for the crossref.org API. The format is seperate `<keyword> = <value>` line with the keyword being EMAIL.
