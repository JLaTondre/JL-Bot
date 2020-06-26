package citationsDB;

use strict;
use warnings;

use Carp;
use DBI;
use File::Copy;

#
# Internal Subroutines
#


#
# External Subroutines
#

sub new {

    my $class = shift;

    my $self = bless {}, $class;

    return $self;
}

sub cloneDatabase {

    my $self        = shift;
    my $source      = shift;
    my $destination = shift;

    unless (($source) and ($destination)) {
        croak "\nMySqlite->cloneDatabase: database files not specified!";
    }

    unless (-f $source) {
        croak "\nMySqlite->cloneDatabase: source database file does not exist!";
    }

    if (-f $destination) {
        croak "\nMySqlite->cloneDatabase: destination database file already exists!";
    }

    copy($source, $destination)
        or croak "\nMySqlite->cloneDatabase: file copy failed!";

    return;
}

sub commit {

    my $self = shift;

    $self->{dbh}->commit();

    return;
}

sub createIndexes {

    my $self    = shift;
    my $indexes = shift;

    for my $index (@$indexes) {
        my $sth = $self->{'dbh'}->prepare($index);
        $sth->execute();
    }
    $self->{'dbh'}->commit();

    return;
}

sub createTables {

    my $self   = shift;
    my $tables = shift;

    for my $table (@$tables) {
        my $sth = $self->{'dbh'}->prepare($table);
        $sth->execute()
    }
    $self->{'dbh'}->commit();

    return;
}

sub disconnect {

    my $self = shift;

    $self->{'dbh'}->commit();
    $self->{'dbh'}->disconnect;

    return;
}

sub openDatabase {

    my $self = shift;
    my $file = shift;

    unless ($file) {
        croak "\nMySqlite->openDatabase: database file not specified!";
    }

    my $dbh = DBI->connect("dbi:SQLite:dbname=$file",'','')
        or croak '\nMySqlite->openDatabase: database open failed: ' . DBI->errstr;
    $dbh->{AutoCommit} = 0;
    $dbh->{PrintError} = 0;
    $dbh->{RaiseError} = 1;
    $dbh->{sqlite_unicode} = 1;

    $self->{'dbh'} = $dbh;

    return;
}

sub prepare {

    my $self    = shift;
    my $prepare = shift;

    my $sth = $self->{'dbh'}->prepare($prepare);

    return $sth;
}

1;
