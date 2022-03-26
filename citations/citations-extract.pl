#!/usr/bin/perl

# This script extracts the citations and dois from the parsed templates and
# generates the normalizations.

use warnings;
use strict;

use Benchmark;
use File::Basename;
use File::ReadBackwards;
use HTML::Entities;
use POSIX;

use lib dirname(__FILE__) . '/../modules';

use citations qw( findTemplates normalizeCitation );
use citationsDB;

use utf8;

#
# Validate Environment Variables
#

unless (exists $ENV{'WIKI_WORKING_DIR'}) {
    die "ERROR: WIKI_WORKING_DIR environment variable not set\n";
}

#
# Configuration & Globals
#

my $DBTITLES    = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-titles.sqlite3';
my $DBCITATIONS = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-citations.sqlite3';
my $CTEMPLATES  = $ENV{'WIKI_WORKING_DIR'} . '/Citations/templates-citation';
my $DTEMPLATES  = $ENV{'WIKI_WORKING_DIR'} . '/Citations/templates-doi';

my @TABLES = (
    'CREATE TABLE citations(type TEXT, citation TEXT, article TEXT, count INTEGER)',
    'CREATE TABLE normalizations(type TEXT, citation TEXT, normalization TEXT, length INTEGER)',
    'CREATE TABLE dois(type TEXT, prefix TEXT, entire TEXT, citation TEXT, article TEXT, count INTEGER)',
);

my @INDEXES = (
    'CREATE INDEX indexCType ON citations(type)',
    'CREATE INDEX indexCitation ON citations(citation)',
    'CREATE INDEX indexNType ON normalizations(type)',
    'CREATE INDEX indexNCitation ON normalizations(citation)',
    'CREATE INDEX indexNormalization ON normalizations(normalization)',
    'CREATE INDEX indexLength ON normalizations(length)',
    'CREATE INDEX indexDType ON dois(type)',
    'CREATE INDEX indexPrefix ON dois(prefix)',
);

my $DOIDIRECTORY = $ENV{'WIKI_WORKING_DIR'} . '/Dois';

#
# Subroutines
#

sub extractDoiField {

    # Extract the doi field from a citation template.

    my $citation = shift;
    my $doiLimit = shift;

    $citation =~ s/<!--(?:(?!<!--).)*?-->//sg;               # remove comments

    # should only be one |doi= field but match last (by using .* at start) in
    # case there is more than one (since that is the one displayed)

    if ($citation =~ /.*\|\s*doi\s*=\s*(?:\(\(\s*)?(.*?)(?:\s*\)\))?\s*(?=\||\}\}$)/ig) {
        return validateDoi($1, $doiLimit);
    }

    return;
}

