#!/usr/bin/perl
#
# =================
#   DigManager
# =================
#
# Digs:
#   *) Collect list of current glyphs
#   *) On each ready planet, search in order of:
#       1. What we have the fewest glyphs of
#       2. What we have the most ore of
#       3. Random
#   *) Dig!
#
# Spit out interesting times
#   *) When digs will be done


use strict;
use warnings;

use feature ':5.10';

use DBI;
use FindBin;
use List::Util qw(first min max sum reduce);
use POSIX qw(ceil);
use Date::Parse qw(str2time);
use Math::Round qw(round);
use Getopt::Long;
use Data::Dumper;
use Exception::Class;

use lib "$FindBin::Bin/../lib";
use Games::Lacuna::Client;

my @batches;
my $current_batch = 0;
my $batch_opt_cb = sub {
    my ($opt, $val) = @_;

    if ($opt eq 'and') {
        $current_batch++;
        return;
    }

    $batches[$current_batch]{$opt} = $val;
};
my %opts;
GetOptions(\%opts,
    # General options
    'h|help',
    'q|quiet',
    'v|verbose',
    'config=s',
    'planet=s@',
    'dry-run|dry',
    'full-times',

    # Arch digs
    'do-digs|dig',
    'min-ore=i',
    'min-arch=i',
    'preferred-ore|ore=s@',

    'and'                     => $batch_opt_cb,

    # Allow this to run in an infinate glyph-sucking loop.  Value is
    # minutes between cycles (default 360)
    'continuous:i',
) or usage();

push @batches, {} unless @batches;

usage() if $opts{h};

# Consider probe data from within the last 3 days to be recent
# enough to believe inhabited status
my $RECENT_CHECK = 86400 * 3;

my %do_planets;
if ($opts{planet}) {
    %do_planets = map { normalize_planet($_) => 1 } @{$opts{planet}};
}

my ($finished, $status, $glc);
while (!$finished) {
    my $ok = eval {
        # We'll create this inside the loop for a couple reasons, primarily
        # that it gives us a chance to reauth each time through the loop, in
        # case you get the "Session expired" error.
        $glc = Games::Lacuna::Client->new(
            cfg_file       => $opts{config} || "$FindBin::Bin/../lacuna.yml",
            rpc_sleep      => 1.333, # 45 per minute, new default is 50 rpc/min
        );

        output("Starting up at " . localtime() . "\n");
        get_status();
        do_digs() if $opts{'do-digs'};
        report_status();
        output(pluralize($glc->{total_calls}, "api call") . " made.\n");
        output("You have made " . pluralize($glc->{rpc_count}, "call") . " today\n");
        return 1;
    };
    unless ($ok) {
        my $e = $@;

        diag("Error during run: $@\n");

        if (my $e = Exception::Class->caught('LacunaRPCException')) {
            if ($e->code eq '1006' and $e->text =~ /Session expired/) {
                diag("Caught Session expired error, retrying\n");
                $status = {};
                redo;
            }
            $e->rethrow;
        } else {
            my $e = Exception::Class->caught();
            if ($e =~ /malformed JSON string/) {
                diag("Caught malformed JSON error, restarting\n");
                $status = {};
                redo;
            }
            ref $e ? $e->rethrow : die $e;
        }
    }

    if (defined $opts{continuous}) {
        my $sleep = $opts{continuous} || 360;

        if ($opts{'do-digs'} and $status->{digs}) {
            my $now = time();
            my ($last_dig) =
                map  { ceil(($_->{finished} - $now) / 60) }
                sort { $b->{finished} <=> $a->{finished} }
                @{$status->{digs}};

            if (defined $last_dig) {
                # Sleep until the digs end, but at least 10 minutes, unless asked to not wait that long
                $sleep = min($sleep, max($last_dig, 10));
            }
        }

        # Clear cache before sleeping
        $status = {};

        my $next = localtime(time() + ($sleep * 60));
        output("Sleeping for " . pluralize($sleep, "minute") . ", next run at $next\n");
        $sleep *= 60; # minutes to seconds
        sleep $sleep;
    } else {
        $finished = 1;
    }
}

# Destroy client object prior to global destruction to avoid GLC bug
undef $glc;

exit 0;

