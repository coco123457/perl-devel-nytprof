#! /usr/bin/env perl
# vim: ts=2 sw=2 sts=0 noexpandtab:
##########################################################
## This script is part of the Devel::NYTProf distribution
##
## Copyright, contact and other information can be found
## at the bottom of this file, or by going to:
## http://search.cpan.org/~akaplan/Devel-NYTProf
##
###########################################################
## $Id$
###########################################################
use warnings;
use strict;

use ExtUtils::testlib;
use Benchmark;
use Getopt::Long;
use Config;
use Test::More;

use Devel::NYTProf::Reader;


# skip these tests when the provided condition is true
my %SKIP_TESTS = (
	'test06' => ($] < 5.008) ? 1 : 0,
	'test15' => ($] >= 5.008) ? 1 : 0,
);

my %opts;
GetOptions(\%opts, qw/p=s I=s v/);

$ENV{NYTPROF} = ''; # avoid external interference, but see NYTPROF_TEST below
$| = 1;

my $opt_perl = $opts{p};
my $opt_include = $opts{I};
my $outdir = 'profiler';

chdir( 't' ) if -d 't';
mkdir $outdir or die "mkdir($outdir): $!" unless -d $outdir;

s:^t/:: for @ARGV; # allow args to use t/ prefix
my @tests = @ARGV ? @ARGV : sort <*.p *.v *.w *.x>;  # glob-sort, for OS/2

plan tests => 1 + number_of_tests(@tests);

my $path_sep = $Config{path_sep} || ':';
if( -d '../blib' ){
	unshift @INC, '../blib/arch', '../blib/lib';
}
my $fprofcsv = './bin/nytprofcsv';
if( -d '../bin' ) {
	$fprofcsv = ".$fprofcsv";
}

my $perl5lib = $opt_include || join( $path_sep, @INC );
my $perl = $opt_perl || $^X;

if( $opts{v} ){
	print "tests: @tests\n";
	print "perl: $perl\n";
	print "perl5lib: $perl5lib\n";
	print "fprofcvs: $fprofcsv\n";
}
if( $perl =~ m|^\./| ) {
	# turn ./perl into ../perl, because of chdir(t) above.
	$perl = ".$perl";
}
#ok(-f $perl, "Where's Perl?");
ok(-x $fprofcsv, "Where's fprofcsv?");


$|=1;
foreach my $test (@tests) {

	#print $test . '.'x (20 - length $test);
	$test =~ /(\w+)\.(\w)$/;

	SKIP: {

		if ($2 eq 'p') {
			profile($test);
		}
		elsif ($2 eq 'v') {
			skip "Tests incompatible with your perl version", 1, 
						if $SKIP_TESTS{$1};
			verify_old_data($test);
		}
		elsif ($2 eq 'w') {
			skip "Tests incompatible with your perl version", 1, 
						if $SKIP_TESTS{$1};
			verify_data($test);
		}
		elsif ($2 eq 'x') {
			skip "Tests incompatible with your perl version", 2, 
						if $SKIP_TESTS{$1};
			verify_report($test);
		}
	}
}

exit 0;

sub run_command {
  my ($cmd) = @_;
  local $ENV{PERL5LIB} = $perl5lib;
  open(RV, "$cmd |") or die "Can't execute $cmd: $!\n";
  my @results = <RV>;
  close RV or warn "Error status $? from $cmd\n";
  if ($opts{v}) {
    print "$cmd\n";
    print @results;
    print "\n";
  }
  return @results;
}

sub profile {
	my $test = shift;
	
	my @NYTPROF;
	push @NYTPROF, $ENV{NYTPROF_TEST} if $ENV{NYTPROF_TEST};
	push @NYTPROF, "allowfork" if $test eq "test04.p";
	local $ENV{NYTPROF} = join ":", @NYTPROF;
	print "NYTPROF=$ENV{NYTPROF}\n" if $opts{v} && $ENV{NYTPROF};

	my $t_start = new Benchmark;
	my @results = run_command("$perl -d:NYTProf $test");
	my $t_total = timediff( new Benchmark, $t_start );
	pass($test); # mainly to show progress
	#print timestr( $t_total, 'nop' ), "\n";
}


