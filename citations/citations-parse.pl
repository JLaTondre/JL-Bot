#!/usr/bin/perl

# This script parses the Wikipedia database dump to pull out the citation & doi
# templates as well as the title information.

use warnings;
use strict;

use Benchmark;
use File::Basename;
use Getopt::Std;
use HTML::Entities;
use MediaWiki::DumpFile::FastPages;
use Number::Format qw(:subs);

use lib dirname(__FILE__) . '/../modules';

use citations qw( findTemplates );
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

my $DATABASE   = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-titles.sqlite3';
my $CTEMPLATES = $ENV{'WIKI_WORKING_DIR'} . '/Citations/templates-citation';
my $DTEMPLATES = $ENV{'WIKI_WORKING_DIR'} . '/Citations/templates-doi';
my $BOTINFO    = $ENV{'WIKI_CONFIG_DIR'} .  '/bot-info.txt';

my @CITATIONS = (
    'Template:Citation',
    'Template:Cite AV media',
    'Template:Cite AV media notes',
    'Template:Cite book',
    'Template:Cite conference',
    'Template:Cite encyclopedia',
    'Template:Cite interview',
    'Template:Cite journal',
    'Template:Cite magazine',
    'Template:Cite map',
    'Template:Cite news',
    'Template:Cite newsgroup',
    'Template:Cite podcast',
    'Template:Cite press release',
    'Template:Cite report',
    'Template:Cite serial',
    'Template:Cite sign',
    'Template:Cite speech',
    'Template:Cite techreport',
    'Template:Cite thesis',
    'Template:Cite web',
    'Template:Bluebook journal',
    'Template:Vcite journal',
    'Template:Vcite2 journal',
    'Template:Cite LSA',
);

my @DOI = (
    'Template:doi',
    'Template:doi-inline',
);

my $DISAMBIG = 'Category:Disambiguation message boxes';

my @ISO4 = (
    'Template:R from ISO 4 abbreviation',
);

my @BLUEBOOK = (
    'Template:R from Bluebook abbreviation',
);

my @MATHSCINET = (
    'Template:R from MathSciNet abbreviation',
);

my @NLM = (
    'Template:R from NLM abbreviation',
);

my @UNNECESSARY = (
    'Template:R from unnecessary disambiguation',
);

my @TABLES = (
    'CREATE TABLE titles(title TEXT, pageType TEXT, target TEXT, titleType TEXT)',
    'CREATE TABLE revisions(type TEXT, revision TEXT)',
);

my @INDEXES = (
    'CREATE INDEX indexTitle ON titles(title)',
    'CREATE INDEX indexPageType ON titles(pageType)',
    'CREATE INDEX indexTarget ON titles(target)',
);

my $BLOCK = 10000;   # transaction & status size

#
# Subroutines
#

sub buildNamespacePattern {

    # Build an OR pattern for matching namespaces.

    my $bot = shift;

    print "Building namespace pattern ...\n";

    my $namespaces = $bot->getNamespaces;

    my $pattern = '';

    for my $namespace (sort keys %$namespaces) {
        $pattern .= $namespace . '|';
    }

    $pattern =~ s/\|$//;

    $pattern = qr/^(?:$pattern):/io;

    return $pattern;
}

