package NYTProfTest;

use strict;
use warnings;

use Carp;
use Config;
use ExtUtils::testlib;
use Getopt::Long;
use Test::More;
use Data::Dumper;
use File::Temp qw(tempfile);
use List::Util qw(shuffle);

use base qw(Exporter);
our @EXPORT = qw(
    run_test_group
    run_command
    run_perl_command
);

use Devel::NYTProf::Data;
use Devel::NYTProf::Reader;
use Devel::NYTProf::Util qw(strip_prefix_from_paths html_safe_filename);
use Devel::NYTProf::Run qw(perl_command_words);

my $diff_opts = ($Config{osname} eq 'MSWin32') ? '-c' : '-u';

eval { require BSD::Resource } if $ENV{NYTPROF_TEST_RUSAGE}; # experimental

my %opts = (
    one          => $ENV{NYTPROF_TEST_ONE},
    profperlopts => $ENV{NYTPROF_TEST_PROFPERLOPTS} || '-d:NYTProf',
    html         => $ENV{NYTPROF_TEST_HTML},
    mergerdt     => $ENV{NYTPROF_TEST_MERGERDT}, # overkill, but handy
);
GetOptions(\%opts, qw/p=s I=s v|verbose d|debug html open profperlopts=s leave=i use_db_sub=i savesrc=i compress=i one abort/)
    or exit 1;

$opts{v}    ||= $opts{d};
$opts{html} ||= $opts{open};

# note some env vars that might impact the tests
$ENV{$_} && warn "$_=$ENV{$_}\n" for qw(PERL5DB PERL5OPT PERL_UNICODE PERLIO);

if ($ENV{NYTPROF}) {                        # avoid external interference
    warn "Existing NYTPROF env var value ($ENV{NYTPROF}) ignored for tests. Use NYTPROF_TEST env var if need be.\n";
    $ENV{NYTPROF} = '';
}

# options the user wants to override when running tests
my %NYTPROF_TEST = map { split /=/, $_, 2 } split /:/, $ENV{NYTPROF_TEST} || '';

# set some NYTProf options for this process in case 'extra tests' call
# Devel::NYTProf::Data methods directly. This is a hack because the options
# are global and there's no way to discover defaults or restore previous values.
# So we just do trace for now.
for my $opt (qw(trace)) {
    DB::set_option($opt, $NYTPROF_TEST{$opt}) if defined $NYTPROF_TEST{$opt};
}


my $tests_per_extn = {
    p   => 1,
    rdt => ($opts{mergerdt}) ? 2 : 1,
    x   => 3
};

chdir('t') if -d 't';

if (-d '../blib') {
    unshift @INC, '../blib/arch', '../blib/lib';
}
my $bindir      = (grep {-d} qw(./blib/script ../blib/script))[0] || do {
    my $bin = (grep {-d} qw(./bin ../bin))[0]
        or die "Can't find scripts";
    warn "Couldn't find blib/script directory, so using $bin";
    $bin;
};
my $nytprofcsv  = "$bindir/nytprofcsv";
my $nytprofhtml = "$bindir/nytprofhtml";
my $nytprofmerge= "$bindir/nytprofmerge";

my $path_sep = $Config{path_sep} || ':';
my $perl5lib = $opts{I} || join($path_sep, @INC);
my $perl     = $opts{p} || $^X;

# turn ./perl into ../perl, because of chdir(t) above.
$perl = ".$perl" if $perl =~ m|^\./|;


if ($opts{one}) {           # for one quick test
    $opts{leave}      = 1;
    $opts{use_db_sub} = 0;
    $opts{savesrc}    = 1;
    $opts{compress}   = 1;
}

# force savesrc off for perl 5.11.2 due to perl bug RT#70804
$opts{savesrc} = 0 if $] eq "5.011002";

my @test_opt_leave      = (defined $opts{leave})      ? ($opts{leave})      : (0, 1);
my @test_opt_use_db_sub = (defined $opts{use_db_sub}) ? ($opts{use_db_sub}) : (0, 1);
my @test_opt_savesrc    = (defined $opts{savesrc})    ? ($opts{savesrc})    : (0, 1);
my @test_opt_compress   = (defined $opts{compress})   ? ($opts{compress})   : (0, 1);