sub extractDoiTemplate {

    # Extract the doi field from a doi template.

    my $template = shift;
    my $doiLimit = shift;

    $template =~ s/<!--(?:(?!<!--).)*?-->//sg;               # remove comments

    if ($template =~ /^\{\{\s*(?:Template:)?\s*doi(-inline)?[\s\|]*\}\}$/i) {
        # easiest way to handle template with no parameters: {{doi|}}
        return;
    }
    elsif ($template =~ /^\{\{\s*(?:Template:)?\s*doi\s*\|\s*(.*?)\s*\}\}$/i) {
        # {{doi|number}}
        my $result = validateDoi($1, $doiLimit);
        $result->{'citation'} = 'NONE';
        return $result;
    }
    elsif ($template =~ /^\{\{\s*(?:Template:)?\s*doi-inline\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\}\}$/i) {
        # {{doi-inline|number|journal}}
        my $result = validateDoi($1, $doiLimit);
        my $citation = $2;

        $citation =~ s/&nbsp;\d.*$//;                       # remove trailing &nbsp;25.19 (1998): 3701-3704
        $citation =~ s/^\s*\((.*?)\)$/$1/;                  # remove parenthesis
        $citation =~ s/^\s*'{1,5}(.*?)'{1,5}$/$1/;          # remove single quotes, italics, and bold
        $citation =~ s/^\s*[\"“](.*?)[\"”]$/$1/g;           # remove quotes (regular & irregular)

        $result->{'citation'} = $citation;
        return $result;
    }
    elsif ($template =~ /^\{\{\s*(?:Template:)?\s*doi-inline\s*\|\s*(.*?)\s*\}\}$/i) {
        # {{doi-inline|number}}
        my $result = validateDoi($1, $doiLimit);
        $result->{'citation'} = 'NONE';
        return $result;
    }
    else {
        die "\n\nERROR: Could not parse template!\n$template\n\n";
    }

    return;
}

sub extractField {

    # Extract the journal|magazine field from a citation template.

    my $citation = shift;

    $citation =~ s/<!--(?:(?!<!--).)*?-->//sg;               # remove comments

    $citation =~ s/_/ /g;                                    # ensure spaces (wiki syntax)
    $citation =~ s/&nbsp;/ /g;                               # ensure spaces (non-breaking)
    $citation =~ s/\xA0/ /g;                                 # ensure spaces (non-breaking)
    $citation =~ s/<br\s*\/?>/ /g;                           # ensure spaces (breaks)
    $citation =~ s/\t/ /g;                                   # ensure spaces (tabs)
    $citation =~ s/\s{2,}/ /g;                               # ensure only single space

    $citation =~ s/\[\[[^\|\]]+\|\s*([^\]]+)\s*\]\]/$1/g;                   # remove link from [[link|text]]
    $citation =~ s/\[\[[^\|\]]+\|\s*([^\[\]]*\[[^\]]+\][^\]]*)\s*\]\]/$1/g; # remove link from [[link|text [text] text]]
    $citation =~ s/\[\[[^\{\]]*\s*\{\{\s*!\s*\}\}\s*([^\]]+)\]\]/$1/g;      # remove link from [[link{{!}}text]]
    $citation =~ s/\[\[\s*([^\]]+)\s*\]\]/$1/g;                             # remove link from [[text]]

    $citation =~ s/\{\{\s*subst:/{{/g;                       # remove subst:

    $citation = removeTemplates($citation);

    my $results;

    while ($citation =~ /\|\s*(journal|magazine)\s*=\s*(.*?)\s*(?=\||\}\}$)/ig) {

        my $type  = lcfirst $1;
        my $field = $2;

        $field =~ s/\{\{\s*!\s*\}\}/|/ig;                     # replace {{!}} - while template, needs to be after field extraction
        $field =~ s/\{\{\s*pipe\s*\}\}/\|/ig;                 # replace {{pipe}}

        $field =~ s/<html_ent glyph="\@amp;" ascii="&amp;"\/>/&/ig;  # replace <html_ent glyph="@amp;" ascii="&amp;"/>

        $field =~ s/\[\s*https?:[^\s\]]+\]//g;                # remove [http://link]
        $field =~ s/\[\s*https?:[^\s]+\s+([^\]]+)\]/$1/g;     # remove link from [http://link text]

        $field =~ s/<abbr\s.*?>(.*?)<\/abbr\s*>/$1/ig;        # remove <abbr ...>text</abbr>
        $field =~ s/<span\s.*?>(.*?)<\/span\s*>/$1/ig;        # remove <span ...>text</span>

        $field =~ s/<cite id=["'][^"']+["']\s*>\s*(.*?)\s*<\/cite\s*>/$1/ig;  # remove <cite id="id">text</cite>

        $field =~ s/^\s*''(.*)''\s'''(.*)'''\s*$/$1 $2/g;     # handle special case ''text'' '''text'''

        $field =~ s/<sup>\s*([^\<]+)?\s*<\/sup>/$1/g;         # remove <sub>text</sub>
        $field =~ s/<small>\s*([^\<]+)?\s*<\/small>/$1/g;     # remove <small>text</small>

        $field =~ s/<nowiki>\s*([^\<]+)\s*<\/nowiki>/$1/g;    # remove <nowiki>text</nowiki>

        $field = decode_entities($field);                     # decode HTML entities (&amp; etc)

        $field =~ s/^\s*'{1,5}(.*?)'{1,5}$/$1/g;              # remove single quotes, italics, and bold
        $field =~ s/^\s*[\"“](.*?)[\"”]$/$1/g;                # remove quotes (regular & irregular)

        $field =~ s/\s*\(\)//g;                               # remove ()

        $field =~ s/\s+'+$//;                                 # remove '' at end

        $field =~ s/^\s+//;                                   # remove space at start
        $field =~ s/\s+$//;                                   # remove space at end

        $field =~ s/^:\s*//;                                  # remove : at start

        # skip if results in nothing (ex. comment only)

        next if ($field =~ /^\s*$/);
        next if ($field =~ /^\s*\.\s*$/);

        $results->{$type} = $field;
    }

    return $results;
}

