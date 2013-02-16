#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use List::Util            (qw( first sum ));
use Games::Lacuna::Client ();
use Getopt::Long          (qw(GetOptions));
use Data::Dumper;

if ( $^O !~ /MSWin32/) {
    $Games::Lacuna::Client::PrettyPrint::ansi_color = 1;
}

my $planet_name;
my $help;
my $empire_id;
GetOptions(
    'planet=s' => \$planet_name,
    'empire_id=s' => \$empire_id,
    'c|color!' => \$Games::Lacuna::Client::PrettyPrint::ansi_color,
    'h|help' => \$help,
);

usage() if $help;
usage() unless (defined $planet_name and defined $empire_id);

my $cfg_file = shift(@ARGV) || 'lacuna.yml';
unless ( $cfg_file and -e $cfg_file ) {
  $cfg_file = eval{
    require File::HomeDir;
    require File::Spec;
    my $dist = File::HomeDir->my_dist_config('Games-Lacuna-Client');
    File::Spec->catfile(
      $dist,
      'login.yml'
    ) if $dist;
  };
  unless ( $cfg_file and -e $cfg_file ) {
    die "Did not provide a config file";
  }
}

my $client = Games::Lacuna::Client->new(
	cfg_file => $cfg_file,
	# debug    => 1,
);

# Load the planets
my $empire  = $client->empire->get_status->{empire};

# reverse hash, to key by name instead of id
my %planets = map { $empire->{planets}{$_}, $_ } keys %{ $empire->{planets} };

# Scan each planet
foreach my $name ( sort keys %planets ) {

    next if defined $planet_name && $planet_name ne $name;

    # Load planet data
    my $planet    = $client->body( id => $planets{$name} );
    my $result    = $planet->get_buildings;
    my $body      = $result->{status}->{body};
    
    my $buildings = $result->{buildings};

    # Find the Archaeology Ministry
    my $arch_id = first {
            $buildings->{$_}->{name} eq 'Library of Jith'
    } keys %$buildings;

    next if not $arch_id;
    
    my $arch   = $client->building( id => $arch_id, type => 'LibraryOfJith' );
    my $species_info = $arch->research_species( $empire_id );

    print "Empire ID $empire_id\n";
    print Dumper $species_info->{species};
    print "\n";
    
}


sub usage {
  die <<"END_USAGE";
Usage: $0 CONFIG_FILE 
       --planet PLANET_NAME
       --empire_id EMPIRE_ID

CONFIG_FILE defaults to 'lacuna.yml'

END_USAGE
}


