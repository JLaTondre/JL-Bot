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

    # strip outer braces and template name
    $citation =~ s/^\s*\{\{\s*[^|]+?\s*\|//;
    $citation =~ s/\}\}\s*$//;

    # remove comments
    $citation =~ s/<!--(?:(?!<!--).)*?-->//sg;

    # replace nowiki
    my @nowikiStash;
    my $nowikiCount = 0;
    my $nowikiRe = qr{
        <\s*nowiki\s*>(.*?)<\s*\/\s*nowiki\s*>
    }isx;
    $citation =~ s/$nowikiRe/
        push @nowikiStash, $&;
        "\x01NOWIKI" . (++$nowikiCount) . "\x02";
    /gse;

    # utilize a tokenizer to split the citation into parts
    my $fields;
    my @parts;
    my $current = '';
    my $depth_curly = 0;
    my $depth_square = 0;

    my @chars = split //, $citation;
    for (my $i = 0; $i < @chars; $i++) {
        my $char = $chars[$i];
        my $next = $chars[$i + 1] // '';

        # track nesting
        if ($char eq '{' && $next eq '{') {
            $depth_curly++;
            $current .= $char;
        }
        elsif ($char eq '}' && $next eq '}') {
            $depth_curly-- if $depth_curly > 0;
            $current .= $char;
        }
        elsif ($char eq '[' && $next eq '[') {
            $depth_square++;
            $current .= $char;
        }
        elsif ($char eq ']' && $next eq ']') {
            $depth_square-- if $depth_square > 0;
            $current .= $char;
        }
        elsif ($char eq '|' && $depth_curly == 0 && $depth_square == 0) {
            push @parts, $current;
            $current = '';
        } else {
            $current .= $char;
        }
    }
    push @parts, $current if $current ne '';

    foreach my $part (@parts) {
        $part =~ s/^\s+|\s+$//g;
        if ($part =~ /^([^=]+?)\s*=\s*(.+)$/s) {
            my ($key, $value) = ($1, $2);
            $key =~ s/^\s+|\s+$//g;
            $key = lc $key;

            # only keep journal or magazine fields
            next unless $key eq 'journal' || $key eq 'magazine';

            if ($value =~ /\{\{/) {
                $value = removeTemplates($value);
            }

            # restore <nowiki>
            $value =~ s/\x01NOWIKI(\d+)\x02/$nowikiStash[$1-1]/ge;

            $value =~ s/_/ /g;                                  # ensure spaces (wiki syntax)
            $value =~ s/&nbsp;/ /g;                             # ensure spaces (non-breaking)
            $value =~ s/\xA0/ /g;                               # ensure spaces (non-breaking)
            $value =~ s/<br\s*\/?>/ /g;                         # ensure spaces (breaks)
            $value =~ s/\t/ /g;                                 # ensure spaces (tabs)
            $value =~ s/\s{2,}/ /g;                             # ensure only single space

            $value =~ s/\[\[(?:\s*:[a-zA-Z]{2}:)?[^\|\]]+\|\s*([^\]]+)\s*\]\]/$1/g;  # remove link from [[:en:link|text]]
            $value =~ s/\[\[(?:\s*:[a-zA-Z]{2}:)?\s*([^\]]+?)\s*\|?\]\]/$1/g;        # remove link from [[:en:text]]

            $value =~ s/\[\s*https?:[^\s\]]+\]//g;              # remove [http://link]
            $value =~ s/\[\s*https?:[^\s]+\s+([^\]]+)\]/$1/g;   # remove link from [http://link text]

            $value =~ s/<abbr\s.*?>(.*?)<\/abbr\s*>/$1/ig;      # remove <abbr ...>text</abbr>
            $value =~ s/<span\s.*?>(.*?)<\/span\s*>/$1/ig;      # remove <span ...>text</span>
            $value =~ s/<cite\s.*?>(.*?)<\/cite\s*>/$1/ig;      # remove <cite ...>text</cite>
            $value =~ s/<sup>\s*([^\<]+)?\s*<\/sup>/$1/g;       # remove <sub>text</sub>
            $value =~ s/<small>\s*([^\<]+)?\s*<\/small>/$1/g;   # remove <small>text</small>
            $value =~ s/<nowiki>\s*([^\<]+)\s*<\/nowiki>/$1/g;  # remove <nowiki>text</nowiki>

            $value = decode_entities($value);                   # decode HTML entities (&amp; etc)

            $value =~ s/^\s*'{1,5}(.*?)'{1,5}$/$1/g;            # remove single quotes, italics, and bold
            $value =~ s/^\s*[\"“](.*?)[\"”]$/$1/g;              # remove quotes (regular & irregular)

            $value =~ s/\s*\(\)$//g;                            # remove () at end

            $value =~ s/^\s+|\s+$//g;                           # trim leading/trailing spaces

            # skip if results in nothing (ex. comment only)
            next unless ($value);

            $fields->{$key} = $value;
        }
    }

    return $fields;
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

    $citation =~ s/\{\{\s*subst:/{{/g;                                  # remove subst:

    my $templates = findTemplates($citation);

    for my $template (@$templates) {

        my $start = $template;

        # several of these could be collapsed (conditional, or) but are left separate for simplicity | readability

        $template =~ s/\s*\{\{\s*dead ?link\s*(?:\|.*?)?\}\}//ig;               # remove {{dead link|date=...}}
        $template =~ s/\s*\{\{\s*cbignore\s*(?:\|.*?)?\}\}//ig;                 # remove {{cbignore|bot=...|}}

        while ($template =~ s/(\{\{\s*abbrv?(?=\s*[|}])[^{}]*?)\|\s*(?!1\s*=)[^|=\s]+(?:\s*=\s*)[^|}]*(?=\||\}\})/$1/ig) {} # remove non-1= parameters
        $template =~ s/\{\{\s*abbrv?(?=\s*[|}])[^}]*?\|\s*1\s*=\s*([^|}]+)[^}]*\}\}/$1/ig;                                  # replace {{abbrv|...|1=text|...}}
        $template =~ s/\{\{\s*abbrv?(?=\s*[|}])[^}]*?\|\s*([^|}]+)[^}]*\}\}/$1/ig;                                          # replace {{abbrv|text|...}}

        $template =~ s/\{\{\s*sup\s*\|([^\}]+)\}\}/$1/ig;                       # replace {{sup|text}}
        $template =~ s/\{\{\s*title case\s*\|([^\}]+)\}\}/$1/ig;                # replace {{title case|text}}

        $template =~ s/\{\{\s*not a typo\s*\|([^\|]+)\|([^\}]+)\}\}/$1$2/ig;    # replace {{not a typo|text|text}}
        $template =~ s/\{\{\s*not a typo\s*\|([^\}]+)\}\}/$1/ig;                # replace {{not a typo|text}}

        $template =~ s/\{\{\s*as written\s*\|([^\|]+)\|([^\}]+)\}\}/$1$2/ig;    # replace {{as written|text|text}}
        $template =~ s/\{\{\s*as written\s*\|([^\}]+)\}\}/$1/ig;                # replace {{as written|text}}

        $template =~ s/\{\{\s*text\s*\|([^\|]+)\|([^\}]+)\}\}/$1$2/ig;          # replace {{text|text|text}}
        $template =~ s/\{\{\s*text\s*\|([^\}]+)\}\}/$1/ig;                      # replace {{text|text}}

        $template =~ s/\{\{\s*wikiLeaks cable\s*\|(?:id=)?(.+)\}\}/WikiLeaks cable: $1/ig;          # replace {{wikiLeaks cable|id=text|}}

        $template =~ s/\{\{\s*transl(?:iteration)?\s*\|[^\|]*\|[^\|]*\|([^\}\|]+).*?\}\}/$1/ig;     # replace {{transl|no|no|text|...}}
        $template =~ s/\{\{\s*transl(?:iteration)?\s*\|[^\|]*\|([^\}\|]+).*?\}\}/$1/ig;             # replace {{transl|no|text|...}}

        $template =~ s/\{\{\s*illm?\s*\|[^\}\|]+\{\{\s*!\s*\}\}\s*([^\}\|]+).*?\}\}/$1/ig;                              # replace {{ill|remove{{!}}text|...}}
        $template =~ s/\{\{\s*interlanguage(?: link(?: multi)?)?\s*\|[^\}\|]+\{\{\s*!\s*\}\}\s*([^\}\|]+).*?\}\}/$1/ig; # replace {{interlanguage link|remove{{!}}text|...}}
        $template =~ s/\{\{\s*link-interwiki\s*\|[^\}\|]+\{\{\s*!\s*\}\}\s*([^\}\|]+).*?\}\}/$1/ig;                     # replace {{link-interwiki|remove{{!}}text|...}}

        $template =~ s/\{\{\s*illm?.*?\|[^\}]*lt\s*=\s*([^\}\|]+).*?\}\}/$1/ig;                                 # replace {{ill|...|lt=text|...}}
        $template =~ s/\{\{\s*interlanguage(?: link(?: multi)?)?\s*\|[^\}]*lt\s*=\s*([^\}\|]+).*?\}\}/$1/ig;    # replace {{interlanguage link|...|lt=text|...}}
        $template =~ s/\{\{\s*link-interwiki\|[^\}]*lt\s*=\s*([^\}\|]+).*?\}\}/$1/ig;                           # replace {{link-interwiki|...|lt=text|...}}

        $template =~ s/\{\{\s*illm?\s*\|([^\}\|]+).*?\}\}/$1/ig;                                    # replace {{ill|text|...}}
        $template =~ s/\{\{\s*interlanguage(?: link(?: multi)?)?\s*\|([^\}\|]+).*?\}\}/$1/ig;       # replace {{interlanguage link|text|...}}
        $template =~ s/\{\{\s*link-interwiki\s*\|([^\}\|]+).*?\}\}/$1/ig;                           # replace {{link-interwiki|text|...}}

        while ($template =~ s/(\{\{\s*langx?(?=\s*[|}])[^{}]*?)\|\s*(?!(?:2|text)\s*=)[^|=\s]+(?:\s*=\s*)[^|}]*(?=\||\}\})/$1/ig) {}    # remove non-(2|text)= parameters
        $template =~ s/\{\{\s*langx?(?=\s*[|}])[^}]*?\|\s*(?:2|text)\s*=\s*([^|}]+)[^}]*\}\}/$1/ig;                                     # replace {{lang|...|(2|text)=text|...}}
        $template =~ s/\{\{\s*langx?\s*\|[^\|]+\|\s*([^\}]+)\}\}/$1/ig;                                                                 # replace {{lang|...|text|...}}

        while ($template =~ s/(\{\{\s*nihongo2?(?=\s*[|}])[^{}]*?)\|\s*(?![13]\s*=)[^|=\s]+(?:\s*=\s*)[^|}]*(?=\||\}\})/$1/ig) {}   # remove non-(1|3)= parameters
        $template =~ s/\{\{\s*nihongo2?(?=\s*[|}])[^}]*?\|\s*1\s*=\s*([^|}]+)[^}]*\}\}/$1/ig;                                       # replace {{nihongo|...|1=text|...}}
        $template =~ s/\{\{\s*nihongo2?(?=\s*[|}])[^}]*?\|\s*3\s*=\s*([^|}]+)[^}]*\}\}/$1/ig;                                       # replace {{nihongo|...|3=text|...}}
        $template =~ s/\{\{\s*nihongo(?=\s*[|}])[^}]*?\|\s*(?=\|)\|[^|}]*\|\s*([^|}]+)[^}]*\}\}/$1/ig;                              # replace {{nihongo||..|text|...}} (no nihongo2 for this one, but needs to be before next)
        $template =~ s/\{\{\s*nihongo2?(?=\s*[|}])[^}]*?\|\s*([^|}]+)[^}]*\}\}/$1/ig;                                               # replace {{nihongo|text|...}}

        $template =~ s/\{\{\s*nihongo krt(?=\s*[|}])[^}]*?\|\s*2\s*=\s*([^|}]+)[^}]*\}\}/$1/ig; # replace {{nihongo krt|...|2=text|...}}
        $template =~ s/\{\{\s*nihongo krt\s*\|[^|]*\|\s*([^|}]+)[^}]*\}\}/$1/ig;                # replace {{nihongo krt|...|text|...}}

        while ($template =~ s/(\{\{\s*(?:lang-)?zhi?(?=\s*[|}])[^{}]*?)\|\s*[^|=\s]+(?:\s*=\s*)[^|}]*(?=\||\}\})/$1/ig) {}  # remove named parameters
        $template =~ s/\{\{\s*(?:lang-)?zhi?(?=\s*[|}])[^|}]*\|\s*([^|}]+)[^}]*\}\}/$1/ig;                                  # replace {{lang-zh|text|...}}
        $template =~ s/\{\{\s*(?:lang-)?zhi?(?=\s*[|}])[^}]*\}\}//ig;                                                       # remove {{lang-zh}} (no parameters remaining)

        $template =~ s/\{\{\s*korean\s*?\|\s*hangul\s*=\s*([^|}]+)[^}]*\}\}/$1/ig;                              # replace {{korean|hangul=text|...}}
        $template =~ s/\{\{\s*korean\s*\|\s*labels\s*=\s*no\b\s*\|\s*([^|=}][^|}]*)[^}]*\}\}/$1/ig;             # replace {{korean|labels=no|text|...}}
        $template =~ s/\{\{\s*korean\s*(?=[^}]*\|\s*labels\s*=\s*no\b)\s*\|\s*([^|=}][^|}]*)[^}]*\}\}/$1/ig;    # replace {{korean|...|labels=no|text|...}}

        $template =~ s/\s*\{\{\s*in lang\s*\|[^\}]+\}\}//ig;            # remove {{in lang|remove}}

        $template =~ s/\{\{\s*okina\s*\}\}/&#x02BB;/ig;                 # replace {{okina}}
        $template =~ s/\{\{\s*hamza\s*\}\}/&#x02BC;/ig;                 # replace {{hamza}}

        $template =~ s/\{\{\s*pi\s*\}\}/π/ig;                           # replace {{pi}}

        $template =~ s/\{\{\s*ordinal\s*\|\s*1\s*\}\}/1st/ig;           # replace {{ordinal|1}}
        $template =~ s/\{\{\s*ordinal\s*\|\s*2\s*\}\}/2nd/ig;           # replace {{ordinal|2}}
        $template =~ s/\{\{\s*ordinal\s*\|\s*3\s*\}\}/3rd/ig;           # replace {{ordinal|3}}
        $template =~ s/\{\{\s*ordinal\s*\|\s*([4-9])\s*\}\}/$1th/ig;    # replace {{ordinal|4}}

        $template =~ s/\{\{\s*convert\s*\|\s*(\d+)\s*\|\s*F\s*\}\}/$1 °F/ig;    # replace {{convert|text|F}}

        $template =~ s/\s*\{\{\s*dn\s*(?:\|.*?)?\}\}//ig;                       # remove {{dn|date=...}}
        $template =~ s/\s*\{\{\s*disambiguation needed\s*(?:\|.*?)?\}\}//ig;    # remove {{disambiguation needed|date=...}}

        $template =~ s/\{\{\s*usurped\s*\|\s*1\s*=\s*\[https?:[^\s]+\s+([^\]\}]+)\]?\}\}/$1/ig;   # replace {{usurped|1=[URL text]}}

        $template =~ s/\s*\{\{\s*specify\s*(?:\|.*?)?\}\}//ig;          # remove {{specify|reason=...}}

        $template =~ s/\s*\{\{\s*clarify\s*(?:\|.*?)?\}\}//ig;              # remove {{clarify|date=...}}
        $template =~ s/\s*\{\{\s*full citation needed\s*(?:\|.*?)?\}\}//ig; # remove {{full citation needed|date=...}}

        $template =~ s/\s*\{\{\s*date\s*(?:\|.*?)?\}\}//ig;             # remove {{date|remove}}

        $template =~ s/\{\{\s*ECCC\s*\|.*?\|\s*(\d+)\s*\|\s*(\d+)\s*\}\}/ECCC TR$1-$2/ig;  # replace {{ECCC|no|num|num}}

        $template =~ s/\{\{\s*(?:en |en|en-|n)dash\s*\}\}/–/ig;         # replace {{en dash}}
        $template =~ s/\{\{\s*(?:spaced (?:en |n))?dash\s*\}\}/ – /ig;  # replace {{spaced en dash}}
        $template =~ s/\{\{\s*snd\s*\}\}/ – /ig;                        # replace {{snd}}

        $template =~ s/\{\{\s*em ?dash\s*\}\}/—/ig;                     # replace {{em dash}}

        $template =~ s/\{\{\s*nbsp\s*\}\}/ /ig;                         # replace {{nbsp}}

        $template =~ s/\{\{\s*dot\s*\}\}/ · /ig;                        # replace {{dot}}
        $template =~ s/\{\{\s*•\s*\}\}/ · /ig;                          # replace {{•}}

        $template =~ s/\{\{\s*shy\s*\}\}//ig;                           # remove {{shy}}

        $template =~ s/\{\{\s*'\s*\}\}/'/ig;                            # replace {{'}}
        $template =~ s/\{\{\s*=\s*\}\}/=/ig;                            # replace {{=}}
        $template =~ s/\{\{\s*&\s*\}\}/&/ig;                            # replace {{&}}
        $template =~ s/\{\{\s*colon\s*\}\}/:/ig;                        # replace {{colon}}
        $template =~ s/\{\{\s*!\(\s*\}\}/\[/ig;                         # replace {{!(}}
        $template =~ s/\{\{\s*\)!\s*\}\}/\]/ig;                         # replace {{)!}}

        $template =~ s/\{\{\s*bracket\s*\|([^\}]+)\}\}/\[$1\]/ig;       # replace {{bracket|text}}
        $template =~ s/\{\{\s*interp\s*\|([^\}]+)\}\}/\[$1\]/ig;        # replace {{interp|text}}

        $template =~ s/,?\s*\{\{\s*ODNBsub\s*\}\}//ig;                  # remove {{ODNBsub}}
        $template =~ s/\s*\{\{\s*arxiv\s*\|[^\}]*\}\}//ig;              # remove {{arxiv}}
        $template =~ s/\s*\{\{\s*paywall\s*\}\}//ig;                    # remove {{paywall}}
        $template =~ s/\s*\{\{\s*registration required\s*\}\}//ig;      # remove {{registration required}}

        $template =~ s/\s*\{\{\s*subscription needed\s*(?:\|.*?)?\}\}//ig;    # remove {{subscription needed|remove}}
        $template =~ s/\s*\{\{\s*subscription required\s*(?:\|.*?)?\}\}//ig;  # remove {{subscription required|remove}}
        $template =~ s/\s*\{\{\s*subscription\s*(?:\|.*?)?\}\}//ig;           # remove {{subscription|remove}}

        $template =~ s/\s*\{\{\s*better source needed\s*(?:\|.*?)?\}\}//ig;            # remove {{better source needed|remove}}
        $template =~ s/\s*\{\{\s*unreliable source(?: inline)?\s*(?:\|.*?)?\}\}//ig;   # remove {{unreliable source|remove}}

        $template =~ s/\{\{\s*HighBeam\s*\}\}//ig;                      # remove {{HighBeam}}

        $template =~ s/\{\{\s*Please check ISBN\s*\|([^\}]+)\}\}//ig;   # remove {{Please check ISBN|remove}}

        $template =~ s/\s*\{\{\s*doi\s*\|([^\}]+)\}\}//ig;              # remove {{doi|remove}}
        $template =~ s/\s*\{\{\s*ISBN\s*\|([^\}]+)\}\}//ig;             # remove {{ISBN|remove}}
        $template =~ s/\s*\{\{\s*ISSN\s*\|([^\}]+)\}\}//ig;             # remove {{ISSN|remove}}
        $template =~ s/\s*\{\{\s*JSTOR(?:\s*\|([^\}]+))?\}\}//ig;       # remove {{JSTOR|remove}}

        $template =~ s/\{\{\s*nobr\s*\|([^\}]+)\}\}/$1/ig;              # replace {{nobr|text}}
        $template =~ s/\{\{\s*normal\s*\|([^\}]+)\}\}/$1/ig;            # replace {{normal|text}}
        $template =~ s/\{\{\s*nowrap\s*\|([^\}]+)\}\}/$1/ig;            # replace {{nowrap|text}}
        $template =~ s/\{\{\s*noitalic\s*\|([^\}]+)\}\}/$1/ig;          # replace {{noitalic|text}}
        $template =~ s/\{\{\s*small\s*\|([^\}]+)\}\}/$1/ig;             # replace {{small|text}}
        $template =~ s/\{\{\s*smallcaps\s*\|([^\}]+)\}\}/$1/ig;         # replace {{smallcaps|text}}

        $template =~ s/\{\{\s*gr[ae]y\s*\|([^\}]+)\}\}/$1/ig;           # replace {{gray|text}}

        $template =~ s/\{\{\s*lcfirst:\s*(.)([^\}]+)\}\}/\l$1$2/ig;     # replace {{lcfirst:text}} where first letter of kept text is converted to lowercase
        $template =~ s/\{\{\s*ucfirst:\s*(.)([^\}]+)\}\}/\u$1$2/ig;     # replace {{ucfirst:text}} where first letter of kept text is converted to uppercase

        $template =~ s/\s*\{\{\s*\^\s*\|([^\}]+)\}\}//ig;               # remove {{^|remove}}
        $template =~ s/\s*\{\{\s*void\s*\|([^\}]+)\}\}//ig;             # remove {{void|remove}}

        $template =~ s/\{\{\s*chem\s*\|\s*CO\s*\|\s*2\s*\}\}/CO2/ig;    # replace {{chem|CO|2}}
        $template =~ s/\s*\{\{\s*CO2\s*(?:\|.*?)?\}\}/CO2/ig;           # replace {{CO2|...}}

        $template =~ s/\{\{\s*w\s*\|([^\}\|]+)\|.*?\}\}/$1/ig;          # replace {{w|text|...}}
        $template =~ s/\{\{\s*w\s*\|([^\}]+)\}\}/$1/ig;                 # replace {{w|text}}

        $template =~ s/\{\{\s*annotated link(?=\s*[|}])[^}]*?\|\s*(?:2|disp(?:lay)?)\s*=\s*([^|}]+)[^}]*\}\}/$1/ig;         # replace {{annotated link|...|(2|display)=text|...}}
        while ($template =~ s/(\{\{\s*annotated link(?=\s*[|}])[^{}]*?)\|\s*[^|=\s]+(?:\s*=\s*)[^|}]*(?=\||\}\})/$1/ig) {}  # remove named parameters
        $template =~ s/\{\{\s*annotated link\s*\|([^\|]+)\|([^\}]+)\}\}/$2/ig;                                              # replace {{annotated link|...|text}}
        $template =~ s/\{\{\s*annotated link\s*\|([^\}]+)\}\}/$1/ig;                                                        # replace {{annotated link|text}}

        $template =~ s/\{\{\s*link if exists\s*\|([^\}]+)\}\}/$1/ig;    # replace {{link if exists|text|...}}
        $template =~ s/\{\{\s*linktext\s*\|([^\}\|]+)\|.*?\}\}/$1/ig;   # replace {{linktext|text|...}}
        $template =~ s/\{\{\s*no ?italics?\s*\|([^\}]+)\}\}/$1/ig;      # replace {{noitalic|text}}

        $template =~ s/\{\{\s*no self link\s*\|([^\|]+)\|([^\}]+)\}\}/$2/ig;  # replace {{no self link|...|text}}
        $template =~ s/\{\{\s*no self link\s*\|([^\}]+)\}\}/$1/ig;            # replace {{no self link|text}}
        $template =~ s/\{\{\s*nsl\s*\|([^\|]+)\|([^\}]+)\}\}/$2/ig;           # replace {{not a typo|...|text}}
        $template =~ s/\{\{\s*nsl\s*\|([^\}]+)\}\}/$1/ig;                     # replace {{not a typo|text}}

        $citation =~ s/\Q$start\E/$template/;
    }

    # pipe templates - must be after other template expansions
    $citation =~ s/\{\{\s*!\s*\}\}/|/ig;                                # replace {{!}}
    $citation =~ s/\{\{\s*pipe\s*\}\}/\|/ig;                            # replace {{pipe}}

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