sub mk_opt_combinations {
    my ($overrides) = @_;

    my @opt_combinations;
    my %seen;
    for my $leave (@test_opt_leave) {
        for my $use_db_sub (@test_opt_use_db_sub) {
            for my $savesrc (@test_opt_savesrc) {
                for my $compress (@test_opt_compress) {
                    my $o = {
                        start      => 'init',
                        slowops    => 2,
                        leave      => $leave,
                        use_db_sub => $use_db_sub,
                        savesrc    => $savesrc,
                        compress   => $compress,
                        ($overrides) ? %$overrides : (),
                    };
                    my $key = join "\t", map { "$_=>$o->{$_}" } sort keys %$o;
                    next if $seen{$key}++;
                    push @opt_combinations, $o;
                }
            }
        }
    }
    @opt_combinations = shuffle @opt_combinations;
    return \@opt_combinations;
}

my %env_influence;
my %env_failed;


sub do_foreach_opt_combination {
    my ($opt_combinations, $code) = @_;

    my $rusage_start = get_rusage();

    COMBINATION:
    for my $env (@$opt_combinations) {

        my $prev_failures = count_of_failed_tests();

        my %env = (%$env, %NYTPROF_TEST);
        my @keys = sort keys %env; # put trace option first:
        @keys = ('trace', grep { $_ ne 'trace' } @keys) if $env{trace};

        local $ENV{NYTPROF} = join ":", map {"$_=$env{$_}"} @keys;

        my $context_msg = "NYTPROF=$ENV{NYTPROF}\n";
        ($opts{v}) ? warn $context_msg : print $context_msg;

        ok eval { $code->(\%env) };
        if ($@) {
            diag "Test group aborted: $@";
            last COMBINATION;
        }

        # did any tests fail?
        my $failed = (count_of_failed_tests() - $prev_failures) ? 1 : 0;
        # record what env settings may have influenced the failure
        ++$env_influence{$_}{$env->{$_}}{$failed ? 'fail' : 'pass'}
            for keys %$env;
        $env_failed{ $ENV{NYTPROF} } = $failed;
    }
    report_rusage($rusage_start);
}


# report which env vars influenced the failures, if any
sub report_env_influence {
    my ($tag) = @_;
    #warn Dumper(\%env_influence);

    my @env_influence;
    for my $envvar (sort keys %env_influence) {
        my $variants = $env_influence{$envvar};
        local $Data::Dumper::Indent   = 0;
        local $Data::Dumper::Sortkeys = 1;
        local $Data::Dumper::Terse    = 1;
        local $Data::Dumper::Quotekeys= 0;
        local $Data::Dumper::Pair     = ' ';
        $variants->{$_} = Dumper($variants->{$_}) for keys %$variants;
        my $v = (values %$variants)[0]; # use one as a reference
        # all the same?
        next if keys %$variants == grep { $_ eq $v } values %$variants;
        push @env_influence, sprintf "%15s: %s\n", $envvar,
            join ', ', map { "$_ => $variants->{$_}" } sort keys %$variants;
    }
    if (@env_influence and not defined wantarray) {
        push @env_influence, sprintf "%s with %s\n",
                $env_failed{$_} ? 'FAILED' : 'Passed', $_
            for sort keys %env_failed;

        diag "SUMMARY: Breakdown of $tag test failures by option settings:";
        diag $_ for @env_influence;
    }

    %env_influence = ();
    return @env_influence;
}