sub findDoiLimit {

    # Find the maximum DOI number for invalid testing

    print "  find DOI limit ...\n";

    my $directory = shift;

    my @files = glob($directory . '/doi-registrants-*');
    my $latest = (reverse sort @files)[0];

    my $file = File::ReadBackwards->new($latest)
        or die "ERROR: Unable to open DOI file ($latest)\n --> $!\n\n";

    my $line = $file->readline;

    if ($line =~ /^(10.\d+).*$/) {
        my $prefix = $1;
        # cannot simply use ceil as want 10.55000 to also go to 10.56000
        $prefix = $prefix * 100;
        $prefix = $prefix + 1;
        $prefix = floor($prefix);
        $prefix = $prefix / 100;
        return $prefix;
    }

    die "ERROR: Did not find a DOI prefix in $latest\n\n";
}

sub queryDisambiguatedTitles {

    # Return all 'title (journal)' or 'title (magazine)' articles

    print "  loading disambiguated titles ...\n";

    my $dbTitles = shift;

    my $database = citationsDB->new;
    $database->openDatabase($dbTitles);

    my $sth = $database->prepare(q{
        SELECT title, target FROM titles
        WHERE (
            title LIKE '% (journal)'
            OR title LIKE '% (magazine)'
        )
        AND pageType != 'REDIRECT-UNNECESSARY'
    });
    $sth->execute();

    my $titles;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $title = $ref->{'title'};
        my $target = $ref->{'target'};
        # skip redirects that point back to original
        unless ($title =~ /^\Q$target\E \((?:journal|magazine)\)/) {
            $titles->{$title} = 1;
        }
    }

    $database->disconnect;

    return $titles;
}

