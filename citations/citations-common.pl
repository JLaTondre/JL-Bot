#!/usr/bin/perl

# This script generates the most popular target results for journals (WP:JCW/TAR) and
# magazines (WP:MCW/TAR).

# This has significant overlap with citations-specified, but kept separate as handling
# magazine would over complicate citations-specified.

use warnings;
use strict;

use Benchmark;
use File::Basename;
use Getopt::Std;
use Text::LevenshteinXS qw( distance );

use lib dirname(__FILE__) . '/../modules';

use citations qw(
    findCitation
    findIndividual
    findNormalizations
    findRedirectExpansions
    formatCitation
    isUppercaseMatch
    loadRedirects
    normalizeCitation
    retrieveFalsePositives
    setFormat
);
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

my $DBTITLES     = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-titles.sqlite3';
my $DBINDIVIDUAL = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-individual.sqlite3';
my $DBCOMMON     = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-common.sqlite3';
my $BOTINFO      = $ENV{'WIKI_CONFIG_DIR'} .  '/bot-info.txt';

my @TYPES = qw(
    journal magazine
);

my %MAX = (
    'journal' => 3000,
    'magazine' => 500,
);

my $FALSEPOSITIVES = 'User:JL-Bot/Citations.cfg';

my @TABLES = (
    'CREATE TABLE commons(type TEXT, target TEXT, entries TEXT, entryCount INTEGER, lineCount INTEGER, articles TEXT, citations INTEGER)',
    'CREATE TABLE revisions(type TEXT, revision TEXT)',
);

my $BLOCK = 100;   # status size

#
# Subroutines
#

sub combineSpecified {

    # Combine specified targets along with redirects

    my $database = shift;
    my $type = shift;
    my $common = shift;

    print "  combining $type targets and redirects ...\n";

    my $combined;
    my $allRedirects;

    for my $selected (keys %$common) {
        $combined->{$selected} = undef;
        my $redirects = loadRedirects($database, $selected);
        for my $redirect (keys %$redirects) {
            next if ($redirect =~ /^10\.\d+$/);                         # skip DOI redirects
            $combined->{$redirect} = undef;
            $allRedirects->{$selected}->{$redirect} = 1;
        }
    }

    return $combined, $allRedirects;
}

