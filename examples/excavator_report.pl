#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use List::Util            (qw( first sum ));
use Games::Lacuna::Client ();
use Getopt::Long          (qw(GetOptions));

if ( $^O !~ /MSWin32/) {
    $Games::Lacuna::Client::PrettyPrint::ansi_color = 1;
}

my $planet_name;
my $help;
GetOptions(
    'planet=s' => \$planet_name,
    'c|color!' => \$Games::Lacuna::Client::PrettyPrint::ansi_color,
    'h|help' => \$help,
);

usage() if $help;

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
            $buildings->{$_}->{name} eq 'Archaeology Ministry'
    } keys %$buildings;

    next if not $arch_id;
    
    my $arch   = $client->building( id => $arch_id, type => 'Archaeology' );
    my $excavators = $arch->view_excavators();
    next unless defined $excavators;
    
    printf "%s\n", $name;
    print "=" x length $name;
    print "\n";

    printf "\n%d of %d excavators in place. ", (scalar @{$excavators->{excavators}}) - 1, $excavators->{max_excavators};

    my $unused_excavation_sites = $excavators->{max_excavators} - (scalar @{$excavators->{excavators}}) + 1;;

    if ( $unused_excavation_sites > 0 ) {
        print _c_('yellow') .  "$name would still support $unused_excavation_sites excavation sites!" .  _c_('reset');
    }
    print "\n\n";

    map {
        printf "%s (%d,%d), Artifact: %d, Glyph: %d, Plan %d, Resource: %d\n", 
            $_->{body}->{name},
            $_->{body}->{x}, $_->{body}->{y}, 
            $_->{artifact}, $_->{glyph}, $_->{plan}, $_->{resource},
    } @{$excavators->{excavators}};
    
    print "\n";
}

sub _c_ {
    use Games::Lacuna::Client::PrettyPrint;
    Games::Lacuna::Client::PrettyPrint::_c_(@_);
}

sub usage {
  die <<"END_USAGE";
Usage: $0 CONFIG_FILE 
       --planet PLANET_NAME

CONFIG_FILE defaults to 'lacuna.yml'

If --planet arg is missing, the report will entail all colonies of the empire.

END_USAGE
}


