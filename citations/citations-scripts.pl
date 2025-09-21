#!/usr/bin/perl

# This script finds citations with multiple scripts and saves the results to Wikipedia.

use warnings;
use strict;

use Benchmark;
use File::Basename;
use Unicode::UCD 'charinfo';

use lib dirname(__FILE__) . '/../modules';

use citationsDB;
use mybot;

use feature 'state';
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

my $DBINDIVIDUAL = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-individual.sqlite3';
my $DBSCRIPTS    = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-scripts.sqlite3';
my $BOTINFO      = $ENV{'WIKI_CONFIG_DIR'}  . '/bot-info.txt';

my @TABLES = (
    'CREATE TABLE scripts(citation TEXT, annotated TEXT, dFormat TEXT, dType TEXT, target TEXT, tFormat TEXT, tType TEXT, cCount INTEGER, aCount INTEGER)',
    'CREATE TABLE legend(script TEXT, color TEXT)',
);

my @INDEXES = (
    'CREATE INDEX indexSCitation ON scripts(citation)',
    'CREATE INDEX indexAnnotated ON scripts(annotated)',
    'CREATE INDEX indexScript ON legend(script)',
);

my %COLORS = (
    'Arabic'    => 'Orange',
    'Cyrillic'  => 'Green',
    'Greek'     => 'Blue',
    'Han'       => 'DarkKhaki',
    'Hebrew'    => 'Indigo',
    'Hiragana'  => 'Violet',
    'Katakana'  => 'Violet',
    'Latin'     => 'Red',
    'other1'    => 'DeepSkyBlue',
    'other2'    => 'MediumPurple',
    'other3'    => 'DeepPink',
);

#
# Subroutines
#

sub annotateCitation {

    # Annotate citation with {{JCW-script|ScriptName|...}}

    my $citation = shift;

    # skip for certain cases
    return $citation if excludeCases($citation);

    # split into grapheme clusters
    my @grapheme_clusters;
    while ($citation =~ /(\X)/gu) { push @grapheme_clusters, $1 }

    my $output                = '';
    my $current_script        = '';
    my $current_run_content   = '';
    my $pending_neutral_text  = '';

    for my $cluster (@grapheme_clusters) {
        my $script = determineGraphemeClusterScript($cluster);

        if ($script eq 'Neutral') {
            # buffer neutrals so we can decide what to do once we see what's next
            $pending_neutral_text .= $cluster;
            next;
        }

        if ($current_script eq '') {
            # leading neutrals stay outside
            $output .= $pending_neutral_text;
            $pending_neutral_text = '';
            $current_script       = $script;
            $current_run_content  = $cluster;
            next;
        }

        if ($script eq $current_script) {
            # same script: absorb *all* buffered neutrals into the current run
            $current_run_content .= $pending_neutral_text . $cluster;
            $pending_neutral_text = '';
        } else {
            # script switch: flush the current run; neutrals stay outside (between scripts)
            if ($current_run_content ne '') {
                $output .= applyTemplate($citation, $current_script, $current_run_content);
            }
            $output .= $pending_neutral_text;  # neutrals between different scripts -> outside
            $pending_neutral_text = '';
            $current_script       = $script;
            $current_run_content  = $cluster;
        }
    }

    # flush any open run; trailing neutrals remain outside
    if ($current_run_content ne '') {
        $output .= applyTemplate($citation, $current_script, $current_run_content);
    }
    $output .= $pending_neutral_text;

    return $output;
}

sub applyTemplate {

    # Wrap content with formatting and tooltip

    my $citation = shift;
    my $script   = shift;
    my $content  = shift;

    state $current = 0;         # current citation being processed
    state %assigned;            # remembers colors for scripts not in %COLORS
    state $unseen = 0;          # how many non-%COLORS scripts we've assigned so far

    # if new citation, reset state
    if ($current ne $citation) {
        $current  = $citation;
        %assigned = ();
        $unseen   = 0;
    }

    # determine color
    my $color;
    if (exists $COLORS{$script}) {
        # known script color from the table
        $color = $COLORS{$script};
    } elsif (exists $assigned{$script}) {
        # reuse previously assigned color for this unknown script
        $color = $assigned{$script};
    } else {
        # assign based on first, second, or subsequent unseen scripts
        $unseen++;
        my $bucket = $unseen == 1 ? 'other1'
                   : $unseen == 2 ? 'other2'
                   :                'other3';
        $color = $COLORS{$bucket};
        $assigned{$script} = $color;
    }
    my $style = $color ? "style='color: $color;'" : '';

    # return annotated content
    return "<span class='tooltip' $style title='$script'><nowiki>$content</nowiki></span>";
}