sub generateResult {

    # Generate the final result for a given target

    my $selected = shift;
    my $specified = shift;
    my $redirects = shift;
    my $normalizations = shift;
    my $falsePositives = shift;
    my $type = shift;
    my $dbCommon = shift;
    my $dbTitles = shift;

    my $citations = {};             # citation format, counts, & articles

    # process record matches (if any)

    if (exists $specified->{$selected}->{'record'}) {
        my $record = $specified->{$selected}->{'record'};
        my $target = $record->{'target'};

        $citations->{$selected}->{'formatted'} = formatCitation($selected, $record);
        $citations->{$selected}->{'count'} = $record->{'citation-count'};
        $citations->{$selected}->{'articles'} = $record->{'articles'};

        # process normalization matches to record (if any)

        for my $normalization (keys %{$specified->{$selected}->{'record'}->{'normalizations'}}) {
            for my $match (keys %{$normalizations->{$normalization}}) {

                next if (exists $falsePositives->{$selected}->{$match});

                next if (exists $specified->{$match});                                      # matches self or other top level
                next if (isUppercaseMatch($match, $selected, $redirects->{$selected}));     # both uppercase

                my $record = $normalizations->{$normalization}->{$match};
                $citations->{$match}->{'formatted'} = formatCitation($match, $record);
                $citations->{$match}->{'count'} = $record->{'citation-count'};
                $citations->{$match}->{'articles'} = $record->{'articles'};
            }
        }
    }

    # process normalization matches to selected (if any)

    for my $normalization (keys %{$specified->{$selected}->{'normalizations'}}) {
        for my $match (keys %{$normalizations->{$normalization}}) {

            next if (exists $falsePositives->{$selected}->{$match});

            next if (exists $specified->{$match});                                      # matches self or other top level
            next if (isUppercaseMatch($match, $selected, $redirects->{$selected}));     # both uppercase

            my $record = $normalizations->{$normalization}->{$match};

            $citations->{$match}->{'formatted'} = formatCitation($match, $record);
            $citations->{$match}->{'count'} = $record->{'citation-count'};
            $citations->{$match}->{'articles'} = $record->{'articles'};
        }
    }

    # process redirects

    for my $redirect (keys %{$redirects->{$selected}}) {

        next if (exists $falsePositives->{$selected}->{$redirect});

        # process record matches (if any)

        if (exists $specified->{$redirect}->{'record'}) {
            my $record = $specified->{$redirect}->{'record'};

            die "selected =/= redirect! how...\n  selected = $selected\n  redirect = $redirect\n" if ($record->{'target'} ne $selected);    # check

            $citations->{$redirect}->{'formatted'} = formatCitation($redirect, $record);
            $citations->{$redirect}->{'count'} = $record->{'citation-count'};
            $citations->{$redirect}->{'articles'} = $record->{'articles'};

            # process normalization matches to redirect records (if any)

            for my $normalization (keys %{$specified->{$redirect}->{'record'}->{'normalizations'}}) {
                for my $match (keys %{$normalizations->{$normalization}}) {

                    next if (exists $falsePositives->{$selected}->{$match});
                    next if (exists $falsePositives->{$redirect}->{$match});

                    next if (exists $specified->{$match});                                      # matches self or other top level
                    next if (isUppercaseMatch($match, $redirect, $redirects->{$selected}));     # both uppercase
                    next if (isUppercaseMatch($match, $selected, $redirects->{$selected}));     # both uppercase

                    my $record = $normalizations->{$normalization}->{$match};

                    $citations->{$match}->{'formatted'} = formatCitation($match, $record);
                    $citations->{$match}->{'count'} = $record->{'citation-count'};
                    $citations->{$match}->{'articles'} = $record->{'articles'};
                }
            }
        }

        # process normalization matches to redirect (if any)

        for my $normalization (keys %{$specified->{$redirect}->{'normalizations'}}) {
            for my $match (keys %{$normalizations->{$normalization}}) {

                next if (exists $falsePositives->{$selected}->{$match});
                next if (exists $falsePositives->{$redirect}->{$match});

                next if (exists $specified->{$match});                                      # matches self or other top level
                next if (isUppercaseMatch($match, $redirect, $redirects->{$selected}));     # both uppercase
                next if (isUppercaseMatch($match, $selected, $redirects->{$selected}));     # both uppercase
                my $record = $normalizations->{$normalization}->{$match};

                $citations->{$match}->{'formatted'} = formatCitation($match, $record);
                $citations->{$match}->{'count'} = $record->{'citation-count'};
                $citations->{$match}->{'articles'} = $record->{'articles'};
            }
        }
    }

    # process redirect expansions for redirects

    for my $redirect (keys %{$redirects->{$selected}}) {
        my $records = findRedirectExpansions($dbCommon, $type, $redirect);
        for my $citation (keys %$records) {

            next if (exists $falsePositives->{$selected}->{$citation});
            next if (exists $falsePositives->{$redirect}->{$citation});

            # can occur multiple times via different redirects so include all

            my $record = $records->{$citation};

            $citations->{$citation}->{'formatted'} = formatCitation($citation, $record);
            $citations->{$citation}->{'count'} = $record->{'citation-count'};
            $citations->{$citation}->{'articles'} = $record->{'articles'};
        }
    }

    # create final output

    my $entries;

    for my $citation (sort keys %$citations) {
        $entries .= "* $citations->{$citation}->{'formatted'}\n";
    }

    my $totalCitations = 0;
    my $allArticles = {};
    for my $citation (keys %$citations) {
        $totalCitations += $citations->{$citation}->{'count'};
        $allArticles = {%$allArticles, %{$citations->{$citation}->{'articles'}}};
    }

    my $result->{'entries'} = $entries;
    $result->{'entryCount'} = () = $entries =~ / \(\d+ in /g;
    $result->{'lineCount'} = () = $entries =~ /\n/g;
    $result->{'articles'} = scalar keys %$allArticles;
    $result->{'citations'} = $totalCitations;

    return $result;
}

sub loadCommon {

    # Retrieve the top common targets

    my $database = shift;
    my $type = shift;
    my $max = shift;

    print "  retrieving $type targets ...\n";

    my $sth = $database->prepare('
        SELECT target, SUM(cCount)
        FROM individuals
        WHERE type = ?
        AND target NOT IN ("&mdash;", "LANGUAGE", "INTERWIKI", "Invalid")
        GROUP BY target
        ORDER BY SUM(cCount) DESC
        LIMIT ?
    ');
    $sth->bind_param(1, $type);
    $sth->bind_param(2, $max);
    $sth->execute();

    my $specified;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $target = $ref->{'target'};
        $specified->{$target} = 1;
    }

    return $specified;
}

sub saveResult {

    # Save the result to the database

    my $database = shift;
    my $type = shift;
    my $target = shift;
    my $result = shift;

    my $entries = $result->{'entries'};
    my $entryCount = $result->{'entryCount'};
    my $lineCount = $result->{'lineCount'};
    my $articles = $result->{'articles'};
    my $citations = $result->{'citations'};

    my $sth = $database->prepare(qq{
        INSERT INTO commons (type, target, entries, entryCount, lineCount, articles, citations)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    });
    $sth->execute($type, $target, $entries, $entryCount, $lineCount, $articles, $citations);

    return;
}

#
# Main
#

# handle UTF-8

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

# auto-flush output

$| = 1;

# generate output

print "Generating common targets ...\n";

my $p0 = Benchmark->new;

# delete existing database & create new one

print "  creating database ...\n";

if (-e $DBCOMMON) {
    unlink $DBCOMMON
        or die "ERROR: Could not delete database ($DBCOMMON)\n --> $!\n\n";
}

my $dbCommon = citationsDB->new;
$dbCommon->cloneDatabase($DBINDIVIDUAL, $DBCOMMON);
$dbCommon->openDatabase($DBCOMMON);
$dbCommon->createTables(\@TABLES);

my $dbTitles = citationsDB->new;
$dbTitles->openDatabase($DBTITLES);

# load false positives

my ($falsePositives, $fpRevision) = retrieveFalsePositives($BOTINFO, $FALSEPOSITIVES, $dbTitles);

my $sth = $dbCommon->prepare('INSERT INTO revisions VALUES (?, ?)');
$sth->execute('falsePositive', $fpRevision);
$dbCommon->commit;

# process each type

for my $type (@TYPES) {

    my $maximum = $MAX{$type} * 1.05;         # do more than max as initial numbers expand

    # find top common targets and their rediercts

    my $common = loadCommon($dbCommon, $type, $maximum);

    my ($specified, $redirects) = combineSpecified($dbTitles, $type, $common);

    # process specified

    print "  finding citations for specified ...\n";

    my $normalizations;

    for my $selected (keys %$specified) {
        my $citation = findCitation($dbCommon, $type, $selected);
        if ($citation) {
            $specified->{$selected}->{'record'} = $citation;
            for my $normalization (keys %{$citation->{'normalizations'}}) {
                $normalizations->{$normalization} = undef;
            }
        }
        else {
            my $normalization = normalizeCitation($selected);
            $specified->{$selected}->{'normalizations'}->{$normalization} = 1;
            $normalizations->{$normalization} = undef;
        }
    }

    # process normalizations

    my $current = 0;
    my $total = scalar keys %$normalizations;

    print "  processing normalizations ...\r";
    for my $normalization (keys %$normalizations) {
        $current++;
        if (($current % $BLOCK) == 0) {
            print "  processing normalizations $current of $total ...\r";
        }
        next if ($normalization eq '--');
        my $candidates = findNormalizations($dbCommon, $type, $normalization);
        for my $candidate (keys %$candidates) {
            my $result = findIndividual($dbCommon, $type, $candidate);
            $normalizations->{$normalization}->{$candidate} = $result if ($result);
        }
    }
    print "  processing normalizations ...                                  \n";

    # put it together

    print "  generating results ...\n";
    for my $target (keys %$common) {
        my $result = generateResult(
            $target,
            $specified,
            $redirects,
            $normalizations,
            $falsePositives,
            $type,
            $dbCommon,
            $dbTitles
        );
        saveResult($dbCommon, $type, $target, $result);
    }
    $dbCommon->commit;
}

$dbCommon->disconnect;
$dbTitles->disconnect;

my $p1 = Benchmark->new;
my $pd = timediff($p1, $p0);
my $ps = timestr($pd);
$ps =~ s/^\s*(\d+)\swallclock secs.*$/$1/;
print "  specified citations processed in $ps seconds\n";
