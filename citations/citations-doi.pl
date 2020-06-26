#!/usr/bin/perl

# This script generates and saves to Wikipedia the WP:JCW/DOI results.

use warnings;
use strict;

use Benchmark;
use File::Basename;
use Getopt::Std;
use HTML::Entities;
use List::Util qw(sum);
use POSIX qw(strftime);

use lib dirname(__FILE__) . '/../modules';

use citations qw( checkInterwiki loadInterwiki queryDate setFormat );
use citationsDB;
use mybot;

use utf8;

#
# Validate Environment Variables
#

unless (exists $ENV{'WIKI_CONFIG_DIR'}) {
    die "ERROR: WIKI_CONFIG_DIR environment variable not set\n";
}

unless (exists $ENV{'WIKI_WORKING_DIR'}) {
    die "ERROR: WIKI_WORKING_DIR environment variable not set\n";
}

#
# Configuration & Globals
#

my $DBTITLES   = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-titles.sqlite3';
my $INDIVIDUAL = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-individual.sqlite3';
my $BOTINFO    = $ENV{'WIKI_CONFIG_DIR'} .  '/bot-info.txt';
my $PREFIXES   = dirname(__FILE__) . '/interwiki-prefixes.cfg';

my $DOIREDIRECT = 'Template:R from DOI prefix';
my $MAIN = 'Template:JCW-Main';

#
# Subroutines
#

sub buildTemplatePattern {

    # Build an OR pattern for matching templates
    # Similar to what is in parse, could refactor into common

    my $bot      = shift;
    my $template = shift;

    print "  building template pattern ...\n";

    my $pattern = $template . '|';

    my $redirects = $bot->getRedirects($template, 10);
    for my $redirect (sort keys %$redirects) {
        $pattern .= $redirect . '|';
    }

    $pattern =~ s/Template://g;
    $pattern =~ s/ /\[ _\]\+/g;
    $pattern =~ s/\|$//;

    $pattern = qr/\{\{\s*(?:Template\s*:\s*)?(?:$pattern)\s*/i;

    return $pattern;
}

sub determineFormat {

    # Determine the format and target for a citation / target

    my $database = shift;
    my $citation = shift;
    my $citationFormat = shift;
    my $target = shift;
    my $targetFormat = shift;

    if (($citationFormat eq 'existent') or
        ($citationFormat eq 'normal') or
        ($citationFormat eq 'disambiguation') or
        ($citationFormat eq 'nonexistent') or
        ($citationFormat eq 'nowiki')
    ) {
        return $citationFormat, $citation, $citationFormat;
    }
    elsif ($citationFormat eq 'redirect') {
        return $citationFormat, $target, 'existent';
    }
    elsif ($citationFormat eq 'redirect-disambiguation') {
        return $citationFormat, $target, 'disambiguation';
    }
    elsif ($citationFormat eq 'NONE') {
        my ($pageType, $pageTarget) = queryTitle($database, $citation);

        if ($pageType) {

            if ($pageType eq 'NORMAL') {
                return 'existent', $citation, 'existent';
            }
            elsif ($pageType eq 'DISAMBIG') {
                return 'disambiguation', $citation, 'disambiguation';
            }
            elsif (($pageType eq 'REDIRECT') or ($pageType eq 'REDIRECT-UNNECESSARY')) {
                ($pageType, ) = queryTitle($database, $pageTarget);
                if ($pageType eq 'DISAMBIG') {
                    return 'redirect-disambiguation', $pageTarget, 'disambiguation';
                }
                else {
                    return 'redirect', $pageTarget, 'existent';
                }
            }
            else {
                die "ERROR: unknown page type\ncitation = $citation\ntype     = $pageType\n";
            }
        }
        else {
            return 'nonexistent', $citation, 'nonexistent';
        }
    }

    die "ERROR: should not reach here (determineFormat)!\ncitation = $citation\ncitationFormat = $citationFormat\n";
}

sub determinePage {

    # Determine which page the results should be displayed upon

    my $number = shift;
    my $pages = shift;

    return 'Invalid' if ($number =~ /^Invalid/);

    $number =~ s/^10\.//;

    for my $index (reverse sort {$a <=> $b} keys %$pages) {
        return '10.' . $pages->{$index} if ($number >= $pages->{$index});
    }

    die "ERROR: should not reach here (determinePage): number = $number\n";
}

sub determineRegistrant {

    # Determine registrant from Wikipedia page (if exists)

    my $bot = shift;
    my $prefix = shift;
    my $pattern = shift;

    my ($text, $timestamp) = $bot->getText($prefix);

    return '' unless ($text);

    if ($text =~ /$pattern\|\s*registrant\s*=\s*(.+?)\s*[\|\}]/i) {
        return $1;
    }

    if ($text =~ /^\s*#redirect\s*:?\s*\[\[\s*:?\s*(.+?)\s*(?:\]|(?<!&)#|\n|\|)/i) {
        # partially shared with parse, could refactor into common
        my $target = $1;
        $target = decode_entities($target);
        $target =~ s/%26/&/;
        $target =~ tr/_/ /;
        $target =~ s/ {2,}/ /g;
        $target =~ s/^ //;
        $target =~ s/ $//;
        $target = ucfirst $target;
        return $target;
    }

    return '';
}

sub formatArticles {

    # Format article count to include article names

    my $articles = shift;

    my $formatted;
    my $index = 0;
    for my $article (sort keys %$articles) {
        $index++;
        $article = ":$article" if ($article =~ /^(?:\/|Category\s*:|File\s*:|Image\*:)/i);
        $formatted .= ',&nbsp;' unless ($index == 1);
        $formatted .= "[[$article|$index]]";
    }

    return $formatted;
}

sub formatEntries {

    # Format entries to include proper linking

    my $entries = shift;

    my $result;

    for my $target (sort sortCitations keys %$entries) {
        if ($target eq 'NONE') {
            for my $citation (sort keys %{$entries->{$target}->{'citations'}}) {
                my $count = $entries->{$target}->{'citations'}->{$citation}->{'count'};
                $result .= "* $citation $count\n";
            }
        }
        else {
            $result .= '* ' . setFormat('display', $target, $entries->{$target}->{'format'});
            if (exists $entries->{$target}->{'citations'}->{$target}) {
                $result .= " $entries->{$target}->{'citations'}->{$target}->{'count'}"
            }
            $result .= "\n";
            for my $citation (sort keys %{$entries->{$target}->{'citations'}}) {
                next if ($citation eq $target);
                my $format = $entries->{$target}->{'citations'}->{$citation}->{'format'};
                my $count = $entries->{$target}->{'citations'}->{$citation}->{'count'};
                $result .= '** ' . setFormat('display', $citation, $format) . " $count\n";
            }
        }
    }

    return $result;
}

sub loadCitations {

    # Returns all the doi citations from the database

    my $databaseFile = shift;

    print "  loading citations ...\n";

    my $database = citationsDB->new;
    $database->openDatabase($databaseFile);

    my $sth = $database->prepare('
        SELECT d.type, d.prefix, d.entire, d.citation, d.article, d.count, i.dFormat, i.target
        FROM dois AS d
        LEFT JOIN individuals AS i
        ON d.citation = i.citation
        AND i.type = "journal"
    ');
    $sth->execute();

    my $results;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $type     = $ref->{'type'};
        my $prefix   = $ref->{'prefix'};
        my $entire   = $ref->{'entire'};
        my $citation = $ref->{'citation'};
        my $article  = $ref->{'article'};
        my $count    = $ref->{'count'};
        my $format   = $ref->{'dFormat'};
        my $target   = $ref->{'target'};

        unless (defined $format) {
            $format  = 'NONE';
            $target  = 'NONE';
        }

        if ($prefix eq 'INVALID') {
            $prefix = "Invalid: $entire";
        }

        $results->{$prefix}->{'citations'}->{$citation}->{'articles'}->{$article} = 1;
        $results->{$prefix}->{'citations'}->{$citation}->{'count'} += $count;
        $results->{$prefix}->{'citations'}->{$citation}->{'format'} = $format;
        $results->{$prefix}->{'citations'}->{$citation}->{'target'} = $target;
        $results->{$prefix}->{'articles'}->{$article} = 1;
        $results->{$prefix}->{'count'} += $count;
    }

    $database->disconnect;

    return $results;
}

sub queryTitle {

    # Query information regarding a title from the database

    my $database = shift;
    my $title = shift;

    my $sth = $database->prepare(q{
        SELECT pageType, target
        FROM titles
        WHERE title = ?
    });
    $sth->bind_param(1, $title);
    $sth->execute();

    while (my $ref = $sth->fetchrow_hashref()) {
        return $ref->{'pageType'}, $ref->{'target'};
    }

    return;
}

sub retrievePages {

    # Retrieves and parses template to determine pages to use

    my $bot = shift;
    my $template = shift;

    print "  retrieving page definitions ...\n";

    my ($text, $timestamp) = $bot->getText($template);

    my $pages = {};
    my $count = 1;

    while ($text =~ /^\*\s*\[\[\s*Wikipedia:WikiProject Academic Journals\/Journals cited by Wikipedia\/DOI\/10.(\d+)\s*\|/gm) {
        $pages->{$count} = $1;
        $count++;
    }

    return $pages;
}

sub saveOutput {

    # Save output for the current page

    my $current = shift;
    my $output = shift;
    my $bot = shift;

    # save page

    my $page = "Wikipedia:WikiProject Academic Journals/Journals cited by Wikipedia/DOI/$current";
    $page = "Wikipedia:WikiProject Academic Journals/Journals cited by Wikipedia/Maintenance/Invalid DOI prefixes" if ($current eq 'Invalid');
    my ($old, $timestamp) = $bot->getText($page);
    $bot->saveText($page, $timestamp, $output, 'updating Wikipedia citation statistics', 'NotMinor', 'Bot');

    unless ($old)  {
        # create talk page redirect
        my $talk = "Wikipedia talk:WikiProject Academic Journals/Journals cited by Wikipedia/DOI/$current";
        ($old, $timestamp) = $bot->getText($talk);
        my $redirect = "#REDIRECT [[Wikipedia talk:WikiProject Academic Journals/Journals cited by Wikipedia]]";
        $bot->saveText($talk, $timestamp, $redirect, 'redirect to primary talk page', 'NotMinor', 'Bot');

        # create shortcut
        my $shortcut = "WP:JCW/DOI/$current";
        ($old, $timestamp) = $bot->getText($shortcut);
        $redirect = "#REDIRECT [[Wikipedia:WikiProject Academic Journals/Journals cited by Wikipedia/DOI/$current]]";
        $bot->saveText($shortcut, $timestamp, $redirect, 'navigation shortcut', 'NotMinor', 'Bot');
    }

    return;
}

sub sortCitations {

    # Sort the citations such that NONE is always last

    return  0 if ($a eq $b);
    return  1 if ($a eq 'NONE');
    return -1 if ($b eq 'NONE');
    return $a cmp $b;
}

sub sortPrefixes {

    # Sort prefixes so that order is 4-digits, 5-digits, Invalid

    return  0 if ($a eq $b);

    return  1 if (($a =~ /^Invalid/) and ($b !~ /^Invalid/));
    return -1 if (($b =~ /^Invalid/) and ($a !~ /^Invalid/));
    return $a cmp $b if (($a =~ /^Invalid/) and ($b =~ /^Invalid/));

    return  1 if (($a =~ /^10\.\d{5}$/) and ($b =~ /^10\.\d{4}$/));
    return -1 if (($b =~ /^10\.\d{5}$/) and ($a =~ /^10\.\d{4}$/));
    return $a <=> $b;
}

#
# Main
#

# command line options

my %opts;
getopts('hp', \%opts);

if ($opts{h}) {
    print "usage: citations-doi.pl [-hp]\n";
    print "       where: -h = help\n";
    print "              -p = print output to temp file (instead of saving to Wikipedia)\n";
    exit;
}

my $print = $opts{p} ? $opts{p} : 0;       # specify printing output

# handle UTF-8

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

# auto-flush output

$| = 1;

# generate output

print "Creating DOI pages ...\n";

my $b0 = Benchmark->new;

# initialize bot

my $bot = mybot->new($BOTINFO);

# preparation

my $pattern = buildTemplatePattern($bot, $DOIREDIRECT);
my $interwikiPrefixes = loadInterwiki($PREFIXES);
my $pages = retrievePages($bot, $MAIN);

# query doi citations

my $dois = loadCitations($INDIVIDUAL);

# open titles database

my $dbTitles = citationsDB->new;
$dbTitles->openDatabase($DBTITLES);

# process dois

my $current = 0;
my $total = scalar keys %$dois;

my $results;

for my $prefix (sort sortPrefixes keys %$dois) {

    $current++;
    print "  processing $current of $total ...\r";

    my $aCount = scalar keys %{$dois->{$prefix}->{'articles'}};
    my $cCount = $dois->{$prefix}->{'count'};

    my $registrant = '';
    $registrant = determineRegistrant($bot, $prefix, $pattern) unless ($prefix =~ /^Invalid:/);

    my $doi = $prefix;
    $doi =~ s/^Invalid: //;
    $doi =~ s/\|/{{!}}/g;

    my $result = "{{JCW-DOI-rank|doi=$doi|registrant=$registrant|citations=$cCount|articles=$aCount";
    my $entries;

    my $citations = $dois->{$prefix}->{'citations'};
    for my $citation (keys %$citations) {

        my $articles = scalar keys %{$citations->{$citation}->{'articles'}};
        my $count = $citations->{$citation}->{'count'};
        my $target = $citations->{$citation}->{'target'};
        my $citationFormat = $citations->{$citation}->{'format'};
        my $targetFormat = 'nonexistent';

        if ($articles <= 5) {
            $articles = formatArticles($citations->{$citation}->{'articles'});
        }

        my $interwiki = checkInterwiki($citation, $interwikiPrefixes);
        if ($interwiki) {
            # citation results in an interwiki link
            $citationFormat = 'nowiki';
            $target = $citation;
            $targetFormat = 'nowiki';
        }
        elsif ($citation =~ /[#<>\[\]\|{}_]/) {
            # citation results in an invalid link
            $citationFormat = 'nowiki';
            $target = $citation;
            $targetFormat = 'nowiki';
        }
        elsif ($citation eq 'NONE') {
            $citation = "{{doi prefix|$doi|mode=t}}";
            $target = 'NONE';
        }
        else {
            ($citationFormat, $target, $targetFormat) = determineFormat($dbTitles, $citation, $citationFormat, $target, $targetFormat);
        }

        $entries->{$target}->{'format'} = $targetFormat;
        $entries->{$target}->{'citations'}->{$citation}->{'count'} = "($count in $articles)";
        $entries->{$target}->{'citations'}->{$citation}->{'format'} = $citationFormat;
    }

    my $formattedEntries = formatEntries($entries);
    my $lineCount = () = $formattedEntries =~ /\n/g;
    my $entryCount = () = $formattedEntries =~ / \(\d+ in /g;

    $result .= "|l-count=$lineCount|e-count=$entryCount|entries=\n$formattedEntries}}\n";
    my $page = determinePage($prefix, $pages);
    push @{$results->{$page}}, $result;
}

$dbTitles->disconnect;

# empty pages

for my $index (keys %$pages) {
    my $page = '10.' . $pages->{$index};
    unless (exists $results->{$page}) {
        my $result = "|-\n| colspan=5 |No results for this prefix\n";
        push @{$results->{$page}}, $result;
    }
}
unless (exists $results->{'Invalid'}) {
    my $result = "|-\n| colspan=5 |No invalid results found\n";
    push @{$results->{'Invalid'}}, $result;
}

# output results

if ($print) {
    print "  generating output file ...\n";
    my $file = $ENV{'WIKI_WORKING_DIR'} . '/../x-doi-' . strftime('%H%M%S', localtime);
    open OUTPUT, '>:utf8', $file
        or die "ERROR: could not open file ($file)!\n$!\n";
    for my $index (sort sortPrefixes keys %$results) {
        print OUTPUT "INDEX = $index\n";
        for my $result (@{$results->{$index}}) {
            print OUTPUT $result;
        }
    }
    close OUTPUT;
}
else {

    my $date = queryDate($DBTITLES);

    my $previous = '';
    my $current = '10.1000';
    my $output = "{{JCW-Main|letter=DOI}}\n{{JCW-DOI-top}}\n";

    for my $index (sort sortPrefixes keys %$results) {
        if ($index ne $current) {

            # bottom of page

            $output .= "{{JCW-bottom|date=$date|type=no|legend=no}}\n";
            if (not $previous) {
                $output .= "{{JCW-PrevNext|previous=|current=DOI/$current|next=DOI/$index}}\n";
            }
            elsif ($index eq 'Invalid') {
                $output .= "{{JCW-PrevNext|previous=DOI/$previous|current=DOI/$current|next=}}\n";
            }
            else {
                $output .= "{{JCW-PrevNext|previous=DOI/$previous|current=DOI/$current|next=DOI/$index}}\n";
            }
            $output .= "{{DEFAULTSORT:δ-$current}}\n";

            # save

            print "  saving $current ...                  \r";
            saveOutput($current, $output, $bot);

            # get ready for next page

            $previous = $current;
            $current = $index;
            $output = "{{JCW-Main|letter=DOI}}\n{{JCW-DOI-top}}\n";

        }
        for my $result (@{$results->{$index}}) {
            $output .= $result;
        }
    }

    # add bottom of page & save for last one (which would be Invalid)
    $output .= "{{JCW-bottom|date=$date|type=no|legend=no}}\n";
    $output .= "{{DEFAULTSORT:* Invalid DOI prefixes}}\n" ;
    print "  saving $current ...                  \r";
    saveOutput($current, $output, $bot);
}
print "                                 \r";

my $b1 = Benchmark->new;
my $bd = timediff($b1, $b0);
my $bs = timestr($bd);
$bs =~ s/^\s*(\d+)\swallclock secs.*$/$1/;
print "  DOI pages processed in $bs seconds\n";