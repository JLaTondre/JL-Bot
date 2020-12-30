#!/usr/bin/perl

# This script saves the results to Wikipedia.

use warnings;
use strict;

use DateTime;
use File::Basename;
use Getopt::Std;
use Switch;
use URI::Escape qw( uri_escape_utf8 );

use lib dirname(__FILE__) . '/../modules';

use citations qw( queryDate requiresColon setFormat );
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
my $DBSPECIFIC   = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-specific.sqlite3';
my $DBMAINTAIN   = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-maintenance.sqlite3';
my $BOTINFO      = $ENV{'WIKI_CONFIG_DIR'} .  '/bot-info.txt';

my $FALSEPOSITIVES = 'User:JL-Bot/Citations.cfg';

my @INITIALS = qw(
    A B C D E F G H I J K L M N O P Q R S T U V W X Y Z Num Non
);

my @TYPES = qw(
    journal magazine
);

my $POPULAR = 1000;             # number of most popular entries to output
my %COMMON = (                  # number of common entries to output (shared with citations-4-common)
    'journal' => 3000,
    'magazine' => 500,
);

my $NORMALMAX = 250;            # number of entries per non-target page
my $COMMONMAX = 100;            # number of entries per target page
my $LINEMAX   = 9500;           # maximum number of lines per page

my %PAGETITLE = (
    'journal'  => 'WikiProject Academic Journals/Journals cited by Wikipedia',
    'magazine' => 'WikiProject Magazines/Magazines cited by Wikipedia',
);

my %MAIN = (
    'journal'  => 'JCW-Main',
    'magazine' => 'MCW-Main',
);

my %PREVNEXT = (
    'journal'  => 'JCW-PrevNext',
    'magazine' => 'MCW-PrevNext',
);

my %SHORTCUT = (
    'journal'  => 'Wikipedia:JCW',
    'magazine' => 'Wikipedia:MCW',
);


#
# Subroutines
#