sub verify_old_data {
	my $test = shift;
	my $hash = eval { Devel::NYTProf::Reader::process('nytprof.out') };
	if ($@) {
		diag($@);
		fail($test);
		return;
	}

  # remove times unless specifically testing times
  foreach my $outer (keys %$hash) {
		pop_times($hash->{$outer});
	}

	my $expected;
	eval scalar slurp_file($test);
	is_deeply($hash, $expected, $test);
}


sub verify_data {
	my $test = shift;

	my $profile = eval { Devel::NYTProf::Data->new( { filename => 'nytprof.out' }) };
	if ($@) {
		diag($@);
		fail($test);
		return;
	}

	$profile->normalize_variables;
	dump_profile_to_file($profile, "$test.new");
	my @got      = slurp_file("$test.new");
	my @expected = slurp_file($test);

	is_deeply(\@got, \@expected, $test)
		or diff_files($test, "$test.new");
}

sub dump_profile_to_file {
	my ($profile, $file) = @_;
	open my $fh, ">", $file or die "Can't open $file: $!\n";
	$profile->dump_profile_data( {
		filehandle => $fh,
		separator  => "\t",
	} );
	return;
}

sub diff_files {
	# we don't care if this fails, it's just an aid to debug test failures
	system("diff", "-u", @_);
}

sub verify_report {
	my $test = shift;

	my @results = run_command("$perl $fprofcsv");

	# parse/check
  my $infile;
  { local ($1, $2);
	$test =~ /^(\w+\.(\w+\.)?)x$/;
  $infile = $1;
  if (defined $2) {
  } else {
    $infile .= "p.";
  }
  }
	my @got      = slurp_file("$outdir/${infile}csv");
	my @expected = slurp_file($test);

	if ($opts{v}) {
		print "GOT:\n";
		print @got;
		print "EXPECTED:\n";
		print @expected;
		print "\n";
	}

	my $index = 0;
	foreach (@expected) {
    if ($expected[$index++] =~ m/^# Version/) {
    	splice @expected, $index-1, 1;
    }
  }
 
	my @accuracy_errors;
	$index = 0;
	my $limit = scalar(@got)-1;
	while ($index < $limit) {
		$_ = shift @got;

    if (m/^# Version/) {
			next;
    }

    # Ignore version numbers
		s/^([0-9.]+),([0-9.]+),([0-9.]+),(.*)$/0,$2,0,$4/o;
		my $t0 = $1;
		my $c0 = $2;
		my $tc0 = $3;

		if (0 != $expected[$index] =~ s/^\|([0-9.]+)\|(.*)/0$2/o) {
			push @accuracy_errors, "$test line $index: got $t0 expected ~$1 for time"
				if abs($1 - $t0) > 0.2; # Test times. expected to be within 200ms
			my $tc = $t0 / $c0;
			push @accuracy_errors, "$test line $index: got $tc0 expected ~$tc for time/calls"
				if abs($tc - $tc0) > 0.00002; # expected to be very close (rounding errors only)
		}

		push @got, $_;
		$index++;
	}

	if ($opts{v}) {
		print "TRANSFORMED TO:\n";
		print @got;
		print "\n";
	}

	is_deeply(\@got, \@expected, $test);
	is(join("\n",@accuracy_errors), '', $test);
}

sub pop_times {
	my $hash = shift||return;

	foreach my $key (keys %$hash) {
		shift @{$hash->{$key}};
		pop_times($hash->{$key}->[1]);
	}
}

sub number_of_tests {
	my $tests = 0;
	for (@_) {
		next unless m/\.(.)$/;
		$tests += { p => 1, v => 1, w => 1, x => 2 }->{$1};
	}
	return $tests;
}


sub slurp_file { # individual lines in list context, entire file in scalar context
	my ($file) = @_;
	open my $fh, "<", $file or die "Can't open $file: $!\n";
	return <$fh> if wantarray;
	local $/ = undef; # slurp;
	return <$fh>;
}


# vim:ts=2:sw=2