sub buildTemplatePatternCategory {

    # Build an OR pattern for matching templates from a category.

    my $bot      = shift;
    my $category = shift;
    my $name     = shift;

    print "Building $name pattern ...\n";

    my $templates = $bot->getCategoryMembers($category, 10);

    my $pattern = '';

    for my $template (sort keys %$templates) {

        $pattern .= $template . '|';

        my $redirects = $bot->getRedirects($template, 10);
        for my $redirect (sort keys %$redirects) {
            $pattern .= $redirect . '|';
        }

    }

    $pattern =~ s/Template://g;
    $pattern =~ s/ /\[ _\]\+/g;
    $pattern =~ s/\|$//;

    $pattern = qr/\{\{\s*(?:Template\s*:\s*)?(?:$pattern)\s*(?:\||\})/i;

    return $pattern;
}

sub buildTemplatePatternTemplates {

    # Build an OR pattern for matching templates from templates.

    my $bot       = shift;
    my $templates = shift;
    my $name      = shift;

    print "Building $name pattern ...\n";

    my $pattern = '';

    for my $template (@$templates) {

        $pattern .= $template . '|';

        my $redirects = $bot->getRedirects($template, 10);
        for my $redirect (sort keys %$redirects) {
            $pattern .= $redirect . '|';
        }

    }

    $pattern =~ s/Template://g;
    $pattern =~ s/ /\[ _\]\+/g;
    $pattern =~ s/\|$//;

    $pattern = qr/\{\{\s*(?:Template\s*:\s*)?(?:$pattern)\s*[\|\}]/i;

    return $pattern;
}

sub pageType {

    # Determine the page type (NORMAL, DISAMBIG, REDIRECT).

    my $text     = shift;
    my $dPattern = shift;
    my $uPattern = shift;

    if ($text =~ /^\s*#redirect\s*:?\s*\[\[\s*:?\s*(.+?)\s*(?:\]|(?<!&)#|\n|\|)/i) {
        my $target = $1;
        $target = decode_entities($target);
        $target =~ s/%26/&/;
        $target =~ tr/_/ /;
        $target =~ s/ {2,}/ /g;
        $target =~ s/^ //;
        $target =~ s/ $//;
        $target = ucfirst $target;
        if ($text =~ /$uPattern/) {
            return ('REDIRECT-UNNECESSARY', $target);
        }
        return ('REDIRECT', $target);
    }

    if ($text =~ /$dPattern/) {
        return ('DISAMBIG', '--');
    }

    return ('NORMAL', '--');
}

sub saveDate {

    # Parse the dump date from the dump file name & save to database

    my $database = shift;
    my $file = shift;

    if ($file =~ /enwiki-(\d{4})(\d{2})(\d{2})-pages-articles/) {
        my $date = "$1-$2-$3";
        my $sth = $database->prepare('INSERT INTO revisions VALUES (?, ?)');
        $sth->execute('date', $date);
        $database->commit;
    }
    else {
        die "ERROR: Could not parse dump date ($file)!\n\n";
    }

    return;
}

sub saveTitles {

    # save titles to database as single transaction

    my $database = shift;
    my $titles = shift;

    my $sth = $database->prepare(q{
        INSERT INTO titles (title, pageType, target, titleType) VALUES (?, ?, ?, ?)
    });

    for my $title (keys %$titles) {
        $sth->execute($title, $titles->{$title}->{pageType}, $titles->{$title}->{target}, $titles->{$title}->{titleType});
    }
    $database->commit;

    return;
}

sub titleType {

    # Determines the title type.

    my $title    = shift;
    my $text     = shift;
    my $isoregex = shift;
    my $bbregex  = shift;
    my $msnregex = shift;
    my $nlmregex = shift;

    my $journalregex = qr/
        (?:
          abh(?:andlungen|\.)?
        | ann(?:als?|\.)?
        | berichte
        | bull(?:etin|\.)?
        | cahiers
        | c(?:omptes|\.)?\s?r(?:endus|\.)?
        | j(?:ournal|\.)?
        | lett(?:ers?|\.)?
        | not(?:ices?|\.)?
        | proc(?:eedings?|\.)?
        | publications\s+of
        | publ\.?
        | rev(?:iews?|\.)?
        | trans(?:actions?|\.)?
        | z(?:eitschrift|\.)?
        )
    /iox;

    my $magazineregex = qr/
        (?:
          digest
        | mag(?:azine|\.)?
        | newsl(?:etter|\.)?
        | (?:fan|web)zine
        )
    /iox;

    my $newspaperregex = qr/
        (?:
          chronicle
        | courier
        | daily
        | echo
        | gazette
        | herald
        | mail
        | newspaper
        | post
        | standard
        | star
        | Sun(?:day)?
        | tabloid
        | telegraph
        | times
        | tribune
        )
    /iox;

    my $websiteregex = qr/
        (?:
          website
        | www\.
        | \.org
        | \.com
        | \.gov
        )
    /iox;

    my $bookregex = qr/
        (?:
          anthology
        | book
        | dictionary
        | encyclop(?:e|ae|æ)dia
        | handbook
        )
    /iox;

    my $databaseregex = qr/
        (?:
          catalog(?:ue)?
        | database
        )
    /iox;

    my $publisherregex = qr/
        (?:
          academy
        | agency
        | association
        | books
        | comm(?:ission|ittee)
        | co(?:mpany|\.)?
        | corporation
        | école
        | [eé]ditions
        | gmbh
        | group
        | imprint
        | inc\.?
        | institute
        | ltd\.?
        | museum
        | organi(?:s|z)ation
        | press(?:es)?
        | \w+ publications
        | publish(?:ers?|ing)
        | school
        | society
        | sons
        | university
        )
    /iox;

    # check {{R from ISO 4}} first
    # check {{R from Bluebook abbreviation}} second
    # check {{R from MathSciNet abbreviation}} third
    # check {{R from NLM abbreviation}} fourth
    # check 'TITLE (type)' fifth
    # check category sixth
    # check title seventh

    if ($text =~ /$isoregex/o) {
        return 'iso';
    }
    elsif ($text =~ /$bbregex/o) {
        return 'bluebook';
    }
    elsif ($text =~ /$msnregex/o) {
        return 'math';
    }
    elsif ($text =~ /$nlmregex/o) {
        return 'nlm';
    }
    elsif (
        ($title =~ /\([^\)]*\b${journalregex}\)$/o) and
        ($title =~ /\([^\)]*\b${magazineregex}\)$/o)
    ) {
        return 'journal+magazine';
    }
    elsif ($title =~ /\([^\)]*\b${journalregex}\)$/o) {
        return 'journal';
    }
    elsif ($title =~ /\([^\)]*\b${magazineregex}\)$/o) {
        return 'magazine';
    }
    elsif ($title =~ /\([^\)]*\b${newspaperregex}\)$/o) {
        return 'newspaper';
    }
    elsif ($title =~ /\([^\)]*\bwebsite\)$/io) {
        return 'website';
    }
    elsif ($title =~ /\([^\)]*\b${bookregex}\)$/io) {
        return 'book';
    }
    elsif ($title =~ /\([^\)]*\b${databaseregex}\)$/io) {
        return 'database';
    }
    elsif ($title =~ /\([^\)]*\b${publisherregex}\)$/o) {
        return 'publisher';
    }
    elsif (
        ($text =~ /\[\[\s*Category:[^\]]*\b(?:annals|journals|proceedings|transactions)\b/io) and
        ($text =~ /\[\[\s*Category:[^\]]*\b(?:digests|magazines|newsletters|(?:fan|web)zines)\b/io)
    ) {
        return 'journal+magazine';
    }
    elsif ($text =~ /\[\[\s*Category:[^\]]*\b(?:annals|journals|proceedings|transactions)\b/io) {
        return 'journal';
    }
    elsif ($text =~ /\[\[\s*Category:[^\]]*\b(?:digests|magazines|newsletters|(?:fan|web)zines)\b/io) {
        return 'magazine';
    }
    elsif ($text =~ /\[\[\s*Category:[^\]]*\b(?:gazettes|newspapers|tabloids)\b/io) {
        return 'newspaper';
    }
    elsif ($text =~ /\[\[\s*Category:[^\]]*\bwebsites\b/io) {
        return 'website';
    }
    elsif ($text =~ /\[\[\s*Category:[^\]]*\b(?:anthologies|books|dictionaries|encyclopedias|handbooks)\b/io) {
        return 'book';
    }
    elsif ($text =~ /\[\[\s*Category:[^\]]*\b(?:catalog(?:ue)s|databases)\b/io) {
        return 'database';
    }
    elsif ($text =~ /\[\[\s*Category:[^\]]*\b(?:academies|agencies|associations|commissions|committees|companies|corporations|imprints|institutes|museums|organi(?:s|z)ations|presses|publishers|schools|societies|universities)\b/io) {
        return 'publisher';
    }
    elsif (
        ($title =~ /\b$journalregex\b/o) and
        ($title =~ /\b$magazineregex\b/o)
    ) {
        return 'journal+magazine';
    }
    elsif ($title =~ /\b$journalregex\b/o) {
        return 'journal';
    }
    elsif ($title =~ /\b$magazineregex\b/o) {
        return 'magazine';
    }
    elsif ($title =~ /\b$newspaperregex\b/o) {
        return 'newspaper';
    }
    elsif ($title =~ /\b$websiteregex\b/io) {
        return 'website';
    }
    elsif ($title =~ /\b$databaseregex\b/io) {
        return 'database';
    }
    elsif ($title =~ /\b$bookregex\b/io) {
        return 'book';
    }
    elsif ($title =~ /\b$publisherregex\b/o) {
        return 'publisher';
    }

    return 'default';
}

#
# Main
#

# command line options

my %opts;
getopts('ht', \%opts);

if ($opts{h}) {
    print "usage: citations-1-parse.pl [-h] <file>\n";
    print "       where: -h = help\n";
    exit;
}

my $file = $ARGV[0];                    # specify file to process

if (not $file) {
    die "usage: citations-parse.pl [-h] <file>\n";
}

# handle UTF-8

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

# auto-flush output

$| = 1;

# benchmark

my $b0 = Benchmark->new;

# initialize bot

my $bot = mybot->new($BOTINFO);

# retrieve patterns

my $pCitation = buildTemplatePatternTemplates($bot, \@CITATIONS, 'citation');
my $pDoi = buildTemplatePatternTemplates($bot, \@DOI, 'doi');
my $pDisambig = buildTemplatePatternCategory($bot, $DISAMBIG, 'disambig');
my $pISO4redirect = buildTemplatePatternTemplates($bot, \@ISO4, 'ISO4');
my $pBBredirect = buildTemplatePatternTemplates($bot, \@BLUEBOOK, 'Bluebook');
my $pMSNredirect = buildTemplatePatternTemplates($bot, \@MATHSCINET, 'MathSciNet');
my $pNLMredirect = buildTemplatePatternTemplates($bot, \@NLM, 'NLM');
my $pUnnecessary = buildTemplatePatternTemplates($bot, \@UNNECESSARY, 'unnecessary');
my $pNamespace = buildNamespacePattern($bot);

# delete existing files & create new one

if (-e $CTEMPLATES) {
    unlink $CTEMPLATES
        or die "ERROR: Could not delete file ($CTEMPLATES)\n  --> $!\n\n";
}

open CTEMPLATES, '>:utf8', $CTEMPLATES
    or die "ERROR: Could not open file ($CTEMPLATES)\n  --> $!\n\n";

if (-e $DTEMPLATES) {
    unlink $DTEMPLATES
        or die "ERROR: Could not delete file ($DTEMPLATES)\n  --> $!\n\n";
}

open DTEMPLATES, '>:utf8', $DTEMPLATES
    or die "ERROR: Could not open file ($DTEMPLATES)\n  --> $!\n\n";

# delete existing database and open new one

print "Creating database...\n";

if (-e $DATABASE) {
    unlink $DATABASE
        or die "ERROR: Could not delete database ($DATABASE)\n  --> $!\n\n";
}

my $database = citationsDB->new;
$database->openDatabase($DATABASE);
$database->createTables(\@TABLES);

# save dump file date

saveDate($database, $file);

# parse database file

print "Parsing database dump...\n";

my $pages = MediaWiki::DumpFile::FastPages->new($file);

my $cTitles    = 0;
my $cCitations = 0;

my $titles = {};

while (my ($title, $text) = $pages->next) {

    # ignore non-article namespace (not sure why even in dump)

    next if ($title =~ /$pNamespace/);

    $cTitles++;

    if (($cTitles % $BLOCK) == 0) {
        print '  count = ' .  format_number($cTitles) . "\r";
        saveTitles($database, $titles);
        $titles = {};
    }

    # process title & only proceed if not a redirect

    my ($pageType, $target) = pageType($text, $pDisambig, $pUnnecessary);
    my $titleType = titleType($title, $text, $pISO4redirect, $pBBredirect, $pMSNredirect, $pNLMredirect);

    $titles->{$title}->{pageType}  = $pageType;
    $titles->{$title}->{target}    = $target;
    $titles->{$title}->{titleType} = $titleType;

    next if ($pageType eq 'REDIRECT');

    # skip unless contains journal|magazine|doi parameter or doi template

    next unless (
        ($text =~ /(?:journal|magazine|doi)\s*=/) or           # can be comment before parameter
        ($text =~ /^$pDoi/)
    );

    # check for and process templates

    my $templates = findTemplates($text);

    for my $template (@$templates) {

        if (
            ($template =~ /^$pCitation/) and
            ($template =~ /(?:journal|magazine|doi)\s*=(?!\s*\|)/)      # skip empty fields
        ) {

            $template =~ s/\n/ /g;
            $template =~ s/\s{2,}/ /g;

            $cCitations++;

            print CTEMPLATES "$title\t$template\n";

        }
        elsif ($template =~ /^$pDoi/) {

            $template =~ s/\n/ /g;
            $template =~ s/\s{2,}/ /g;

            $cCitations++;

            print DTEMPLATES "$title\t$template\n";

        }

    }
}

saveTitles($database, $titles);      # need to save any remaining ones

# wrap-up

$database->createIndexes(\@INDEXES);
$database->disconnect;

close CTEMPLATES;
close DTEMPLATES;

my $b1 = Benchmark->new;
my $bd = timediff($b1, $b0);
my $bs = timestr($bd);
$bs =~ s/^\s*(\d+)\swallclock secs.*$/$1/;
print "  $cTitles titles & $cCitations citations processed in $bs seconds\n";
