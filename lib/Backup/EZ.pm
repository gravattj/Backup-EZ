package Backup::EZ;

use strict;
use warnings;
use warnings FATAL => 'all';
use Data::Dumper;
use Config::General;
use Carp;
use Time::localtime;
use Unix::Syslog qw(:macros :subs);
use Data::UUID;
use Sys::Hostname;
use File::Slurp qw(slurp);
use File::Spec;

#
# CONSTANTS
#
use constant EXCLUDE_FILE        => '/etc/ezbackup/ezbackup_exclude.rsync';
use constant CONF                => '/etc/ezbackup/ezbackup.conf';
use constant COPIES              => 30;
use constant DEST_HOSTNAME       => 'localhost';
use constant DEST_DIR            => '/backups';
use constant DEST_APPEND_MACH_ID => 0;

=head1 NAME

Backup::EZ - Simple backups based on rsync

=head1 VERSION

Version 0.20

=cut

our $VERSION = '0.20';

=head1 SYNOPSIS

  use Backup::EZ;

  my $ez = Backup::EZ->new;
  $ez->backup;

=head1 DESCRIPTION

Backup::EZ is backup software that is designed to be as easy to use
as possible, yet provide a robust solution

If you only want to run backups, see the included command line utility "ezbackup".   

=head1 SUBROUTINES/METHODS

=head2 new

optional args:
    conf         => $config_file      
    dryrun       => $bool,            
    exclude_file => $rsync_excl_file  
  
=cut

sub new {
	my $class = shift;
	my %a     = @_;

	my $self = {};

	if ( $ENV{VERBOSE} ) {
		setlogmask( LOG_UPTO(LOG_DEBUG) );
		$self->{syslog_option} = LOG_PID | LOG_PERROR;
	}
	else {
		setlogmask( LOG_UPTO(LOG_INFO) );
		$self->{syslog_option} = LOG_PID;
	}

	_read_conf( $self, @_ );

	if ( $a{dryrun} ) {
		$self->{dryrun} = 1;
	}

	if ( !defined $a{exclude_file} ) {
		$self->{exclude_file} = EXCLUDE_FILE;
	}
	else {
		$self->{exclude_file} = $a{exclude_file};
	}

	bless $self, $class;
	return $self;
}

sub _debug {
	my $self = shift;
	my $msg  = shift;

	openlog "ezbackup", $self->{syslog_option}, LOG_LOCAL7;
	syslog LOG_DEBUG, $msg;
	closelog;
}

sub _error {
	my $self = shift;
	my $msg  = shift;

	openlog "ezbackup", $self->{syslog_option}, LOG_LOCAL7;
	syslog LOG_ERR, $msg;
	closelog;
}

sub _info {
	my $self = shift;
	my $msg  = shift;

	openlog "ezbackup", $self->{syslog_option}, LOG_LOCAL7;
	syslog LOG_INFO, $msg;
	closelog;
}

sub _read_conf {
	my $self = shift;
	my %a    = @_;

	my $conf = $a{conf} ? $a{conf} : CONF;

	my $config = Config::General->new(
		-ConfigFile     => $conf,
		-ForceArray     => 1,
		-LowerCaseNames => 1,
		-AutoTrue       => 1,

	);

	my %conf = $config->getall;
	_debug( $self, Dumper \%conf );

	foreach my $key ( keys %conf ) {

		if ( !defined $conf{backup_host} ) {
			$conf{backup_host} = DEST_HOSTNAME;
		}

		if ( !defined $conf{copies} ) {
			$conf{copies} = COPIES;
		}

		if ( !defined $conf{dest_dir} ) {
			$conf{dest_dir} = DEST_DIR;
		}

		if ( !defined $conf{append_machine_id} ) {
			$conf{append_machine_id} = DEST_APPEND_MACH_ID;
		}
	}

	$self->{conf} = \%conf;
}

sub _get_dirs {
	my $self = shift;

	my @dirs;

	foreach my $dir ( keys %{ $self->{conf}->{dirs} } ) {

		if ( !File::Spec->file_name_is_absolute($dir) ) {
			confess "relative dirs are not supported";
		}

		push( @dirs, $dir );
	}
	return @dirs;
}

sub _ssh {
	my $self   = shift;
	my $cmd    = shift;
	my $dryrun = shift;

	my $user = '';
	if ( $self->{conf}->{backup_user} ) {
		$user = $self->{conf}->{backup_user};
		$user .= '@';
	}

	my $sshcmd =
	  sprintf( "ssh %s%s %s", $user, $self->_get_dest_hostname, $cmd );

	$self->_debug($sshcmd);
	return undef if $dryrun;

	my @out = `$sshcmd`;
	confess if $?;

	return @out;
}

sub _get_dest_hostname {
	my $self = shift;

	return $self->{conf}->{backup_host};
}

