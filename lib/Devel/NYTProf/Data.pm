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
use Cwd qw(getcwd);

use Devel::NYTProf::Core;
use Devel::NYTProf::Util qw(strip_prefix_from_paths);

=head2 new

	$profile = Devel::NYTProf::Data->new( { filename => 'nytprof.out' } );
  
Reads the specified file containing profile data written by L<Devel::NYTProf>,
aggregates the contents, and returns the results as a blessed data structure.

=cut

sub new {
	my $class = shift;
	my $args = shift || { filename => 'nytprof.out' };

	croak "No file specified (@{[ %$args ]})" unless $args->{filename};
	
	my @files;
	if(defined $args->{allowfork}) {
		@files = glob($args->{filename} . "*");
	} else {
		push @files, $args->{filename};
	}
	my $profile = Devel::NYTProf::Data::load_profile_data_from_file(\@files);
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

	$self->make_fid_filenames_relative( [ @INC, '.' ] );

	return;
}


sub make_fid_filenames_relative {
	my ($self, $roots) = @_;
	$roots ||= [ '.' ]; # e.g. [ @INC, '.' ]
	strip_prefix_from_paths($roots, $self->{fid_filename});
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


sub _filename_to_fid {
	my $self = shift;
	return $self->{_filename_to_fid_cache} ||= do {
		my $fid_filename = $self->{fid_filename} || [];
		my $filename_to_fid = {};
		for my $fid (1..@$fid_filename-1) {
			my $filename = $fid_filename->[$fid];
			$filename = $filename->[0] if ref $filename; # string eval
			$filename_to_fid->{$filename} = $fid;
		}
		$filename_to_fid;
	};
}


=head2 file_line_range_of_sub

    ($file, $fid, $first, $last) = $profile->file_line_range_of_sub("main::foo");

Returns the filename, fid, and first and last line numbers for the specified
subroutine (which must be fully qualified with a package name).

Returns an empty list if the subroutine name is not in the profile data.

The $fid return is the 'original' fid associated with the file the subroutine was created in.

The $file returned is the source file that defined the subroutine.

Where is a subroutine is defined within a string eval, for example, the fid
will be the pseudo-fid for the eval, and the $file will be the filename that
executed the eval.

=cut

sub file_line_range_of_sub {
	my ($self, $sub) = @_;

	my $sub_fid_line = $self->{sub_fid_line}{$sub}
			or return; # no such sub
	my ($fid, $first, $last) = @$sub_fid_line;

	my $file = $self->{fid_filename}->[$fid];
	while (ref $file eq 'ARRAY') {
		# eg string eval
		# eg [ "(eval 6)[/usr/local/perl58-i/lib/5.8.6/Benchmark.pm:634]", 2, 634 ]
		warn sprintf "%s: fid %d -> %d for %s\n",
			$sub, $fid, $file->[1], $file->[0];
		$first = $last = $file->[2] if 1; # XXX control via param?
		# follow next link in chain
		my $outer_fid = $file->[1];
		$file = $self->{fid_filename}->[$outer_fid];
	}

	return ($file, $fid, $first, $last);
}


=head2 resolve_fid

  $fid = $profile->resolve_fid( $file );

Returns the integer I<file id> that corresponds to $file.

If $file can't be found and $file looks like a positive integer then it's
presumed to already be a fid and is returned. This is used to enable other
methods to work with fid or file arguments.

If $file can't be found but it uniquely matches the suffix of one of the files
then that corresponding fid is returned.

=cut

sub resolve_fid {
	my ($self, $file) = @_;
	my $resolve_fid_cache = $self->_filename_to_fid;

	# exact match
	return $resolve_fid_cache->{$file}
		if exists $resolve_fid_cache->{$file};

	# looks like a fid already
	return $file
		if $file =~ m/^\d+$/;

	# unfound absolute path, so we're sure we won't find it
	return undef	# XXX carp?
		if $file =~ m/^\//;

	# prepend '/' and grep for trailing matches - if just one then use that
	my $match = qr{/\Q$file\E$};
	my @matches = grep { m/$match/ } keys %$resolve_fid_cache;
	return $self->resolve_fid($matches[0])
		if @matches == 1;
	carp "Can't resolve '$file' to a unique file id (matches @matches)"
		if @matches >= 2;

	return undef;
}


=head2 line_calls_for_file

  $line_calls_hash = $profile->line_calls_for_file( $file );

Returns a reference to a hash containing information about subroutine calls
made at individual lines within a source file.  lines in the file.  The $file
argument can be an integer file id (fid) or a file path. Returns undef if the
profile contains no C<sub_caller> data.

The keys of the returned hash are line numbers. The values are references to
hashes with fully qualifies subroutine names as keys and integer call counts as
values.

For example, if the following was line 42 of a file C<foo.pl>:

  ++$wiggle if foo(24) == bar(42);

that line was executed once, and foo and bar were imported from pkg1, then
$profile->line_calls_for_file( 'foo.pl' ) would return:

	{
		42 => {
			'pkg1::foo' => 1,
			'pkg1::bar' => 1,
		},
	}

=cut

sub line_calls_for_file {
	my ($self, $fid) = @_;

	$fid = $self->resolve_fid($fid);
	my $sub_caller = $self->{sub_caller}
		or return;

	my $line_calls = {};
	while ( my ($sub, $fid_hash) = each %$sub_caller) {
		my $line_calls_hash = $fid_hash->{$fid}
			or next;

		while ( my ($line, $calls) = each %$line_calls_hash) {
			$line_calls->{$line}{$sub} += $calls;
		}

	}
	return $line_calls;
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
