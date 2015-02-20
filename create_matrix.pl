#!/usr/bin/perl

# PODNAME: create_matrix

use strict;
use warnings;

use Data::Dumper;
use File::Basename;
use File::Spec;
use IO::File;
use MetaCPAN::Client;
use Parse::CPAN::Packages;
use LWP::Simple qw(getstore);
use File::Temp ();
use JSON;
use DBI;
use List::Util qw(first);
use HTTP::Tiny;

our $VERSION = 0.03;

my $db              = _find_or_create_db();
my $perlbrew        = File::Spec->catdir( $ENV{HOME}, qw/perl5 perlbrew perls/ );
my @perl_versions   = _get_perl_versions( $perlbrew );
my @dancer_versions = _get_dancer_versions( \@perl_versions );

my $file = File::Temp->new( UNLINK => 1, SUFFIX => '.txt.gz' );
print STDERR "Download 02packages.details.txt.gz...\n";
my $url = 'http://www.cpan.org/modules/02packages.details.txt.gz';
getstore $url, $file->filename;
print STDERR "downloaded " . (-s $file->filename) . " bytes to " . $file->filename . "\n";

my %modules = get_modules( $file->filename, \@ARGV );
create_matrix( $db, $perlbrew, \@perl_versions, \@dancer_versions, \%modules, \@ARGV );

sub create_matrix {
    my ($db, $brew, $perls, $dancers, $modules, $requested) = @_;

    my $sth  = $db->prepare( 'INSERT INTO matrix (pname, pversion, abstract, perl_version, dancer_version, result, author) VALUES( ?,?,?,?,?,?,? )' );
    my $sth_select = $db->prepare( 'SELECT pname FROM matrix WHERE pname = ? AND pversion = ? AND perl_version = ? AND dancer_version = ? LIMIT 1');

    print STDERR "Create matrix...\n";

    my $blacklist = File::Spec->catfile( dirname( __FILE__ ), 'blacklist' );
    my %blacklisted_modules;
    if ( -f $blacklist ) {
        print STDERR "read blacklist...";
        if ( open my $fh, '<', $blacklist ) {
            while ( my $line = <$fh> ) {
                chomp $line;
                next if !$line;
                print STDERR "$line\n";
                $blacklisted_modules{$line}++;
            }
            print STDERR "done\n";
        }
        else {
            print STDERR "error ($!)\n";
        }
    }

    my $report = '';

    MODULE:
    for my $module ( sort keys %{ $modules } ) {
        my $name = $module =~ s/-/::/gr;
        my $info = $modules->{$module};

        if ( $requested && @{ $requested } && !first{ $module eq $_ }@{ $requested } ) {
            next MODULE;
        }

        next MODULE if $name eq 'Dancer';
        if ( $blacklisted_modules{$module} ) {
            print STDERR "Skipped $module as it is blacklisted!\n";
            next MODULE;
        }

        for my $perl ( @{ $perls } ) {

            MOJO:
            for my $dancer ( @{ $dancers } ) {
                my $dir     = File::Temp->newdir( CLEANUP => 1 );
                my $dirname = $dir->dirname;

                $sth_select->execute( $module, $info->{version}, $perl, $dancer );
                my $found_name;
                while ( my @row = $sth_select->fetchrow_array ) {
                    $found_name = shift @row;
                }

                next MOJO if $found_name;

                if ( $dancer < $info->{dependency} ) {
                    print STDERR "$module requires Dancer2 " . $info->{dependency} . "\n";
                    $sth->execute( $module, $info->{version}, $info->{abstract}, $perl, $dancer, "-1", $info->{author} );
                    next MOJO;
                }

                print STDERR "cpanm $name ($module) for Perl $perl/Dancer2 $dancer...\n";
                my $cpan  = File::Spec->catfile( $brew, 'perl-' . $perl, 'bin', 'cpanm' );
                my $perlx = File::Spec->catfile( $brew, 'perl-' . $perl, 'bin', 'perl' );
                my $inc   = File::Spec->catfile( $ENV{HOME}, 'dancerlib', $perl, $dancer, "lib", "perl5" );
                my $cpanm_output = qx{ PERL5LIB=$inc $cpan --local-lib $dirname $name };
                my $error        = $? ? 1 : 0;
                my $pversion = $info->{version};

                if ( $cpanm_output =~ m{Successfully installed Dancer2-\d+} ) {
                    $sth->execute( $module, $info->{version}, $info->{abstract}, $perl, $dancer, "-1", $info->{author} );
                }
                elsif ( !$error ) {
                    $sth->execute( $module, $info->{version}, $info->{abstract}, $perl, $dancer, 1, $info->{author} );
                    qx{ cpanm-reporter };            
                }
                else {
                    $sth->execute( $module, $info->{version}, $info->{abstract}, $perl, $dancer, 0, $info->{author} );
                    $report .= sprintf "%s %s (%s/%s)\n", $module, $info->{version}, $perl, $dancer;
                }
            }
        }
    }

    print STDERR $report,"\n";
}

sub get_modules {
    my ($packages_file, $preselected) = @_;

    my $whitelist = File::Spec->catfile( dirname( __FILE__ ), 'whitelist' );
    my %whitelisted_modules;
    if ( -f $whitelist ) {
        print STDERR "read whitelist...";
        if ( open my $fh, '<', $whitelist ) {
            while ( my $line = <$fh> ) {
                chomp $line;
                next if !$line;
                print STDERR "$line\n";
                $whitelisted_modules{$line}++;
            }
            print STDERR "done\n";
        }
        else {
            print STDERR "error ($!)\n";
        }
    }

    print STDERR "Get modules...";

    my $parser        = Parse::CPAN::Packages->new( $packages_file );
    my $mcpan         = MetaCPAN::Client->new(
        ua => HTTP::Tiny->new( agent => 'Dancer Plugin Matrix (dancer.perl-services.de) / ' . $VERSION ),
    );

    my @distributions;
    if ( $preselected && @{ $preselected } ) {
        for my $package ( @{ $preselected } ) {
            my $name = $package =~ s/-/::/gr;
            my $module = $parser->package( $name );
            push @distributions, $module->distribution;
        }
    }
    else {
        @distributions = $parser->latest_distributions;
    }

    my %modules;
    for my $dist ( @distributions ) {
        my $name = $dist->dist;

        next if $name !~ m!^Dancer2-!x && !$whitelisted_modules{$name};

        my $version  = $dist->version;

        my $releases = $mcpan->release({ all => [ { distribution => $name }, { version => $version } ] })->next;
        my $release  = $releases ? $releases : $mcpan->release( $name );
        my $abstract = $release->abstract || '';

        print STDERR "found $name ($version)\n";

        my ($depends) =
            map{$_->{version_numified}}
            grep{
                $_->{module} =~ m{\ADancer2\z}
            }@{ $release->dependency || [{module => 1}] };

        $modules{$name} = +{
            version    => $version,
            abstract   => $abstract,
            dependency => ( $depends || 0 ),
            author     => $release->author,
        };
    }

    print STDERR " found " . (scalar keys %modules) . "modules\n";

    return %modules;
}

sub _find_or_create_db {
    my $dbfile = File::Spec->catfile( dirname( __FILE__ ), '.plugins.sqlite' );
    my $exists = -f $dbfile;

    my $dbh = DBI->connect( 'DBI:SQLite:' . $dbfile );

    if ( !$exists ) {
        my @creates = (
            q~CREATE TABLE matrix ( pname TEXT NOT NULL, pversion TEXT NOT NULL, abstract TEXT, perl_version TEXT NOT NULL, dancer_version TEXT NOT NULL, result TEXT, author TEXT )~,
        );

        $dbh->do( $_ ) for @creates;
    }

    return $dbh;
}

sub _get_dancer_versions {
    my $perls = shift;

    my $dir = File::Spec->catdir( $ENV{HOME}, qw/dancerlib/ );
    my @dancer_versions;
    opendir my $dancerlibh, File::Spec->catdir( $dir, $perls->[0] );
    while ( my $version = readdir $dancerlibh ) {
        next if $version !~ m{\A[0-9]+\.};
        push @dancer_versions, $version;
    }
    closedir $dancerlibh;

    return @dancer_versions;
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