sub get_status {
    my $empire = $glc->empire->get_status->{empire};

    # reverse hash, to key by name instead of id
    my %planets = map { $empire->{planets}{$_}, $_ } keys %{$empire->{planets}};
    $status->{planets} = \%planets;

    # Scan each planet
    my $now = time();
    for my $planet_name (keys %planets) {
        if (keys %do_planets) {
            next unless $do_planets{normalize_planet($planet_name)};
        }

        verbose("Inspecting $planet_name\n");

        # Load planet data
        my $planet    = $glc->body(id => $planets{$planet_name});
        my $result    = $planet->get_buildings;
        my $buildings = $result->{buildings};
        $status->{planet_location}{$planet_name}{x} = $result->{status}{body}{x};
        $status->{planet_location}{$planet_name}{y} = $result->{status}{body}{y};
        $status->{planet_resources}{$planet_name}{$_} = $result->{status}{body}{$_}
            for qw/water_hour energy_hour ore_hour food_hour/;

        my ($arch, $level, $seconds_remaining) = find_arch_min($buildings);
        if ($arch) {
            verbose("Found an archaeology ministry on $planet_name\n");
            $status->{archmin}{$planet_name}   = $arch;
            $status->{archlevel}{$planet_name} = $level;
            if ($seconds_remaining) {
                push @{$status->{digs}}, {
                    planet   => $planet_name,
                    finished => $now + $seconds_remaining,
                };
            } else {
                $status->{idle}{$planet_name} = 1;
                $status->{available_ore}{$planet_name} =
                    $arch->get_ores_available_for_processing->{ore};
            }

            my $glyphs = $arch->get_glyphs->{glyphs};
            for my $glyph (@$glyphs) {
                $status->{glyphs}{$glyph->{type}}++;
            }
        } else {
            verbose("No archaeology ministry on $planet_name\n");
        }

    }
}

sub report_status {
    if (keys %{$status->{glyphs} || {}}) {
        my $total_glyphs = 0;
        output("Current glyphs:\n");
        my $cnt;
        for my $glyph (sort keys %{$status->{glyphs}}) {
            $total_glyphs += $status->{glyphs}->{$glyph};
            output(sprintf '%13s: %3s', $glyph, $status->{glyphs}->{$glyph});
            output("\n") unless ++$cnt % 4
        }
        output("\n") if $cnt % 4;
        output("\n");
        output("Current stock: " . pluralize($total_glyphs, "glyph") . "\n\n");
    }

    # Ready to go now?
    if (my @planets = grep { scalar @{$status->{ready}{$_}} } keys %{$status->{ready}}) {
        output(<<END);
**** Notice! ****
You have excavators ready to send.  Specify --send-excavators if you want to
send them to the closest available destinations.
*****************
END
        for my $planet (sort @planets) {
            output("$planet has ", pluralize(scalar @{$status->{ready}{$planet}}, 'excavator')
                , " ready to launch!\n");
        }
        output("\n");
    }

    # Any idle archmins?
    if (keys %{$status->{idle}}) {
        output(<<END);
**** Notice! ****
You have idle archaeology minstries.  Specify --do-digs if you want to
start the recommended digs automatically.
*****************
END
        for my $planet (keys %{$status->{idle}}) {
            output("Archaeology Ministry on $planet is idle!\n");
        }
        output("\n");
    }


    my @events;
    my $digging_count = @{$status->{digs} || []};
    for my $dig (@{$status->{digs}}) {
        push @events, {
            epoch  => $dig->{finished},
            detail => "Dig finishing on $dig->{planet}",
        };
    }

    @events =
        sort { $a->{epoch} <=> $b->{epoch} }
        map  { $_->{when} = format_time($_->{epoch}, $opts{'full-times'}); $_ }
        @events;

    if (@events) {
        output("Searches completing:\n");
        for my $event (@events) {
            display_event($event);
        }
    }

    output("\n");
    output("Summary: " . pluralize($digging_count, "dig") . " ongoing\n\n");
    for my $planet (keys %{$status->{build_limits}}) {
        output("$planet needs more $status->{build_limits}{$planet}{type}\n");
    }
}

sub normalize_planet {
    my ($planet_name) = @_;

    $planet_name =~ s/\W//g;
    $planet_name = lc($planet_name);
    return $planet_name;
}

sub format_time_delta {
    my ($delta, $strict) = @_;

    given ($delta) {
        when ($_ < 0) {
            return "just finished";
        }
        when ($_ < ($strict ? 60 : 90)) {
            return pluralize($_, 'second');
        }
        when ($_ < ($strict ? 3600 : 5400)) {
            my $min = round($_ / 60);
            return pluralize($min, 'minute');
        }
        when ($_ < 86400) {
            my $hrs = round($_ / 3600);
            return pluralize($hrs, 'hour');
        }
        default {
            my $days = round($_ / 86400);
            return pluralize($days, 'day');
        }
    }
}

sub format_time_delta_full {
    my ($delta) = @_;

    return "just finished" if $delta <= 0;

    my @formatted;
    my $sec = $delta % 60;
    if ($sec) {
        unshift @formatted, format_time_delta($sec,1);
        $delta -= $sec;
    }
    my $min = $delta % 3600;
    if ($min) {
        unshift @formatted, format_time_delta($min,1);
        $delta -= $min;
    }
    my $hrs = $delta % 86400;
    if ($hrs) {
        unshift @formatted, format_time_delta($hrs,1);
        $delta -= $hrs;
    }
    my $days = $delta;
    if ($days) {
        unshift @formatted, format_time_delta($days,1);
    }

    return join(', ', @formatted);
}

sub format_time {
    my ($time, $full) = @_;
    my $delta = $time - time();
    return $full ? format_time_delta_full($delta) : format_time_delta($delta);
}

sub pluralize {
    my ($num, $word) = @_;

    if ($num == 1) {
        return "$num $word";
    } else {
        return "$num ${word}s";
    }
}