sub determineCodePointScript {

    # Determine Unicode script name; return 'Neutral' for Common/Inherited

    my $code_point = shift;

    my $character = chr $code_point;

    return 'Neutral' if $character =~ /\p{sc=Common}|\p{sc=Inherited}/;

    my $info   = charinfo($code_point) // {};
    my $script = $info->{script} || $info->{block} || sprintf("U+%04X", $code_point);

    # remove underscores in names like Old_Persian -> Old Persian
    $script =~ s/_/ /g;

    return $script;
}

sub determineGraphemeClusterScript {

    # Determine the script of a grapheme cluster: first strong (non-neutral) wins

    my $grapheme_cluster = shift;

    for my $code_point (unpack 'U*', $grapheme_cluster) {
        my $script = determineCodePointScript($code_point);
        return $script if $script ne 'Neutral';
    }

    return 'Neutral';
}

sub excludeCases {

    # Exclude certain cases from processing

    my $citation = shift;

    # exclude if only Latin + neutrals (no need to mark up)
    return 1 if $citation =~ /^[\p{sc=Latin}\p{sc=Common}\p{sc=Inherited}]+$/u;

    # find the first non-Latin, non-Common, non-Inherited code point's script (use script extensions for matching)
    my ($first) = $citation =~ /([^\p{sc=Latin}\p{sc=Common}\p{sc=Inherited}])/u;
    my $info    = charinfo(ord $first) // {};
    my $script  = $info->{script} // 'Unknown';

    # exclude if only single non-Latin script + neutrals
    return 1 if $citation =~ /^[\p{scx=$script}\p{sc=Common}\p{sc=Inherited}]+$/u;

    # exclude if 3+ Latin plus neutrals plus 3+ single other script
    return 1 if $citation =~ /
        ^                                                   # start of string
        [\p{sc=Common}\p{sc=Inherited}]*                    # optional leading neutrals
        (?:
            \p{sc=Latin}{3,}                                        # EITHER 3+ contiguous Latin
        |   \p{sc=Latin}{1,2}[\p{sc=Common}\p{sc=Inherited}]+       # OR 1-2 Latin + neutrals +
            \p{sc=Latin}{3,}                                        #   then 3+ Latin
        )
        [\p{sc=Common}\p{sc=Inherited}\p{sc=Latin}]*?       # optional more Latin with neutrals
        [\p{sc=Common}\p{sc=Inherited}]+                    # one or more neutrals
        (?:
            \p{scx=$script}{3,}                                         # EITHER 3+ contiguous other script
        |   \p{scx=$script}{1,2}[\p{sc=Common}\p{sc=Inherited}]+        # OR 1-2 other script + neutrals +
            \p{scx=$script}{3,}                                         #   then 3+ other script
        )
        [\p{sc=Common}\p{sc=Inherited}\p{scx=$script}]*?    # optional more other script with neutrals
        [\p{sc=Common}\p{sc=Inherited}]*                    # optional trailing neutrals
        $                                                   # end of string
    /xu;

    # exclude if 3+ single other script plus neutrals plus 3+ Latin
    return 1 if $citation =~ /
        ^                                                   # start of string
        [\p{sc=Common}\p{sc=Inherited}]*                    # optional leading neutrals
        (?:
            \p{scx=$script}{3,}                                         # EITHER 3+ contiguous other script
        |   \p{scx=$script}{1,2}[\p{sc=Common}\p{sc=Inherited}]+        # OR 1-2 other script + neutrals +
            \p{scx=$script}{3,}                                         #   then 3+ other script
        )
        [\p{sc=Common}\p{sc=Inherited}\p{scx=$script}]*?    # optional more other script with neutrals
        [\p{sc=Common}\p{sc=Inherited}]+                    # one or more neutrals
        (?:
            \p{sc=Latin}{3,}                                        # EITHER 3+ contiguous Latin
        |   \p{sc=Latin}{1,2}[\p{sc=Common}\p{sc=Inherited}]+       # OR 1-2 Latin + neutrals +
            \p{sc=Latin}{3,}                                        #   then 3+ Latin
        )
        [\p{sc=Common}\p{sc=Inherited}\p{sc=Latin}]*?       # optional more Latin with neutrals
        [\p{sc=Common}\p{sc=Inherited}]*                    # optional trailing neutrals
        $                                                   # end of string
    /xu;

    return 0;
}

