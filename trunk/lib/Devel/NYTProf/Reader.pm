# vim: ts=8 sw=4 expandtab:
##########################################################
## This script is part of the Devel::NYTProf distribution
##
## Copyright, contact and other information can be found
## at the bottom of this file, or by going to:
## http://search.cpan.org/dist/Devel-NYTProf/
##
###########################################################
## $Id$
###########################################################
package Devel::NYTProf::Reader;

our $VERSION = '3.11';

use warnings;
use strict;
use Carp;
use Config;

use List::Util qw(sum max);
use Data::Dumper;

use Devel::NYTProf::Data;
use Devel::NYTProf::Util qw(
    fmt_float
    fmt_time
    strip_prefix_from_paths
    html_safe_filename
    calculate_median_absolute_deviation
);

# These control the limits for what the script will consider ok to severe times
# specified in standard deviations from the mean time
use constant SEVERITY_SEVERE => 2.0;    # above this deviation, a bottleneck
use constant SEVERITY_BAD    => 1.0;
use constant SEVERITY_GOOD   => 0.5;    # within this deviation, okay

my $trace = 0;

# Static class variables
our $FLOAT_FORMAT = $Config{nvfformat};
$FLOAT_FORMAT =~ s/"//g;

# Class methods
sub new {
    my $class = shift;
    my $file  = shift;
    my $opts  = shift;

    my $self = {
        file => $file || 'nytprof.out',
        output_dir => '.',
        suffix     => '.csv',
        header     => "# Profile data generated by Devel::NYTProf::Reader\n"
            . "# Version: v$Devel::NYTProf::Core::VERSION\n"
            . "# More information at http://search.cpan.org/dist/Devel-NYTProf/\n"
            . "# Format: time,calls,time/call,code\n",
        datastart => '',
        mk_report_source_line => undef,
        mk_report_xsub_line   => undef,
        mk_report_separator_line => undef,
        line      => [
            {},
            {value => 'time',      end => ',', default => '0'},
            {value => 'calls',     end => ',', default => '0'},
            {value => 'time/call', end => ',', default => '0'},
            {value => 'source',    end => '',  default => ''},
            {end   => "\n"}
        ],
        dataend  => '',
        footer   => '',
        merged_fids => '',
        taintmsg => "# WARNING!\n"
            . "# The source file used in generating this report has been modified\n"
            . "# since generating the profiler database.  It might be out of sync\n",
    };

    bless($self, $class);
    $self->{profile} = Devel::NYTProf::Data->new({filename => $self->{file}});

    return $self;
}



##
sub set_param {
    my ($self, $param, $value) = @_;

    if (!exists $self->{$param}) {
        confess "Attempt to set $param to $value failed: $param is not a valid " . "parameter\n";
    }
    else {
        return $self->{$param} unless defined($value);
        $self->{$param} = $value;
    }
    undef;
}


sub get_param {
    my ($self, $param, $code_args) = @_;
    my $value = $self->{$param};
    if (ref $value eq 'CODE') {
        $code_args ||= [];
        $value = $value->(@$code_args);
    }
    return $value;
}

##
sub file_has_been_modified {
    my $self = shift;
    my $file = shift;
    return undef unless -f $file;
    my $mtime = (stat $file)[9];
    return ($mtime > $self->{profile}{attribute}{basetime});
}

##
sub _output_additional {
    my ($self, $fname, $content) = @_;
    open(OUT, '>', "$self->{output_dir}/$fname")
        or confess "Unable to open $self->{output_dir}/$fname for writing; $!\n";
    print OUT $content;
    close OUT;
}

##
sub output_dir {
    my ($self, $dir) = @_;
    return $self->{output_dir} unless defined($dir);
    if (!mkdir $dir) {
        confess "Unable to create directory $dir: $!\n" if !$! =~ /exists/;
    }
    $self->{output_dir} = $dir;
}

##
sub report {
    my $self = shift;
    my ($opts) = @_;

    print "Writing report to $self->{output_dir} directory\n"
        unless $opts->{quiet};

    my $level_additional_sub = $opts->{level_additional};
    my $profile              = $self->{profile};
    my $modes                = $profile->get_profile_levels;
    for my $level (grep { {reverse %$modes}->{$_} } qw(sub block line)) {
        $self->_generate_report($profile, $level);
        $level_additional_sub->($profile, $level)
            if $level_additional_sub;
    }
}

