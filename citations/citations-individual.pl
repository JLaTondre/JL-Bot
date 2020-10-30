#!/usr/bin/perl

# This script generates the individual citation results for journals (WP:JCW/ALPHA)
# and magazines (WP:MCW/ALPHA).

use warnings;
use strict;

use Benchmark;
use File::Basename;

use lib dirname(__FILE__) . '/../modules';

use citations qw( checkInterwiki initial loadInterwiki requiresColon );
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

my $DBTITLES     = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-titles.sqlite3';
my $DBCITATIONS  = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-citations.sqlite3';
my $DBINDIVIDUAL = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-individual.sqlite3';
my $PREFIXES     = dirname(__FILE__) . '/interwiki-prefixes.cfg';

my @TYPES = qw(
    journal magazine
);

my @TABLES = (
    'CREATE TABLE individuals(type TEXT, letter TEXT, citation TEXT, dFormat TEXT, dType TEXT, target TEXT, tFormat TEXT, tType TEXT, cCount INTEGER, aCount INTEGER)',
);

my @INDEXES = (
    'CREATE INDEX indexType ON individuals(type)',
    'CREATE INDEX indexLetter ON individuals(letter)',
    'CREATE INDEX indexTarget ON individuals(target)',
    'CREATE INDEX indexICitation ON individuals(citation)'
);


#
# Subroutines
#

sub articleCount {

    # Format the article count

    my $articles = shift;

    my $count = keys %$articles;

    return $count if ($count > 5);

    my $formatted;

    my $index = 0;
    for my $article (sort keys %$articles) {
        $index++;
        $article = ":$article" if (requiresColon($article));
        $formatted .= ',&nbsp;' unless ($index == 1);
        $formatted .= "[[$article|$index]]";
    }

    return $formatted;
}

sub queryCitations {

    # Query all citations of specified type

    my $database = shift;
    my $type = shift;

    my $sth = $database->prepare(q{
        SELECT citation, article, count
        FROM citations
        WHERE type = ?
    });

    $sth->bind_param(1, $type);
    $sth->execute();

    my $results;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $citation = $ref->{'citation'};
        my $article = $ref->{'article'};
        my $count = $ref->{'count'};
        $results->{$citation}->{'articles'}->{$article} = 1;
        $results->{$citation}->{'count'} += $count;
    }

    return $results;
}

sub queryTitle {

    # Query information regarding a title from the database

    my $database = shift;
    my $title = shift;

    my $sth = $database->prepare(q{
        SELECT pageType, target, titleType
        FROM titles
        WHERE title = ?
    });
    $sth->bind_param(1, $title);
    $sth->execute();

    my $result;

    while (my $ref = $sth->fetchrow_hashref()) {
        $result->{'pageType'}  = $ref->{'pageType'};
        $result->{'target'}    = $ref->{'target'};
        $result->{'titleType'} = $ref->{'titleType'};
        last;
    }

    return $result;
}

