package Devel::NYTProf::Data;

# $Id: Reader.pm 67 2008-04-03 11:42:43Z tim.bunce $

=head1 NAME

Devel::NYTProf::Data - L<Devel::NYTProf> data loading and manipulation

=head1 SYNOPSIS

  use Devel::NYTProf::Data;

	$profile = Devel::NYTProf::Data->new( { filename => 'nytprof.out' } );

	$profile->dump_profile_data();

=head1 DESCRIPTION

Reads a profile data file written by L<Devel::NYTProf>, aggregates the
contents, and returns the results as a blessed data structure.

=head1 METHODS

=cut

use warnings;
use strict;

use Carp;

use Devel::NYTProf::Core;

=head2 new

	$profile = Devel::NYTProf::Data->new( { filename => 'nytprof.out' } );
  
Reads the specified file containing profile data written by L<Devel::NYTProf>,
aggregates the contents, and returns the results as a blessed data structure.

=cut

sub new {
	my $class = shift;
	my $args = shift || { filename => 'nytprof.out' };

	croak "No file specified (@{[ %$args ]})" unless $args->{filename};

	my $profile = Devel::NYTProf::Data::load_profile_data_from_file(
									$args->{filename});
	bless $profile => $class;

	return $profile;
}


=head2 dump_profile_data

  $profile->dump_profile_data;
  $profile->dump_profile_data( {
    filehandle => \*STDOUT,
		separator  => "",
  } );

Writes the profile data in a reasonably human friendly format to the sepcified
C<filehandle> (default STDOUT).

For non-trivial profiles the output can be very large. As a guide, there'll be
at least one line of output for each line of code executed, plus one for each
place a subroutine was called from, plus one per subroutine.

The default format is a Data::Dumper style whitespace-indented tree.
The types of data present can depend on the options used when profiling.

 {
    attribute => {
        basetime => 1207228764
        ticks_per_sec => 1000000
        xs_version => 1.13
    }
    fid_filename => [
        1: test01.p
    ]
    fid_line_time => [
        1: [
            2: [ 4e-06 2 ]
            3: [ 1.2e-05 2 ]
            7: [ 4.6e-05 4 ]
            11: [ 2e-06 1 ]
            16: [ 1.2e-05 1 ]
        ]
    ]
    sub_caller => {
        main::bar => {
            1 => {
                12 => 1
                16 => 1
                3 => 2
            }
        }
        main::foo => {
            1 => {
                11 => 1
            }
        }
    }
    sub_fid_line => {
        main::bar => [ 1 6 8 ]
        main::foo => [ 1 1 4 ]
    }
 }

If C<separator> is true then instead of whitespace, each item of data is
indented with the I<path> through the structure with C<separator> used to
separarate the elements of the path.

	attribute	basetime	1207228260
	attribute	ticks_per_sec	1000000
	attribute	xs_version	1.13
	fid_filename	1	test01.p
	fid_line_time	1	2	[ 4e-06 2 ]
	fid_line_time	1	3	[ 1.1e-05 2 ]
	fid_line_time	1	7	[ 4.4e-05 4 ]
	fid_line_time	1	11	[ 2e-06 1 ]
	fid_line_time	1	16	[ 1e-05 1 ]
	sub_caller	main::bar	1	12	1
	sub_caller	main::bar	1	16	1
	sub_caller	main::bar	1	3	2
	sub_caller	main::foo	1	11	1
	sub_fid_line	main::bar	[ 1 6 8 ]
	sub_fid_line	main::foo	[ 1 1 4 ]

This format is especially useful for grep'ing and diff'ing.

=cut

sub dump_profile_data {
	my $self = shift;
	my $args = shift;
	my $separator  = $args->{separator} || '';
	my $filehandle = $args->{filehandle} || \*STDOUT;
	my $startnode  = $args->{startnode} || $self; # undocumented
	croak "Invalid startnode" unless ref $startnode;
	_dump_elements($startnode, $separator, $filehandle, []);
}

