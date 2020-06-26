#!/usr/bin/perl

# This script is used to test changes in the normalization code. It compares the
# current normalization results with the last version and shows any deltas.

use warnings;
use strict;

use File::Basename;

use lib dirname(__FILE__) . '/../modules';

use citations qw( normalizeCitation );
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

my $DBEXTRACT = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-citations.sqlite3';

#
# Subroutines
#

#
# Main
#

# handle UTF-8

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

# auto-flush output

$| = 1;

# open database

my $database = citationsDB->new;
$database->openDatabase($DBEXTRACT);

my $sth = $database->prepare(q{
    SELECT citation, normalization
    FROM normalizations
    ORDER BY type ASC, citation ASC, normalization ASC, length ASC
});
$sth->execute();

while (my $ref = $sth->fetchrow_hashref()) {
    my $citation = $ref->{'citation'};
    my $original = $ref->{'normalization'};

    my $current1 = normalizeCitation($citation);

    $_ = $citation;
    if (s/ \((?:journal|magazine)\)$//o) {
        my $current2 = normalizeCitation($_);
        if (($original ne $current1) and ($original ne $current2)) {
            print "$citation\n";
            print "  < $original\n";
            print "  > $current1\n";
            print "  > $current2\n\n";
        }
    }
    elsif ($original ne $current1) {
        print "$citation\n";
        print "  < $original\n";
        print "  > $current1\n\n";
    }

}

$database->disconnect;