# execute a group of tests (t/testFoo.*) - calls plan()
sub run_test_group {
    my ($rtg_opts) = @_;
    my $extra_test_code  = $rtg_opts->{extra_test_code};
    my $extra_test_count = $rtg_opts->{extra_test_count} || 0;
    my $extra_options    = $rtg_opts->{extra_options};
    if ($ENV{NYTPROF_TEST_NOEXTRA}) {
        diag "NYTPROF_TEST_NOEXTRA - skipping $extra_test_count extra tests"
            if $extra_test_count;
        $extra_test_code = undef;
        $extra_test_count = 0;
        $extra_options = {};
    }

    # obtain group from file name
    my $group;
    if ((caller)[1] =~ /([^\/\\]+)\.t$/) {
        $group = $1;
    } else {
        croak "Can't determine test group";
    }

    my @tests = grep { -f $_ } map { "$group.$_" } sort keys %$tests_per_extn;
    unlink <$group.*_new{,p}>; # delete _new and _newp files from previous run

    if ($opts{v}) {
        print "tests: @tests\n";
        print "perl: $perl\n";
        print "perl5lib: $perl5lib\n";
        print "nytprofcvs: $nytprofcsv\n";
    }

    plan skip_all => "No '$group.*' test files and no extra_test_code"
        if !@tests and !$extra_test_code;

    my $opts = mk_opt_combinations($extra_options);
    my $tests_per_env = number_of_tests(@tests) + $extra_test_count + 1;

    plan tests => 1 + $tests_per_env * @$opts;

    # Windows emulates the executable bit based on file extension only
    ok($^O eq "MSWin32" ? -f $nytprofcsv : -x $nytprofcsv, "Found nytprofcsv as $nytprofcsv");

    # non-default output file to test override works and to allow parallel testing
    my $profile_datafile = "nytprof_$group.out";
    $NYTPROF_TEST{file} = $profile_datafile;

    do_foreach_opt_combination( $opts, sub {
        my ($env) = @_;

        for my $test (@tests) {
            run_test($test, $env);
        }

        if ($extra_test_code) {
            my $profile;
            if (@tests) {
                print("running $extra_test_count extra tests...\n");
                $profile = eval { Devel::NYTProf::Data->new({ filename => $profile_datafile }) };
                if ($@) {
                    diag($@);
                    fail("extra tests group '$group'") foreach (1 .. $extra_test_count);
                    return;
                }
            }

            $extra_test_code->($profile, $env);
        }

        return 1;
    } );

    report_env_influence($group);
}


sub run_test {
    my ($test, $env) = @_;
    my $tag = join " ", map { ($_ ne 'file') ? "$_=$env->{$_}" : () } sort keys %$env;

    #print $test . '.'x (20 - length $test);
    $test =~ / (.+?) \. (?:(\d)\.)? (\w+) $/x or do {
        warn "Can't parse test filename '$test'";
        return;
    };
    my ($basename, $fork_seqn, $type) = ($1, $2 || 0, $3);
    #warn "($basename, $fork_seqn, $type)\n";

    my $profile_datafile = $NYTPROF_TEST{file};
    my $test_datafile = (profile_datafiles($profile_datafile))[$fork_seqn];
    my $outdir = $basename.'_outdir';

    if ($type eq 'p') {
        unlink_old_profile_datafiles($profile_datafile);
        profile($test, $profile_datafile)
            or die "Profiling $test failed\n";

        if ($opts{html}) {
            my $htmloutdir = "/tmp/$outdir";
            unlink <$htmloutdir/*>;
            my $cmd = "$perl $nytprofhtml --file=$profile_datafile --out=$htmloutdir";
            $cmd .= " --open" if $opts{open};
            run_command($cmd);
        }
    }
    elsif ($type eq 'rdt') {
        verify_data($test, $tag, $test_datafile);

        if ($opts{mergerdt}) { # run the file through nytprofmerge
            my $merged = "$profile_datafile.merged";
            my $merge_cmd = "$nytprofmerge -v --out=$merged $test_datafile";
            warn "$merge_cmd\n";
            system($merge_cmd) == 0
                or die "Error running $merge_cmd\n";
            verify_data($test, "$tag (merged)", $merged);
            unlink $merged;
        }
    }
    elsif ($type eq 'x') {
        mkdir $outdir or die "mkdir($outdir): $!" unless -d $outdir;
        unlink <$outdir/*>;

        verify_csv_report($test, $tag, $test_datafile, $outdir);
    }
    elsif ($type =~ /^(?:pl|pm|new|outdir)$/) {
        # skip; handy for "test.pl t/test01.*"
    }
    else {
        warn "Unrecognized extension '$type' on test file '$test'\n";
    }

    if ($opts{abort}) {
        my $test_builder = Test::More->builder;
        my @summary = $test_builder->summary;
        BAIL_OUT("Aborting after test failure")
            if grep { !$_ } @summary;
    }
}


sub run_command {
    my ($cmd, $show_stdout) = @_;
    warn "NYTPROF=$ENV{NYTPROF}\n" if $opts{v} && $ENV{NYTPROF};
    local $ENV{PERL5LIB} = $perl5lib;
    warn "$cmd\n" if $opts{v};
    local *RV;
    open(RV, "$cmd |") or die "Can't execute $cmd: $!\n";
    my @results = <RV>;
    my $ok = close RV;
    if (not $ok) {
        warn "Error status $? from $cmd!\n";
        warn "NYTPROF=$ENV{NYTPROF}\n" if $ENV{NYTPROF} and not $opts{v};
        $show_stdout = 1;
        sleep 2;
    }
    if ($show_stdout) { warn $_ for @results }
    return $ok;
}


# some tests use profile_this() in Devel::NYTProf::Run
sub run_perl_command {
    my ($cmd, $show_stdout) = @_;
    local $ENV{PERL5LIB} = $perl5lib;
    my @perl = perl_command_words(skip_sitecustomize => 1);
    run_command("@perl $cmd", $show_stdout);
}


sub profile {
    my ($test, $profile_datafile) = @_;

    my @perl = perl_command_words(skip_sitecustomize => 1);
    my $cmd = "@perl $opts{profperlopts} $test";
    return ok run_command($cmd), "$test runs ok under the profiler";
}


sub verify_data {
    my ($test, $tag, $profile_datafile) = @_;

    my $profile = eval { Devel::NYTProf::Data->new({filename => $profile_datafile}) };
    if ($@) {
        diag($@);
        fail($test);
        return;
    }

    SKIP: {
        skip 'Expected profile data does not have VMS paths', 1
            if $^O eq 'VMS' and $test =~ m/test60|test14/i;
        $profile->normalize_variables;
        dump_profile_to_file($profile, $test.'_new', $test.'_newp');
        my @got      = slurp_file($test.'_new'); chomp @got;
        my @expected = slurp_file($test);        chomp @expected;
        is_deeply(\@got, \@expected, "$test match generated profile data for $tag")
            ? unlink($test.'_new')
            : diff_files($test, $test.'_new', $test.'_newp');
    }
}


sub dump_data_to_file {
    my ($profile, $file) = @_;
    open my $fh, ">", $file or croak "Can't open $file: $!";
    local $Data::Dumper::Indent   = 1;
    local $Data::Dumper::Sortkeys = 1;
    print $fh Data::Dumper->Dump([$profile], ['expected']);
    return;
}


sub dump_profile_to_file {
    my ($profile, $file, $rename_existing) = @_;
    rename $file, $rename_existing or warn "rename($file, $rename_existing): $!"
        if $rename_existing && -f $file;
    open my $fh, ">", $file or croak "Can't open $file: $!";
    $profile->dump_profile_data(
        {   filehandle => $fh,
            separator  => "\t",
            skip_fileinfo_hook => sub {
                my $fi = shift;
                return 1 if $fi->filename =~ /(AutoLoader|Exporter)\.pm$/ or $fi->filename =~ m!^/\.\.\./!;
                return 0;
            },
        }
    );
    return;
}

sub diff_files {
    my ($old_file, $new_file, $newp_file) = @_;

    # we don't care if this fails, it's just an aid to debug test failures
    my @opts = split / /, $ENV{NYTPROF_DIFF_OPTS} || $diff_opts;    # e.g. '-y'
    system("cmp -s $new_file $newp_file || diff @opts $old_file $new_file 1>&2");
}


sub verify_csv_report {
    my ($test, $tag, $profile_datafile, $outdir) = @_;

    # generate and parse/check csv report

    # determine the name of the generated csv file
    my $csvfile = $test;

    # fork tests will still report using the original script name
    $csvfile =~ s/\.\d\./.0./;

    # foo.p  => foo.p.csv  is tested by foo.x
    # foo.pm => foo.pm.csv is tested by foo.pm.x
    $csvfile =~ s/\.x//;
    $csvfile .= ".p" unless $csvfile =~ /\.p/;
    $csvfile = html_safe_filename($csvfile);
    $csvfile = "$outdir/${csvfile}-1-line.csv";
    unlink $csvfile;

    my $cmd = "$perl $nytprofcsv --file=$profile_datafile --out=$outdir";
    ok run_command($cmd), "nytprofcsv runs ok";

    my @got      = slurp_file($csvfile);
    my @expected = slurp_file($test);

    if ($opts{d}) {
        print "GOT:\n";
        print @got;
        print "EXPECTED:\n";
        print @expected;
        print "\n";
    }

    my $index = 0;
    foreach (@expected) {
        if ($expected[$index++] =~ m/^# Version/) {
            splice @expected, $index - 1, 1;
        }
    }

    my $automated_testing = $ENV{AUTOMATED_TESTING}
        # also try to catch some cases where AUTOMATED_TESTING isn't set
        # like http://www.cpantesters.org/cpan/report/07588221-b19f-3f77-b713-d32bba55d77f
                        || ($ENV{PERL_BATCH}||'') eq 'yes';
    # if it was slower than expected then we're very generous, to allow for
    # slow systems, e.g. cpan-testers running in cpu-starved virtual machines.
    # e.g., http://www.nntp.perl.org/group/perl.cpan.testers/2009/06/msg4227689.html
    my $max_time_overrun_percentage = ($automated_testing) ? 400 : 200;
    # e.g., http://www.nntp.perl.org/group/perl.cpan.testers/2009/06/msg4230206.html
    my $max_time_underrun_percentage = 90;

    my @accuracy_errors;
    $index = 0;
    my $limit = scalar(@got) - 1;
    while ($index < $limit) {
        $_ = shift @got;

        next if m/^# Version/;    # Ignore version numbers

        s/^([0-9.]+),([0-9.]+),([0-9.]+),(.*)$/0,$2,0,$4/o;
        my $t0  = $1;
        my $c0  = $2;
        my $tc0 = $3;

        if (    defined $expected[$index]
            and 0 != $expected[$index] =~ s/^~([0-9.]+)/0/
            and $c0               # protect against div-by-0 in some error situations
            )
        {
            my $expected = $1;
            my $percent  = int(($t0 / $expected) * 100);    # <100 if faster, >100 if slower

            # Test aproximate times
            push @accuracy_errors,
                  "$test line $index: got $t0 expected approx $expected for time ($percent%)"
                if ($percent < $max_time_underrun_percentage)
                or ($percent > $max_time_overrun_percentage);

            my $tc = $t0 / $c0;
            push @accuracy_errors, "$test line $index: got $tc0 expected ~$tc for time/calls"
                if abs($tc - $tc0) > 0.00002;   # expected to be very close (rounding errors only)
        }

        push @got, $_;
        $index++;
    }

    if ($opts{d}) {
        print "TRANSFORMED TO:\n";
        print @got;
        print "\n";
    }

    chomp @got;
    chomp @expected;
    is_deeply(\@got, \@expected, "$test match generated CSV data for $tag") or do {
        spit_file($test.'_new', join("\n", @got,''), $test.'_newp');
        diff_files($test, $test.'_new', $test.'_newp');
    };
    is(join("\n", @accuracy_errors), '', "$test times should be reasonable");
}


sub pop_times {
    my $hash = shift || return;

    foreach my $key (keys %$hash) {
        shift @{$hash->{$key}};
        pop_times($hash->{$key}->[1]);
    }
}


sub number_of_tests {
    my $total_tests = 0;
    for (@_) {
        next unless m/\.(\w+)$/;
        my $tests = $tests_per_extn->{$1};
        warn "Unknown test type '$1' for test file '$_'\n" if not defined $tests;
        $total_tests += $tests if $tests;
    }
    return $total_tests;
}


sub slurp_file {    # individual lines in list context, entire file in scalar context
    my ($file) = @_;
    open my $fh, "<", $file or croak "Can't open $file: $!";
    return <$fh> if wantarray;
    local $/ = undef;    # slurp;
    return <$fh>;
}


sub spit_file {
    my ($file, $content, $rename_existing) = @_;
    rename $file, $rename_existing or warn "rename($file, $rename_existing): $!"
        if $rename_existing && -f $file;
    open my $fh, ">", $file or croak "Can't open $file: $!";
    print $fh $content;
    close $fh or die "Error closing $file: $!";
}


sub profile_datafiles {
    my ($filename) = @_;
    croak "No filename specified" unless $filename;
    my @profile_datafiles = glob("$filename*");

    # sort to ensure datafile without pid suffix is first
    @profile_datafiles = sort @profile_datafiles;
    return @profile_datafiles;    # count in scalar context
}

sub unlink_old_profile_datafiles {
    my ($filename) = @_;
    my @profile_datafiles = profile_datafiles($filename);
    print "Unlinking old @profile_datafiles\n"
        if @profile_datafiles and $opts{v};
    1 while unlink @profile_datafiles;
}


sub count_of_failed_tests {
    my @details = Test::Builder->new->details;
    return scalar grep { not $_->{ok} } @details;
}


sub get_rusage {
    return scalar eval { BSD::Resource::getrusage(BSD::Resource::RUSAGE_CHILDREN()) };
}

sub report_rusage {
    my $ru1 = shift or return;
    my $ru2 = get_rusage();
    my %diff;
    $diff{$_} = $ru2->$_ - $ru1->$_ for (qw(maxrss));
    warn " maxrss: $diff{maxrss}\n";
}


1;

# vim:ts=8:sw=4:et
