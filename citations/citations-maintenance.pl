#!/usr/bin/perl

# This script generates the journal maintenance results (WP:JCW/MAINT).

use warnings;
use strict;

use Benchmark;
use File::Basename;
use Unicode::Normalize;

use lib dirname(__FILE__) . '/../modules';

use citations qw(
    loadRedirects
    normalizeCitation
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

my $DBPARSE      = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-titles.sqlite3';
my $DBINDIVIDUAL = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-individual.sqlite3';
my $DBMAINTAIN   = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-maintenance.sqlite3';
my $BOTINFO      = $ENV{'WIKI_CONFIG_DIR'} .  '/bot-info.txt';

my $FALSEPOSITIVES = 'User:JL-Bot/Citations.cfg';
my $MAINTENANCE = 'User:JL-Bot/Maintenance.cfg';

my $PATTERNMAX = 1000;

my @TABLES = (
    'CREATE TABLE capitalizations(precedence INTEGER, target TEXT, entries TEXT, articles TEXT, citations INTEGER)',
    'CREATE TABLE spellings(target TEXT, entries TEXT, articles TEXT, citations INTEGER)',
    'CREATE TABLE patterns(target TEXT, entries TEXT, articles TEXT, citations INTEGER)',
    'CREATE TABLE diacritics(target TEXT, entries TEXT, articles TEXT, citations INTEGER)',
    'CREATE TABLE dots(target TEXT, entries TEXT, articles TEXT, citations INTEGER)',
    'CREATE TABLE revisions(type TEXT, revision TEXT)',
);

my $CAPITALIZATIONS = 'Category:Redirects from miscapitalisations';
my @SPELLINGS = (
    'Category:Redirects from misspellings',
    'Category:Redirects from incorrect names',
    'Category:Redirects from database entries'
);
my @DIACRITICS = (
    'Category:Redirects from titles without diacritics',
    'Category:Redirects from titles with diacritics'
);
my $ABBREVIATIONS = 'Category:Redirects from ISO 4 abbreviations';

#
# Subroutines
#

sub articleCount {

    # Find the unique article count.

    my $database = shift;
    my $type = shift;
    my $citations = shift;

    my $articles;

    for my $citation (%$citations) {

        my $sth = $database->prepare('
            SELECT article
            FROM citations
            WHERE type = ?
            AND citation = ?
        ');
        $sth->bind_param(1, $type);
        $sth->bind_param(2, $citation);
        $sth->execute();

        while (my $ref = $sth->fetchrow_hashref()) {
            my $article = $ref->{'article'};
            $articles->{$article} = 1;
        }

    }

    return scalar keys %$articles;
}

sub citationCount {

    # Find the total citation count

    my $citations = shift;

    my $count = 0;

    for my $citation (keys %$citations) {
        $count += $citations->{$citation}->{'citation-count'};
        unless ($citations->{$citation}->{'citation-count'}) {
            print "\nCitation = $citation\n";
            use Data::Dumper;
            print Dumper($citations);
            exit;
        }
    }

    return $count;
}

sub determineCapitalizationType {

    # Determine if an all caps citation and which category

    my $citation = shift;

    if (($citation =~ /\p{IsUpper}/) and ($citation !~ /\p{IsLower}/)) {
        if ($citation =~ /^(?:\p{IsUpper}|:|,|&|;|-|–|—|’|‘|'|"|\.|\s)+$/) {
            if (length($citation) > 5) {
                return 'ALL CAPS (Long)';
            }
            else {
                return 'ALL CAPS (Short)';
            }
        }
        return 'ALL CAPS (Other)';
    }

    return 0;
}

sub findCapitalizationTargets {

    # Finds the targets for capitalization processing

    my $database = shift;

    print "  finding capitalization targets ...\n";

    my $results;

    my $sth = $database->prepare('
        SELECT citation, dFormat, target
        FROM individuals
        WHERE type = "journal"
    ');
    $sth->execute();
    while (my $ref = $sth->fetchrow_hashref()) {
        my $citation = $ref->{'citation'};
        my $dFormat  = $ref->{'dFormat'};
        my $target   = $ref->{'target'};
        next if ($dFormat eq 'nonexistent');
        next if ($dFormat eq 'nowiki');
        $results->{$target}->{$citation} = 1;
    }

    return $results;
}

sub findDiacriticCitations {

    # Finds citations without articles that have diacritics

    my $database = shift;
    my $type = shift;

    print "  finding " . $type . " citations ...\n";

    my $sql = '
        SELECT citation
        FROM individuals
        WHERE type = "journal"
    ';

    if ($type eq 'existent') {
        $sql .= 'AND dFormat != "nonexistent"'
    }
    elsif ($type eq 'nonexistent') {
        $sql .= 'AND dFormat = "nonexistent"'
    }
    else {
        die "\n\nERROR: findDiacriticCitations should not reach here!\n\n";
    }

    my $results;

    my $sth = $database->prepare($sql);
    $sth->execute();
    while (my $ref = $sth->fetchrow_hashref()) {
        my $citation = $ref->{'citation'};
        my $term = NFKD($citation);
        $term =~ s/\p{NonspacingMark}//g;
        $results->{$term}->{$citation} = 1;
    }

    return $results;
}

sub findDotCitations {

    # Finds citations & normalize ones without articles that have dots

    my $database = shift;
    my $type = shift;

    print "  finding " . $type . " citations ...\n";

    my $sql = '
        SELECT citation, target, dFormat, cCount, aCount
        FROM individuals
        WHERE type = "journal"
    ';

    if ($type eq 'existent') {
        $sql .= 'AND dFormat != "nonexistent"'
    }
    elsif ($type eq 'nonexistent') {
        $sql .= 'AND dFormat = "nonexistent"'
    }
    else {
        die "\n\nERROR: findDotCitations should not reach here!\n\n";
    }

    my $results;

    my $sth = $database->prepare($sql);
    $sth->execute();
    while (my $ref = $sth->fetchrow_hashref()) {
        my $citation = $ref->{'citation'};
        my $target = $ref->{'target'};
        my $dFormat = $ref->{'dFormat'};
        my $cCount = $ref->{'cCount'};
        my $aCount = $ref->{'aCount'};
        my $term = lc $citation;
        $term =~ s/\s\(journal\)$//g;
        $term =~ s/\s*[\.,]//g;
        if ($type eq 'nonexistent') {
            $results->{$term}->{$citation}->{'dFormat'} = $dFormat;
            $results->{$term}->{$citation}->{'citation-count'} = $cCount;
            $results->{$term}->{$citation}->{'article-count'} = $aCount;
        }
        else {
            $results->{$target}->{$citation}->{'term'} = $term;
            $results->{$target}->{$citation}->{'dFormat'} = $dFormat;
        }
    }

    return $results;
}

sub findRedirectTargets {

    # Finds the targets of redirects

    my $database  = shift;
    my $redirects = shift;

    my $total = scalar keys %$redirects;
    print "  finding $total redirect targets ...\n";

    my $results;

    for my $redirect (keys %$redirects) {
        my $sth = $database->prepare('SELECT target FROM titles WHERE title = ?');
        $sth->bind_param(1, $redirect);
        $sth->execute();
        while (my $ref = $sth->fetchrow_hashref()) {
            my $target = $ref->{'target'};
            $results->{$target}->{$redirect} = 1;
        }
    }

    return $results;
}

sub formatPatternEntries {

    # Format the entries field for pattern output

    my $citations = shift;

    # create temporary structure to determine nesting
    # this should also factor in normalization...

    my $temporary;

    for my $citation (sort keys %$citations) {
        my $format = $citations->{$citation}->{'d-format'};
        my $target = $citations->{$citation}->{'target'};
        if ($format =~ /^redirect/) {
            $temporary->{$target}->{redirects}->{$citation} = $citations->{$citation};
        }
        else {
            $temporary->{$citation}->{main} = $citations->{$citation};
        }
    }

    # generate final output

    my $output;

    for my $citation (sort keys %$temporary) {
        # process main first
        if (exists $temporary->{$citation}->{main}) {
            my $format = $citations->{$citation}->{'d-format'};
            my $count = $citations->{$citation}->{'citation-count'};
            my $articles = $citations->{$citation}->{'article-count'};
            my $formatted = setFormat('display', $citation, $format);
            $output .= "* $formatted ($count in $articles)\n";
        }
        else {
            $output .= "* [[$citation]]\n";
        }
        # then process redirects
        for my $redirect (sort keys %{$temporary->{$citation}->{redirects}}) {
            my $data = $temporary->{$citation}->{redirects}->{$redirect};
            my $format = $data->{'d-format'};
            my $count = $data->{'citation-count'};
            my $articles = $data->{'article-count'};
            my $formatted = setFormat('display', $redirect, $format);
            $output .= "** $formatted ($count in $articles)\n";
        }
    }

    return $output;
}

sub formatTypoEntries {

    # Format the entries field for typo output

    my $citations = shift;

    my $output;

    for my $citation (sort keys %$citations) {
        my $format = $citations->{$citation}->{'d-format'};
        my $count = $citations->{$citation}->{'citation-count'};
        my $articles = $citations->{$citation}->{'article-count'};
        my $formatted = setFormat('display', $citation, $format);
        $output .= "* $formatted ($count in $articles)\n";
    }

    return $output;
}

sub pageType {

    # Returns the page type

    my $database = shift;
    my $title = shift;

    my $sth = $database->prepare(q{
        SELECT pageType
        FROM titles
        WHERE title = ?
    });
    $sth->bind_param(1, $title);
    $sth->execute();

    while (my $ref = $sth->fetchrow_hashref()) {
        my $type = $ref->{'pageType'};
        $type =~ s/-UNNECESSARY//;
        return $type;
    }

    return 'NONEXISTENT';
}

sub retrieveMaintenance {

    # Retrieve maintenance settings from wiki page.

    my $info = shift;
    my $page = shift;

    print "  retrieving maintenance configuration ...\n";

    my $bot = mybot->new($info);

    my ($text, $timestamp, $revision) = $bot->getText($page);

    my $maintenance;

    for my $line (split "\n", $text) {

        $line =~ s/\[\[([^\|\]]+)\|([^\]]+)\]\]/##--##$1##--##$2##-##/g;        # escape [[this|that]]

        if ($line =~ /^\s*\{\{\s*JCW-pattern\s*\|\s*(?:1\s*=\s*)?(.*?)\s*(?:\|(.*?))?\s*\}\}\s*$/i) {
            my $target     = $1;
            my $additional = $2;

            # see if exclusion type specified & capture
            my $exclusion = 'none';
            if ($additional =~ /\|\s*exclude\s*=\s*(.+)\s*$/) {
                $exclusion = $1;
                if (($exclusion ne 'bluelinks') and ($exclusion ne 'redlinks')) {
                    warn "$target pattern has unknown exclude type $exclusion in $line\n";
                    next;
                }
                $additional =~ s/\|\s*exclude\s*=\s*.+\s*$//;
            }

            # pull out patterns

            my @terms = split(/\|/, $additional);
            for my $term (@terms) {
                $term =~ s/^\d+\s*=\s*//;
                $term =~ s/\{\{\(\(\}\}/{{/g;     # replace Template:((
                $term =~ s/\{\{!\}\}/|/g;         # replace Template:!
                if ($term =~ /\Q.*\E/) {
                    $maintenance->{$target}->{'include'}->{$term} = $exclusion;
                }
                elsif ($term =~ /!/) {
                    $maintenance->{$target}->{'exclude'}->{$term} = 1;
                }
                else {
                    warn "Unknown pattern: $target --> [$term]\n";
                }
            }
        }
    }

    return $maintenance, $revision;
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

print "Generating maintenance ...\n";

my $m0 = Benchmark->new;

# delete existing database & create new one

print "  creating database ...\n";

if (-e $DBMAINTAIN) {
    unlink $DBMAINTAIN
        or die "ERROR: Could not delete file ($DBMAINTAIN)\n --> $!\n\n";
}

my $dbMaintain = citationsDB->new;
$dbMaintain->cloneDatabase($DBINDIVIDUAL, $DBMAINTAIN);
$dbMaintain->openDatabase($DBMAINTAIN);
$dbMaintain->createTables(\@TABLES);

my $dbTitles = citationsDB->new;
$dbTitles->openDatabase($DBPARSE);

# retrieve configuration

my ($maintenance, $mRevision) = retrieveMaintenance($BOTINFO, $MAINTENANCE);

my $sth = $dbMaintain->prepare('INSERT INTO revisions VALUES (?, ?)');
$sth->execute('maintenance', $mRevision);
$dbMaintain->commit;

# process capitalization differences

my $bot = mybot->new($BOTINFO);

print "  retrieving members of $CAPITALIZATIONS ...\n";
my $members = $bot->getCategoryMembers($CAPITALIZATIONS);
my $targets = findCapitalizationTargets($dbMaintain);

my $total = scalar keys %$targets;
print "  processing $total capitalization targets ...\n";

for my $target (keys %$targets) {

    my $results;

    for my $citation (keys %{$targets->{$target}}) {

        my $alternate = $citation =~ s/ \(journal\)$//r;

        my $normalizations;
        $normalizations->{$citation} = normalizeCitation($citation);
        $normalizations->{$alternate} = normalizeCitation($alternate);

        for my $normalized (keys %$normalizations) {
            my $sth = $dbMaintain->prepare('
                SELECT citation
                FROM normalizations
                WHERE type = "journal"
                AND normalization = ?
            ');
            $sth->bind_param(1, $normalizations->{$normalized});
            $sth->execute();
            while (my $ref = $sth->fetchrow_hashref()) {
                my $candidate = $ref->{'citation'};
                my $type = pageType($dbTitles, $candidate);
                next unless (lc $normalized eq lc $candidate);
                next unless (
                    ($type eq 'NONEXISTENT') or
                    (($type eq 'REDIRECT') and (exists $members->{$candidate}))
                );
                my $sth = $dbMaintain->prepare('
                    SELECT dFormat, target, cCount, aCount
                    FROM individuals
                    WHERE type = "journal"
                    AND citation = ?
                ');
                $sth->bind_param(1, $candidate);
                $sth->execute();
                while (my $ref = $sth->fetchrow_hashref()) {
                    $results->{$candidate}->{'d-format'} = $ref->{'dFormat'};
                    $results->{$candidate}->{'target'} = $ref->{'target'};
                    $results->{$candidate}->{'citation-count'} = $ref->{'cCount'};
                    $results->{$candidate}->{'article-count'} = $ref->{'aCount'};
                }
            }
        }

    }

    # generate final data (que up transactions & commit at end)

    if ($results) {

        my $entries = formatTypoEntries($results);
        my $articles = articleCount($dbMaintain, 'journal', $results);
        my $citations = citationCount($results);

        my $sth = $dbMaintain->prepare("
            INSERT INTO capitalizations (precedence, target, entries, articles, citations)
            VALUES (1, ?, ?, ?, ?)
        ");
        $sth->execute($target, $entries, $articles, $citations);

    }

}

# process all capital non-existent targets

print "  processing non-existent targets ...\n";

my $results;

$sth = $dbMaintain->prepare('
    SELECT citation, cCount, aCount
    FROM individuals
    WHERE type = "journal"
    AND dFormat = "nonexistent"
');
$sth->execute();
while (my $ref = $sth->fetchrow_hashref()) {
    my $citation = $ref->{'citation'};
    my $cCount  = $ref->{'cCount'};
    my $aCount  = $ref->{'aCount'};
    my $type = determineCapitalizationType($citation);
    if ($type) {
        $results->{$type}->{$citation}->{'d-format'} = 'nonexistent';
        $results->{$type}->{$citation}->{'citation-count'} = $ref->{'cCount'};
        $results->{$type}->{$citation}->{'article-count'} = $ref->{'aCount'};
    }
}

for my $type (keys %$results) {

    # generate final data (que up transactions & commit at end)

    my $entries = formatTypoEntries($results->{$type});
    my $articles = articleCount($dbMaintain, 'journal', $results->{$type});
    my $citations = citationCount($results->{$type});

    my $sth = $dbMaintain->prepare("
        INSERT INTO capitalizations (precedence, target, entries, articles, citations)
        VALUES (2, ?, ?, ?, ?)
    ");
    $sth->execute($type, $entries, $articles, $citations);

}

# process spellings

$members = {};
for my $category (@SPELLINGS) {
    print "  retrieving members of $category ...\n";
    my $local = $bot->getCategoryMembers($category);
    $members = { %$members, %$local };
}
$targets = findRedirectTargets($dbTitles, $members);

$total = scalar keys %$targets;
print "  processing $total spelling targets ...\n";

for my $target (keys %$targets) {

    my $results;

    # process typos

    for my $typo (keys %{$targets->{$target}}) {

        my $normalization = normalizeCitation($typo);

        my $sth = $dbMaintain->prepare('
            SELECT citation
            FROM normalizations
            WHERE type = "journal"
            AND normalization = ?
        ');
        $sth->bind_param(1, $normalization);
        $sth->execute();
        while (my $ref = $sth->fetchrow_hashref()) {
            my $citation = $ref->{'citation'};
            my $type = pageType($dbTitles, $citation);
            next unless (lc $typo eq lc $citation);
            next unless (
                ($type eq 'NONEXISTENT') or
                (($type eq 'REDIRECT') and (exists $members->{$citation}))
            );
            my $sth = $dbMaintain->prepare('
                SELECT dFormat, target, cCount, aCount
                FROM individuals
                WHERE type = "journal"
                AND citation = ?
            ');
            $sth->bind_param(1, $citation);
            $sth->execute();
            while (my $ref = $sth->fetchrow_hashref()) {
                $results->{$citation}->{'d-format'} = $ref->{'dFormat'};
                $results->{$citation}->{'target'} = $ref->{'target'};
                $results->{$citation}->{'citation-count'} = $ref->{'cCount'};
                $results->{$citation}->{'article-count'} = $ref->{'aCount'};
            }
        }

    }

    # generate final data (que up transactions & commit at end)

    if ($results) {

        my $entries = formatTypoEntries($results);
        my $articles = articleCount($dbMaintain, 'journal', $results);
        my $citations = citationCount($results);

        my $sth = $dbMaintain->prepare("
            INSERT INTO spellings (target, entries, articles, citations)
            VALUES (?, ?, ?, ?)
        ");
        $sth->execute($target, $entries, $articles, $citations);

    }

}

# process patterns

$total = scalar keys %$maintenance;
print "  processing $total patterns ...\n";

for my $target (keys %$maintenance) {

    my $results;
    my $counts;

    # create ignore

    my $ignore = '';

    for my $pattern (keys %{$maintenance->{$target}->{'exclude'}}) {
        $pattern =~ s/!/%/g;
        $ignore .= "AND citation NOT LIKE '$pattern'\n";
    }

    # process pattern

    for my $pattern (keys %{$maintenance->{$target}->{'include'}}) {

        my $exclusion = $maintenance->{$target}->{'include'}->{$pattern};

        (my $like = $pattern) =~ s/\Q.*\E/%/g;

        my $sth = $dbMaintain->prepare("
            SELECT citation, dFormat, target, cCount, aCount
            FROM individuals
            WHERE type = 'journal'
            AND citation LIKE ?
            $ignore
        ");
        $sth->bind_param(1, $like);
        $sth->execute();
        while (my $ref = $sth->fetchrow_hashref()) {
            my $citation = $ref->{'citation'};
            my $format = $ref->{'dFormat'};
            # apply exclusions if any
            next if ($exclusion eq 'bluelinks') and (($format ne 'nonexistent') and ($format ne 'nowiki'));
            next if ($exclusion eq 'redlinks') and (($format eq 'nonexistent') or ($format eq 'nowiki'));
            # save results
            $results->{$citation}->{'d-format'} = $format;
            $results->{$citation}->{'target'} = $ref->{'target'};
            $results->{$citation}->{'citation-count'} = $ref->{'cCount'};
            $results->{$citation}->{'article-count'} = $ref->{'aCount'};
            $counts->{$pattern}++;
        }

    }

    # generate final data (que up transactions & commit at end)

    if ($results) {

        my $entries = formatPatternEntries($results);
        my $articles = articleCount($dbMaintain, 'journal', $results);
        my $citations = citationCount($results);

        if (scalar keys %$results > $PATTERNMAX) {
            $entries = "Patterns returned too many entries. Check patterns:\n";
            for my $pattern (sort keys %$counts) {
                $entries .= "* $pattern returned $counts->{$pattern} entries\n";
            }
            $articles = 'N/A';
            $citations = 'N/A';
        }

        my $sth = $dbMaintain->prepare(q{
            INSERT INTO patterns (target, entries, articles, citations)
            VALUES (?, ?, ?, ?)
        });
        $sth->execute($target, $entries, $articles, $citations);

    }

}

# process diacritics based on templates

$members = {};
for my $category (@DIACRITICS) {
    print "  retrieving members of $category ...\n";
    my $local = $bot->getCategoryMembers($category);
    $members = { %$members, %$local };
}
$targets = findRedirectTargets($dbTitles, $members);

$total = scalar keys %$targets;
print "  processing $total diacritic targets ...\n";

for my $target (keys %$targets) {

    my $results;

    # process diacritics

    for my $typo (keys %{$targets->{$target}}) {

        my $normalization = normalizeCitation($typo);

        my $sth = $dbMaintain->prepare('
            SELECT citation
            FROM normalizations
            WHERE type = "journal"
            AND normalization = ?
        ');
        $sth->bind_param(1, $normalization);
        $sth->execute();
        while (my $ref = $sth->fetchrow_hashref()) {
            my $citation = $ref->{'citation'};
            my $type = pageType($dbTitles, $citation);
            next unless (lc $typo eq lc $citation);
            next unless (
                ($type eq 'NONEXISTENT') or
                (($type eq 'REDIRECT') and (exists $members->{$citation}))
            );
            my $sth = $dbMaintain->prepare('
                SELECT dFormat, target, cCount, aCount
                FROM individuals
                WHERE type = "journal"
                AND citation = ?
            ');
            $sth->bind_param(1, $citation);
            $sth->execute();
            while (my $ref = $sth->fetchrow_hashref()) {
                $results->{$citation}->{'d-format'} = $ref->{'dFormat'};
                $results->{$citation}->{'target'} = $ref->{'target'};
                $results->{$citation}->{'citation-count'} = $ref->{'cCount'};
                $results->{$citation}->{'article-count'} = $ref->{'aCount'};
            }
        }

    }

    # generate final data (que up transactions & commit at end)

    if ($results) {

        my $entries = formatTypoEntries($results);
        my $articles = articleCount($dbMaintain, 'journal', $results);
        my $citations = citationCount($results);

        my $sth = $dbMaintain->prepare("
            INSERT INTO diacritics (target, entries, articles, citations)
            VALUES (?, ?, ?, ?)
        ");
        $sth->execute($target, $entries, $articles, $citations);

    }

}

# process diacritics based on red links

my $diacriticBlueLinks = findDiacriticCitations($dbMaintain, "existent");
my $diacriticRedLinks = findDiacriticCitations($dbMaintain, "nonexistent");

$total = scalar keys %$diacriticBlueLinks;
print "  processing $total blue links for diacritics ...\n";

for my $nonDiacritic (keys %$diacriticBlueLinks) {

    if (exists $diacriticRedLinks->{$nonDiacritic}) {

        my $results;

        # if multiple blue links, arbitrarily use first

        my @blues = sort keys %{$diacriticBlueLinks->{$nonDiacritic}};
        my $first = $blues[0];

        next if (exists $targets->{$first}); # skipping as already seen via redirects

        # check red links

        for my $red (keys %{$diacriticRedLinks->{$nonDiacritic}}) {

            if (($first ne $nonDiacritic) or ($red ne $nonDiacritic)) {

                my $sth = $dbMaintain->prepare('
                    SELECT dFormat, target, cCount, aCount
                    FROM individuals
                    WHERE type = "journal"
                    AND citation = ?
                ');
                $sth->bind_param(1, $red);
                $sth->execute();
                while (my $ref = $sth->fetchrow_hashref()) {
                    $results->{$red}->{'d-format'} = $ref->{'dFormat'};
                    $results->{$red}->{'target'} = $ref->{'target'};
                    $results->{$red}->{'citation-count'} = $ref->{'cCount'};
                    $results->{$red}->{'article-count'} = $ref->{'aCount'};
                }

            }

        }

        # generate final data (que up transactions & commit at end)

        if ($results) {

            my $entries = formatTypoEntries($results);
            my $articles = articleCount($dbMaintain, 'journal', $results);
            my $citations = citationCount($results);

            my $sth = $dbMaintain->prepare("
                INSERT INTO diacritics (target, entries, articles, citations)
                VALUES (?, ?, ?, ?)
            ");
            $sth->execute($first, $entries, $articles, $citations);

        }

    }
}

# process dots based on blue links & redirects

print "  retrieving members of $ABBREVIATIONS ...\n";
my $redirects = $bot->getCategoryMembers($ABBREVIATIONS);
my $redirectTargets = findRedirectTargets($dbTitles, $redirects);

my $dotBlueLinks = findDotCitations($dbMaintain, "existent");
my $dotRedLinks = findDotCitations($dbMaintain, "nonexistent");

for my $target (keys %$redirectTargets) {
    for my $redirect (keys %{$redirectTargets->{$target}}) {
        (my $term = lc $redirect) =~ s/\s*[\.,]//g;
        unless (exists $results->{$redirect}->{$target}) {
            $dotBlueLinks->{$target}->{$redirect}->{'term'} = $term;
            $dotBlueLinks->{$target}->{$redirect}->{'dFormat'} = 'redirect';
        }
    }
}

$total = scalar keys %$dotBlueLinks;
print "  processing $total dot targets ...\n";

for my $target (keys %$dotBlueLinks) {

    my $entries;
    my $articleTotal = 0;
    my $citationTotal = 0;

    for my $blueCitation (sort keys %{$dotBlueLinks->{$target}}) {

        my $blueTerm = $dotBlueLinks->{$target}->{$blueCitation}->{'term'};
        my $blueFormat = $dotBlueLinks->{$target}->{$blueCitation}->{'dFormat'};

        if (exists $dotRedLinks->{$blueTerm}) {

            my $label = 0;

            for my $redCitation (sort keys %{$dotRedLinks->{$blueTerm}}) {

                next if ((lc $blueCitation) eq (lc $redCitation));
                next if ($blueCitation !~ /[\.,]/) and ($redCitation !~ /[\.,]/);

                my $redFormat = $dotRedLinks->{$blueTerm}->{$redCitation}->{'dFormat'};
                my $redCCount = $dotRedLinks->{$blueTerm}->{$redCitation}->{'citation-count'};
                my $redACount = $dotRedLinks->{$blueTerm}->{$redCitation}->{'article-count'};

                my $formatted = setFormat('display', $redCitation, $redFormat);

                unless ($label) {
                    $entries .= "* " . setFormat('display', $blueCitation, $blueFormat) . "\n";
                    $label = 1;
                }
                $entries .= "** $formatted ($redCCount in $redACount)\n";

            }

            $articleTotal += articleCount($dbMaintain, 'journal', $dotRedLinks->{$blueTerm});
            $citationTotal += citationCount($dotRedLinks->{$blueTerm});

        }
    }

    if ($entries) {

        my $sth = $dbMaintain->prepare("
            INSERT INTO dots (target, entries, articles, citations)
            VALUES (?, ?, ?, ?)
        ");
        $sth->execute($target, $entries, $articleTotal, $citationTotal);

    }

}

$dbMaintain->commit;
$dbMaintain->disconnect;
$dbTitles->disconnect;

my $m1 = Benchmark->new;
my $md = timediff($m1, $m0);
my $ms = timestr($md);
$ms =~ s/^\s*(\d+)\swallclock secs.*$/$1/;
print "  maintenance citations processed in $ms seconds\n";