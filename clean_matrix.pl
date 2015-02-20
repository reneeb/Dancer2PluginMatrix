#!/usr/bin/env perl

use strict;
use warnings;

use File::Path::Tiny;
use File::Spec;
use File::Basename;
use Getopt::Long;
use DBI;

my $dancerlibs = File::Spec->catdir( $ENV{HOME}, qw/dancerlib/ ); 
my $db         = _connect_db();
my $perlbrew   = File::Spec->catdir( $ENV{HOME}, qw/perl5 perlbrew perls/ );

GetOptions(
    'perl=s'   => \my @perls,
    'dancer=s' => \my @dancers,
);

my $delete_perl = 'DELETE FROM matrix WHERE perl_version = ?';
my $delete_dancer = 'DELETE FROM matrix WHERE dancer_version = ?';

for my $perl ( @perls ) {
    $db->do( $delete_perl, undef, $perl );
    File::Path::Tiny::rm( File::Spec->catdir( $dancerlibs, $perl ) );
    qx{perlbrew uninstall $perl};
}

my @perl_versions = _get_perl_versions($perlbrew);

for my $dancer ( @dancers ) {
    $db->do( $delete_dancer, undef, $dancer );
    for my $perl ( @perl_versions ) {
        File::Path::Tiny::rm( File::Spec->catdir( $dancerlibs, $perl, $dancer ) );
    }
}

sub _get_perl_versions {
    my @versions;
    opendir my $dirh, shift;
    while ( my $version = readdir $dirh ) {
        next if $version =~ m{\A\.\.?\z};
        $version =~ s/perl-//;
        push @versions, $version;
    }
    closedir $dirh;

    return @versions;
}

sub _connect_db {
    my $dbfile = File::Spec->catfile( dirname( __FILE__ ), '.plugins.sqlite' );
    my $exists = -f $dbfile;

    die "Cannot find DB" if !$exists;

    my $dbh = DBI->connect( 'DBI:SQLite:' . $dbfile );
    return $dbh;
}
