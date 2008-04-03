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
my @tests = @ARGV ? @ARGV : sort <*.p *.v *.x>;  # glob-sort, for OS/2

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
	
		if ($2 eq 'p') {
			profile($test);
		} elsif($2 eq 'v') {
			SKIP: {
        skip "Tests incompatible with your perl version", 1, 
              if $SKIP_TESTS{$1};
        verify_result($test);
      }
		} elsif($2 eq 'x') {
			SKIP: {
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

sub verify_result {
	my $test = shift;
	my $hash = eval { Devel::NYTProf::Reader::process() };
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
	{
		local $/ = undef;
		open(TEST, $test) or die "Unable to open test $test: $!\n";
		my $contents = <TEST>; #slurp
		close TEST;
		eval $contents;
	}
	is_deeply($hash, $expected, $test);
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
	open(IN, "$outdir/${infile}csv") or die "Can't open test file: $outdir/${infile}csv";
	my @got = <IN>;
	close IN;

	open(EXP, $test) or die "Unable to open testing file t/$test\n";
	my @expected = <EXP>;
	close EXP;

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
		$tests += { p => 1, v => 1, x => 2 }->{$1};
	}
	return $tests;
}

# vim:ts=2:sw=2