sub removeTemplates {

    # Remove templates from within a citation.

    my $citation = shift;

    my $templates = findTemplates($citation);

    for my $template (@$templates) {
        next if ($template eq $citation);                               # don't process whole thing

        my $start = $template;

        # several of these could be collapsed (conditional, or) but are left separate for simplicity | readability

        $template =~ s/\{\{\s*URL\s*\|[^\|]+\|\s*(.+?)\s*\}\}/$1/g;     # remove link from {{URL|link|text}}

        $template =~ s/\s*\{\{\s*dead link\s*(?:\|.*?)?\}\}//ig;        # remove {{dead link|date=...}}
        $template =~ s/\s*\{\{\s*cbignore\s*(?:\|.*?)?\}\}//ig;         # remove {{cbignore|bot=...|}}

        $template =~ s/\{\{\s*abbr\s*\|([^\}\|]+)\|.*?\}\}/$1/ig;       # remove {{abbr|text|...}}
        $template =~ s/\{\{\s*sup\s*\|([^\}]+)\}\}/$1/ig;               # remove {{sup|text}}
        $template =~ s/\{\{\s*title case\s*\|([^\}]+)\}\}/$1/ig;        # remove {{title case|text}}

        $template =~ s/\{\{\s*req\s*\|([^\}]+)\}\}/$1/ig;               # remove {{req|text}}

        $template =~ s/\{\{\s*not a typo\s*\|([^\|]+)\|([^\}]+)\}\}/$1 $2/ig;  # remove {{not a typo|text|text}}
        $template =~ s/\{\{\s*not a typo\s*\|([^\}]+)\}\}/$1/ig;               # remove {{not a typo|text}}

        $template =~ s/\s*\{\{\s*sic\s*(?:\|.*?)?\}\}//ig;              # remove {{sic|remove}}

        $template =~ s/\s*\{\{\s*unicode\s*\|([^\}]+)\}\}/$1/ig;        # remove {{unicode|text}}
        $template =~ s/\s*\{\{\s*polytonic\s*\|([^\}]+)\}\}/$1/ig;      # remove {{polytonic|text}}

        $template =~ s/\{\{\s*annotated link\s*\|([^\}\|]+).*?\}\}/$1/ig;;     # remove {{annotated link|text|...}}

        $template =~ s/\{\{\s*asiantitle\s*\|[^\|]*\|[^\|]*\|([^\}\|]+).*?\}\}/$1/ig;  # remove {{asiantitle|no|no|text|...}}
        $template =~ s/\{\{\s*asiantitle\s*\|[^\|]*\|([^\}\|]+).*?\}\}/$1/ig;          # remove {{asiantitle|no|text|...}}
        $template =~ s/\{\{\s*asiantitle\s*\|([^\}\|]+).*?\}\}/$1/ig;                  # remove {{asiantitle|text|...}}

        $template =~ s/\{\{\s*transl\s*\|[^\|]*\|[^\|]*\|([^\}\|]+).*?\}\}/$1/ig;      # remove {{transl|no|no|text|...}}
        $template =~ s/\{\{\s*transl\s*\|[^\|]*\|([^\}\|]+).*?\}\}/$1/ig;              # remove {{transl|no|text|...}}

        $template =~ s/\{\{\s*illm?\s*\|[^\}\|]+\{\{\s*!\s*\}\}\s*([^\}\|]+).*?\}\}/$1/ig;        # remove {{ill|remove{{!}}text|...}}

        $template =~ s/\{\{\s*illm?.*?\|\s*lt\s*=\s*([^\}\|]+).*?\}\}/$1/ig;                            # remove {{ill|...|lt=text|...}}
        $template =~ s/\{\{\s*interlanguage link(?: multi)?.*?\|\s*lt\s*=\s*([^\}\|]+).*?\}\}/$1/ig;    # remove {{interlanguage link|...|lt=text|...}}

        $template =~ s/\{\{\s*illm?\s*\|([^\}\|]+).*?\}\}/$1/ig;                                  # remove {{ill|text|...}}
        $template =~ s/\{\{\s*interlanguage link(?: multi)?\s*\|([^\}\|]+).*?\}\}/$1/ig;          # remove {{interlanguage link|text|...}}
        $template =~ s/\{\{\s*link-interwiki\s*\|(?:[^e\|]*)\s*en\s*=\s*([^\}\|]+).*?\}\}/$1/ig;  # remove {{link-interwiki|en=text|...}}

        $template =~ s/\{\{\s*iw2?\s*\|([^\}\|]+).*?\}\}/$1/ig;         # remove {{iw2|text|...}}

        $template =~ s/\{\{\s*lang\s*\|[^\|]+\|([^\}]+)\}\}/$1/ig;      # remove {{lang|ln|text}}
        $template =~ s/\{\{\s*nihongo\s*\|([^\}\|]+)(?:\|.*?)?\}\}/$1/ig;       # remove {{nihongo|text|...}}
        $template =~ s/\{\{\s*nihongo krt\s*\|([^\}\|]+)(?:\|.*?)?\}\}/$1/ig;   # remove {{nihongo krt|text|...}}
        $template =~ s/\{\{\s*nihongo\s*\|\|([^\\|}]+)\|.*?\}\}/$1/ig;  # remove {{nihongo||text|...}}
        $template =~ s/\{\{\s*zh\s*(?:\|[^\|]*)*\|l=([^\|\}]+)/$1/ig;   # remove {{zh|l=text}}

        # should the text be removed or kept?
        $template =~ s/\s*\{\{\s*lang-el\s*\|[^\}]+\}\}//ig;            # remove {{lang-el|remove}}
        $template =~ s/\s*\{\{\s*lang-en\s*\|[^\}]+\}\}//ig;            # remove {{lang-en|remove}}
        $template =~ s/\s*\{\{\s*lang-fa\s*\|[^\}]+\}\}//ig;            # remove {{lang-fa|remove}}
        $template =~ s/\s*\{\{\s*lang-fr\s*\|[^\}]+\}\}//ig;            # remove {{lang-fr|remove}}
        $template =~ s/\s*\{\{\s*lang-ru\s*\|[^\}]+\}\}//ig;            # remove {{lang-ru|remove}}
        $template =~ s/\s*\{\{\s*nihongo2\s*\|[^\}]+\}\}//ig;           # remove {{nihongo2|remove}}
        $template =~ s/\s*\{\{\s*hebrew\s*\|[^\}]+\}\}//ig;             # remove {{hebrew|remove}}
        $template =~ s/\s*\{\{\s*my\s*\|[^\}]+\}\}//ig;                 # remove {{my|remove}}

        $template =~ s/\s*\{\{\s*in lang\s*\|[^\}]+\}\}//ig;            # remove {{in lang|remove}}

        $template =~ s/\{\{\s*okina\s*\}\}/&#x02BB;/ig;                 # replace {{okina}}
        $template =~ s/\{\{\s*hamza\s*\}\}/&#x02BC;/ig;                 # replace {{hamza}}

        $template =~ s/\{\{\s*pi\s*\}\}/π/ig;                           # replace {{pi}}

        $template =~ s/\{\{\s*Ordinal\s*\|\s*1\s*\}\}/1st/ig;           # replace {{Ordinal|1}}
        $template =~ s/\{\{\s*Ordinal\s*\|\s*2\s*\}\}/2nd/ig;           # replace {{Ordinal|2}}
        $template =~ s/\{\{\s*Ordinal\s*\|\s*3\s*\}\}/3rd/ig;           # replace {{Ordinal|3}}
        $template =~ s/\{\{\s*Ordinal\s*\|\s*([4-9])\s*\}\}/$1th/ig;    # replace {{Ordinal|4}}

        $template =~ s/\s*\{\{\s*dn\s*(?:\|.*?)?\}\}//ig;                     # remove {{dn|date=...}}
        $template =~ s/\s*\{\{\s*disambiguation needed\s*(?:\|.*?)?\}\}//ig;  # remove {{disambiguation needed|date=...}}

        $template =~ s/\s*\{\{\s*specify\s*(?:\|.*?)?\}\}//ig;                # remove {{specify|reason=...}}

        $template =~ s/\s*\{\{\s*clarify\s*(?:\|.*?)?\}\}//ig;                # remove {{clarify|date=...}}
        $template =~ s/\s*\{\{\s*full citation needed\s*(?:\|.*?)?\}\}//ig;   # remove {{full citation needed|date=...}}

        $template =~ s/\s*\{\{\s*date\s*(?:\|.*?)?\}\}//ig;                    # remove {{date|remove}}

        $template =~ s/\{\{\s*ECCC\s*\|.*?\|\s*(\d+)\s*\|\s*(\d+)\s*\}\}/ECCC TR$1-$2/ig;  # remove {{ECCC|no|num|num}}

        $template =~ s/\{\{\s*(?:en |n)dash\s*\}\}/–/ig;                # replace {{en dash}}
        $template =~ s/\{\{\s*spaced (?:en |n)dash\s*\}\}/ – /ig;       # replace {{spaced en dash}}
        $template =~ s/\{\{\s*snd\s*\}\}/ – /ig;                        # replace {{snd}}

        $template =~ s/\{\{\s*nbsp\s*\}\}/ /ig;                         # replace {{nbsp}}

        $template =~ s/\{\{\s*shy\s*\}\}//ig;                           # remove {{shy}}

        $template =~ s/\{\{\s*'\s*\}\}/'/ig;                            # replace {{'}}
        $template =~ s/\{\{\s*=\s*\}\}/=/ig;                            # replace {{=}}
        $template =~ s/\{\{\s*colon\s*\}\}/:/ig;                        # replace {{colon}}

        $template =~ s/\{\{\s*bracket\s*\|([^\}]+)\}\}/\[$1\]/ig;       # replace {{bracket|text}}
        $template =~ s/\{\{\s*interp\s*\|([^\}]+)\}\}/\[$1\]/ig;        # replace {{interp|text}}

        $template =~ s/,?\s*\{\{\s*ODNBsub\s*\}\}//ig;                  # remove {{ODNBsub}}
        $template =~ s/\s*\{\{\s*arxiv\s*\|[^\}]*\}\}//ig;              # remove {{arxiv}}
        $template =~ s/\s*\{\{\s*paywall\s*\}\}//ig;                    # remove {{paywall}}
        $template =~ s/\s*\{\{\s*registration required\s*\}\}//ig;      # remove {{registration required}}

        $template =~ s/\s*\{\{\s*subscription needed\s*(?:\|.*?)?\}\}//ig;    # remove {{subscription needed|remove}}
        $template =~ s/\s*\{\{\s*subscription required\s*(?:\|.*?)?\}\}//ig;  # remove {{subscription required|remove}}
        $template =~ s/\s*\{\{\s*subscription\s*(?:\|.*?)?\}\}//ig;           # remove {{subscription|remove}}

        $template =~ s/\{\{\s*HighBeam\s*\}\}//ig;                      # remove {{HighBeam}}

        $template =~ s/\{\{\s*Please check ISBN\s*\|([^\}]+)\}\}//ig;   # remove {{Please check ISBN|remove}}

        $template =~ s/\s*\{\{\s*doi\s*\|([^\}]+)\}\}//ig;              # remove {{doi|remove}}
        $template =~ s/\s*\{\{\s*ISBN\s*\|([^\}]+)\}\}//ig;             # remove {{ISBN|remove}}
        $template =~ s/\s*\{\{\s*ISSN\s*\|([^\}]+)\}\}//ig;             # remove {{ISSN|remove}}
        $template =~ s/\s*\{\{\s*JSTOR(?:\s*\|([^\}]+))?\}\}//ig;       # remove {{JSTOR|remove}}

        $template =~ s/\{\{\s*nowrap\s*\|([^\}]+)\}\}/$1/ig;            # remove {{nowrap|text}}
        $template =~ s/\{\{\s*noitalic\s*\|([^\}]+)\}\}/$1/ig;          # remove {{noitalic|text}}
        $template =~ s/\{\{\s*small\s*\|([^\}]+)\}\}/$1/ig;             # remove {{small|text}}
        $template =~ s/\{\{\s*smallcaps\s*\|([^\}]+)\}\}/$1/ig;         # remove {{smallcaps|text}}

        $template =~ s/\{\{\s*gr[ae]y\s*\|([^\}]+)\}\}/$1/ig;           # remove {{gray|text}}

        $template =~ s/\{\{\s*lc:\s*([^\}]+)\}\}/\L$1/ig;               # remove {{lc:text}} where kept text is converted to lowercase
        $template =~ s/\{\{\s*uc:\s*([^\}]+)\}\}/\U$1/ig;               # remove {{uc:text}} where kept text is converted to uppercase
        $template =~ s/\{\{\s*lcfirst:\s*(.)([^\}]+)\}\}/\l$1$2/ig;     # remove {{lcfirst:text}} where first letter of kept text is converted to lowercase
        $template =~ s/\{\{\s*ucfirst:\s*(.)([^\}]+)\}\}/\u$1$2/ig;     # remove {{ucfirst:text}} where first letter of kept text is converted to uppercase

        $template =~ s/\s*\{\{\s*\^\s*\|([^\}]+)\}\}//ig;               # remove {{^|remove}}
        $template =~ s/\s*\{\{\s*void\s*\|([^\}]+)\}\}//ig;             # remove {{void|remove}}

        $template =~ s/\{\{\s*chem\s*\|\s*CO\s*\|\s*2\s*\}\}/CO2/ig;    # replace {{chem|CO|2}}

        $template =~ s/\{\{\s*w\s*\|([^\}\|]+)\|.*?\}\}/$1/ig;          # remove {{w|text|...}}
        $template =~ s/\{\{\s*w\s*\|([^\}]+)\}\}/$1/ig;                 # remove {{w|text}}

        $template =~ s/\{\{\s*linktext\s*\|([^\}\|]+)\|.*?\}\}/$1/ig;   # remove {{linktext|text|...}}
        $template =~ s/\{\{\s*no ?italics?\s*\|([^\}]+)\}\}/$1/ig;      # remove {{noitalic|text}}

        $citation =~ s/\Q$start\E/$template/;

        $citation =~ s/\s{2,}/ /g;                                      # ensure only single space
    }

    return $citation;
}

