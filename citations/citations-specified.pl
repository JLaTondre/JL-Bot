#!/usr/bin/perl

# This script generates the publisher (WP:JCW/PUB) and questionable (WP:CITEWATCH) results.

use warnings;
use strict;

use Benchmark;
use File::Basename;
use Getopt::Std;

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
    removeControlCharacters
    requiresColon
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
my $DBSPECIFIC   = $ENV{'WIKI_WORKING_DIR'} . '/Citations/db-specific.sqlite3';
my $BOTINFO      = $ENV{'WIKI_CONFIG_DIR'} .  '/bot-info.txt';

my $FALSEPOSITIVES = 'User:JL-Bot/Citations.cfg';

my @PUBLISHER = (
    'User:JL-Bot/Publishers.cfg'
);
my @QUESTIONABLE = (
    'User:JL-Bot/Questionable.cfg/General',
    'User:JL-Bot/Questionable.cfg/Publishers',
    'User:JL-Bot/Questionable.cfg/Journals',
);

my @PUBTABLE = (
    'CREATE TABLE publishers(target TEXT, entries TEXT, entryCount INTEGER, lineCount INTEGER, articles TEXT, citations INTEGER, source TEXT, note TEXT, doi TEXT)',
);

my @QUETABLE = (
    'CREATE TABLE questionables(target TEXT, entries TEXT, entryCount INTEGER, lineCount INTEGER, articles TEXT, citations INTEGER, source TEXT, note TEXT, doi TEXT)',
);

my @TABLES = (
    @PUBTABLE,
    @QUETABLE,
    'CREATE TABLE revisions(type TEXT, revision TEXT)',
);

my $BLOCK = 100;   # status size

#
# Subroutines
#

sub combineSpecified {

    # Combine specified targets along with redirects

    my $database = shift;
    my $publishers = shift;
    my $questionables = shift;

    print "  combining publisher and questionable ...\n";

    my $combined;

    # combine publishers & questionables

    for my $publisher (keys %$publishers) {
        $combined->{$publisher} = undef;
        for my $selected (keys %{$publishers->{$publisher}->{'selected'}}) {
            $combined->{$selected} = undef;
        }
    }

    for my $questionable (keys %$questionables) {
        $combined->{$questionable} = undef;
        for my $selected (keys %{$questionables->{$questionable}->{'selected'}}) {
            $combined->{$selected} = undef;
        }
    }

    # add in redirects

    my $allRedirects;

    for my $selected (keys %$combined) {
        my $redirects = loadRedirects($database, $selected);
        for my $redirect (keys %$redirects) {
            next if ($redirect =~ /^10\.\d+$/);                         # skip DOI redirects
            $combined->{$redirect} = undef;
            $allRedirects->{$selected}->{$redirect} = 1;
        }
    }

    return $combined, $allRedirects;
}

