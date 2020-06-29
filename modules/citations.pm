package citations;

use strict;
use warnings;

use Carp;
use Exporter;
use vars qw(@EXPORT @EXPORT_OK);

use Clone qw( clone );
use Switch;
use Text::LevenshteinXS qw( distance );
use Text::Unidecode;
use Unicode::Normalize;

use utf8;

our @ISA       = qw(Exporter);
our @EXPORT    = ();
our @EXPORT_OK = qw(
    checkInterwiki
    findCitation
    findIndividual
    findTemplates
    loadInterwiki
    findNormalizations
    findRedirectExpansions
    formatCitation
    initial
    isUppercaseMatch
    loadRedirects
    normalizeCitation
    queryDate
    removeControlCharacters
    retrieveFalsePositives
    setFormat
);

#
# Internal Subroutines
#

#
# Exported Subroutines
#

sub checkInterwiki {

    # Check if the display title will result in an interwiki link.

    my $display  = shift;
    my $prefixes = shift;

    if ($display =~ /^:?(.+):/) {
        my $prefix = lc $1;
        return $prefixes->{$prefix} if exists $prefixes->{$prefix};
    }

    return 0;
}

sub findCitation {

    # Find individual citation along with articles & normalization

    my $database = shift;
    my $type = shift;
    my $citation = shift;

    my $sth = $database->prepare('
        SELECT i.target, i.dFormat, i.cCount, i.aCount, c.article, n.normalization
        FROM individuals AS i, citations AS c, normalizations AS n
        WHERE i.type = c.type
        AND i.type = n.type
        AND i.type = ?
        AND i.citation = c.citation
        AND i.citation = n.citation
        AND i.citation = ?
    ');
    $sth->bind_param(1, $type);
    $sth->bind_param(2, $citation);
    $sth->execute();

    my $result;

    while (my $ref = $sth->fetchrow_hashref()) {
        # due to join, multiple duplicate results will be returned for these
        $result->{'article-count'} = $ref->{'aCount'};
        $result->{'citation-count'} = $ref->{'cCount'};
        $result->{'display-format'} = $ref->{'dFormat'};
        $result->{'target'} = $ref->{'target'};
        # article & normalization can have multiple results
        $result->{'articles'}->{ $ref->{'article'} } = 1;
        $result->{'normalizations'}->{ $ref->{'normalization'} } = 1;
    }

    return $result;
}

sub findIndividual {

    # Find individual record for a specific citation.

    my $database = shift;
    my $type = shift;
    my $citation = shift;

    my $sth = $database->prepare('
        SELECT i.target, i.dFormat, i.cCount, i.aCount, c.article
        FROM individuals AS i, citations AS c
        WHERE i.type = c.type
        AND i.type = ?
        AND i.citation = c.citation
        AND i.citation = ?
        AND (
            target = "&mdash;"
            OR target = "Invalid"
        )
    ');
    $sth->bind_param(1, $type);
    $sth->bind_param(2, $citation);
    $sth->execute();

    my $result;

    while (my $ref = $sth->fetchrow_hashref()) {
        # due to join, multiple duplicate results will be returned for these
        $result->{'article-count'} = $ref->{'aCount'};
        $result->{'citation-count'} = $ref->{'cCount'};
        $result->{'display-format'} = $ref->{'dFormat'};
        $result->{'target'} = $ref->{'target'};
        # article can have multiple results
        $result->{'articles'}->{ $ref->{'article'} } = 1;
    }

    return $result;
}

sub findNormalizations {

    # Find citations that match the candidate normalization

    my $database = shift;
    my $type = shift;
    my $candidate = shift;

    # 0-2  = process with delta of 0
    # 3-5  = process with delta of 1
    # 6-20 = process with delta of 2
    # 21+  = process with delta of 3

    my $length = length($candidate);
    my $delta = 0;
    my $like;

    # create patterns based on beginning & ending characters and the max delta
    # there should be a way to do this dynamically vs. if...elsif

    if ($length < 3) {
        $like = qq{
            normalization = "$candidate"
        };
    }
    elsif ($length < 6) {
        $delta = 1;
        my $start0 = substr($candidate, 0, 1);
        my $start1 = substr($candidate, 1, 2);
        my $last0 = substr($candidate, $length - 1, 1);
        my $last1 = substr($candidate, $length - 2, 1);
        $like = qq{ (
                normalization LIKE "$start0%"
                OR normalization LIKE "$start1%"
                OR normalization LIKE "_$start0%"
                OR normalization LIKE "_$start1%"
            )
            AND (
                normalization LIKE "%${last0}"
                OR normalization LIKE "%${last1}"
                OR normalization LIKE "%${last0}_"
                OR normalization LIKE "%${last1}_"
            )
        };
    }
    elsif ($length < 21) {
        $delta = 2;
        my $start0 = substr($candidate, 0, 1);
        my $start1 = substr($candidate, 1, 2);
        my $start2 = substr($candidate, 2, 2);
        my $last0 = substr($candidate, $length - 1, 1);
        my $last1 = substr($candidate, $length - 2, 1);
        my $last2 = substr($candidate, $length - 3, 1);
        $like = qq{ (
                normalization LIKE "$start0%"
                OR normalization LIKE "$start1%"
                OR normalization LIKE "$start2%"
                OR normalization LIKE "_$start0%"
                OR normalization LIKE "_$start1%"
                OR normalization LIKE "_$start2%"
                OR normalization LIKE "__$start0%"
                OR normalization LIKE "__$start1%"
                OR normalization LIKE "__$start2%"
            )
            AND (
                normalization LIKE "%${last0}"
                OR normalization LIKE "%${last1}"
                OR normalization LIKE "%${last0}_"
                OR normalization LIKE "%${last1}_"
                OR normalization LIKE "%${last2}_"
                OR normalization LIKE "%${last0}__"
                OR normalization LIKE "%${last1}__"
                OR normalization LIKE "%${last2}__"
            )
        };
    }
    else {
        $delta = 3;
        my $start0 = substr($candidate, 0, 1);
        my $start1 = substr($candidate, 1, 2);
        my $start2 = substr($candidate, 2, 2);
        my $start3 = substr($candidate, 3, 2);
        my $last0 = substr($candidate, $length - 1, 1);
        my $last1 = substr($candidate, $length - 2, 1);
        my $last2 = substr($candidate, $length - 3, 1);
        my $last3 = substr($candidate, $length - 4, 1);
        $like = qq{ (
                normalization LIKE "$start0%"
                OR normalization LIKE "$start1%"
                OR normalization LIKE "$start2%"
                OR normalization LIKE "$start3%"
                OR normalization LIKE "_$start0%"
                OR normalization LIKE "_$start1%"
                OR normalization LIKE "_$start2%"
                OR normalization LIKE "_$start3%"
                OR normalization LIKE "__$start0%"
                OR normalization LIKE "__$start1%"
                OR normalization LIKE "__$start2%"
                OR normalization LIKE "__$start3%"
                OR normalization LIKE "___$start0%"
                OR normalization LIKE "___$start1%"
                OR normalization LIKE "___$start2%"
                OR normalization LIKE "___$start3%"
            )
            AND (
                normalization LIKE "%${last0}"
                OR normalization LIKE "%${last1}"
                OR normalization LIKE "%${last2}"
                OR normalization LIKE "%${last3}"
                OR normalization LIKE "%${last0}_"
                OR normalization LIKE "%${last1}_"
                OR normalization LIKE "%${last2}_"
                OR normalization LIKE "%${last3}_"
                OR normalization LIKE "%${last0}__"
                OR normalization LIKE "%${last1}__"
                OR normalization LIKE "%${last2}__"
                OR normalization LIKE "%${last3}__"
                OR normalization LIKE "%${last0}___"
                OR normalization LIKE "%${last1}__-"
                OR normalization LIKE "%${last2}__-"
                OR normalization LIKE "%${last3}__-"
            )
        };
    }

    my $minimum = $length - $delta;
    my $maximum = $length + $delta;

    my $sql = qq{
        SELECT citation, normalization
        FROM normalizations
        WHERE type = "$type"
        AND length >= $minimum
        AND length <= $maximum
        AND $like
    };

    my $sth = $database->prepare($sql);
    $sth->execute();

    my $results;

    # redo delta based on 'non-countable' terms
    # need to do after query as want to match with term, but reduce delta if needed

    my $temporary = $candidate;
    if ($temporary =~ s/(?:journals?|newsl?(?:etter)?|magazine|proc(?:eeding)?s?|rev(?:iew)?s?|online|trans(?:action)?s?)//g) {
        $length = length($temporary);
        # 0-2  = process with delta of 0
        # 3-5  = process with delta of 1
        # 6-20 = process with delta of 2
        # 21+  = process with delta of 3
        $delta = 2 if ($length < 21);
        $delta = 1 if ($length < 6);
        $delta = 0 if ($length < 3);
    }

    while (my $ref = $sth->fetchrow_hashref()) {
        my $citation = $ref->{'citation'};
        my $normalization = $ref->{'normalization'};
        if (distance($normalization, $candidate) <= $delta) {
            $results->{$citation} = 1;
        }
    }

    return $results;
}

sub findTemplates {

    # Find templates in a text string.

    my $text = shift;

    # the following code is based on perlfaq6's "Can I use Perl regular
    # expressions to match balanced text?" example

    my $regex = qr/
        (               # start of bracket 1
        \{\{           # match an opening template
            (?:
            [^{}]++      # one or more non brackets, non backtracking
            |
            (?1)         # recurse to bracket 1
            )*
        \}\}           # match a closing template
        )               # end of bracket 1
        /x;

    my @queue   = ( $text );
    my @templates = ();

    while( @queue ) {
        my $string = shift @queue;
        my @matches = $string =~ m/$regex/go;
        @templates = ( @templates, @matches);
        unshift @queue, map { s/^\{\{//; s/\}\}$//; $_ } @matches;
    }

    return \@templates;
}

sub findRedirectExpansions {

    # Find citations that are longer forms of a redirect

    my $database = shift;
    my $type = shift;
    my $redirect = shift;

    my $results;

    if ($redirect =~ / [A-Z]\.?$/) {

        my $candidate = $redirect;
        $candidate =~ s/\.$/_/;         # if ends in period require two characters so avoids matching with self
        $candidate .= '_%';

        my $sth = $database->prepare('
            SELECT i.citation, i.target, i.dFormat, i.cCount, i.aCount, c.article, n.normalization
            FROM individuals AS i, citations AS c, normalizations AS n
            WHERE i.type = c.type
            AND c.type = n.type
            AND i.type = ?
            AND i.citation = c.citation
            AND i.citation = n.citation
            AND i.citation LIKE ?
            AND (
                target = "&mdash;"
                OR target = "Invalid"
            )
        ');
        $sth->bind_param(1, $type);
        $sth->bind_param(2, $candidate);
        $sth->execute();

        while (my $ref = $sth->fetchrow_hashref()) {
            my $citation = $ref->{'citation'};
            # due to join, multiple duplicate results will be returned for these
            $results->{$citation}->{'article-count'} = $ref->{'aCount'};
            $results->{$citation}->{'citation-count'} = $ref->{'cCount'};
            $results->{$citation}->{'display-format'} = $ref->{'dFormat'};
            $results->{$citation}->{'target'} = $ref->{'target'};
            # article & normalization can have multiple results
            $results->{$citation}->{'articles'}->{ $ref->{'article'} } = 1;
            $results->{$citation}->{'normalizations'}->{ $ref->{'normalization'} } = 1;
        }
    }

    return $results;
}

sub formatCitation {

    # Return a formatted citation

    my $citation = shift;
    my $record = shift;

    my $format = $record->{'display-format'};
    my $citations = $record->{'citation-count'};
    my $articles = $record->{'article-count'};

    my $formatted = setFormat('display', $citation, $format);

    return "$formatted ($citations in $articles)";
}

sub initial {

    # Return the first 'letter' of the title | citation.

    my $term = shift;

    my $initial = $term;

    $initial =~ s/^(?:(?:the|les?|la)\s|l')?(.).*$/$1/i;    # extract first character
    $initial = 'Non' if ($initial !~ /\p{IsASCII}/);        # non-letters and non-numbers
    $initial = 'Num' if ($initial !~ /\p{IsAlpha}/);        # numbers
    $initial = uc $initial if ($initial =~ /^[a-z]/);       # make sure alpha are uppercase

    return $initial;
}

sub isUppercaseMatch {

    # Determine if citation matches on all uppercase

    my $candidate = shift;
    my $comparison = shift;
    my $redirects = shift;

    # remove disambiguation

    $candidate =~ s/ \((?:journal|magazine)\)$//;
    $comparison =~ s/ \((?:journal|magazine)\)$//;

    # check cases

    if ($candidate =~ /^\p{Uppercase}+$/) {

        if ($comparison =~ /^\p{Uppercase}+$/) {
            # both all uppercase
            return 1;
        }
        elsif ($comparison !~ / /) {
            # if single word, check if uppercase redirect exists
            (my $noPunctuation = $comparison) =~ s/\p{Punct}//g;
            if (exists $redirects->{uc $noPunctuation}) {
                return 1;
            }
        }
    }

    return 0;
}

sub loadInterwiki {

    # Loads Interwiki prefixes from a configuration file.

    my $file = shift;

    print "  loading interwiki prefixes ...\n";

    open FILE, '<:utf8', $file
        or croak "ERROR: Could not open file ($file)!\n  $!\n\n";

    my $prefixes;

    while (<FILE>) {

        chomp;

        if (/^(INTERWIKI|LANGUAGE) = (.+)$/) {
            my $type   = $1;
            my $prefix = $2;
            $prefixes->{$prefix} = $type;
        }

    }

    close FILE;

    return $prefixes;
}

sub loadRedirects {

    # Load redirects to the target from the database.

    my $database = shift;
    my $target   = shift;

    my $sth = $database->prepare('SELECT title FROM titles WHERE target = ?');
    $sth->bind_param(1, $target);
    $sth->execute();

    my $results;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $title = $ref->{'title'};
        $results->{$title} = 1;
    }

    return $results;
}

sub normalizeCitation {

    # Normalize the citation.

    my $term = shift;

    # convert to ASCII only

    $term = NFKD( $term );
    $term =~ s/\p{NonspacingMark}//g;
    $term = unidecode($term);

    $term = lc $term;

    # standardize abbreviations

    $term =~ s/\babh\b/abhandlungen/g;              # abh
    $term =~ s/\bann\b/annal/g;                     # annal
    $term =~ s/\bbull\b/bulletin/g;                 # bull
    $term =~ s/\bc\.? ?r\.?\b/compte rendu/g;       # cr, c.r., c. r.
    $term =~ s/\bintl?\b/international/g;           # intl?
    $term =~ s/\bj\b/journal/g;                     # j
    $term =~ s/\blett\b/letter/g;                   # lett
    $term =~ s/\bmag\b/magazine/g;                  # mag
    $term =~ s/\bnewsl\b/newsletter/g;              # newsl
    $term =~ s/\bnot\b/notice/g;                    # not
    $term =~ s/\bproc\b/proceeding/g;               # proc
    $term =~ s/\bpubl\b/publication/g;              # publ
    $term =~ s/\brev\b/review/g;                    # rev
    $term =~ s/\bsuppl\b/supplement/g;              # suppl
    $term =~ s/\btrans\b/transaction/g;             # trans
    $term =~ s/\bz\b/zeitschrift/g;                 # z

    # standardize spellings

    $term =~ s/\bcatalogue\b/catalog/g;                 # catalogue
    $term =~ s/\bencyclop(?:ae|æ)dia\b/encyclopedia/g;  # encyclopaedia | encyclopædia

    # punctuation dependent processing first

    $term =~ s/(?<=.{2})\s*=.*$//;                  # keep = remove (where keep is at least two characters)
    $term =~ s/(?<=.{9})\s*\/.*$//;                 # keep / remove (where keep is at least nine characters)

    my $regex = qr/
        \s*:\s*
        (?:an|the|les?|la|l')?\s+
        (?:official|international)?\s*
        (?:blog|bulletin|gazette|guide|handbook|journal|magazine|newsletter)
        .*$
    /x;

    $term =~ s/$regex//o;                           # : The Official Journal of the ...

    $term =~ s/\b(?:the|les?|la|l')\b//g;           # the
    $term =~ s/\b(?:of|fur|des?|du|d')\b//g;        # of

    $term =~ s/\bn\.?[sf]\.?\b//g;                  # ns | nf
    $term =~ s/\bo\.?s\.?\b//g;                     # os

    # everything else should be punctuation independent

    $term =~ s/[[:punct:]]+/ /g;                    # punctuation

    $term =~ s/\baccepted in\b//g;                  # accepted in
    $term =~ s/\bin press\b//g;                     # in press
    $term =~ s/\bsubmitted(?: (?:in|to))?\b//g;     # submitted | submitted in | submitted to
    $term =~ s/\bto be published(?: in)?\b//g;      # to be published
    $term =~ s/\bto appear(?: in)?\b//g;            # to appear | to appear in

    $term =~ s/\b(?:and|et|und)\b//g;               # and
    $term =~ s/\bin\b//g;                           # in
    $term =~ s/\bfor\b//g;                          # for

    $regex = qr/
        \b
        (?:
            abstract            |
            new                 |
            nouv(?:elle)?       |
            novaya              |
            orig(?:inal)?       |
            supplement(?:um)?   |
            first               |
            second              |
            third               |
            fourth              |
            fifth               |
            sixth               |
            seventh             |
            eighth              |
            ninth               |
            tenth               |
            premiere            |
            seconde             |
            troisieme           |
            quatrieme           |
            cinqieme            |
            sixieme             |
            septieme            |
            huitieme            |
            neuvieme            |
            dixieme             |
            \d+(?:st|nd|rd|th)  |
            1er                 |
            (?:[2-9]|10)eme?
        )
        \s+
        (?:
            ser(?:ies?)?        |
            seriya              |
            part                |
            section             |
            v(?:ol.?(?:ume)?)?
        )
        \b
    /x;

    $term =~ s/$regex//go;                          # WORD série | series | part | section | volume

    $regex = qr/
        \b
        (?:
            ser(?:ies?|\.)?     |
            parts?              |
            sections?           |
            vol(?:ume|\.)?      |
            iss(?:ue)?          |
            abteilung           |
            supplementbande     |
            beihefte            |
            teil
        )
        \s+
        [a-z]
        \b
        .*$
    /x;

    $term =~ s/$regex//go;                          # série | series | part | section | volume | issue A ANYTHING

    $regex = qr/
        \b
        (?:
            ser(?:ies?|\.)?         |
            seriya                  |
            parts?                  |
            sections?               |
            v(?:ols?\.?(?:umes?)?)? |
            iss(?:ues?)?            |
            abteilung               |
            supplementbande         |
            beihefte                |
            teil
        )
        \s+
        (?:
            nouv(?:elle|\.)?    |
            novaya              |
            orig(?:inal|\.)?    |
            one                 |
            two                 |
            three               |
            four                |
            five                |
            six                 |
            seven               |
            eight               |
            nine                |
            ten                 |
            premiere            |
            seconde             |
            troisieme           |
            quatrieme           |
            cinqieme            |
            sixieme             |
            septieme            |
            huitieme            |
            neuvieme            |
            dixieme             |
            un                  |
            deux                |
            trois               |
            quatre              |
            cinq                |
            sept                |
            huit                |
            neuf                |
            dix                 |
            [mdclxvi]+          |
            [a-z]               |
            no(?:\s*\d+)+       |
            ndeg(?:\s*\d+)+     |
            \d+(?:\s*\d+)*
        )
        \b
    /x;

    $term =~ s/$regex//go;                          # série | series | part | section | volume | issue WORD

    $term =~ s/\bndeg\s*\d+\b//g;                   # N° number (without series)

    $regex = qr/
        \b
        (?:
            n(?:o|um(?:ber)?)?  |
            p(?:ages?|\s*p)?
        )
        (?:
            (?:\s*\d+)          |
            \s+[mdclxvi]+
        )+
        \b
    /x;
    # need space with roman numerals so doesn't pick up words starting with n | p

    $term =~ s/$regex//go;                          # number | pages NUMBER

    $term =~ s/\bsupplement(?:um)?s?\b//g;          # supplementum | supplement
    $term =~ s/\bneue folge\b//g;                   # neue folge

    $term =~ s/\bmonogr(?:aphs?)?\b//g;             # monograph | monogr
    $term =~ s/\blett(?:ers?)?$//g;                 # letter | lett -- needs $ or breaks things

    $term =~ s/ special issue.*$//;                 # journal special issue topic
    $term =~ s/ special edition.*$//;               # journal special edition topic

    $term =~ s/ +/ /g;                              # single spaces

    $term =~ s/^ +//;                               # spaces at start
    $term =~ s/ +$//;                               # spaces at end

    $term =~ s/\se?\d+(?:\se?\d+)*$//;              # numbers at end

    $term =~ s/\sjan(?:uary)?$//;                   # months at end
    $term =~ s/\sfeb(?:ruary)?$//;
    $term =~ s/\smar(?:ch)?$//;
    $term =~ s/\sapr(?:il)?$//;
    $term =~ s/\smay$//;
    $term =~ s/\sjune?$//;
    $term =~ s/\sjuly?$//;
    $term =~ s/\saug(?:ust)?$//;
    $term =~ s/\ssept?(?:ember)?$//;
    $term =~ s/\soct(?:ober)?$//;
    $term =~ s/\snov(?:ember)?$//;
    $term =~ s/\sdec(?:ember)?$//;

    $term =~ s/\se?\d+(?:\se?\d+)*$//;              # numbers at end (repeated)

    $term =~ s/\s//g;                               # spaces

    $term = '--' unless ($term);

    return $term;
}

sub queryDate {

    # Query the dump date from the titles database.

    my $file = shift;

    my $database = citationsDB->new;
    $database->openDatabase($file);

    my $sth = $database->prepare("
        SELECT revision
        FROM revisions
        WHERE type = 'date'
    ");
    $sth->execute();

    my $revision;

    while (my $ref = $sth->fetchrow_hashref()) {
        $revision = $ref->{'revision'};
    }

    $database->commit;
    $database->disconnect;

    return $revision;
}

sub removeControlCharacters {

    # Remove control characters that interfere with checking matches

    my $text = shift;

    $text =~ s/\x{200e}//g;      # remove left-to-right characters
    $text =~ s/\x{200f}//g;      # remove right-to-left characters

    return $text;
}

sub retrieveFalsePositives {

    # Retrieve false positives from wiki page.

    my $info        = shift;
    my $page        = shift;
    my $database    = shift;
    my $noRedirects = shift;   # optional flag

    print "  retrieving false positives ...\n";

    my $bot = mybot->new($info);

    my ($text, $timestamp, $revision) = $bot->getText($page);
    $text = removeControlCharacters($text);

    my $falsePositives;

    for my $line (split "\n", $text) {
        if ($line =~ /^\s*\{\{\s*[JM]CW-exclude\s*\|\s*(.*?)\s*\|\s*(?:2\s*=\s*)?(.*?)\s*(?:\|\s*c\s*=\s*\d+\s*)?\}\}\s*$/i) {
            my $target = $1;
            my $ignore = $2;
            $falsePositives->{$target}->{$ignore} = 1;
        }
    }

    unless ($noRedirects) {
        # ignore redirects to target also
        for my $target (keys %$falsePositives) {
            my $redirects = loadRedirects($database, $target);
            for my $redirect (keys %$redirects) {
                if (exists $falsePositives->{$redirect}) {
                    # if redirect already in false positives, need to combine the two hash refs
                    my $existing = $falsePositives->{$redirect};
                    my $additions = clone($falsePositives->{$target});
                    %{$falsePositives->{$redirect}} = ( %$existing, %$additions );
                }
                else {
                    $falsePositives->{$redirect} = clone($falsePositives->{$target});
                }
            }
        }
    }

    return $falsePositives, $revision;
}

sub setFormat {

    # Returns the formated citation | target for the specified format

    my $type   = shift;
    my $record = shift;
    my $format = shift;

    $record = ":$record" if ($record =~ /^(?:\/|Category\s*:|File\s*:|Image\s*:)/i);

    if ($type eq 'display') {
        $_ = $record;
        if (s/ \((?:journal|magazine)\)$//o) {
            switch ($format) {
                case 'existent'                 { return "'''[[$record|$_]]'''" }
                case 'disambiguation'           { return "'''[[$record|<u>$_</u>]]'''" }
                case 'nonexistent'              { return "[[$record]]" }
                case 'normal'                   { return "'''[[$record|$_]]'''" }
                case 'nowiki'                   { return "<nowiki>$record</nowiki>" }
                case 'redirect'                 { return "''[[$record|$_]]''" }
                case 'redirect-disambiguation'  { return "''[[$record|<u>$_</u>]]''" }
                else		                    { croak "ERROR: setFormat unknown format1 = $record -- $format\n\n" }
            }
        }
    }

    switch ($format) {
        case 'existent'                 { return "'''[[$record]]'''" }
        case 'disambiguation'           { return "'''[[$record|<u>$record</u>]]'''" }
        case 'none'                     { return $record }
        case 'nonexistent'              { return "[[$record]]" }
        case 'normal'                   { return "[[$record]]" }
        case 'nowiki'                   { return "<nowiki>$record</nowiki>" }
        case 'redirect'                 { return "''[[$record]]''" }
        case 'redirect-disambiguation'  { return "''[[$record|<u>$record</u>]]''" }
        else		                    { croak "ERROR: setFormat unknown format2 = $record -- $format\n\n" }
    }

    croak "ERROR: should not get here (setFormat)\n\n";
}

1;