sub generateIndividual {

    # Generate individual results (by type & letter) from database

    my $database = shift;
    my $type = shift;
    my $letter = shift;
    my $row = shift;

    my $sth = $database->prepare("
        SELECT citation, dFormat, dType, target, tFormat, tType, cCount, aCount
        FROM individuals
        WHERE type = ?
        AND letter = ?
    ");
    $sth->bind_param(1, $type);
    $sth->bind_param(2, $letter);
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

    # generate output lines

    my @results;

    for my $citation (sort { sortCitations($a, $b) } keys %$records) {

        my $record = $records->{$citation};

        my $display = setFormat( 'display', $citation, $record->{'d-format'} );
        my $target  = setFormat( 'target', $record->{'target'}, $record->{'t-format'} );

        my $dType = setType( $type, $record->{'d-type'} );
        my $tType = setType( $type, $record->{'t-type'} );

        my $cCount  = $record->{'citations'};
        my $aCount  = $record->{'articles'};

        my $search = createSearch($citation);

        my $line = "{{$row|display=$display|d-type=$dType|target=$target|t-type=$tType|citations=$cCount|articles=$aCount|search=$search}}\n";

        push @results, $line;
    }

    return \@results;
}

sub generatePopular {

    # Generate most popular results (by type) from database

    my $database = shift;
    my $type = shift;
    my $maximum = shift;
    my $row = shift;

    # find the minimum count to return

    my $sth = $database->prepare("
        SELECT cCount
        FROM individuals
        WHERE type = ?
        ORDER BY cCount DESC
        LIMIT ?,1
    ");
    $sth->bind_param(1, $type);
    $sth->bind_param(2, $maximum);
    $sth->execute();

    my $count;

    while (my $ref = $sth->fetchrow_hashref()) {
        $count = $ref->{'cCount'};
    }

    # find all results equal to or more than that count

    $sth = $database->prepare("
        SELECT citation, dFormat, dType, target, tFormat, tType, cCount, aCount
        FROM individuals
        WHERE type = ?
        AND cCount >= ?
    ");
    $sth->bind_param(1, $type);
    $sth->bind_param(2, $count);
    $sth->execute();

    my $records;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $cCount = $ref->{'cCount'};
        my $citation = $ref->{'citation'};
        $records->{$cCount}->{$citation}->{'d-format'} = $ref->{'dFormat'};
        $records->{$cCount}->{$citation}->{'d-type'} = $ref->{'dType'};
        $records->{$cCount}->{$citation}->{'target'} = $ref->{'target'};
        $records->{$cCount}->{$citation}->{'t-format'} = $ref->{'tFormat'};
        $records->{$cCount}->{$citation}->{'t-type'} = $ref->{'tType'};
        $records->{$cCount}->{$citation}->{'articles'} = $ref->{'aCount'};
    }

    # generate output lines

    my @results;
    my $number = 1;

    for my $cCount (sort { $b <=> $a } keys %$records) {

        my $rank = $number;

        for my $citation (sort { sortCitations($a, $b) } keys %{$records->{$cCount}}) {

            $number++;

            my $record = $records->{$cCount}->{$citation};

            my $display = setFormat( 'display', $citation, $record->{'d-format'} );
            my $target  = setFormat( 'target', $record->{'target'}, $record->{'t-format'} );

            my $dType = setType( $type, $record->{'d-type'} );
            my $tType = setType( $type, $record->{'t-type'} );

            my $aCount  = $record->{'articles'};

            my $search = createSearch($citation);

            my $line = "{{$row|rank=$rank|display=$display|d-type=$dType|target=$target|t-type=$tType|citations=$cCount|articles=$aCount|search=$search}}\n";

            push @results, $line;
        }

    }

    return \@results;
}

sub generateMissing {

    # Generate most popular missing results (by type) from database
    # Significant overlap with generatePopular (only SQL different) so could refactor

    my $database = shift;
    my $type = shift;
    my $maximum = shift;
    my $row = shift;

    # find the minimum count to return

    my $sth = $database->prepare("
        SELECT cCount
        FROM individuals
        WHERE type = ?
        AND target = '&mdash;'
        ORDER BY cCount DESC
        LIMIT ?,1
    ");
    $sth->bind_param(1, $type);
    $sth->bind_param(2, $maximum);
    $sth->execute();

    my $count;

    while (my $ref = $sth->fetchrow_hashref()) {
        $count = $ref->{'cCount'};
    }

    # find all results equal to or more than that count

    $sth = $database->prepare("
        SELECT citation, dFormat, dType, target, tFormat, tType, cCount, aCount
        FROM individuals
        WHERE type = ?
        AND target = '&mdash;'
        AND cCount >= ?
    ");
    $sth->bind_param(1, $type);
    $sth->bind_param(2, $count);
    $sth->execute();

    my $records;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $cCount = $ref->{'cCount'};
        my $citation = $ref->{'citation'};
        $records->{$cCount}->{$citation}->{'d-format'} = $ref->{'dFormat'};
        $records->{$cCount}->{$citation}->{'d-type'} = $ref->{'dType'};
        $records->{$cCount}->{$citation}->{'target'} = $ref->{'target'};
        $records->{$cCount}->{$citation}->{'t-format'} = $ref->{'tFormat'};
        $records->{$cCount}->{$citation}->{'t-type'} = $ref->{'tType'};
        $records->{$cCount}->{$citation}->{'articles'} = $ref->{'aCount'};
    }

    # generate output lines

    my @results;
    my $number = 1;

    for my $cCount (sort { $b <=> $a } keys %$records) {

        my $rank = $number;

        for my $citation (sort { sortCitations($a, $b) } keys %{$records->{$cCount}}) {

            $number++;

            my $record = $records->{$cCount}->{$citation};

            my $display = setFormat( 'display', $citation, $record->{'d-format'} );
            my $target  = setFormat( 'target', $record->{'target'}, $record->{'t-format'} );

            my $dType = setType( $type, $record->{'d-type'} );
            my $tType = setType( $type, $record->{'t-type'} );

            my $aCount  = $record->{'articles'};

            my $search = createSearch($citation);

            my $line = "{{$row|rank=$rank|display=$display|d-type=$dType|target=$target|t-type=$tType|citations=$cCount|articles=$aCount|search=$search}}\n";

            push @results, $line;
        }

    }

    return \@results;
}

sub generateInvalid {

    # Generate invalid results (by type) from database

    my $database = shift;
    my $type = shift;

    my $sth = $database->prepare("
        SELECT citation, cCount, aCount
        FROM individuals
        WHERE type = ?
        AND target = 'Invalid'
    ");
    $sth->bind_param(1, $type);
    $sth->execute();

    my $records;
    my $total = 0;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $citation = $ref->{'citation'};
        $records->{$citation}->{'citations'} = $ref->{'cCount'};
        $records->{$citation}->{'articles'} = $ref->{'aCount'};
        $total += $ref->{'cCount'};
    }

    # generate output lines

    my $results;

    for my $citation (sort {$a cmp $b} keys %$records) {
        my $citations = $records->{$citation}->{'citations'};
        my $articles = $records->{$citation}->{'articles'};
        $results .= "* <nowiki>$citation</nowiki> ($citations in $articles)\n";
    }

    $results .= "|$total\n";

    return $results;
}

sub generateCommon {

    # Generate top common results (by type) from database

    my $database = shift;
    my $type = shift;
    my $max = shift;
    my $row = shift;

    my $sth = $database->prepare("
        SELECT target, entries, articles, citations
        FROM commons
        WHERE type = ?
        ORDER BY citations DESC, CAST(articles AS INTEGER) DESC, target ASC
        LIMIT ?
    ");
    $sth->bind_param(1, $type);
    $sth->bind_param(2, $max);
    $sth->execute();

    my @results;
    my $rank = 0;

    while (my $ref = $sth->fetchrow_hashref()) {

        my $target = $ref->{'target'};
        my $entries = $ref->{'entries'};
        my $articles = $ref->{'articles'};
        my $citations = $ref->{'citations'};

        $rank++;

        my $line = "{{$row|rank=$rank|target=[[$target]]|citations=$citations|articles=$articles|entries=\n$entries}}\n";

        push @results, $line;
    }

    return \@results;
}

sub commonRevision {

    # Return the revision from database

    my $database = shift;

    my $sth = $database->prepare("
        SELECT revision
        FROM revisions
        WHERE type = 'falsePositive'
    ");
    $sth->execute();

    my $revision;

    while (my $ref = $sth->fetchrow_hashref()) {
        $revision = $ref->{'revision'};
    }

    my $date = DateTime->now;
    my $result = "e-id=$revision|r-time=" . $date->ymd;

    return $result;
}

sub saveBottom {

    # Save bottom template contents

    my $bot =  shift;
    my $template = shift;
    my $contents = shift;

    my $page = "Template:$template";

    $contents .= '<noinclude>{{documentation}}</noinclude>';

    my ($text, $timestamp) = $bot->getText($page);
    $bot->saveText($page, $timestamp, $contents, 'updating Wikipedia citation statistics', 'NotMinor', 'Bot');

    return;
}

sub generateQuestionable {

    # Generate questionable results from database

    my $database = shift;
    my $row = shift;

    my $sth = $database->prepare("
        SELECT target, entries, entryCount, lineCount, articles, citations, source, note, doi
        FROM questionables
        WHERE citations > 0
        ORDER BY citations DESC, CAST(articles AS INTEGER) DESC, target ASC
    ");
    $sth->execute();

    my @results;
    my $rank = 0;

    while (my $ref = $sth->fetchrow_hashref()) {

        my $target = $ref->{'target'};
        my $entries = $ref->{'entries'};
        my $entryCount = $ref->{'entryCount'};
        my $lineCount = $ref->{'lineCount'};
        my $articles = $ref->{'articles'};
        my $citations = $ref->{'citations'};
        my $source = $ref->{'source'};
        my $note = $ref->{'note'};
        my $doi = $ref->{'doi'};

        $rank++;

        $target = ":$target" if (requiresColon($target));

        my $line = "{{$row|rank=$rank|target=[[$target]]|citations=$citations|articles=$articles|source=$source|note=$note|doi1=$doi|l-count=$lineCount|e-count=$entryCount|entries=\n$entries}}\n";

        push @results, $line;
    }

    return \@results;
}

sub questionableRevisions {

    # Return the formatted questionable revisions from database
    # Very similar to commonRevision (could refactor, but worth the effort?)

    my $database = shift;

    my $sth = $database->prepare('
        SELECT type, revision
        FROM revisions
    ');
    $sth->execute();

    my $revisions;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $type = $ref->{'type'};
        $revisions->{$type} = $ref->{'revision'};;
    }

    my $date = DateTime->now;
    my $result = "e-id=$revisions->{'falsePositive'}|q-id=$revisions->{'questionable'}|r-time=" . $date->ymd;

    return $result;
}

sub generatePublisher {

    # Generate publisher results from database

    my $database = shift;
    my $row = shift;

    my $sth = $database->prepare("
        SELECT target, entries, entryCount, lineCount, articles, citations, note, doi
        FROM publishers
        WHERE citations > 0
        ORDER BY citations DESC, CAST(articles AS INTEGER) DESC, target ASC
    ");
    $sth->execute();

    my @results;
    my $rank = 0;

    while (my $ref = $sth->fetchrow_hashref()) {

        my $target = $ref->{'target'};
        my $entries = $ref->{'entries'};
        my $entryCount = $ref->{'entryCount'};
        my $lineCount = $ref->{'lineCount'};
        my $articles = $ref->{'articles'};
        my $citations = $ref->{'citations'};
        my $note = $ref->{'note'};
        my $doi = $ref->{'doi'};

        $rank++;

        $target = ":$target" if (requiresColon($target));

        my $line = "{{$row|rank=$rank|target=[[$target]]|citations=$citations|articles=$articles|note=$note|doi1=$doi|l-count=$lineCount|e-count=$entryCount|entries=\n$entries}}\n";

        push @results, $line;
    }

    return \@results;
}

sub publisherRevisions {

    # Return the formatted publisher revisions from database
    # Very similar to commonRevision & questionableRevisions (could refactor, but worth the effort?)

    my $database = shift;

    my $sth = $database->prepare('
        SELECT type, revision
        FROM revisions
    ');
    $sth->execute();

    my $revisions;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $type = $ref->{'type'};
        $revisions->{$type} = $ref->{'revision'};;
    }

    my $date = DateTime->now;
    my $result = "e-id=$revisions->{'falsePositive'}|p-id=$revisions->{'publisher'}|r-time=" . $date->ymd;

    return $result;
}

sub setType {

    # Returns the type flag for the specified description

    my $type = shift;
    my $text = shift;

    if ($text eq 'journal+magazine') {
        $text = 'journal'  if ($type eq 'journal');
        $text = 'magazine' if ($type eq 'magazine');
        die "ERROR: unknown type = $type\n\n" if ($text eq 'journal+magazine');
    }

    switch ($text) {
        case 'bluebook'     { return 'bb' }
        case 'book'         { return 'b' }
        case 'database'     { return 'd' }
        case 'default'      { return '?' }
        case 'iso'          { return 'i' }
        case 'journal'      { return 'j' }
        case 'magazine'     { return 'm' }
        case 'math'         { return 'math' }
        case 'newspaper'    { return 'n' }
        case 'nlm'          { return 'nlm' }
        case 'publisher'    { return 'p' }
        case 'website'      { return 'w' }
        else		        { die "ERROR: setText unknown text = $text\n\n" }
    }

    die "ERROR: should not get here (setType)\n\n";
}

sub createSearch {

    # Create the search string

    my $search = shift;

    $search =~ s/ \((?:journal|magazine)\)$//;
    $search = uri_escape_utf8($search);

    return $search;
}

sub pageStatus {

    # Find existing page status

    my $text = shift;

    my $result;

    unless ($text) {
        return 'NEW';
    }

    if ($text =~ /\{\{(?:J|M)CW-PrevNext\|.*?\|next=\}\}/) {
        return 'LAST';
    }

    return 'MORE';
}

sub createRedirect {

    # Create a talk page redirect

    my $page   = shift;
    my $type   = shift;
    my $bot    = shift;
    my $target = shift;

    (my $talk = $page) =~ s/^Wikipedia:/Wikipedia talk:/;

    if ($talk eq $page) {
        die "ERROR: should not happen!\n\n";
    }

    my $redirect = "#REDIRECT [[Wikipedia talk:$target]]";

    my ($text, $timestamp) = $bot->getText($talk);
    $bot->saveText($talk, $timestamp, $redirect, 'redirect to primary talk page', 'NotMinor', 'Bot');

    return;
}

sub createShortcut {

    # Create a shortcut redirect

    my $page   = shift;
    my $type   = shift;
    my $bot    = shift;
    my $target = shift;

    my $shortcut = "$SHORTCUT{$type}/$target";

    my $redirect = "#REDIRECT [[$page]]";

    my ($text, $timestamp) = $bot->getText($shortcut);
    $bot->saveText($shortcut, $timestamp, $redirect, 'navigation shortcut', 'NotMinor', 'Bot');

    return;
}

sub savePages {

    # Save the record types to the appropriate pages

    my $bot = shift;
    my $type = shift;
    my $letter = shift;
    my $top = shift;
    my $bottom = shift;
    my $records = shift;
    my $pMaximum = shift;               # maximum records per page
    my $lMaximum = shift;               # maximum lines per page

    my $pCurrent = 1;                   # current page number
    my $rPage    = 0;                   # current record number within page
    my $rTotal   = 0;                   # total records output so far
    my $lTotal   = 0;                   # total lines output so far
    my $rMaximum = scalar(@$records);   # maximum records to output
    my $pStatus  = 0;                   # page's status

    my $output;                         # page output

    for my $line (@$records) {

        # create page header if needed

        if ($rPage == 0) {
            $output = "{{$MAIN{$type}|letter=$letter}}\n";
            $output .= "{{$top";
            $output .= "|rank=Yes" if (($letter eq 'Popular') or ($letter eq 'Missing'));
            $output .= "}}\n";
        }

        # only output lines if first record or won't exceed line maximum

        $lTotal += () = $line =~ /\n/g;

        if (($rPage == 0) or ($lTotal <= $lMaximum)) {
            $output .= $line;

            $rPage++;
            $rTotal++;
        }

        # if we reach the maximums for the page or the last possible record, end page

        if (($rPage == $pMaximum) or ($lTotal > $lMaximum) or ($rTotal == $rMaximum)) {

            $output .= "{{$bottom}}\n";
            $output .= "{{$PREVNEXT{$type}|previous=";
            $output .= $letter . ($pCurrent - 1) if ($pCurrent > 1);
            $output .= "|current=$letter$pCurrent|next=";
            $output .= $letter . ($pCurrent + 1) if ($rTotal < $rMaximum);
            $output .= '}}';

            my $prefix = $letter;
            $prefix = '0' if ($letter eq 'Num');
            $prefix = '1' if ($letter eq 'Non');
            $prefix = 'μ' if ($letter eq 'Missing');
            $prefix = 'π' if ($letter eq 'Popular');
            $prefix = 'ρ' if ($letter eq 'Publisher');
            $prefix = 'ϙ' if ($letter eq 'Questionable');
            $prefix = 'τ' if ($letter eq 'Target');

            my $defaultsort = sprintf("\n{{DEFAULTSORT:%s-%02d}}", $prefix, $pCurrent);

            $output .= $defaultsort;

            print "  saving $type $letter$pCurrent ...           \r";

            # save main page

            my $page = "Wikipedia:$PAGETITLE{$type}/$letter$pCurrent";
            my ($text, $timestamp) = $bot->getText($page);

            $pStatus = pageStatus($text);

            $bot->saveText($page, $timestamp, $output, 'updating Wikipedia citation statistics', 'NotMinor', 'Bot');

            # create redirects if this is a new page

            if ($pStatus eq 'NEW') {
                createRedirect($page, $type, $bot, $PAGETITLE{$type});
                createShortcut($page, $type, $bot, "$letter$pCurrent");
            }

            $pCurrent++;

            if (($rPage > 1) and ($lTotal > $lMaximum)) {
                # if exceeded max lines, didn't output current record
                # so need to repeat loop to output
                $rPage = 0;
                $lTotal = 0;
                redo;
            }

            $rPage = 0;
            $lTotal = 0;
        }
    }

    # if 'more' pages 'remaining', then notify they need deleting

    if ($pStatus eq 'MORE') {
        my $lastNumber = $pCurrent - 1;
        my $lastPage = "Wikipedia:$PAGETITLE{$type}/$letter$lastNumber";
        print "DELETE AFTER: $lastPage\n";
    }

    return;
}

sub saveInvalid {

    # Save invalid to the appropriate pages

    my $bot = shift;
    my $type = shift;
    my $bottom = shift;
    my $records = shift;

    print "  saving $type Invalid ...           \r";

    my $output  = "{{$MAIN{$type}|letter=Invalid}}\n";
    $output .= "{|class=wikitable\n|-\n!Target\n!Entries (Citations, Articles)\n!Total Citations\n";
    $output .= "|-\n|Invalid\n|\n";
    $output .= $records;
    $output .= "{{$bottom}}\n";
    $output .= '{{DEFAULTSORT:* Invalid}}';

    my $page = "Wikipedia:$PAGETITLE{$type}/Maintenance/Invalid titles";
    my ($text, $timestamp) = $bot->getText($page);

    $bot->saveText($page, $timestamp, $output, 'updating Wikipedia citation statistics', 'NotMinor', 'Bot');

    return;
}

sub sortCitations {

    # sort citations in proper order
    # this same function is used in citations-configuration, but sort
    # functions need to be local to file and not imported

    my $oa = shift;
    my $ob = shift;

    (my $na = $oa) =~ s/^(?:(?:The|Les?|La) |L')//i;
    (my $nb = $ob) =~ s/^(?:(?:The|Les?|La) |L')//i;

    # if they are the same (one with & one w/o "The"), compare originals so sorted consistently

    if ($na eq $nb) {
        my $result = (lc $oa cmp lc $ob);
        return $result if ($result);          # return lc result if not the same
        return ($oa cmp $ob);                 # return original case result otherwise
    }

    # if not the same, compare without

    my $result = (lc $na cmp lc $nb);
    return $result if ($result);            # return lc result if not the same
    return ($na cmp $nb);                   # return original case result otherwise
}

sub sortTemplates {

    # sort templates in selected, pattern, doi order
    # this same function is used in citations-configuration, but sort
    # functions need to be local to file and not imported

    my %order = (
        'selected'      => 1,
        'pattern'       => 2,
        'doi-redirects' => 3,
    );

    unless (exists $order{$a}) {
        die "ERROR: template type unknown --> $a";
    }

    unless (exists $order{$b}) {
        die "ERROR: template type unknown --> $b";
    }

    return $order{$a} <=> $order{$b};
}

sub typoRevision {

    my $date = DateTime->now;
    my $result = "r-time=" . $date->ymd;

    return $result;
}

sub generateCapitalization {

    # Generate capitalization results from database

    my $database = shift;
    my $row = shift;

    my $sth = $database->prepare("
        SELECT target, entries, articles, citations
        FROM capitalizations
        WHERE citations > 0
        ORDER BY precedence ASC, citations DESC, CAST(articles AS INTEGER) DESC, target ASC
    ");
    $sth->execute();

    my @results;
    my $rank = 0;

    while (my $ref = $sth->fetchrow_hashref()) {

        my $target = $ref->{'target'};
        my $entries = $ref->{'entries'};
        my $articles = $ref->{'articles'};
        my $citations = $ref->{'citations'};

        $rank++;

        my $line = "{{$row|rank=$rank|target=[[$target]]|citations=$citations|articles=$articles|entries=\n$entries}}\n";

        push @results, $line;
    }

    return \@results;
}

sub saveMaintenance {

    # Save maintenance pages

    my $bot = shift;
    my $name = shift;
    my $top = shift;
    my $bottom = shift;
    my $records = shift;

    print "  saving $name ...           \r";

    my $type = 'journal';

    my $output = "{{$MAIN{$type}|letter=}}\n";
    $output .= "{{$top}}\n";

    for my $line (@$records) {
        $output .= $line;
    }

    $output .= "{{$bottom}}\n";
    $output .= "{{DEFAULTSORT:* $name}}";

    my $page = "Wikipedia:$PAGETITLE{$type}/Maintenance/$name";
    my ($text, $timestamp) = $bot->getText($page);

    $bot->saveText($page, $timestamp, $output, 'updating Wikipedia citation statistics', 'NotMinor', 'Bot');

    return;
}

sub generateSpelling {

    # Generate spelling results from database

    my $database = shift;
    my $row = shift;

    my $sth = $database->prepare("
        SELECT target, entries, articles, citations
        FROM spellings
        WHERE citations > 0
        ORDER BY citations DESC, CAST(articles AS INTEGER) DESC, target ASC
    ");
    $sth->execute();

    my @results;
    my $rank = 0;

    while (my $ref = $sth->fetchrow_hashref()) {

        my $target = $ref->{'target'};
        my $entries = $ref->{'entries'};
        my $articles = $ref->{'articles'};
        my $citations = $ref->{'citations'};

        $rank++;

        my $line = "{{$row|rank=$rank|target=[[$target]]|citations=$citations|articles=$articles|entries=\n$entries}}\n";

        push @results, $line;
    }

    return \@results;
}

sub patternRevision {

    # Return the revision from database
    # Very similar to commonRevision; could refactor but worth the effort?

    my $database = shift;

    my $sth = $database->prepare("
        SELECT revision
        FROM revisions
        WHERE type = 'maintenance'
    ");
    $sth->execute();

    my $revision;

    while (my $ref = $sth->fetchrow_hashref()) {
        $revision = $ref->{'revision'};
    }

    my $date = DateTime->now;
    my $result = "m-id=$revision|r-time=" . $date->ymd;

    return $result;
}

sub generatePattern {

    # Generate pattern results from database

    my $database = shift;
    my $row = shift;

    my $sth = $database->prepare("
        SELECT target, entries, articles, citations
        FROM patterns
        WHERE citations > 0
        ORDER BY citations DESC, CAST(articles AS INTEGER) DESC, target ASC
    ");
    $sth->execute();

    my @results;
    my $rank = 0;

    while (my $ref = $sth->fetchrow_hashref()) {

        my $target = $ref->{'target'};
        my $entries = $ref->{'entries'};
        my $articles = $ref->{'articles'};
        my $citations = $ref->{'citations'};

        $rank++;

        my $line = "{{$row|rank=$rank|target=$target|citations=$citations|articles=$articles|entries=\n$entries}}\n";

        push @results, $line;
    }

    return \@results;
}


#
# Main
#

# command line options

my %opts;
getopts('hicqpmf', \%opts);

if ($opts{h}) {
    print "usage: citations-8-save.pl [-hicqpmf]\n";
    print "       where: -h = help\n";
    print "              -i = save individual targets\n";
    print "              -c = save common targets\n";
    print "              -q = save questionable targets\n";
    print "              -p = save publishers\n";
    print "              -m = save maintenance\n";
    print "              -f = save false positive counts\n";
    print "       by default saves all, but if any specified only saves those\n";
    exit;
}

my $saveIndividual = $opts{i} ? $opts{i} : 0;       # specify individual targets
my $saveCommon = $opts{c} ? $opts{c} : 0;           # specify common targets
my $saveQuestionable = $opts{q} ? $opts{q} : 0;     # specify questionable targets
my $savePublishers = $opts{p} ? $opts{p} : 0;       # specify publishers
my $saveMaintenance = $opts{m} ? $opts{m} : 0;      # specify maintenance
my $saveFPCounts = $opts{f} ? $opts{f} : 0;         # specify saveFPCounts

unless ($saveIndividual or $saveCommon or $saveQuestionable or $savePublishers or $saveMaintenance or $saveFPCounts) {
    # non-specified so save all
    $saveIndividual = 1;
    $saveCommon = 1;
    $saveQuestionable = 1;
    $savePublishers = 1;
    $saveMaintenance = 1;
    $saveFPCounts = 1;
}

# handle UTF-8

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

# auto-flush output

$| = 1;

# initialize bot

my $bot = mybot->new($BOTINFO);

# obtain database dump date

print "Saving to Wikipedia ...\n";

my $wikidate = queryDate($DBTITLES);

# save individual pages

if ($saveIndividual) {

    my %top = (
        'journal'  => 'JCW-top',
        'magazine' => 'MCW-top',
    );

    my %bottom = (
        'journal'  => 'JCW-bottom',
        'magazine' => 'MCW-bottom',
    );

    my %row = (
        'journal'  => 'JCW-row',
        'magazine' => 'MCW-row',
    );

    my $database = citationsDB->new;
    $database->openDatabase($DBINDIVIDUAL);

    for my $type (@TYPES) {

        my $top = $top{$type};
        my $bottom = "$bottom{$type}|date=$wikidate";

        for my $letter (@INITIALS) {
            my $records = generateIndividual($database, $type, $letter, $row{$type});
            savePages($bot, $type, $letter, $top, $bottom, $records, $NORMALMAX, $LINEMAX);
        }

        my $records = generatePopular($database, $type, $POPULAR, $row{$type});
        savePages($bot, $type, 'Popular', $top, $bottom, $records, $NORMALMAX, $LINEMAX);

        $records = generateMissing($database, $type, $POPULAR, $row{$type});
        savePages($bot, $type, 'Missing', $top, $bottom, $records, $NORMALMAX, $LINEMAX);

        $bottom .= '|type=no|legend=no';

        $records = generateInvalid($database, $type);
        saveInvalid($bot, $type, $bottom, $records);

    }

    $database->commit;
    $database->disconnect;
}

# save common pages

if ($saveCommon) {

    my %top = (
        'journal'  => 'JCW-TAR-top',
        'magazine' => 'MCW-TAR-top',
    );

    my %bottom = (
        'journal'  => 'JCW-bottom',
        'magazine' => 'MCW-bottom',
    );

    my %bottomCommon = (
        'journal'  => 'JCW-bottom-common',
        'magazine' => 'MCW-bottom-common',
    );

    my %row = (
        'journal' => 'JCW-TAR-rank',
        'magazine' => 'MCW-TAR-rank',
    );

    my $database = citationsDB->new;
    $database->openDatabase($DBCOMMON);

    for my $type (@TYPES) {
        my $records = generateCommon($database, $type, $COMMON{$type}, $row{$type});
        my $revision = commonRevision($database);

        my $top = $top{$type};
        my $bottom = $bottomCommon{$type};

        savePages($bot, $type, 'Target', $top, $bottom, $records, $COMMONMAX, $LINEMAX);
        saveBottom($bot, $bottomCommon{$type}, "{{$bottom{$type}|date=$wikidate|$revision}}");
    }

    $database->commit;
    $database->disconnect;
}

# save questionable

if ($saveQuestionable) {

    my $top = 'JCW-CRAP-top';
    my $bottom = 'JCW-bottom';
    my $bottomQuestionable = 'JCW-bottom-questionable';
    my $row = 'JCW-CRAP-rank';

    my $database = citationsDB->new;
    $database->openDatabase($DBSPECIFIC);

    my $records = generateQuestionable($database, $row);
    my $revision = questionableRevisions($database);
    savePages($bot, 'journal', 'Questionable', $top, $bottomQuestionable, $records, $COMMONMAX, $LINEMAX);
    saveBottom($bot, $bottomQuestionable, "{{$bottom|date=$wikidate|$revision}}");

    $database->commit;
    $database->disconnect;
}

# save publisher

if ($savePublishers) {

    my $top = 'JCW-PUB-top';
    my $bottom = 'JCW-bottom';
    my $bottomPublishers = 'JCW-bottom-publishers';
    my $row = 'JCW-PUB-rank';

    my $database = citationsDB->new;
    $database->openDatabase($DBSPECIFIC);

    my $records = generatePublisher($database, $row);
    my $revision = publisherRevisions($database);
    savePages($bot, 'journal', 'Publisher', $top, $bottomPublishers, $records, $COMMONMAX, $LINEMAX);
    saveBottom($bot, $bottomPublishers, "{{$bottom|date=$wikidate|$revision}}");

    $database->commit;
    $database->disconnect;
}

# save maintenance

if ($saveMaintenance) {

    my $top = 'JCW-TAR-top';
    my $bottom = "JCW-bottom|date=$wikidate|type=no";
    my $row = 'JCW-TAR-rank';

    my $database = citationsDB->new;
    $database->openDatabase($DBMAINTAIN);

    # save capitalizations

    my $records = generateCapitalization($database, $row);
    my $revision = typoRevision();
    saveMaintenance($bot, 'Miscapitalisations', $top, "$bottom|$revision", $records);

    # save spellings

    $records = generateSpelling($database, $row);
    saveMaintenance($bot, 'Misspellings', $top, "$bottom|$revision", $records);

    # save patterns

    $records = generatePattern($database, $row);
    $revision = patternRevision($database);
    saveMaintenance($bot, 'Patterns', $top, "$bottom|$revision", $records);

    $database->commit;
    $database->disconnect;
}

# save false positive counts

if ($saveFPCounts) {

    my $database = citationsDB->new;
    $database->openDatabase($DBINDIVIDUAL);

    my ($text, $timestamp) = $bot->getText($FALSEPOSITIVES);

    my $output = '';
    my $templates;

    for my $line (split "\n", $text) {
        if ($line =~ /^\s*\{\{\s*([JM]CW-exclude)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*(?:\|\s*c\s*=\s*\d+\s*)?\}\}\s*$/i) {
            # update templates & save within a section
            my $type   = $1;
            my $target = $2;
            my $entry  = $3;
            my $new .= "{{$type|$target|$entry";

            $entry =~ s/^\d+\s*=\s*//;
            my $sth = $database->prepare('
                SELECT cCount
                FROM individuals
                WHERE citation = ?
            ');
            $sth->bind_param(1, $entry);
            $sth->execute();

            my $count = 0;
            while (my $ref = $sth->fetchrow_hashref()) {
                $count += $ref->{'cCount'};
            }

            $new .= "|c=$count}}";
            $templates->{$target}->{'exclude'}->{$new} = 1;

        }
        elsif ($line =~ /^\s*<\/div>\s*$/) {
            # end of section so output sorted templates
            for my $target (sort { sortCitations($a, $b) } keys %$templates) {
                for my $template (sort sortTemplates keys %{$templates->{$target}}) {
                    for my $line (sort keys %{$templates->{$target}->{$template}}) {
                        $output .= "$line\n";
                    }
                }
            }
            $output .= "</div>\n";
            $templates = {};

        }
        else {
            # pass through other lines
            $output .= "$line\n";
        }
    }

    $database->disconnect;

    $bot->saveText($FALSEPOSITIVES, $timestamp, $output, 'updating Wikipedia citation statistics', 'NotMinor', 'Bot');
}

# clean-up

print "                                 \r";
