package Devel::NYTProf::Util;

# $Id: Reader.pm 67 2008-04-03 11:42:43Z tim.bunce $

=head1 NAME

Devel::NYTProf::Util - general utility functions for L<Devel::NYTProf>

=head1 SYNOPSIS

  use Devel::NYTProf::Util qw(strip_prefix_from_paths);

=head1 DESCRIPTION

Contains general utility functions for L<Devel::NYTProf>

=head1 FUNCTIONS

=cut

use warnings;
use strict;

use base qw'Exporter';

use Carp;
use Cwd qw(getcwd);

our @EXPORT_OK = qw(
	strip_prefix_from_paths
);


# edit @$paths in-place to remove specified absolute path prefixes

sub strip_prefix_from_paths {
	my ($inc_ref, $paths) = @_;

	my @inc = @$inc_ref or return;

	# rewrite relative directories to be absolute
  # the logic here should match that in get_file_id()
  my $cwd;
  for (@inc) {
    next if m{^\/};   # already absolute
    $_ =~ s/^\.\///;  # remove a leading './'
		$cwd ||= getcwd();
    $_ = ($_ eq '.') ? $cwd : "$cwd/$_";
  }

	# build string regex for each path
	my $inc_regex = join "|", map { quotemeta $_ } @inc;

	# convert to regex object, anchor at start, soak up any /'s at end
	$inc_regex = qr{^(?:$inc_regex)/*};

	# strip off prefix using regex, skip any empty/undef paths
	$_ and s{$inc_regex}{} for @$paths;

	return;
}


1;

__END__

=head1 SEE ALSO

L<Devel::NYTProf>

=head1 AUTHOR

Tim Bunce, L<http://www.tim.bunce.name> and L<http://blog.timbunce.org>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by Tim Bunce, Ireland.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut

# vim: ts=2 sw=2 sts=0 noexpandtab:
