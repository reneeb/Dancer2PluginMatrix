#!/usr/bin/env perl

use strict;
use warnings;

use File::Path::Tiny;
use File::Spec;
use MetaCPAN::Client;
use Data::Dumper;

my $perlbrew    = File::Spec->catdir( $ENV{HOME}, qw/perl5 perlbrew perls/ );
my @perls       = _get_perl_versions( $perlbrew );
my @dancer = _get_and_install_dancer_versions( $perlbrew, \@perls );

#print Dumper [ \@perls, \@dancer ];

sub _get_and_install_dancer_versions {
    my $perlbrew = shift;
    my $perls    = shift;

    my $mcpan_client   = MetaCPAN::Client->new;
    my $latest         = $mcpan_client->release( 'Dancer2' );
    my $latest_version = $latest->version;

    my $dir = File::Spec->catdir( $ENV{HOME}, qw/dancerlib/ );
    my @dancer_versions;
    opendir my $dancerlibh, File::Spec->catdir( $dir, $perls->[0] );
    while ( my $version = readdir $dancerlibh ) {
        next if $version !~ m{\A[0-9]+\.};
        push @dancer_versions, $version;
    }
    closedir $dancerlibh;
    push @dancer_versions, $latest_version;

    for my $perl ( @{ $perls } ) {
        my $cpanm   = File::Spec->catfile( $perlbrew, 'perl-' . $perl, 'bin', 'cpanm' );
        print STDERR "install DBD::Pg, DBD::mysql and cpanm-reporter...";
        qx{ $cpanm DBD::Pg };
        qx{ $cpanm --force DBD::mysql };
        qx{ $cpanm App::cpanminus::reporter };
        print STDERR "done\n";

        VERSION:
        for my $version ( @dancer_versions ) {
            print STDERR "Work on $dir/$perl/$version...";

            my $path = File::Spec->catdir( $dir, $perl, $version );
            File::Path::Tiny::mk( $path ) if !-d $path;

            my $inc   = File::Spec->catdir( $path, 'lib', 'perl5' );
            my $perlx = File::Spec->catfile( $perlbrew, 'perl-' . $perl, 'bin', 'perl' );
            my $qx    = qx{ $perlx -I$inc -MDancer2 -E 'say Dancer2->VERSION' 2>&1};

            if ( $qx !~ m{Can't locate Dancer2.pm} ) {
                print STDERR $qx;
                next VERSION;
            }

            my ($release) = $mcpan_client->release({
                'all' => [
                    { distribution => 'Dancer2' },
                    { version      => "$version" },
                ],
            });
            my $target = $release->next->download_url;

            my @urls = ($target);
            for my $new ( qw{http://search.cpan.org/CPAN/ http://backpan.perl.org/} ) {
                my $new_target = $target =~ s{https://cpan.metacpan.org/}{$new}r;
                push @urls, $new_target;
            }

            URL:
            while ( @urls ) {
                my $url = shift @urls;
                print STDERR "$cpanm -L $path $url...\n";
                qx{ $cpanm -L $path $url };
                last URL if !$?;
            }

            my $check = qx{ $perlx -I$inc -MDancer2 -E 'say Dancer2->VERSION'};
            print STDERR "ok...\n" if $check =~ m{$version};
        }
    }

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