sub findDOICitations {

    # Find citations that match dois

    my $database = shift;
    my $dois = shift;

    my $results;

    my $sth = $database->prepare('
        SELECT type, citation, article, count
        FROM dois
        WHERE prefix = ?
    ');
    for my $prefix (keys %$dois) {
        $sth->bind_param(1, $prefix);
        $sth->execute();
        $results->{$prefix} = {};                                # create even if no entries
        while (my $ref = $sth->fetchrow_hashref()) {
            my $type     = $ref->{'type'};
            my $citation = $ref->{'citation'};
            my $article  = $ref->{'article'};
            my $count    = $ref->{'count'};
            $results->{$prefix}->{$type}->{$citation}->{'articles'}->{$article} = 1;
            $results->{$prefix}->{$type}->{$citation}->{'citation-count'} += $count;
        }
    }

    return $results;
}

sub findPatternCitations {

    # Find citations that match patterns

    my $database = shift;
    my $patterns = shift;

    my $results;

    for my $excludeType (keys %$patterns) {

        my @include;
        my $exclude = '';

        for my $pattern (keys %{$patterns->{$excludeType}}) {
            if ($pattern =~ s/\Q.*\E/%/g) {
                push @include, $pattern;
            }
            elsif ($pattern =~ s/!/%/g) {
                $exclude .= "AND i.citation NOT LIKE '$pattern'\n";
            }
            else {
                warn "Unknown pattern: [$pattern]\n";
            }
        }

        my $sth = $database->prepare("
            SELECT i.citation, i.target, i.dFormat, i.cCount, i.aCount, c.article
            FROM individuals AS i, citations AS c
            WHERE i.type = 'journal'
            AND c.type = 'journal'
            AND i.citation LIKE ?
            AND i.citation = c.citation
            $exclude
        ");
        for my $pattern (@include) {
            $sth->bind_param(1, $pattern);
            $sth->execute();
            while (my $ref = $sth->fetchrow_hashref()) {
                my $displayFormat = $ref->{'dFormat'};
                # apply exclusions if any
                next if ($excludeType eq 'bluelinks') and (($displayFormat ne 'nonexistent') and ($displayFormat ne 'nowiki'));
                next if ($excludeType eq 'redlinks') and (($displayFormat eq 'nonexistent') or ($displayFormat eq 'nowiki'));
                # due to join, multiple duplicate results will be returned for these
                my $citation = $ref->{'citation'};
                $results->{$citation}->{'article-count'} = $ref->{'aCount'};
                $results->{$citation}->{'citation-count'} = $ref->{'cCount'};
                $results->{$citation}->{'display-format'} = $displayFormat;
                $results->{$citation}->{'target'} = $ref->{'target'};
                # article can have multiple results
                $results->{$citation}->{'articles'}->{ $ref->{'article'} } = 1;
            }

        }

    }

    return $results;
}

sub formatDOICitation {

    # Return a formatted citation

    my $database = shift;
    my $prefix = shift;
    my $citation = shift;
    my $ref = shift;

    my $citations = $ref->{'citation-count'};
    my $articles = scalar keys %{$ref->{'articles'}};

    # include articles in article count if 5 or less

    if ($articles <= 5) {
        my $formatted;
        my $index = 0;
        for my $article (sort keys %{$ref->{'articles'}}) {
            $index++;
            $article = ":$article" if (requiresColon($article));
            $formatted .= ',&nbsp;' unless ($index == 1);
            $formatted .= "[[$article|$index]]";
        }
        $articles = $formatted;
    }

    # handle DOI without a citation

    if ($citation eq 'NONE') {
        return "{{tlx|doi|$prefix/...}} ($citations in $articles)";
    }

    # determine title format

    my $format = 'nonexistent';
    if ($citation =~ /[#<>\[\]\|{}_]/) {
        $format = 'nowiki';
    }
    else {
        my $sth = $database->prepare('
            SELECT pageType
            FROM titles
            WHERE title = ?
        ');
        $sth->bind_param(1, $citation);
        $sth->execute();
        while (my $ref = $sth->fetchrow_hashref()) {
            $format = 'disambiguation' if ($ref->{'pageType'} eq 'DISAMBIG');
            $format = 'existent' if ($ref->{'pageType'} eq 'NORMAL');
            $format = 'redirect' if ($ref->{'pageType'} =~ /^REDIRECT/);
        }
    }
    my $formatted = setFormat('display', $citation, $format);

    return "$formatted ($citations in $articles)";
}

sub generateResult {

    # Generate the final result for a given subject

    my $subject = shift;
    my $configuration = shift;
    my $specified = shift;
    my $patterns = shift;
    my $dois = shift;
    my $redirects = shift;
    my $normalizations = shift;
    my $falsePositives = shift;
    my $dbSpecific = shift;
    my $dbTitles = shift;

    my $hierarchy = {};             # citation hierarchy
    my $citations = {};             # citation format, counts, & articles

    # process selected

    for my $selected (keys %{$configuration->{'selected'}}) {

        next if (exists $falsePositives->{$subject}->{$selected});

        # process record matches (if any)

        if (exists $specified->{$selected}->{'record'}) {
            my $record = $specified->{$selected}->{'record'};
            my $target = $record->{'target'};

            $citations->{$selected}->{'formatted'} = formatCitation($selected, $record);
            $citations->{$selected}->{'count'} = $record->{'citation-count'};
            $citations->{$selected}->{'articles'} = $record->{'articles'};

            my $reference;      # abstract whether a parent or child

            if (($selected eq $target) or ($target eq '&mdash;')) {
                $reference = \%{ $hierarchy->{$selected} };
            }
            else {
                $reference = \%{ $hierarchy->{$target}->{$selected} };
            }

            # process normalization matches to record (if any)

            for my $normalization (keys %{$specified->{$selected}->{'record'}->{'normalizations'}}) {
                for my $match (keys %{$normalizations->{$normalization}}) {

                    next if (exists $falsePositives->{$subject}->{$match});
                    next if (exists $falsePositives->{$selected}->{$match});

                    next if (exists $specified->{$match});                                              # matches self or other top level
                    next if (isUppercaseMatch($match, $selected, $redirects->{$selected}));             # both uppercase

                    my $record = $normalizations->{$normalization}->{$match};
                    $citations->{$match}->{'formatted'} = formatCitation($match, $record);
                    $citations->{$match}->{'count'} = $record->{'citation-count'};
                    $citations->{$match}->{'articles'} = $record->{'articles'};

                    $reference->{$match} = {};
                }
            }
        }

        # process normalization matches to selected (if any)

        for my $normalization (keys %{$specified->{$selected}->{'normalizations'}}) {
            for my $match (keys %{$normalizations->{$normalization}}) {

                next if (exists $falsePositives->{$subject}->{$match});
                next if (exists $falsePositives->{$selected}->{$match});

                next if (exists $specified->{$match});                                              # matches self or other top level
                next if (isUppercaseMatch($match, $selected, $redirects->{$selected}));             # both uppercase

                my $record = $normalizations->{$normalization}->{$match};

                $citations->{$match}->{'formatted'} = formatCitation($match, $record);
                $citations->{$match}->{'count'} = $record->{'citation-count'};
                $citations->{$match}->{'articles'} = $record->{'articles'};

                $hierarchy->{$selected}->{$match} = {};
            }
        }

        # process redirects

        for my $redirect (keys %{$redirects->{$selected}}) {

            next if (exists $falsePositives->{$subject}->{$redirect});
            next if (exists $falsePositives->{$selected}->{$redirect});

            # process record matches (if any)

            if (exists $specified->{$redirect}->{'record'}) {
                my $record = $specified->{$redirect}->{'record'};

                die "selected =/= redirect! how...\n  selected = $selected\n  redirect = $redirect\n" if ($record->{'target'} ne $selected);    # check

                $citations->{$redirect}->{'formatted'} = formatCitation($redirect, $record);
                $citations->{$redirect}->{'count'} = $record->{'citation-count'};
                $citations->{$redirect}->{'articles'} = $record->{'articles'};

                $hierarchy->{$selected}->{$redirect} = {};

                # process normalization matches to redirect records (if any)

                for my $normalization (keys %{$specified->{$redirect}->{'record'}->{'normalizations'}}) {
                    for my $match (keys %{$normalizations->{$normalization}}) {

                        next if (exists $falsePositives->{$subject}->{$match});
                        next if (exists $falsePositives->{$selected}->{$match});
                        next if (exists $falsePositives->{$redirect}->{$match});

                        next if (exists $specified->{$match});                                              # matches self or other top level
                        next if (isUppercaseMatch($match, $redirect, $redirects->{$selected}));             # both uppercase
                        next if (isUppercaseMatch($match, $selected, $redirects->{$selected}));             # both uppercase

                        my $record = $normalizations->{$normalization}->{$match};

                        $citations->{$match}->{'formatted'} = formatCitation($match, $record);
                        $citations->{$match}->{'count'} = $record->{'citation-count'};
                        $citations->{$match}->{'articles'} = $record->{'articles'};

                        $hierarchy->{$selected}->{$redirect}->{$match} = {};
                    }
                }
            }

            # process normalization matches to redirect (if any)

            for my $normalization (keys %{$specified->{$redirect}->{'normalizations'}}) {
                for my $match (keys %{$normalizations->{$normalization}}) {

                    next if (exists $falsePositives->{$subject}->{$match});
                    next if (exists $falsePositives->{$selected}->{$match});
                    next if (exists $falsePositives->{$redirect}->{$match});

                    next if (exists $specified->{$match});                                              # matches self or other top level
                    next if (isUppercaseMatch($match, $redirect, $redirects->{$selected}));             # both uppercase
                    next if (isUppercaseMatch($match, $selected, $redirects->{$selected}));             # both uppercase

                    my $record = $normalizations->{$normalization}->{$match};

                    $citations->{$match}->{'formatted'} = formatCitation($match, $record);
                    $citations->{$match}->{'count'} = $record->{'citation-count'};
                    $citations->{$match}->{'articles'} = $record->{'articles'};

                    $hierarchy->{$selected}->{$redirect}->{$match} = {};
                }
            }
        }
    }

    # process redirect expansions (have to do separately from prior loop to avoid duplicates)

    for my $selected (keys %{$configuration->{'selected'}}) {

        next if (exists $falsePositives->{$subject}->{$selected});

        next if (($selected =~ /^\p{Uppercase}+$/) and (length($selected) <= 5));       # do not expand short all caps redirects

        # process redirect expansions for redirects

        for my $redirect (keys %{$redirects->{$selected}}) {
            my $records = findRedirectExpansions($dbSpecific, 'journal', $redirect);
            for my $citation (keys %$records) {

                next if (exists $falsePositives->{$subject}->{$citation});
                next if (exists $falsePositives->{$selected}->{$citation});
                next if (exists $falsePositives->{$redirect}->{$citation});

                # can occur multiple times via different redirects so include all

                my $record = $records->{$citation};

                $citations->{$citation}->{'formatted'} = formatCitation($citation, $record);
                $citations->{$citation}->{'count'} = $record->{'citation-count'};
                $citations->{$citation}->{'articles'} = $record->{'articles'};

                $hierarchy->{$selected}->{$redirect}->{$citation} = {};
            }
        }

        # process redirect expansions when selected is a redirect

        if (exists $specified->{$selected}->{'record'}) {
            if ($specified->{$selected}->{'record'}->{'display-format'} eq 'redirect') {
                my $target = $specified->{$selected}->{'record'}->{'target'};
                my $records = findRedirectExpansions($dbSpecific, 'journal', $selected);
                for my $citation (keys %$records) {

                    next if (exists $falsePositives->{$subject}->{$citation});
                    next if (exists $falsePositives->{$selected}->{$citation});

                    # can occur multiple times via different redirects so include all

                    my $record = $records->{$citation};

                    $citations->{$citation}->{'formatted'} = formatCitation($citation, $record);
                    $citations->{$citation}->{'count'} = $record->{'citation-count'};
                    $citations->{$citation}->{'articles'} = $record->{'articles'};

                    $hierarchy->{$target}->{$selected}->{$citation} = {};
                }
            }
        }
    }

    # process patterns

    for my $citation (keys %$patterns) {

        next if (exists $falsePositives->{$subject}->{$citation});

        next if (exists $citations->{$citation});                                                       # already picked up via other methods

        $citations->{$citation}->{'formatted'} = formatCitation($citation, $patterns->{$citation});
        $citations->{$citation}->{'count'} = $patterns->{$citation}->{'citation-count'};
        $citations->{$citation}->{'articles'} = $patterns->{$citation}->{'articles'};

        my $target = $patterns->{$citation}->{'target'};

        if (($citation eq $target) or ($target eq '&mdash;')) {
            $hierarchy->{$citation} = {} unless (exists $hierarchy->{$citation});                       # only create if not already created (parent seen after child)
        }
        else {
            $hierarchy->{$target}->{$citation} = {};
        }
    }

    # process dois

    my $doiCitations;
    my $doiParameters = '';
    my $doiIndex = 1;

    for my $prefix (sort { $a <=> $b } keys %$dois) {

        $doiParameters .= "|doi$doiIndex=" if ($doiIndex > 1);
        $doiParameters .= $prefix;
        $doiIndex++;

        # process field results : field results are only included if there is not a matching
        # citation result as would already have been picked up by name

        for my $citation (keys %{$dois->{$prefix}->{'field'}}) {

            my $temporary1 = "$citation (journal)";
            my $temporary2 = "$citation (magazine)";

            unless (
                (exists $citations->{$citation}) or
                (exists $citations->{$temporary1}) or
                (exists $citations->{$temporary2})
            ) {
                my $record = $dois->{$prefix}->{'field'}->{$citation};

                $doiCitations->{$prefix}->{$citation} = {};

                # include prefix as same journal can be entered with multiple prefixes
                $citations->{$prefix . '::' . $citation}->{'formatted'} = formatDOICitation($dbTitles, $prefix, $citation, $record);
                $citations->{$prefix . '::' . $citation}->{'count'} = $record->{'citation-count'};
                $citations->{$prefix . '::' . $citation}->{'articles'} = $record->{'articles'};
            }

        }

        # process template results

        for my $citation (keys %{$dois->{$prefix}->{'template'}}) {
            my $record = $dois->{$prefix}->{'template'}->{$citation};

            my $match;
            my $temporary1 = "$citation (journal)";
            my $temporary2 = "$citation (magazine)";
            $match = $temporary2 if (exists $citations->{$temporary2});
            $match = $temporary1 if (exists $citations->{$temporary1});
            $match = $citation if (exists $citations->{$citation});                                         # matches to citation result
            $match = $prefix . '::' . $citation if (exists $citations->{$prefix . '::' . $citation});       # matches to field result

            if ($match) {
                # combine doi record with citation record (needed for formatDOICitation)
                $record->{'citation-count'} += $citations->{$match}->{'count'};
                $record->{'articles'} = {%{$record->{'articles'}}, %{$citations->{$match}->{'articles'}}};
                $record->{'article-count'} = scalar keys %{$record->{'articles'}};
                # update citation record with combined result
                my $replacement = $prefix . '::';
                (my $title = $match) =~ s/$replacement//;                                                   # back out prefix from title if field match
                $citations->{$match}->{'formatted'} = formatDOICitation($dbTitles, $prefix, $title, $record);
                $citations->{$match}->{'count'} = $record->{'citation-count'};
                $citations->{$match}->{'articles'} = $record->{'articles'};
            }
            else {
                # new record
                $doiCitations->{$prefix}->{$citation} = {};
                # include prefix as same journal can be entered with multiple prefixes
                $citations->{$prefix . '::' . $citation}->{'formatted'} = formatDOICitation($dbTitles, $prefix, $citation, $record);
                $citations->{$prefix . '::' . $citation}->{'count'} = $record->{'citation-count'};
                $citations->{$prefix . '::' . $citation}->{'articles'} = $record->{'articles'};
            }
        }

    }

    # create final output

    my $entries;

    for my $citation (sort keys %$hierarchy) {
        my $entry = exists $citations->{$citation} ? $citations->{$citation}->{'formatted'} : "[[$citation]]";
        $entries .= "* $entry\n";

        for my $child (sort keys %{$hierarchy->{$citation}}) {
            my $entry = exists $citations->{$child} ? $citations->{$child}->{'formatted'} : "[[$child]]";
            $entries .= "** $entry\n";

            for my $grandchild (sort keys %{$hierarchy->{$citation}->{$child}}) {
                my $entry = exists $citations->{$grandchild} ? $citations->{$grandchild}->{'formatted'} : "[[$grandchild]]";
                $entries .= "*** $entry\n";
            }
        }
    }

    # doiCitations

    for my $prefix (sort keys %$doiCitations) {
        $entries .= "* {{doi prefix|$prefix}}\n";
        for my $citation (sort sortDoiCitation keys %{$doiCitations->{$prefix}}) {
            $entries .= "** $citations->{$prefix . '::' . $citation}->{'formatted'}\n";
        }
    }

    return unless ($entries);         # no results

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
    $result->{'source'} = exists $configuration->{'source'} ? $configuration->{'source'} : '';
    $result->{'note'} = exists $configuration->{'note'} ? $configuration->{'note'} : '';
    $result->{'doi'} = $doiParameters;

    return $result;
}

sub retrieveSpecified {

    # Retrieve the specified targets from wiki pages

    my $info = shift;
    my $type = shift;
    my $pages = shift;

    print "  retrieving $type configuration ...\n";

    my $bot = mybot->new($info);

    my $specified;
    my $newest = 0;

    for my $page (@$pages) {

        my ($text, $timestamp, $revision) = $bot->getText($page);
        unless ($text) {
            die "ERROR: Configuration page not found! --> $page\n";
        }
        $text = removeControlCharacters($text);

        $newest = $revision if ($revision > $newest);

        for my $line (split "\n", $text) {

            $line =~ s/\[\[([^\|\]]+)\|([^\]]+)\]\]/##--##$1##--##$2##-##/g;        # escape [[this|that]]

            if ($line =~ /^\s*\{\{\s*JCW-(selected|pattern|doi-redirects)\s*\|\s*(?:1\s*=\s*)?(.*?)\s*(?:\|(.*?))?\s*\}\}\s*$/i) {
                my $template   = $1;
                my $target     = $2;
                my $additional = $3;

                # pull out source & notes

                if (($additional) and ($additional =~ s/(?:^|\|)\s*source\s*=\s*(.*?)\s*(\||$)/$2/)) {
                    my $rationale = $1;
                    $rationale =~ s/##--##(.*?)##--##(.*?)##-##/[[$1|$2]]/g;        # unescape [[this|that]]
                    $specified->{$target}->{'source'} = $rationale;
                }

                if (($additional) and ($additional =~ s/(?:^|\|)\s*note\s*=\s*(.*?)\s*(\||$)/$2/)) {
                    my $rationale = $1;
                    $rationale =~ s/##--##(.*?)##--##(.*?)##-##/[[$1|$2]]/g;        # unescape [[this|that]]
                    $specified->{$target}->{'note'} = $rationale;
                }

                if ($template eq 'selected') {

                    $specified->{$target}->{'selected'}->{$target} = 1;
                    if ($additional) {
                        my @terms = split(/\|/, $additional);
                        for my $term (@terms) {
                            next unless ($term);
                            $term =~ s/^\d+\s*=\s*//;
                            if ($term =~/^\s*doi\d*\s*=\s*(.+)$/) {
                                $specified->{$target}->{'doi'}->{$1} = 1;
                            }
                            elsif ($term =~/^Category:/) {
                                my $members = $bot->getCategoryMembers($term);
                                for my $member (keys %$members) {
                                    $specified->{$target}->{'selected'}->{$member} = 1;
                                }
                            }
                            else {
                                $specified->{$target}->{'selected'}->{$term} = 1;
                            }
                        }
                    }

                }
                elsif ($template eq 'pattern') {

                    my $exclusion = 'none';
                    if ($additional) {
                        # see if exclusion type specified & capture
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
                            next unless ($term);
                            $specified->{$target}->{'pattern'}->{$exclusion}->{$term} = 1;
                        }
                    }

                }
                elsif ($template eq 'doi-redirects') {
                    if ($additional) {
                        my @terms = split(/\|/, $additional);
                        for my $term (@terms) {
                            if ($term !~ /^10\.\d{4,5}$/) {
                                warn "WARNING: unexpected DOI format --> $target --> $term\n$line\n";
                                next;
                            }
                            $specified->{$target}->{'doi'}->{$term} = 1;
                        }
                    }
                    else {
                        warn "WARNING: missing DOI parameters --> $target\n$line\n";
                    }
                }
            }
        }

    }

    return $specified, $newest;
}

sub saveResult {

    # Save the result to the database

    my $database = shift;
    my $table = shift;
    my $target = shift;
    my $result = shift;

    my $entries = $result->{'entries'};
    my $entryCount = $result->{'entryCount'};
    my $lineCount = $result->{'lineCount'};
    my $articles = $result->{'articles'};
    my $citations = $result->{'citations'};
    my $doi = $result->{'doi'};
    my $source = $result->{'source'};
    my $note = $result->{'note'};

    my $sth = $database->prepare(qq{
        INSERT INTO $table (target, entries, entryCount, lineCount, articles, citations, source, note, doi)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    });
    $sth->execute($target, $entries, $entryCount, $lineCount, $articles, $citations, $source, $note, $doi);

    return;
}

sub sortDoiCitation {

    # Sort the doi citations such that prefix only is always last

    return  1 if ($a eq 'NONE');
    return -1 if ($b eq 'NONE');
    return $a cmp $b;
}

#
# Main
#

my %opts;
getopts('hpq', \%opts);

if ($opts{h}) {
    print "usage: citations-specified.pl [-hpq]\n";
    print "       where: -h = help\n";
    print "              -p = process publishers\n";
    print "              -q = process questionable targets\n";
    print "       by default process both\n";
    exit;
}

my $processPublishers = $opts{p} ? $opts{p} : 0;       # specify publishers
my $processQuestionable = $opts{q} ? $opts{q} : 0;     # specify questionable targets

unless ($processPublishers or $processQuestionable) {
    # non-specified so do both
    $processPublishers = 1;
    $processQuestionable = 1;
}

# handle UTF-8

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

# auto-flush output

$| = 1;

# generate output

print "Generating specified targets ...\n";

my $p0 = Benchmark->new;

# delete existing database & create new one

print "  preparing database ...\n";

my $dbSpecific = citationsDB->new;

if (-e $DBSPECIFIC) {
    $dbSpecific->openDatabase($DBSPECIFIC);
    my @commands;
    my @table;
    if ($processPublishers) {
        push (@commands, (
            q{ DROP TABLE publishers; },
            q{ DELETE FROM revisions WHERE type = "publisher"; },
            q{ DELETE FROM revisions WHERE type = "falsePositive"; },
        ));
        push (@table, @PUBTABLE);
    }
    if ($processQuestionable) {
        push (@commands, (
            q{ DROP TABLE questionables; },
            q{ DELETE FROM revisions WHERE type = "questionable"; },
            q{ DELETE FROM revisions WHERE type = "falsePositive"; },
        ));
        push (@table, @QUETABLE);
    }
    for my $sql (@commands) {
        my $sth = $dbSpecific->prepare($sql);
        $sth->execute;
    }
    $dbSpecific->createTables(\@table);
}
else {
    $dbSpecific->cloneDatabase($DBINDIVIDUAL, $DBSPECIFIC);
    $dbSpecific->openDatabase($DBSPECIFIC);
    $dbSpecific->createTables(\@TABLES);
}

my $dbTitles = citationsDB->new;
$dbTitles->openDatabase($DBTITLES);

# load false positives

my ($falsePositives, $fpRevision) = retrieveFalsePositives($BOTINFO, $FALSEPOSITIVES, $dbTitles);

my $sth = $dbSpecific->prepare('INSERT INTO revisions VALUES (?, ?)');
$sth->execute('falsePositive', $fpRevision);
$dbSpecific->commit;

# retrieve each type & save revisions

my $publishers;
my $questionables;

if ($processPublishers) {
    ($publishers, my $pRevision) = retrieveSpecified($BOTINFO, 'publisher', \@PUBLISHER);
    $sth = $dbSpecific->prepare('INSERT INTO revisions VALUES (?, ?)');
    $sth->execute('publisher', $pRevision);
    $dbSpecific->commit;
}

if ($processQuestionable) {
    ($questionables, my $qRevision) = retrieveSpecified($BOTINFO, 'questionable', \@QUESTIONABLE);
    $sth = $dbSpecific->prepare('INSERT INTO revisions VALUES (?, ?)');
    $sth->execute('questionable', $qRevision);
    $dbSpecific->commit;
}

# combine specified & redirects

my ($specified, $redirects) = combineSpecified($dbTitles, $publishers, $questionables);

# process specified

print "  finding citations for specified ...\n";

my $normalizations;

for my $selected (keys %$specified) {
    my $citation = findCitation($dbSpecific, 'journal', $selected);
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
    my $candidates = findNormalizations($dbSpecific, 'journal', $normalization);
    for my $candidate (keys %$candidates) {
        my $result = findIndividual($dbSpecific, 'journal', $candidate);
        $normalizations->{$normalization}->{$candidate} = $result if ($result);
    }
}
print "  processing normalizations ...                                  \n";

# put it together

print "  generating publisher results ...\n";
for my $publisher (keys %$publishers) {
    my $patterns = findPatternCitations($dbSpecific, $publishers->{$publisher}->{'pattern'});
    my $dois = findDOICitations($dbSpecific, $publishers->{$publisher}->{'doi'});
    my $result = generateResult(
        $publisher,
        $publishers->{$publisher},
        $specified,
        $patterns,
        $dois,
        $redirects,
        $normalizations,
        $falsePositives,
        $dbSpecific,
        $dbTitles
    );
    saveResult($dbSpecific, 'publishers', $publisher, $result) if ($result);
}
$dbSpecific->commit;

print "  generating questionable results ...\n";
for my $questionable (keys %$questionables) {
    my $patterns = findPatternCitations($dbSpecific, $questionables->{$questionable}->{'pattern'});
    my $dois = findDOICitations($dbSpecific, $questionables->{$questionable}->{'doi'});
    my $result = generateResult(
        $questionable,
        $questionables->{$questionable},
        $specified,
        $patterns,
        $dois,
        $redirects,
        $normalizations,
        $falsePositives,
        $dbSpecific,
        $dbTitles
    );
    saveResult($dbSpecific, 'questionables', $questionable, $result) if ($result);
}
$dbSpecific->commit;

$dbSpecific->disconnect;
$dbTitles->disconnect;

my $p1 = Benchmark->new;
my $pd = timediff($p1, $p0);
my $ps = timestr($pd);
$ps =~ s/^\s*(\d+)\swallclock secs.*$/$1/;
print "  specified citations processed in $ps seconds\n";
