package Devel::NYTProf::Core;

# $Id$

use XSLoader;

our $VERSION = '1.13'; # increment with XS changes too

XSLoader::load('Devel::NYTProf', $VERSION);

1;

__END__

=head1 NAME

Devel::NYTProf::Core - load internals of Devel::NYTProf

=head1 DESCRIPTION

This module is not meant to be used directly.
See L<Devel::NYTProf> and L<Devel::NYTProf::Reader>.

=head1 AUTHOR

Adam Kaplan, akaplan at nytimes dotcom.

Tim Bunce, L<http://www.tim.bunce.name> and L<http://blog.timbunce.org>

=head1 COPYRIGHT AND LICENSE

  Copyright (C) 2008 by Adam Kaplan and The New York Times Company.
  Copyright (C) 2008 by Tim Bunce.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut

# vim: ts=2 sw=2 sts=0 noexpandtab:
