#!/usr/bin/perl

# This script generates and saves to Wikipedia the statistics (WP:JCW#Statistics).

use warnings;
use strict;

use Benchmark;
use File::Basename;
use File::Grep qw (fgrep);
use Getopt::Std;
use HTML::Entities;
use Number::Format qw(format_number);
use POSIX qw(strftime);

use lib dirname(__FILE__) . '/../modules';

use citations qw( queryDate );
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
my $CITATIONS  = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-citations.sqlite3';
my $CTEMPLATES = $ENV{'WIKI_WORKING_DIR'} . '/Citations/templates-citation';
my $DTEMPLATES = $ENV{'WIKI_WORKING_DIR'} . '/Citations/templates-doi';
my $BOTINFO    = $ENV{'WIKI_CONFIG_DIR'} .  '/bot-info.txt';

#
# Subroutines
#

sub articleStatistics {

    # Generate statistics based on the articles

    my $databaseFile = shift;

    print "  generating article statistics ...\n";

    my $database = citationsDB->new;
    $database->openDatabase($databaseFile);

    my $citationArticles;
    my $doiArticles;
    my $totalArticles;

    # query citation articles

    my $sth = $database->prepare(q{
        SELECT article
        FROM citations
    });
    $sth->execute();

    while (my $ref = $sth->fetchrow_hashref()) {
        my $article = $ref->{'article'};
        $citationArticles->{$article} = 1;
        $totalArticles->{$article} = 1;
    }

    # query doi articles

    $sth = $database->prepare(q{
        SELECT article
        FROM dois
        WHERE type = 'template'
    });
    $sth->execute();

    while (my $ref = $sth->fetchrow_hashref()) {
        my $article = $ref->{'article'};
        $doiArticles->{$article} = 1;
        $totalArticles->{$article} = 1;
    }

    $database->disconnect;

    # combine

    my $result = '* ' . format_number(scalar keys %$totalArticles) . " articles with journal or DOI citations:\n";
    $result .= '** ' . format_number(scalar keys %$citationArticles) . " articles with {{cite xxx}}\n";
    $result .= '** ' . format_number(scalar keys %$doiArticles) . " articles with DOI templates\n";

    return $result;
}

sub doiStatistics {

    # Generate statistics based on the dois

    my $databaseFile = shift;
    my $citationFile = shift;
    my $doiFile = shift;

    print "  generating DOI statistics ...\n";

    my $database = citationsDB->new;
    $database->openDatabase($databaseFile);

    my $prefix;
    my $entire;
    my $count;
    my $free;

    # query prefix

    my $sth = $database->prepare(q{
        SELECT COUNT(DISTINCT prefix)
        FROM dois
    });
    $sth->execute();

    while (my $ref = $sth->fetchrow_hashref()) {
        $prefix = $ref->{'COUNT(DISTINCT prefix)'};
    }

    # query entire

    $sth = $database->prepare(q{
        SELECT COUNT(DISTINCT entire)
        FROM dois
    });
    $sth->execute();

    while (my $ref = $sth->fetchrow_hashref()) {
        $entire = $ref->{'COUNT(DISTINCT entire)'};
    }

    # query count

    $sth = $database->prepare(q{
        SELECT SUM(count)
        FROM dois
    });
    $sth->execute();

    while (my $ref = $sth->fetchrow_hashref()) {
        $count = $ref->{'SUM(count)'};
    }

    $database->disconnect;

    # grep doi-access=free

    my $access = ( fgrep { /\|\s*doi-access\s*=\s*free\s*(?=\||\}\}$)/ } ($citationFile, $doiFile) );

    # combine

    my $result = '* ' . format_number($count) . " total DOI citations:\n";
    $result .= '** ' . format_number($entire) . " distinct DOIs\n";
    $result .= '** ' . format_number($access) . " marked with {{para|doi-access|free}}\n";
    $result .= '** ' . format_number($prefix) . " distinct DOI prefixes\n";

    return $result;
}

sub journalStatistics {

    # Generate statistics based on the journals

    my $databaseFile = shift;

    print "  generating journal statistics ...\n";

    my $database = citationsDB->new;
    $database->openDatabase($databaseFile);

    my $citationJournals;
    my $doiJournals;
    my $totalJournals;
    my $doiTotal;

    # query citation journals

    my $sth = $database->prepare(q{
        SELECT citation
        FROM citations
    });
    $sth->execute();

    while (my $ref = $sth->fetchrow_hashref()) {
        my $article = $ref->{'citation'};
        $citationJournals->{$article} = 1;
        $totalJournals->{$article} = 1;
    }

    # query doi journals

    $sth = $database->prepare(q{
        SELECT citation
        FROM dois
        WHERE type = 'template'
    });
    $sth->execute();

    while (my $ref = $sth->fetchrow_hashref()) {
        my $article = $ref->{'citation'};
        unless ($article eq 'NONE') {
            $doiJournals->{$article} = 1;
            $totalJournals->{$article} = 1;
            $doiTotal++;
        }
    }

    $database->disconnect;

    # combine

    my $result = '* ' . format_number(scalar keys %$totalJournals) . " distinct journal names:\n";
    $result .= '** ' . format_number(scalar keys %$citationJournals) . " distinct journal names in {{cite xxx}} templates\n";
    $result .= '** ' . format_number(scalar keys %$doiJournals) . " distinct journal names in DOI templates\n";
    $result .= '** ' . format_number($doiTotal) . " DOI templates with journal names\n";

    return $result;
}

sub templateRedirect {

    # Find the target of a template redirect

    my $bot  = shift;
    my $page = shift;

    my ($text, ) = $bot->getText("Template:$page");

    unless ($text) {
        warn "WARN: could not find Template:$page\n";
        return;
    }

    if ($text =~ /^\s*#redirect\s*:?\s*\[\[\s*:?(?:Template\s*:)?\s*(.+?)\s*(?:\]|(?<!&)#|\n|\|)/i) {
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

    return;
}

sub templateStatistics {

    # Generate statistics based on the templates

    my $bot  = shift;
    my $type = shift;
    my $file = shift;
    my $text = shift;

    print "  generating $type template statistics ...\n";

    # extract template types

    open INPUT, '<:utf8', $file
        or die "ERROR: Could not open file ($file)!\n  $!\n\n";

    my $byTemplate;
    my $total;

    while (<INPUT>) {
        if ($type eq 'citation') {
            # skip non-journal citations
            next unless (/\|\s*(?:journal|doi)\s*=.*?(?=\||\}\}$)/i);
        }
        if (/^.+?\t\{\{(?:\s*Template\s*:)?\s?(.+?)(?=\s*\|)/i) {
            my $template = ucfirst $1;
            $template =~ s/_/ /g;
            $byTemplate->{$template}++;
            $total++;
        }
        elsif (/^.+?\t\{\{(?:\s*Template\s*:)?\s?(.+?)\}\}$/) {
            # template without contents
            next;
        }
        else {
            die "ERROR: Unknown line! --> $_\n";
        }
    }

    close INPUT;

    # consolidate redirects

    for my $template (keys %$byTemplate) {
        my $target = templateRedirect($bot, $template);
        if ($target) {
            my $count = $byTemplate->{$template};
            $byTemplate->{$target} += $count;
            delete $byTemplate->{$template};
        }
    }

    # reorder by count

    my $byCount;

    for my $template (keys %$byTemplate) {
        my $count = $byTemplate->{$template};
        $byCount->{$count}->{$template} = 1;
    }

    # output results

    my $result = '* ' . format_number($total) . " $text:\n";

    for my $count (reverse sort {$a <=> $b} keys %$byCount) {
        for my $template (sort keys %{$byCount->{$count}}) {
            $template = lcfirst $template;
            $result .= "** {{tl|$template}} × " . format_number($count) . "\n";
        }
    }

    return $result;
}

#
# Main
#

# command line options

my %opts;
getopts('hp', \%opts);

if ($opts{h}) {
    print "usage: citations-statistics.pl [-hp]\n";
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

print "Creating statistics ...\n";

my $b0 = Benchmark->new;

# generate statistics

my $bot = mybot->new($BOTINFO);

my @statistics;

push @statistics, templateStatistics($bot, 'citation', $CTEMPLATES, "{{cite xxx}} using {{para|journal}} or {{para|doi}}");
push @statistics, templateStatistics($bot, 'DOI', $DTEMPLATES, "total DOI templates");
push @statistics, articleStatistics($CITATIONS);
push @statistics, journalStatistics($CITATIONS);
push @statistics, doiStatistics($CITATIONS, $CTEMPLATES, $DTEMPLATES);

# output results

if ($print) {
    print "  generating output file ...\n";
    my $file = $ENV{'WIKI_WORKING_DIR'} . '/x-statistics-' . strftime('%H%M%S', localtime);
    open OUTPUT, '>:utf8', $file
        or die "ERROR: could not open file ($file)!\n$!\n";
    for my $statistic (@statistics) {
        print OUTPUT "$statistic\n";
    }
    close OUTPUT;
}
else {

    my $date = queryDate($DBTITLES);

    my $output = "{{columns-list|colwidth=30em|\n";

    for my $statistic (@statistics) {
        $output .= $statistic;
    }

    $output .= "}}\n";
    $output .= "The statistics are based on the [https://dumps.wikimedia.org/enwiki/ database dump] of {{date|$date}}<noinclude>\n";
    $output .= "{{DEFAULTSORT:* Statistics}}\n";
    $output .= "[[Category:Journals Cited by Wikipedia]]</noinclude>\n";

    print "  saving results ...\n";

    my $page = "Wikipedia:WikiProject Academic Journals/Journals cited by Wikipedia/Statistics";
    my ($old, $timestamp) = $bot->getText($page);
    $bot->saveText($page, $timestamp, $output, 'updating Wikipedia citation statistics', 'NotMinor', 'Bot');

}

my $b1 = Benchmark->new;
my $bd = timediff($b1, $b0);
my $bs = timestr($bd);
$bs =~ s/^\s*(\d+)\swallclock secs.*$/$1/;
print "  statistics processed in $bs seconds\n";