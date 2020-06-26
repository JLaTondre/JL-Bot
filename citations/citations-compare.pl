#!/usr/bin/perl

# This script allows the comparison of results between two runs.  It uses the output
# from wiki-bot-citations -a

use warnings;
use strict;

use utf8;

#
# Subroutines
#

sub readFile {

    my $file = shift;

    open FILE, '<:utf8', $file
        or die "\nError: Could not open file ($file)!\n  --> $!\n\n";

    my $records;
    my $current;

    while (<FILE>) {

        chomp;

        if (/^(.*?)\|\*\s+(.*?)\s\((\d+ in .*)\)$/) {
            $current = $1;
            my $entry = $2;
            my $counts = $3;
            unless ($current and $entry and ($counts)) {
                print "$_\n";
                print "failed to extract target\n" unless ($current);
                print "failed to extract entry\n" unless ($entry);
                print "failed to extract counts\n" unless ($counts);
                exit(1);
            }
            $records->{$current}->{'entries'}->{$entry} = $counts;
        }
        elsif (/^(.*?)\|\*\s(.*)$/) {
            $current = $1;
            my $entry = $2;
            unless ($current and $entry) {
                print "$_\n";
                print "failed to extract target\n" unless ($current);
                print "failed to extract entry\n" unless ($entry);
                exit(1);
            }
            $records->{$current}->{'entries'}->{$entry} = 'NONE';
        }
        elsif (/^\*+\s+(.*?)\s\((\d+ in .*)\)$/) {
            my $entry = $1;
            my $counts = $2;
            unless ($entry) {
                print "$_\n";
                print "failed to extract entry\n" unless ($entry);
                exit(1);
            }
            $records->{$current}->{'entries'}->{$entry} = $counts;
        }
        elsif (/^\*+\s+(.*)$/) {
            my $entry = $1;
            unless ($entry) {
                print "$_\n";
                print "failed to extract entry\n" unless ($entry);
                exit(1);
            }
            $records->{$current}->{'entries'}->{$entry} = 'NONE';
        }
        elsif (/^\|\d+?\|\d+?\|(\d+?)\|(\d+?)$/) {                      # common format
            my $articles = $1;
            my $citations = $2;
            $records->{$current}->{'articles'} = $articles;
            $records->{$current}->{'citations'} = $citations;
        }
        elsif (/^\|\d+?\|\d+?\|(\d+?)\|(\d+?)\|.*?\|.*?\|(.*?)$/) {     # specified format
            my $articles = $1;
            my $citations = $2;
            my $doi = $3;
            $records->{$current}->{'articles'} = $articles;
            $records->{$current}->{'citations'} = $citations;
            $records->{$current}->{'doi'} = $doi;
        }
        else {
            die "unknown line format!\n$_\n";
        }
    }

    close FILE;

    return $records;
}

#
# Main
#

my $file1 = $ARGV[0];
my $file2  = $ARGV[1];

unless ($file1 and $file2) {
    print "usage: file1 file2\n";
    print "       where: file1 is file to prior results\n";
    print "              file2 is file to new results\n";
    exit(1);
}

unless ((-e $file1) and (-e $file2)) {
    unless (-e $file1) {
        print "$file1 is not a readable file\n";
    }
    unless (-e $file2) {
        print "$file2 is not a readable file\n";
    }
    exit(1);
}

my $original = readFile($file1);
my $compared = readFile($file2);

# handle UTF-8

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

# compare first file to second

for my $record (sort keys %$original) {
    my $status = 0;
    if (not exists $compared->{$record}) {
        print "$record is only in first file\n";
        $status++;
    }
    else {
        # compare entries
        for my $entry (sort keys %{$original->{$record}->{'entries'}}) {
            if (not exists $compared->{$record}->{'entries'}->{$entry}) {
                print "$record :: $entry is only in first file\n";
            }
            else {
                if ($original->{$record}->{'entries'}->{$entry} ne $compared->{$record}->{'entries'}->{$entry}) {
                    (my $count1 = $original->{$record}->{'entries'}->{$entry}) =~ s/ in .*$//;
                    (my $count2 = $compared->{$record}->{'entries'}->{$entry}) =~ s/ in .*$//;
                    print "$record :: $entry counts do not match : $count1 =/= $count2\n";
                }
                delete $compared->{$record}->{'entries'}->{$entry};
            }
        }
        for my $entry (sort keys %{$compared->{$record}->{'entries'}}) {
            print "$record :: $entry is only in second file\n";
            $status++;
        }
        # compare citations
        my $citations1 = $original->{$record}->{'citations'};
        my $citations2 = $compared->{$record}->{'citations'};
        if ($citations1 != $citations2) {
            print "$record :: citations count does not match : $citations1 =/= $citations2\n";
            $status++;
        }
        # compare articles
        my $articles1 = $original->{$record}->{'articles'};
        my $articles2 = $compared->{$record}->{'articles'};
        if ($articles1 != $articles2) {
            print "$record :: article count does not match : $articles1 =/= $articles2\n";
            $status++;
        }
        # compare doi
        if (exists $original->{$record}->{'doi'}) {
            my $doi1 = $original->{$record}->{'doi'};
            my $doi2 = $compared->{$record}->{'doi'};
            if ($doi1 ne $doi2) {
                print "$record :: doi does not match : $doi1 =/= $doi2\n";
                $status++;
            }
        }
        delete $compared->{$record};
    }
    print "\n" if ($status);
}

# check if any entries remaining in second file

for my $record (sort keys %$compared) {
    print "$record is only in second file\n";
}