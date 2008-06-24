#! /usr/bin/env perl
# vim: ts=8 sw=4 sts=4 expandtab:
##########################################################
## This script is part of the Devel::NYTProf distribution
##
## Copyright, contact and other information can be found
## at the bottom of this file, or by going to:
## http://search.cpan.org/perldoc?Devel::NYTProf
##
###########################################################
## $Id: test.pl 157 2008-06-23 02:56:43Z steve.peters $
###########################################################
use warnings;
use strict;

use Carp;
use Getopt::Long;
use Benchmark qw(:hireswallclock timethese cmpthese);

GetOptions(
    'v|verbose' => \my $opt_verbose,
) or exit 1;


# simple benchmark script to measure profiling overhead
my $test_script = "benchmark_code.pl";
open my $fh, ">", $test_script or die "Can't write to $test_script: $!\n";
print $fh q{
    sub foo {
        my $loop = shift;
        my $a = 0;
        while ($loop-- > 0) {
            ++$a;
        }
    }
    my $subs = 1000;
    while ($subs-- > 0) {
        foo(1000)
    }
};
close $fh or die "Error writing to $test_script: $!\n";
END { unlink $test_script };


my %tests = (
    baseline => {
        perlargs => '',
    },
    dprof => {
        perlargs => '-d:DProf',
        datafile => 'tmon.out',
    },
    fastprof => {
        perlargs => '-d:FastProf',
        datafile => 'fastprof.out',
    },
    profit => {
        perlargs => '-MDevel::Profit',
        datafile => 'profit.out',
    },
    nytprof => {
        perlargs => '-d:NYTProf',
        datafile => 'nytprof.out',
    },
    nytprof_b => {
        env => [ NYTPROF => 'blocks:file=nytprof_b.out' ],
        perlargs => '-d:NYTProf',
        datafile => 'nytprof_b.out',
    },
);

my %test_subs;
while ( my ($testname, $testinfo) = each %tests ) {
    $testinfo->{testname} = $testname;
    $test_subs{$testname} = sub { run_test($testinfo) };
}

timethese(4, \%test_subs, 'nop');

while ( my ($testname, $testinfo) = each %tests ) {
    if ($testinfo->{datafile}) {
        printf "%10s: %6.1fKB %s\n",
            $testname, (-s $testinfo->{datafile})/1024, $testinfo->{datafile};
        unlink $testinfo->{datafile};
    }
}

exit 0;

sub run_test {
    my $testinfo = shift;

    my $env = $testinfo->{env};
    local $ENV{$env->[0]} = $env->[1] if $env;

    my $cmd = "perl $testinfo->{perlargs} $test_script";
    system($cmd) == 0 or die "$cmd failed";
}