sub current_level {
    my $self = shift;
    $self->{current_level} = shift if @_;
    return $self->{current_level} || 'line';
}

sub fname_for_fileinfo {
    my ($self, $fi, $level) = @_;
    $level ||= $self->current_level;

    my $fname = html_safe_filename($fi->filename_without_inc);
    $fname .= "-".$fi->fid;
    $fname .= "-$level" if $level;

    return $fname;
}


##
sub _generate_report {
    my $self = shift;
    my ($profile, $LEVEL) = @_;

    $self->current_level($LEVEL);

    my @all_fileinfos = $profile->all_fileinfos
        or carp "Profile report data contains no files";

    #$profile->dump_profile_data({ filehandle => \*STDERR, separator=>"\t", });

    foreach my $fi (@all_fileinfos) {

        # we only generate line-level reports for evals
        # for efficiency and because some data model editing only
        # is only implemented for line-level data
        next if $fi->is_eval and $LEVEL ne 'line';

        my $meta = $fi->meta;
        my $filestr = $fi->filename;
        warn "$filestr $LEVEL\n" if $trace;

        my %stats_accum;         # holds all line times. used to find median
        my %stats_by_line;        # holds individual line stats
        my $runningTotalTime = 0;  # holds the running total

        # (should equal sum of $stats_accum)
        my $runningTotalCalls = 0; # holds the running total number of calls.

        # { linenumber => { subname => [ count, time ] } }
        my $subcalls_at_line = { %{ $fi->sub_call_lines } };

        # { linenumber => { fid => $fileinfo } }
        my $evals_at_line = { %{ $fi->evals_by_line } };

        my $subs_defined_hash = $profile->subs_defined_in_file($filestr, 1);

        # note that a file may have no source lines executed, so no keys here
        # (but is included because some xsubs in the package were executed)

        my $lines_array = $fi->line_time_data([$LEVEL]) || [];

        foreach my $linenum (1..@$lines_array) {

            if (my $subdefs = $subs_defined_hash->{$linenum}) {
                $stats_by_line{$linenum}->{'subdef_info'}  = $subdefs;
            }

            if (my $subcalls = $subcalls_at_line->{$linenum}) {
                my $line_stats = $stats_by_line{$linenum} ||= {};

                $line_stats->{'subcall_info'}  = $subcalls;
                $line_stats->{'subcall_count'} = sum(map { $_->[0] } values %$subcalls);
                $line_stats->{'subcall_time'}  = sum(map { $_->[1] } values %$subcalls);

                push @{$stats_accum{$_}}, $line_stats->{$_}
                    for (qw(subcall_count subcall_time));
            }

            if (my $evalcalls = $evals_at_line->{$linenum}) {
                my $line_stats = $stats_by_line{$linenum} ||= {};

                # %$evals => { fid => $fileinfo }
                $line_stats->{'evalcall_info'}  = $evalcalls;
                $line_stats->{'evalcall_count'} = values %$evalcalls;

                # get list of evals, including nested evals
                my @eval_fis = map { ($_, $_->has_evals(1)) } values %$evalcalls;
                $line_stats->{'evalcall_count_nested'} = @eval_fis;
                $line_stats->{'evalcall_stmts_time_nested'} = sum(
                    map { $_->sum_of_stmts_time } @eval_fis);
            }

            if (my $stmts = $lines_array->[$linenum]) {
                next if !@$stmts; # XXX happens for evals, investigate

                my ($stmt_time, $stmt_count) = @$stmts;
                my $line_stats = $stats_by_line{$linenum} ||= {};

                # The debugger cannot stop on BEGIN{...} lines.  A line in a begin
                # may set a scalar reference to something that needs to be eval'd later.
                # as a result, if the variable is expanded outside of the BEGIN, we'll
                # see the original BEGIN line, but it won't have any calls or times
                # associated. This will cause a divide by zero error.
                $stmt_count ||= 1;

                $line_stats->{'time'}  = $stmt_time;
                $line_stats->{'calls'} = $stmt_count;
                $line_stats->{'time/call'} = $stmt_time/$stmt_count;

                push @{$stats_accum{$_}}, $line_stats->{$_}
                    for (qw(time calls time/call));

                $runningTotalTime  += $stmt_time;
                $runningTotalCalls += $stmt_count;
            }

            warn "$linenum: @{[ %{ $stats_by_line{$linenum} } ]}\n"
                if $trace >= 3 && $stats_by_line{$linenum};
        }

        $meta->{'time'}      = $runningTotalTime;
        $meta->{'calls'}     = $runningTotalCalls;
        $meta->{'time/call'} =
            ($runningTotalCalls) ? $runningTotalTime / $runningTotalCalls: 0;

        # Use Median Absolute Deviation Formula to get file deviations for each of
        # calls, time and time/call values
        my %stats_for_file = (
            'calls'     => calculate_median_absolute_deviation($stats_accum{'calls'}||[]),
            'time'      => calculate_median_absolute_deviation($stats_accum{'time'}||[]),
            'time/call' => calculate_median_absolute_deviation($stats_accum{'time/call'}||[]),
            subcall_count => calculate_median_absolute_deviation($stats_accum{subcall_count}||[]),
            subcall_time  => calculate_median_absolute_deviation($stats_accum{subcall_time}||[]),
        );

        # the output file name that will be open later.  Not including directory at this time.
        # keep here so that the variable replacement subs can get at it.
        my $fname = $self->fname_for_fileinfo($fi) . $self->{suffix};

        # localize header and footer for variable replacement
        my $header    = $self->get_param('header',    [$profile, $fi, $fname, $LEVEL]);
        my $datastart = $self->get_param('datastart', [$profile, $fi]);
        my $dataend   = $self->get_param('dataend',   [$profile, $fi]);
        my $FILE      = $filestr;
#warn Dumper(\%stats_by_line);
        # open output file
        #warn "$self->{output_dir}/$fname";
        open(OUT, ">", "$self->{output_dir}/$fname")
            or confess "Unable to open $self->{output_dir}/$fname " . "for writing: $!\n";

        # begin output
        print OUT $header;

        # If we don't have savesrc for the file then we'll be reading the current
        # file contents which may have changed since the profile was run.
        # In this case we need to warn the user as the report would be garbled.
        print OUT $self->get_param('taintmsg', [$profile, $fi])
            if !$fi->has_savesrc and $self->file_has_been_modified($filestr);

        print OUT $self->get_param('merged_fids', [$profile, $fi])
            if $fi->meta->{merged_fids};

        print OUT $datastart;

        my $LINE = 1;    # line number in source code
        my $src_lines = $fi->srclines_array;
        if (!$src_lines) { # no savesrc, and no file available

            my $msg;
            if ($fi->is_eval) {
                $msg = "No source code available for string eval $filestr.\nSee savesrc option in documentation.",
            }
            elsif ($fi->is_fake) {
                # eg the "/unknown-eval-invoker"
                $msg = "No source code available for 'fake' file $filestr.",
            }
            elsif ($filestr =~ m{^/loader/0x[0-9a-zA-Z]+/}) {
                # a synthetic file name that perl assigns when reading
                # code returned by a CODE ref in @INC
                $msg = "No source code available for 'file' loaded via CODE reference in \@INC.\nSee savesrc option in documentation.",
            }
            else {

                # the report will not be complete, but this doesn't need to be fatal
                my $hint = '';
                $hint = " Try running $0 in the same directory as you ran Devel::NYTProf, "
                      . "or ensure \@INC is correct."
                    if $filestr ne '-e'
                    and $filestr !~ m:^/:
                    and not our $_generate_report_inc_hint++;                # only once

                $msg = "Unable to open '$filestr' for reading: $!.$hint\n";
                warn $msg
                    unless our $_generate_report_filestr_warn->{$filestr}++; # only once per filestr

            }

            $src_lines = [ $msg ];
            $LINE = 0;
        }
        
        # if we don't have source code, still pad out the lines to match the data we have
        # so the report page isn't completely useless
        if (!@$src_lines or !$LINE) {
            my @interesting_lines = grep { m/^\d+$/ } (
                keys %$subcalls_at_line,
                keys %$subs_defined_hash,
                keys %stats_by_line
            );
            my $interesting_lines = max(@interesting_lines)||1;
            $src_lines->[$_] ||= '' for 0..$interesting_lines-1; # grow array
        }

        my $line_sub = $self->{mk_report_source_line}
            or die "mk_report_source_line not set";

        my $prev_line = '-';
        while ( @$src_lines ) {
            my $line = shift @$src_lines;
            chomp $line;

            # detect a series of blank lines, e.g. a chunk of pod savesrc didn't store
            my $skip_blanks = (
                $prev_line eq '' && $line eq '' &&            # blank behind and here
                @$src_lines && $src_lines->[0] =~ /^\s*$/ &&  # blank ahead
                !$stats_by_line{$LINE}                        # nothing to report
            );

            if ($line =~ m/^\# \s* line \s+ (\d+) \b/x) {
                # XXX we should be smarter about this - patches welcome!
                # We should at least ignore the common AutoSplit case
                # which we detect and workaround elsewhere.
                warn "Ignoring '$line' directive at line $LINE - profile data for $filestr will be out of sync with source!\n"
                    unless our $line_directive_warn->{$filestr}++; # once per file
            }

            print OUT $line_sub->(
                ($skip_blanks) ? "- -" : $LINE, $line,
                $stats_by_line{$LINE} || {},
                \%stats_for_file,
                $profile,
                $fi,
            );

            if ($skip_blanks) {
                while (
                    @$src_lines && $src_lines->[0] =~ /^\s*$/ &&
                    !$stats_by_line{$LINE+1}
                ) {
                    shift @$src_lines;
                    $LINE++;
                }
            }
            $prev_line = $line;
        }
        continue {
            $LINE++;
        }

        if (my $line_sub = $self->{mk_report_separator_line}) {
            print OUT $line_sub->($profile, $fi);
        }

        # iterate over xsubs 
        $line_sub = $self->{mk_report_xsub_line}
            or die "mk_report_xsub_line not set";
        my $subs_defined_in_file = $profile->subs_defined_in_file($filestr, 0);
        foreach my $subname (sort keys %$subs_defined_in_file) {
            my $subinfo = $subs_defined_in_file->{$subname};
            my $kind = $subinfo->kind;

            next if $kind eq 'perl';
            next if $subinfo->calls == 0;

            print OUT $line_sub->(
                $subname,
                "sub $subname; # $kind\n\t",
                { subdef_info => [ $subinfo ], },  #stats_for_line
                undef, # stats_for_file
                $profile, $fi
            );
        }

        print OUT $dataend;
        print OUT $self->get_param('footer', [$profile, $filestr]);
        close OUT;
    }
}


sub url_for_file {
    my ($self, $file, $anchor, $level) = @_;

    my $fi = $self->{profile}->fileinfo_of($file);
    #return "" if $fi->is_fake;

    my $url = $self->fname_for_fileinfo($fi, $level);
    $url .= '.html';
    $url .= "#$anchor" if defined $anchor;

    return $url;
}

sub href_for_file {
    my $url = shift->url_for_file(@_);
    return qq{href="$url"} if $url;
    return $url;
}


sub url_for_sub {
    my ($self, $sub, %opts) = @_;
    my $profile = $self->{profile};

    my ($file, $fid, $first, $last, $fi) = $profile->file_line_range_of_sub($sub);
    if (!$first) {
        if (not defined $first) {
            warn("No file line range data for sub '$sub' (perhaps an xsub)\n")
                unless our $url_for_sub_no_data_warn->{$sub}++;    # warn just once
            return "";
        }
        # probably xsub
        # return no link if we don't have a file for this xsub
        return "" unless $file;
        # use sanitized subname as label
        ($first = $sub) =~ s/\W/_/g;
    }
    return $self->url_for_file($fi, $first);
}

sub href_for_sub {
    my $url = shift->url_for_sub(@_);
    return qq{href="$url"} if $url;
    return $url;
}


1;