sub storeOutput {

    # Store results to the database

    my $database = shift;
    my $type = shift;
    my $output = shift;

    print "  storing $type output ...\n";

    my $sth = $database->prepare(q{
        INSERT INTO individuals (type, letter, citation, dFormat, dType, target, tFormat, tType, cCount, aCount)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    });

    for my $citation (keys %$output) {
        my $dFormat = $output->{$citation}->{'d-format'};
        my $dType   = $output->{$citation}->{'d-type'};
        my $target  = $output->{$citation}->{'target'};
        my $tFormat = $output->{$citation}->{'t-format'};
        my $tType   = $output->{$citation}->{'t-type'};
        my $cCount  = $output->{$citation}->{'citations'};
        my $aCount  = $output->{$citation}->{'articles'};
        my $letter  = initial($citation);
        $sth->execute($type, $letter, $citation, $dFormat, $dType, $target, $tFormat, $tType, $cCount, $aCount);
    }
    $database->commit();

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

# generate individual output records from citations

print "Processing individual citations ...\n";

my $b0 = Benchmark->new;
my $total = 0;

# load information

my $prefixes = loadInterwiki($PREFIXES);

# delete existing database & create new one

print "  creating database ...\n";

if (-e $DBINDIVIDUAL) {
    unlink $DBINDIVIDUAL
        or die "ERROR: Could not delete database ($DBINDIVIDUAL)\n --> $!\n\n";
}

my $dbIndividual = citationsDB->new;
$dbIndividual->cloneDatabase($DBCITATIONS, $DBINDIVIDUAL);
$dbIndividual->openDatabase($DBINDIVIDUAL);
$dbIndividual->createTables(\@TABLES);

my $dbTitles = citationsDB->new;
$dbTitles->openDatabase($DBTITLES);

# process each citation type

for my $type (@TYPES) {

    print "  processing $type citations ...\n";

    my $citations = queryCitations($dbIndividual, $type);

    my $output;

    for my $citation (keys %$citations) {

        $total++;

        $output->{$citation}->{'citations'} = $citations->{$citation}->{'count'};
        $output->{$citation}->{'articles'} = articleCount($citations->{$citation}->{'articles'});

        my $interwiki = checkInterwiki($citation, $prefixes);
        if ($interwiki) {
            # citation results in an interwiki link
            $output->{$citation}->{'d-format'} = 'nowiki';
            $output->{$citation}->{'d-type'}   = 'default';
            $output->{$citation}->{'target'}   = $interwiki;
            $output->{$citation}->{'t-format'} = 'none';
            $output->{$citation}->{'t-type'}   = 'default';
        }
        elsif ($citation =~ /[#<>\[\]\|{}_]/) {
            # citation results in an invalid link
            $output->{$citation}->{'d-format'} = 'nowiki';
            $output->{$citation}->{'d-type'}   = 'default';
            $output->{$citation}->{'target'}   = 'Invalid';
            $output->{$citation}->{'t-format'} = 'none';
            $output->{$citation}->{'t-type'}   = 'default';
        }
        else {

            my $title = queryTitle($dbTitles, $citation);

            if ($title) {

                if ($title->{'pageType'} eq 'NORMAL') {
                    # citation results in normal page
                    $output->{$citation}->{'d-format'} = 'existent';
                    $output->{$citation}->{'d-type'}   = $title->{'titleType'};
                    $output->{$citation}->{'target'}   = $citation;
                    $output->{$citation}->{'t-format'} = 'normal';
                    $output->{$citation}->{'t-type'}   = $title->{'titleType'};
                }
                elsif ($title->{'pageType'} eq 'DISAMBIG') {
                    # citation results in disambiguation page
                    $output->{$citation}->{'d-format'} = 'disambiguation';
                    $output->{$citation}->{'d-type'}   = $title->{'titleType'};
                    $output->{$citation}->{'target'}   = $citation;
                    $output->{$citation}->{'t-format'} = 'normal';
                    $output->{$citation}->{'t-type'}   = $title->{'titleType'};
                }
                elsif (
                    ($title->{'pageType'} eq 'REDIRECT') and
                    ($title->{'target'} =~ /^?Category:/io)
                ) {
                    # citation results in redirect to category
                    $output->{$citation}->{'d-format'} = 'redirect';
                    $output->{$citation}->{'d-type'}   = $title->{'titleType'};
                    $output->{$citation}->{'target'}   = ":$title->{'target'}";
                    $output->{$citation}->{'t-format'} = 'normal';
                    $output->{$citation}->{'t-type'}   = 'default';
                }
                elsif (
                    ($title->{'pageType'} eq 'REDIRECT') and
                    ($title->{'target'} =~ /^?Template:/io)
                ) {
                    # citation results in redirect to template
                    $output->{$citation}->{'d-format'} = 'redirect';
                    $output->{$citation}->{'d-type'}   = $title->{'titleType'};
                    $output->{$citation}->{'target'}   = ":$title->{'target'}";
                    $output->{$citation}->{'t-format'} = 'normal';
                    $output->{$citation}->{'t-type'}   = 'default';
                }
                elsif (
                    ($title->{'pageType'} eq 'REDIRECT') or
                    ($title->{'pageType'} eq 'REDIRECT-UNNECESSARY')
                ) {
                    # citation results in redirect
                    my $redirect = queryTitle($dbTitles, $title->{'target'});
                    if ($redirect) {
                        while ($redirect->{'pageType'} eq 'REDIRECT') {
                            # resolve double redirects
                            $redirect = queryTitle($dbTitles, $redirect->{'target'});
                        }
                        if ($redirect->{'pageType'} eq 'NORMAL') {
                            # redirect to a normal page
                            $output->{$citation}->{'d-format'} = 'redirect';
                            $output->{$citation}->{'d-type'}   = $title->{'titleType'};
                            $output->{$citation}->{'target'}   = $title->{'target'};
                            $output->{$citation}->{'t-format'} = 'normal';
                            $output->{$citation}->{'t-type'}   = $redirect->{'titleType'};
                        }
                        elsif ($redirect->{'pageType'} eq 'DISAMBIG') {
                            # redirect to a disambiguation page
                            $output->{$citation}->{'d-format'} = 'redirect-disambiguation';
                            $output->{$citation}->{'d-type'}   = $title->{'titleType'};
                            $output->{$citation}->{'target'}   = $title->{'target'};
                            $output->{$citation}->{'t-format'} = 'normal';
                            $output->{$citation}->{'t-type'}   = $redirect->{'titleType'};
                        }
                        else {
                            die "ERROR: unknown redirect target type\ncitation = $citation\nredirect = $redirect->{'target'}\ntype = $redirect->{'pageType'}\n";
                        }
                    }
                    else {
                        # redirect to nonexistent page
                        warn "ERROR: redirect target was not found\ncitation = $citation\nredirect = $title->{'target'}\n\n";
                        $output->{$citation}->{'d-format'} = 'redirect';
                        $output->{$citation}->{'d-type'}   = $title->{'titleType'};
                        $output->{$citation}->{'target'}   = $title->{'target'};
                        $output->{$citation}->{'t-format'} = 'nonexistent';
                        $output->{$citation}->{'t-type'}   = 'default';
                    }
                }
                else {
                    die "ERROR: unknown page type\ncitation = $citation\ntype = $title->{'pageType'}\n\n";
                }

            }
            else {
                # citation results in nonexistent page
                $output->{$citation}->{'d-format'} = 'nonexistent';
                $output->{$citation}->{'d-type'}   = 'default';
                $output->{$citation}->{'target'}   = '&mdash;';
                $output->{$citation}->{'t-format'} = 'none';
                $output->{$citation}->{'t-type'}   = 'default';
            }

        }

    }

    storeOutput($dbIndividual, $type, $output);
}

# wrap up

$dbIndividual->createIndexes(\@INDEXES);
$dbIndividual->disconnect;
$dbTitles->disconnect;

my $b1 = Benchmark->new;
my $bd = timediff($b1, $b0);
my $bs = timestr($bd);
$bs =~ s/^\s*(\d+)\swallclock secs.*$/$1/;
print "  $total citations output in $bs seconds\n";