sub display_event {
    my ($event) = @_;

    output(sprintf "    %11s: %s\n", $event->{when}, $event->{detail});
}

## Buildings ##

sub find_arch_min {
    my ($buildings) = @_;

    # Find the Archaeology Ministry
    my $arch_id = first {
            $buildings->{$_}->{name} eq 'Archaeology Ministry'
    }
    grep { $buildings->{$_}->{level} > 0 and $buildings->{$_}->{efficiency} == 100 }
    keys %$buildings;

    return if not $arch_id;

    my $building  = $glc->building(
        id   => $arch_id,
        type => 'Archaeology',
    );
    my $level     = $buildings->{$arch_id}{level};
    my $remaining = $buildings->{$arch_id}{work} ? $buildings->{$arch_id}{work}{seconds_remaining} : undef;

    return ($building, $level, $remaining);
}

## Arch digs ##

sub do_digs {

    # Try to avoid digging for the same ore on every planet, even if it's
    # determined somehow to be the "best" option.  We don't have access to
    # whatever digs are currently in progress so we'll base this just on what
    # we've started during this run.  This will be computed simply by adding
    # each current dig to glyphs, as if it were going to be successful.
    my $digging = {};

    for my $planet (keys %{$status->{idle}}) {
        if ($opts{'min-arch'} and $status->{archlevel}{$planet} < $opts{'min-arch'}) {
            output("$planet is not above specified Archaeology Ministry level ($opts{'min-arch'}), skipping dig.\n");
            next;
        }
        my $ore = determine_ore(
            $opts{'min-ore'} || 10_000,
            $opts{'preferred-ore'} || [],
            $status->{available_ore}{$planet},
            $status->{glyphs},
            $digging
        );
        if ($ore) {
            if ($opts{'dry-run'}) {
                output("Would have started a dig for $ore on $planet.\n");
            } else {
                output("Starting a dig for $ore on $planet...\n");
                my $ok = eval {
                    $status->{archmin}{$planet}->search_for_glyph($ore);
                    push @{$status->{digs}}, {
                        planet   => $planet,
                        finished => time() + (6 * 60 * 60),
                    };
                    return 1;
                };
                unless ($ok) {
                    my $e = $@;
                    diag("Error starting dig: $e\n");
                }
            }
            delete $status->{idle}{$planet};
        } else {
            output("Not starting a dig on $planet; not enough of any type of ore.\n");
        }
    }
}

sub determine_ore {
    my ($min, $preferred, $ore, $glyphs, $digging) = @_;

    my %is_preferred = map { $_ => 1 } @$preferred;

    my ($which) =
        sort {
            ($is_preferred{$b} || 0) <=> ($is_preferred{$a} || 0) or
            ($glyphs->{$a} || 0) + ($digging->{$a} || 0) <=> ($glyphs->{$b} || 0) + ($digging->{$b} || 0) or
            $ore->{$b} <=> $ore->{$a} or
            int(rand(3)) - 1
        }
        grep { $ore->{$_} >= $min }
        keys %$ore;

    if ($which) {
        $digging->{$which}++;
    }

    return $which;
}

sub usage {
    diag(<<END);
Usage: $0 [options]

This program will manage your glyph hunting worries with minimal manual
intervention required.  It will notice archeology digs.  It can start digs
for the most needed glyphs.

This is suitable for automation with cron(8) or at(1), but you should
know that it tends to use a substantial number of API calls, often 50-100
per run.  With the daily limit of 5000, including all web UI usage, you
will want to keep these at a relatively infrequent interval, such as every
60 minutes at most.

Options:
  --verbose              - Output extra information.
  --quiet                - Print no output except for errors.
  --config <file>        - Specify a GLC config file, normally lacuna.yml.
  --db <file>            - Specify a star database, normally stars.db.
  --planet <name>        - Specify a planet to process.  This option can be
                           passed multiple times to indicate several planets.
                           If this is not specified, all relevant colonies will
                           be inspected.
  --continuous [<min>]   - Run the program in a continuous loop until interrupted.
                           If an argument is supplied, it should be the number of
                           minutes to sleep between runs.  If unspecified, the
                           default is 360 (6 hours).  If all arch digs will finish
                           before the next scheduled loop and --do-digs is specified,
                           it will instead run at that time.
  --do-digs              - Begin archaeology digs on any planets which are idle.
  --min-ore <amount>     - Do not begin digs with less ore in reserve than this
                           amount.  The default is 10,000.
  --min-arch <level>     - Do not begin digs on any archaeology ministry less
                           than this level.  The default is 1.
  --preferred-ore <type> - Dig using the specified ore whenever available.
  --dry-run              - Don't actually take any action, just report status and
                           what actions would have taken place.
  --full-times           - Specify timestamps in full precision instead of rounded

This script was modified from the glyphinator to cut out excavator functions
so it would be easier and run faster as a dig manager.
END
    exit 1;
}

sub verbose {
    return unless $opts{v};
    print @_;
}

sub output {
    return if $opts{q};
    print @_;
}

sub diag {
    my ($msg) = @_;
    print STDERR $msg;
}
