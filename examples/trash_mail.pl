#!/usr/bin/env perl
#
use strict;
use warnings;
use 5.10.0;
use Getopt::Long qw(GetOptions);
use Try::Tiny;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Games::Lacuna::Client;

my %message_tags = (
    alert          => 1,
    alliance       => 1,
    attack         => 1,
    colonization   => 1,
    complaint      => 1,
    correspondence => 1,
    excavator      => 1,
    intelligence   => 1,
    medal          => 1,
    mission        => 1,
    parliament     => 1,
    probe          => 1,
    spies          => 1,
    trade          => 1,
    tutorial       => 1,
);

my %opts = ( config => "lacuna.yml", );
my $ok = GetOptions( \%opts, 'tag=s@', 'help|h', 'debug', 'sleep=i',
    'tagfilterstring=s@' );

unless ( $opts{config} and -e $opts{config} ) {
    $opts{config} = eval {
        require File::HomeDir;
        require File::Spec;
        my $dist = File::HomeDir->my_dist_config('Games-Lacuna-Client');
        File::Spec->catfile( $dist, 'login.yml' ) if $dist;
    };
    unless ( $opts{config} and -e $opts{config} ) {
        die "Did not provide a config file";
    }
}
usage() if ( $opts{h} );

if ( not defined $opts{tag} ) {
    say "Need at least one message tag";
    usage();
}

my $glc = Games::Lacuna::Client->new(
    cfg_file  => $opts{config},
    rpc_sleep => $opts{sleep},
    debug     => $opts{debug},
);

my $current_page = 1;
my $inbox_args = { page_number => $current_page++ };
$inbox_args->{'tags'} = [ grep { exists $message_tags{$_} } @{ $opts{tag} } ];

if ( not scalar @{ $inbox_args->{'tags'} } ) {
    say "Need at least one *valid* message tag";
    usage();
}

my $inbox_content = get_inbox_content($inbox_args);
my $msg_count     = $inbox_content->{'message_count'};
my $msgs          = $inbox_content->{'messages'};
if ( not scalar @$msgs ) {
    say STDERR 'No messages found with the requested tags';
    exit;
}

my $to_be_trashed = process_messages($msgs);

my $max_page = int( $msg_count / 25 );
$max_page++ if $msg_count % 25;
for my $page ( $current_page .. $max_page ) {
    $inbox_args->{'page_number'} = $page;

    my $inbox_content = get_inbox_content($inbox_args);
    my $msgs          = $inbox_content->{'messages'};
    push( @$to_be_trashed, @{ process_messages($msgs) } );
    sleep 5 if $max_page >= 60;
}

say sprintf( 'Deleting %d messages', scalar @$to_be_trashed );
my $rv = try {
    $glc->inbox->trash_messages($to_be_trashed);
}
catch {
    my $msg = ( ref $_ ) ? $_->text : $_;
    die("Unable to delete messages: $msg");
} or die;

say sprintf(
    'Successfully deleted %d messages tagged with %s, tagfilter: %s',
    scalar @{ $rv->{'success'} } || 0,
    join( ',', @{ $inbox_args->{'tags'} } ),
    defined $opts{tagfilterstring}
    ? join( ',', @{ $opts{tagfilterstring} } )
    : 'none'
);
warn sprintf( 'Failed to delete %d messages',
    scalar @{ $rv->{'failure'} } || 0 )
    if scalar @{ $rv->{'failure'} };

say "$glc->{total_calls} api calls made.\n";
say "You have made $glc->{rpc_count} calls today\n";
exit;

sub usage {
    my $message_tags = join( ' ', keys %message_tags );
    die <<"END_USAGE";
Usage: $0 CONFIG_FILE
       --help|h         This help message
       --config         Lacuna Config, default lacuna.yml
       --tagfilterstring tagname:string Multiple may be provided
                        Use string to further filter the trashing per tag.
                        E.g. '--tagfilterstring alert:Glyph' will only trash Alert messages
                        which contain 'Glyph' in the subject.
       --tag tagname    Message tag of messages to be trashed, multiple may be provided.
                        Valid tags are: $message_tags
END_USAGE
}

sub process_messages {
    my $msgs = shift;
    my $to_be_trashed;
MESSAGES: foreach my $m ( @{$msgs} ) {
        next if $m->{'has_read'};
        foreach my $tagfilterstring ( @{ $opts{tagfilterstring} } ) {
            my ( $tag, $string ) = split( ':', $tagfilterstring );
            if ( grep { lc($_) eq $tag } @{ $m->{'tags'} } ) {
                next MESSAGES unless $m->{'subject'} =~ /$string/;
            }
        }
        push( @$to_be_trashed, $m );
    }
    return $to_be_trashed;
}

sub get_inbox_content {
    my $inbox_args    = shift;
    my $inbox_content = try {
        $glc->inbox->view_inbox($inbox_args);
    }
    catch {
        my $msg = ( ref $_ ) ? $_->text : $_;
        die("Unable to read inbox page: $msg");
    } or die;
    return $inbox_content;
}