sub _get_dest_dir {
	my $self = shift;

	my $hostname = hostname();
	$hostname =~ s/\..+$//;

	if ( $self->{conf}->{append_machine_id} ) {

		if ( !-f '/etc/machine-id' ) {

			my $data_uuid = Data::UUID->new;
			my $uuid = $data_uuid->create_str();	
			
			open my $fh, ">/etc/machine-id"
			  or confess "failed to open /etc/machine-id: $!";
			print $fh "$uuid\n";
			close($fh);
		}

		my $uuid = slurp("/etc/machine-id");
		chomp $uuid;

		$hostname = "$hostname-$uuid";

	}

	return sprintf( "%s/%s", $self->{conf}->{dest_dir}, $hostname );
}

sub _get_dest_tmp_dir {
	my $self = shift;

	return sprintf( "%s/%s", $self->_get_dest_dir, ".tmp" );
}

sub _get_dest_backup_dir {
	my $self = shift;

	return sprintf( "%s/%s", $self->_get_dest_dir, $self->{datestamp} );
}

sub _rsync {
	my $self          = shift;
	my $dir           = shift;
	my @extra_options = @_;

	my $dryrun = $self->{dryrun} ? '--dry-run' : '';

	$self->_mk_dest_dir( sprintf( "%s%s", $self->_get_dest_tmp_dir, $dir ) );

	my $cmd = sprintf( "rsync %s %s -aze ssh %s/ %s:%s%s",
					   $dryrun, join( ' ', @extra_options ),
					   $dir, $self->_get_dest_hostname,
					   $self->_get_dest_tmp_dir, $dir );

	if ( $self->{exclude_file} ) {
		$cmd .= " --exclude-from " . $self->{exclude_file};
	}

	$self->_debug($cmd);
	system($cmd);
	confess if $?;
}

sub _full_backup {
	my $self = shift;
	my $dir  = shift;

	$self->_rsync($dir);
}

sub _inc_backup {
	my $self            = shift;
	my $dir             = shift;
	my $last_backup_dir = shift;

	my $link_dest =
	  sprintf( "%s/%s/%s", $self->_get_dest_dir, $last_backup_dir, $dir )
	  ;

	$self->_rsync( $dir, "--link-dest $link_dest" );
}

sub _mk_dest_dir {
	my $self   = shift;
	my $dir    = shift;
	my $dryrun = shift;

	my $cmd = sprintf( "mkdir -p %s", $dir );
	$self->_ssh( $cmd, $dryrun );
}

sub _set_datestamp {
	my $self = shift;

	my $t = localtime;
	$self->{datestamp} = sprintf( "%04d-%02d-%02d_%02d:%02d:%02d",
								  $t->year + 1900,
								  $t->mon + 1,
								  $t->mday, $t->hour, $t->min, $t->sec );
}

=head2 backup

Invokes the backup process.  Takes no args.

=cut

sub backup {
	my $self = shift;

	$self->_mk_dest_dir( $self->_get_dest_dir );
	my @backups = $self->get_list_of_backups;
	$self->_set_datestamp;

	foreach my $dir ( $self->_get_dirs ) {

		$self->_info("backing up $dir");
		$self->_mk_dest_dir( $self->_get_dest_tmp_dir, $self->{dryrun} );

		if ( !@backups ) {

			# full
			$self->_full_backup($dir);
		}
		else {

			# incremental
			$self->_inc_backup( $dir, $backups[$#backups] );
		}
	}

	$self->_mk_dest_dir( $self->_get_dest_dir, $self->{dryrun} );
	$self->_ssh(
				 sprintf( "mv %s %s",
						  $self->_get_dest_tmp_dir,
						  $self->_get_dest_backup_dir ),
				 $self->{dryrun}
	);

	$self->expire();

	return 1;
}

=head2 expire

Expire backups.  Gets a list of current backups and removes old ones that are 
beyond the cutoff (see "copies" in the conf file).

=cut

sub expire {
	my $self = shift;

	my @list = $self->get_list_of_backups;

	while ( scalar(@list) > $self->{conf}->{copies} ) {

		my $subdir = shift @list;
		my $del_dir = sprintf( "%s/%s", $self->_get_dest_dir, $subdir );

		$self->_ssh("rm -rf $del_dir");
	}
}

=head2 get_backup_host

Returns the backup_host name.

=cut

sub get_backup_host {
	my $self = shift;
	return $self->{conf}->{backup_host};
}

=head2 get_dest_dir

Returns the dest_dir.

=cut

sub get_dest_dir {
	my $self = shift;
	return $self->{conf}->{dest_dir};
}

=head2 get_list_of_backups

Returns an array of backups.  They are in the format of "YYYY-MM-DD_HH:MM:SS".
=cut

sub get_list_of_backups {
	my $self = shift;

	my @backups;

	my @list = $self->_ssh( sprintf( "ls %s", $self->_get_dest_dir ) );

	foreach my $e (@list) {
		chomp $e;

		if ( $e =~ /^\d\d\d\d-\d\d-\d\d_\d\d:\d\d:\d\d$/ ) {
			push( @backups, $e );
		}
	}

	return @backups;
}

=head1 AUTHOR

John Gravatt, C<< <john at gravatt.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-backup-ez at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Backup-EZ>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Backup::EZ


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Backup-EZ>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Backup-EZ>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Backup-EZ>

=item * Search CPAN

L<http://search.cpan.org/dist/Backup-EZ/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2014 John Gravatt.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1;    # End of Backup::EZ
