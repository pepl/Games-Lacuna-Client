#!/usr/bin/perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Games::Lacuna::Client ();
use Getopt::Long qw(GetOptions);
use File::Basename;

##----------------------------------------------------------------------
##----------------------------------------------------------------------
sub show_usage
{
  my $script = basename($0);

  print << "_END_USAGE_";
Usage:  perl $script {--ore} {--amount} {--planet="Planet Name"} account_file

This script will dump ore from an Ore Storage Tank on a planet

Valid options:
  --ore                   Which ore to dump
  --amount                Amount of ore to dump
  --planet="PLANET NAME"  Show information for specified planet
  account_file            Configuration file DEFAULT: lacuna.yml

_END_USAGE_

  return;
}
##----------------------------------------------------------------------
## MAIN script body
##----------------------------------------------------------------------
my $show_usage;
my $target_planet;
my $ore;
my $amount;
my $debug_level = 0;
my $cfg_file;

## Pass through unknown parameters in @ARGV
Getopt::Long::Configure(qw(pass_through ));

GetOptions(
    'help'      => \$show_usage,
    'ore=s'     => \$ore,
    'amount=s'  => \$amount,
    'planet=s'  => \$target_planet,
    'debug+'    => \$debug_level,
    'config=s'  => \$cfg_file,
);

if ($show_usage)
{
  show_usage();
  exit(0);
}

$cfg_file = Games::Lacuna::Client->get_config_file([shift @ARGV, 'login.yml', 'lacuna.yml']);
unless ( $cfg_file and -e $cfg_file ) {
   die "Did not provide a config file";
}

## See if there are any unknown args
if (scalar(@ARGV))
{
  print qq{ERROR: Unknown argument(s): "}, join(qq{", "}, @ARGV), qq{"\n\n};
  show_usage();
  exit(1);
}

## Create the Client object
my $client = Games::Lacuna::Client->new(
  cfg_file => $cfg_file,
  debug    => ($debug_level ? 1 : 0),
);

## List for types of resources to check
my @types = ('ore');

# Load the planets
my $empire  = $client->empire->get_status->{empire};
my $planets = $empire->{planets};

## Hash to hold storage by planet
my $stores = {};

## Scan each planet
PLANET_LOOP:
foreach my $planet_id (sort keys %$planets)
{
  my $planet_name = $planets->{$planet_id};

  ## If we are looking for only one planet
  if ($target_planet && (uc($planet_name) ne uc($target_planet)))
  {
    ## This isn't the planet, next
    next PLANET_LOOP;
  }

  ## Load planet data
  my $planet    = $client->body(id => $planet_id);
  my $result    = $planet->get_buildings;
  ## Extract body from the results
  my $body      = $result->{status}->{body};
  ## Create reference for easier to read code
  my $buildings = $result->{buildings};

  ## List for resource storage buildings found on planet
  my @storage_buildings = ();

  ## Iterate through the types
  for my $type (@types)
  {
    ## initialize hash
    $stores->{$planet_name}->{$type} = {};

    ## Determine name of building, based on resource type
    my $building = {
      ore  => 'Ore Storage Tanks',
    }->{$type};

    ## Iterate through buildings
    while (my ($building_id, $building_ref) = each(%{$buildings}))
    {
      ## See if it is what we are looking for
      if ($building_ref->{name} eq $building)
      {
        ## Store it in the list
        push(
          @storage_buildings,
          {
            id   => $building_id,
            type => $type,
            building_type =>
              {ore => qq{OreStorage}}->{$type},
          }
        );
        last; # Only need one ore storage building to dump from
      }
    }
  }

  ## Iterate through the list of storage buildings
  foreach my $info_ref (@storage_buildings)
  {
    ## Get the view info, which has the food_stored or ore_stored key
    my $building = $client->building(
      id   => $info_ref->{id},
      type => $info_ref->{building_type}
    );

   $building->dump( $ore, $amount );
   print "Dumped $amount of $ore on $planet_name\n";
  }
}

print "\n$client->{total_calls} api calls made.\n";
print "You have made $client->{rpc_count} calls today\n";