sub retrieveIndividual {

    # Retrieve individual results from database

    my $database = shift;
    my $row = shift;

    my $sth = $database->prepare("
        SELECT citation, dFormat, dType, target, tFormat, tType, cCount, aCount
        FROM individuals
        WHERE type = 'journal'
    ");
    $sth->execute();

    my $records;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $citation = $ref->{'citation'};
        $records->{$citation}->{'d-format'} = $ref->{'dFormat'};
        $records->{$citation}->{'d-type'} = $ref->{'dType'};
        $records->{$citation}->{'target'} = $ref->{'target'};
        $records->{$citation}->{'t-format'} = $ref->{'tFormat'};
        $records->{$citation}->{'t-type'} = $ref->{'tType'};
        $records->{$citation}->{'citations'} = $ref->{'cCount'};
        $records->{$citation}->{'articles'} = $ref->{'aCount'};
    }

    return $records;
}

#
# Main
#

# handle UTF-8

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

# auto-flush output

$| = 1;

# find multi-script citations

print "Processing multi-script citations ...\n";

my $b0 = Benchmark->new;

# delete existing database & create new one

print "  creating database ...\n";

if (-e $DBSCRIPTS) {
    unlink $DBSCRIPTS
        or die "ERROR: Could not delete database ($DBSCRIPTS)\n --> $!\n\n";
}

my $database = citationsDB->new;
$database->cloneDatabase($DBINDIVIDUAL, $DBSCRIPTS);
$database->openDatabase($DBSCRIPTS);
$database->createTables(\@TABLES);

# retrieve individual results & process them

print "  processing citations ...\n";

my $records = retrieveIndividual($database);

my $sth = $database->prepare(q{
    INSERT INTO scripts(citation, annotated, dFormat, dType, target, tFormat, tType, cCount, aCount)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
});

for my $citation (sort keys %{$records}) {

    my $annotated = annotateCitation($citation);
    if ($annotated ne $citation) {

        my $dFormat = $records->{$citation}->{'d-format'};
        my $dType   = $records->{$citation}->{'d-type'};
        my $target  = $records->{$citation}->{'target'};
        my $tFormat = $records->{$citation}->{'t-format'};
        my $tType   = $records->{$citation}->{'t-type'};
        my $cCount  = $records->{$citation}->{'citations'};
        my $aCount  = $records->{$citation}->{'articles'};

        $sth->execute($citation, $annotated, $dFormat, $dType, $target, $tFormat, $tType, $cCount, $aCount);

    }

}
$database->commit();

# save legend

print "  saving legend ...\n";

for my $script (sort keys %COLORS) {
    my $color = $COLORS{$script};
    $sth = $database->prepare(q{
        INSERT INTO legend(script, color)
        VALUES (?, ?)
    });
    $sth->execute($script, $color);
}
$database->commit();

# wrap-up

$database->createIndexes(\@INDEXES);
$database->commit;
$database->disconnect;

my $total = keys %{$records};

my $b1 = Benchmark->new;
my $bd = timediff($b1, $b0);
my $bs = timestr($bd);
$bs =~ s/^\s*(\d+)\swallclock secs.*$/$1/;
print "  $total citations processed in $bs seconds\n";
