package Devel::NYTProf::Apache;

use strict;

our $VERSION = 0.01;

use constant MP2 => (exists $ENV{MOD_PERL_API_VERSION} &&
                     $ENV{MOD_PERL_API_VERSION} == 2) ? 1 : 0;

BEGIN {
	if(!defined($ENV{NYTPROF})) {
		warn "The environment variable NYTPROF is not available.  Is that what you really want to do?";
	}
	require Devel::NYTProf;
	if (MP2) {
		require mod_perl2;
		require Apache2::ServerUtil;
		my $s = Apache2::ServerUtil->server;
                $s->push_handlers(PerlChildInitHandler => \&DB::enable_profile);
                $s->push_handlers(PerlChildExitHandler => \&DB::_finish);
	} else {
		require Apache;
		Carp::carp("Apache.pm was not loaded\n")
                        and return unless $INC{'Apache.pm'};
                if(Apache->can('push_handlers')) {
                        Apache->push_handlers(PerlChildInitHandler => \&DB::enable_profile);
			Apache->push_handlers(PerlChildExitHandler => \&DB::_finish);
        	}

	}
	DB::_finish_pid() if $ENV{NYTPROF} =~ /allowfork/;
}

1;

__END__

=head1 NAME

Devel::NYTProf::Apache - Profile mod_perl applications with Devel::NYTProf

=head1 SYNOPSIS

    # in you Apache config file with mod_perl installed
    PerlPassEnv NYTPROF
    PerlModule Devel::NYTProf::Apache

=head1 DESCRIPTION

This module allows mod_perl applciations to be profiled using
C<Devel::NYTProf>. 

=head1 NOTES

For proper functioning of C<Devel::NYTProf>, the NYTPROF environment
variable should be set.  See L<Devel::NYTProf/"ENVIRONMENT VARIABLES"> for 
more details on the settings effected by this environment variable.
Certain settings are important for C<mod_perl> users.

=over 4

=item file=N

Tells C<Devel::NYTProf> where to save your profile data.  The module defaults
to './nytprof.out' which is probably not what you want when starting Apache as 
root.

=item allowfork

This setting is necessary when Apache is able to fork child processes to 
handle requests.

Repeating the warning from C<Devel::NYTProf>, I<WARNING: ignoring these
settings may cause unintended side effects in code that might fork>

=back

=head1 SEE ALSO

L<Devel::NYTProf>

=head1 AUTHOR

Steve Peters, C<< <steve at fisharerojo.org> >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by Adam Kaplan and The New York Times Company.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.
