#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';
use Backup::EZ;
use Data::Dumper;
use Test::More;

my $ez = Backup::EZ->new(
						  conf         => 't/ezbackup.conf',
						  exclude_file => 'share/ezbackup_exclude.rsync',
						  dryrun       => 1
);
die if !$ez;
system( "rm -rf " . $ez->{conf}->{dest_dir} );

ok( $ez->backup );
ok( !$ez->get_list_of_backups() );

$ez = Backup::EZ->new(
					   conf         => 't/ezbackup.conf',
					   exclude_file => 'share/ezbackup_exclude.rsync',
					   dryrun       => 0
);
die if !$ez;

ok( $ez->backup );
my @list = $ez->get_list_of_backups();
ok( @list == 1 );

ok( $ez->backup );
@list = $ez->get_list_of_backups();
ok( @list == 2 ) or print Dumper \@list;

# cleanup
my $cmd =
  sprintf( "rm -rf %s", $ez->get_dest_dir() );
system($cmd);

done_testing();