sub _dump_elements {
	my ($r, $separator, $fh, $path) = @_;
	my $pad = "    ";
	my $padN;

	my $is_hash = (UNIVERSAL::isa($r, 'HASH'));
	my ($start, $end, $colon, $keys) = ($is_hash)
		? ('{', '}', ' => ', [ sort keys %$r ])
		: ('[', ']', ': ',   [ 0..@$r-1 ]);

	if ($separator) {
		($start, $end, $colon) = (undef, undef, $separator);
		$padN = join $separator, @$path,'';
	}
	else {
		$padN = $pad x (@$path+1);
	}

	print $fh "$start\n" if $start;
	$path = [ @$path, undef ];
	for my $key (@$keys) {

		my $value = ($is_hash) ? $r->{$key} : $r->[$key];

		# skip undef elements in array
		next if !defined($value) && !$is_hash;

		# special case some common cases to be more compact:
		#		fid_*_time   [fid][line] = [N,N]
		#		sub_fid_line {subname} = [fid,startline,endline]
		my $as_compact = (ref $value eq 'ARRAY' && @$value <= 3
											&& !grep { ref or !defined } @$value);

		# print the value intro
		print $fh "$padN$key$colon"
			unless ref $value && !$as_compact;

		if ($as_compact) {
			print $fh "[ @$value ]\n";
		}
		elsif (ref $value) {
			$path->[-1] = $key;
			_dump_elements($value, $separator, $fh, $path);
		}
		else {
			print $fh "$value\n";
		}
	}
	printf $fh "%s$end\n", ($pad x (@$path-1)) if $end;
}


=head2 normalize_variables

  $profile->normalize_variables;

Traverses the profile data structure and normalizes highly variable data, such
as the time, in order that the data can more easily be compared. This is used,
for example, by the test suite.

The data normalized is:

 - profile timing data: set to 0
 - basetime attribute: set to 0
 - xs_version attribute: set to 0
 - filenames: path prefixes matching absolute paths in @INC are removed

=cut

sub normalize_variables {
	my $self = shift;

  $self->{attribute}{basetime} = 0;
  $self->{attribute}{xs_version} = 0;

	for (keys %$self) {
		# fid_line_times => [fid][line][time,...]
		next unless /^fid_\w+_time$/;
		# iterate over the fids that have data
		my $fid_lines = $self->{$_} || [];
		for my $of_fid (@$fid_lines) {
			_zero_times($of_fid) if $of_fid;
		}
	}

	_strip_prefix_from_paths(\@INC, $self->{fid_filename});

	return;
}


sub _zero_times {
	my ($ary_of_line_data) = @_;
	for my $line_data (@$ary_of_line_data) {
		next unless $line_data;
		$line_data->[0] = 0; # set profile time to 0
		# if line was a string eval
		# then recurse to zero the times within the eval lines
		if (my $eval_lines = $line_data->[2]) {
			_zero_times($eval_lines); # recurse
		}
	}
}


sub _strip_prefix_from_paths {
	my ($inc, $paths) = @_;
	# remove (absolute) @INC paths from filenames

	# build string regex for each path in @INC
	my $inc_regex = join "|", map { quotemeta $_ } grep { m/^\// } @$inc;
	# convert to regex object, anchor at start, soak up any /'s at end
	$inc_regex = qr{^(?:$inc_regex)/*};
	# stip off prefix using regex, skip any empty/undef paths
	$_ and s{$inc_regex}{} for @$paths;

	return;
}


1;

__END__

=head1 PROFILE DATA STRUTURE

XXX

=head1 SEE ALSO

L<Devel::NYTProf>

=head1 AUTHOR

Tim Bunce, L<http://www.tim.bunce.name> and L<http://blog.timbunce.org>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by Adam Kaplan and The New York Times Company.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut

# vim: ts=2 sw=2 sts=0 noexpandtab:
