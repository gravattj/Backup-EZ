#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';
use Backup::EZ;
use Data::Dumper;
use Test::More;

my $ez;
eval {
	$ez = Backup::EZ->new(
						   conf         => 't/ezbackup_user.conf',
						   exclude_file => 'share/ezbackup_exclude.rsync',
						   dryrun       => 0,
	);
};
ok($ez);

ok(	$ez->backup);

done_testing();