sub updateCitation {

    # Update citation if matching page name

    my $citation = shift;
    my $type     = shift;
    my $titles   = shift;

    my $condition1 = "$citation (journal)";
    my $condition2 = "$citation (magazine)";
    if ($type eq 'journal') {
        if (exists $titles->{$condition1}) {
            $citation = $condition1;
        }
        elsif (exists $titles->{$condition2}) {
            $citation = $condition2;
        }
    }
    elsif ($type eq 'magazine') {
        if (exists $titles->{$condition2}) {
            $citation = $condition2;
        }
        elsif (exists $titles->{$condition1}) {
            $citation = $condition1;
        }
    }

    return $citation;
}

sub validateDoi {

    # Validates a doi and returns the prefix & value

    my $field = shift;
    my $limit = shift;

    return if ($field =~ /^\s*$/);
    $field =~ s#^https?://(?:dx\.)?doi\.org/##;
    $field =~ s/^doi://;
    my $result = {};
    if ($field =~ /^(10\.\d{6})/) {
        $result->{'prefix'} = 'INVALID';
    }
    elsif ($field =~ /^(10\.\d{4,5})/) {
        my $prefix = $1;
        if ($prefix < 10.1) {
            $result->{'prefix'} = 'INVALID';
        }
        elsif (($prefix =~ /10\.\d{5}/) and ($prefix > $limit)) {
            $result->{'prefix'} = 'INVALID';
        }
        else {
            $result->{'prefix'} = $prefix;
        }
    }
    else {
        $result->{'prefix'} = 'INVALID';
    }
    $result->{'entire'} = $field;

    return $result;
}

#
# Main
#

# handle UTF-8

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

# auto-flush output

$| = 1;

# extract & process fields from citation templates

print "Extracting citations ...\n";

my $b0 = Benchmark->new;

# find DOI limit

my $doiLimit = findDoiLimit($DOIDIRECTORY);

# delete existing database & create new one

print "  creating database ...\n";

if (-e $DBCITATIONS) {
    unlink $DBCITATIONS
        or die "ERROR: Could not delete database ($DBCITATIONS)\n --> $!\n\n";
}

my $database = citationsDB->new;
$database->openDatabase($DBCITATIONS);
$database->createTables(\@TABLES);

my $titles = queryDisambiguatedTitles($DBTITLES);

# process citation templates

print "  processing citation templates ...\n";

my $citations = {};
my $dois = {};
my $cCitations = 0;

open INPUT, '<:utf8', $CTEMPLATES
    or die "ERROR: Could not open file ($CTEMPLATES)!\n  $!\n\n";

while (<INPUT>) {

    if (/^(.+?)\t(.+?)$/) {
        my $title    = $1;
        my $template = $2;

        # process journal|magazine field

        my $extracted = extractField($template);
        next unless ($extracted);

        my $citation;

        for my $type (sort keys %$extracted) {

            $citation = $extracted->{$type};

            unless ($citation) {
                print "    Citation not parsed!\n";
                print "      Title    = $title\n";
                print "      Template = $template\n";
                next;
            }

            $cCitations++;

            if ($citation =~ /\{\{/) {
                print "    Template remaining in citation!\n";
                print "      Title    = $title\n";
                print "      Citation = $citation\n";
            }

            $citation = ucfirst $citation if ($citation =~ /^[a-z]/);
            $citation = updateCitation($citation, $type, $titles);

            $citations->{$type}->{$citation}->{$title}++;

        }

        # process doi field

        $extracted = extractDoiField($template, $doiLimit);
        next unless ($extracted);

        my $prefix = $extracted->{'prefix'};
        my $entire = $extracted->{'entire'};

        $dois->{'field'}->{$prefix}->{$entire}->{$citation}->{$title}++;

    }
    else {
        die "ERROR: Should not reach here (main)!\nFile = templates-citations\nLine = $_\n\n";
    }

}

close INPUT;

# process doi templates

print "  processing doi templates ...\n";

open INPUT, '<:utf8', $DTEMPLATES
    or die "ERROR: Could not open file ($DTEMPLATES)!\n  $!\n\n";

while (<INPUT>) {

    if (/^(.+?)\t(.+?)$/) {
        my $title    = $1;
        my $template = $2;

        my $extracted = extractDoiTemplate($template, $doiLimit);
        next unless ($extracted);

        $cCitations++;

        my $prefix = $extracted->{'prefix'};
        my $entire = $extracted->{'entire'};
        my $citation = $extracted->{'citation'};

        unless ($citation eq 'NONE') {
            $citation = ucfirst $citation if ($citation =~ /^[a-z]/);
            $citation = updateCitation($citation, 'journal', $titles);
        }

        $dois->{'template'}->{$prefix}->{$entire}->{$citation}->{$title}++;
    }

}

close INPUT;

# generate normalizations
# This is done as a separate loop from above as to avoid re-processing the same citations
# since they repeat within the templates.

print "  generating normalizations ...\n";

my $normalizations = {};

for my $type (keys %$citations) {
    for my $citation (keys %{$citations->{$type}}) {

        # normalize (both with and without "(journal|magazine)")

        my $normalize = normalizeCitation($citation);
        $normalizations->{$type}->{$citation}->{$normalize} = 1;

        $_ = $citation;
        if (s/ \((?:journal|magazine)\)$//o) {
            $normalize = normalizeCitation($_);
            $normalizations->{$type}->{$citation}->{$normalize} = 1;
        }

    }
}

# save citations

print "  saving citations ...\n";

my $sth = $database->prepare(q{
    INSERT INTO citations (type, citation, article, count) VALUES (?, ?, ?, ?)
});

for my $type (keys %$citations) {
    for my $citation (keys %{$citations->{$type}}) {
        for my $title (keys %{$citations->{$type}->{$citation}}) {
            my $count = $citations->{$type}->{$citation}->{$title};
            $sth->execute($type, $citation, $title, $count);
        }
    }
}
$database->commit;

# save dois

print "  saving dois ...\n";

$sth = $database->prepare(q{
    INSERT INTO dois (type, prefix, entire, citation, article, count) VALUES (?, ?, ?, ?, ?, ?)
});

for my $type (keys %$dois) {
    for my $prefix (keys %{$dois->{$type}}) {
        for my $entire (keys %{$dois->{$type}->{$prefix}}) {
            for my $citation (keys %{$dois->{$type}->{$prefix}->{$entire}}) {
                for my $article (keys %{$dois->{$type}->{$prefix}->{$entire}->{$citation}}) {
                    my $count = $dois->{$type}->{$prefix}->{$entire}->{$citation}->{$article};
                    $sth->execute($type, $prefix, $entire, $citation, $article, $count);
                }
            }
        }
    }
}
$database->commit;

# save normalizations

print "  saving normalizations ...\n";

$sth = $database->prepare(q{
    INSERT INTO normalizations (type, citation, normalization, length) VALUES (?, ?, ?, ?)
});

for my $type (keys %$normalizations) {
    for my $citation (keys %{$normalizations->{$type}}) {
        for my $normalization (keys %{$normalizations->{$type}->{$citation}}) {
            my $length = length($normalization);
            $sth->execute($type, $citation, $normalization, $length);
        }
    }
}
$database->commit;

# wrap-up

$database->createIndexes(\@INDEXES);
$database->disconnect;

my $b1 = Benchmark->new;
my $bd = timediff($b1, $b0);
my $bs = timestr($bd);
$bs =~ s/^\s*(\d+)\swallclock secs.*$/$1/;
print "  $cCitations citations processed in $bs seconds\n";
