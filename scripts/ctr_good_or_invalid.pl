#!/usr/bin/perl -w
# -*- perl -*-

#
# Author: Slaven Rezic
#
# Copyright (C) 2008-2010,2012,2013,2014,2015,2016,2017 Slaven Rezic. All rights reserved.
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.
#
# Mail: slaven@rezic.de
# WWW:  http://www.rezic.de/eserte/
#

use strict;
use FindBin;
use lib "$FindBin::RealBin/../lib/perl";

BEGIN {
    if ($ENV{USER} eq 'eserte') { # XXX enable experiment only for me
	eval q{ use CtrGetReportsFastReader };
	warn $@ if $@;
    }
}

use File::Basename qw(basename dirname);
use File::Copy qw(move);
use Hash::Util qw(lock_keys);
use Tk;
use Tk::Balloon;
use Tk::More;
use Tk::ErrorDialog;
use CPAN::Version ();
use Getopt::Long;
use POSIX qw(strftime);

sub sort_by_example ($@);

use constant USE_BETA_MATRIX => 0;

my @current_beforemaintrelease_pairs = (
					'5.24.0:5.25.10',
					'5.24.1:5.25.11',
 					'5.24.0:5.24.1',
 					'5.22.2:5.22.3',
				       );

# Patterns for report analysis
my $v_version_qr = qr{v[\d\.]+};
my $at_source_without_dot_qr = qr{at (?:\(eval \d+\)|\S+) line \d+(?:, <[^>]+> line \d+)?};
my $at_source_qr = qr{$at_source_without_dot_qr\.};

my $the_ct_states_rx = qr{(?:pass|unknown|na|fail)};

my $c_ext_qr = qr{\.(?:h|c|hh|cc|xs|cpp|hpp|cxx)};

my @common_analysis_button_config =
    (
     -padx => 0,
     -pady => 0,
     -borderwidth => 1,
     -relief => 'raised',
    );

my $only_good;
my $auto_good = 1;
my $only_pass_is_good;
my $auto_good_file;
my $confirmed_failure_file;
my $sort_by_date;
my $reversed;
my $geometry;
my $quit_at_end = 1;
my $do_xterm_title = 1;
my $show_recent_states = 1;
my $use_recent_states_cache = 0;
my $recent_months = 1;
my $do_check_screensaver = 1;
my $do_scenario_buttons;
my @annotate_files;
my $show_only;
my $fast_forward;
GetOptions("good" => \$only_good,
	   "auto-good!" => \$auto_good,
	   "only-pass-is-good" => \$only_pass_is_good,
	   'auto-good-file=s' => \$auto_good_file,
	   'confirmed-failure-file=s' => \$confirmed_failure_file,
	   "sort=s" => sub {
	       if ($_[1] eq 'date') {
		   $sort_by_date = 1;
	       } else {
		   die "-sort only takes the date value currently";
	       }
	   },
	   "r" => \$reversed,
	   "geometry=s" => \$geometry,
	   "quit-at-end!" => \$quit_at_end,
	   "xterm-title!" => \$do_xterm_title,
	   "recent-states!" => \$show_recent_states,
	   "recent-states-cache!" => \$use_recent_states_cache,
	   "recent-months=s" => \$recent_months,
	   "check-screensaver!" => \$do_check_screensaver,
	   "scenario-buttons!" => \$do_scenario_buttons,
	   'annotate-file=s@' => \@annotate_files,
	   'show-only' => \$show_only,
	   'fast-forward' => \$fast_forward,
	  )
    or die <<EOF;
usage: $0 [-good] [-[no]auto-good] [-sort date] [-r] [-geometry x11geom]
          [-noquit-at-end] [-[no]xterm-title]
          [-[no]recent-states] [-[no]check-screesaver] [-show-only] [directory [file ...]]
EOF

my $reportdir = shift || "$ENV{HOME}/var/cpansmoker";

return 1 if caller(); # for modulino-style testing

my($distvname2annotation, $distname2annotation, $rtticket_to_title);
if (@annotate_files) {
    ($distvname2annotation, $distname2annotation) = read_annotate_txt(@annotate_files);
    $rtticket_to_title = read_rt_information();
}

if ($auto_good) {
    # just to check if X11::Protocol etc. is available
    is_user_at_computer();
}

if ($do_xterm_title) {
    check_term_title();
}

my $new_directory = "$reportdir/new";

my @files = @ARGV;
if (@files == 1 && -d $files[0]) {
    $reportdir = $files[0];
    @files = ();
}
if (!@files) {
    @files = glob("$new_directory/*.rpt");
}
if (!@files) {
    my $msg = "No files given or found";
    set_term_title("report sender: $msg");
    die "$msg.\n";
}

my $good_directory = "$reportdir/sync";
if (!-d $good_directory) {
    mkdir $good_directory or die "While creating $good_directory: $!";
}
my $invalid_directory = "$reportdir/invalid";
if (!-d $invalid_directory) {
    mkdir $invalid_directory or die "While creating $invalid_directory: $!";
}
my $undecided_directory = "$reportdir/undecided";
if (!-d $undecided_directory) {
    mkdir $undecided_directory or die "While creating $undecided_directory: $!";
}
my $done_directory = "$reportdir/done";
my @recent_done_directories; # sorted newest to oldest
if (-d $done_directory) {
    my $add_done_directory = sub {
	my $month = shift;
	my $check_directory = "$done_directory/$month";
	push @recent_done_directories, $check_directory
	    if -d $check_directory;
    };

    my @l = localtime;
    $l[3] = 1; # things don't work if today's day is the 31th
    my $this_month = strftime "%Y-%m", @l;
    $add_done_directory->($this_month);

    if ($recent_months eq 'all') {
	@recent_done_directories = sort { $b cmp $a } glob("$done_directory/2[0-9][0-9][0-9]-[012][0-9]");
    } elsif ($recent_months =~ m{^\d+$}) {
	for (1..$recent_months) {
	    $l[4]--;
	    if ($l[4] < 0) { $l[4] = 11; $l[5]-- }
	    my $month = strftime "%Y-%m", @l;
	    $add_done_directory->($month);
	}
    } else {
	die "Argument to --recent-months must be either an integer or 'all'\n";
    }
}

my $good_rx = $only_pass_is_good ? qr{/(pass)\.} : qr{/(pass|unknown|na)\.};
my $maybe_good_rx = $only_pass_is_good ? qr{/(unknown|na)\.} : undef;

my $auto_good_rx;
my $confirmed_failure_rx;
if ($auto_good_file) {
    $auto_good_rx = read_auto_good_file($auto_good_file);
    #if ($auto_good_rx) { warn "DEBUG: auto_good_rx=$auto_good_rx\n" }
} elsif ($confirmed_failure_file) {
    $confirmed_failure_rx = read_auto_good_file($confirmed_failure_file);
}

my @new_files;
# "pass" is always good
# "na" and "unknown" is good if --only-pass-is-good given
# exception: 'notests' and 'low perl' are also considered as 'good'
for my $file (@files) {
    my $is_good;
    if ($file =~ $good_rx) {
	$is_good = 1;
    } elsif ($auto_good_rx && $file =~ $auto_good_rx) {
	warn "INFO: $file matches entry in auto good file\n";
	$is_good = 1;
    } elsif (defined $maybe_good_rx && $file =~ $maybe_good_rx) {
	my $ret = parse_test_report($file);
	if (!$ret->{error}) {
	    if (
		   $ret->{analysis_tags}{'notests'}
		|| $ret->{analysis_tags}{'low perl'}
		# || $ret->{analysis_tags}{'os unsupported (incompatible os)'}) { # XXX only prepared
	       ) {
		$is_good = 1;
	    }
	}
    } elsif ( # List of distributions which are OK to be accepted without review
	      # Never include fail.Devel-Fail-MakeTest here --- this is a proxy (just for SREZIC) to signal that a new smoker perl is ready
	        $file =~ m{\Q/fail.CPAN-Test-Dummy-Perl5-Build-Fails-\E\d} # just testing the new functionality
	     || $file =~ m{\Q/fail.Bio-Roary-3.} # frequent releases, never passes - https://rt.cpan.org/Ticket/Display.html?id=104843
	    ) {
	$is_good = 1;
    }

    if ($is_good) {
	move $file, $good_directory
	    or die "Cannot move $file to $good_directory: $!";
    } else {
	push @new_files, $file;
    }
}
@files = @new_files;
if (!@files) {
    my $msg = "No file needs to be checked manually";
    warn "$msg, finishing.\n";
    set_term_title("report sender: $msg");
    exit;
}
if ($auto_good) {
    if (!is_user_at_computer()) {
	my $msg = scalar(@files) . " distribution(s) with FAILs (inactive user)";
	warn "Skipping $msg.\n";
	set_term_title("report sender: $msg");
	exit 1;
    }
} elsif ($only_good) {
    my $msg = scalar(@files) . " distribution(s) with FAILs";
    warn "Skipping $msg.\n";
    set_term_title("report sender: $msg");
    exit 1;
}

if ($sort_by_date) {
    @files =
	map {
	    $_->[1]
	} sort {
	    $a->[0] <=> $b->[0]
	} map {
	    my @s = stat $_;
	    [$s[9], $_]
	} @files;
}
if ($reversed) {
    @files = reverse @files;
}

set_term_title("report sender: interactive mode");

my %images;
my $mw = tkinit;
$mw->geometry($geometry) if $geometry;
if ($fast_forward) {
    $mw->iconify;
}
my $balloon = $mw->Balloon;

my $currfile_i = 0;
my $currfile_st = '';
my $currfile;
my($currdist, $currversion);
my $modtime;
my $following_dists_text;

my $prev_b;
my $next_b;
my $good_b;
my $more = $mw->Scrolled("More")->pack(-fill => "both", -expand => 1);
{
    my $f = $mw->Frame->pack(-fill => "x");
    $f->Label(-text => "Report created:")->pack(-side => "left");
    $f->Label(-textvariable => \$modtime)->pack(-side => "left");
    $f->Label(-textvariable => \$following_dists_text)->pack(-side => "left");

    $f->Label(-text => "/ " . scalar(@files))->pack(-side => "right");
    $f->Label(-textvariable => \$currfile_st)->pack(-side => "right");
}
my $analysis_frame = $mw->Frame->place(-relx => 1, -rely => 0, -x => -2, -y => 2, -anchor => 'ne');
{
    _create_images();

    my $f = $mw->Frame->pack(-fill => "x");
    $prev_b = $f->Button(-text => "Prev (F4)",
	       -command => sub {
		   if ($currfile_i > 0) {
		       $currfile_i--;
		       set_currfile();
		   } else {
		       die "No files before!";
		   }
	       })->pack(-side => "left");
    if (!$show_only) {
	$good_b = $f->Button(-text => "GOOD (C-g)",
			     -command => sub {
				 move $currfile, $good_directory
				     or die "Cannot move $currfile to $good_directory: $!";
				 nextfile();
			     }
			    )->pack(-side => "left");
	$f->Button(-text => "INVALID",
		   -command => sub {
		       move $currfile, $invalid_directory
			   or die "Cannot move $currfile to $invalid_directory: $!";
		       nextfile();
		   }
		  )->pack(-side => "left");
	$f->Button(-text => "UNDECIDED",
		   -command => sub {
		       move $currfile, $undecided_directory
			   or die "Cannot move $currfile to $undecided_directory: $!";
		       nextfile();
		   }
		  )->pack(-side => "left");
    }
       
    $next_b = $f->Button(-text => "Next (F5)",
	       -command => sub { nextfile() },
	      )->pack(-side => "left");

    $f->Label(-width => 2)->pack(-side => "left"); # Spacer

    {
	my $rt_b =
	    $f->Button(-text => 'RT',
		       -image => $images{rt},
		       -width => 24,
		       -command => sub {
			   require Tk::Pod::WWWBrowser;
			   Tk::Pod::WWWBrowser::start_browser("http://rt.cpan.org/Public/Dist/Display.html?" . make_query_string(Name=>$currdist));
		       })->pack(-side => 'left', -fill => 'y');
	$balloon->attach($rt_b, -msg => 'RT @ CPAN');
    }
    {
	my $matrix_b =
	    $f->Button(-text => 'Matrix',
		       -image => $images{matrix},
		       -width => 24,
		       -command => sub {
			   require Tk::Pod::WWWBrowser;
			   Tk::Pod::WWWBrowser::start_browser("http://" . (USE_BETA_MATRIX ? 'beta-' : '') . "matrix.cpantesters.org/?" . make_query_string(dist=>$currdist));
		       })->pack(-side => 'left', -fill => 'y');
	$balloon->attach($matrix_b, -msg => 'Matrix');
    }
    {
	my $mc_b =
	    $f->Button(-text => 'MetaCPAN',
		       -image => $images{metacpan},
		       -width => 24,
		       -command => sub {
			   require Tk::Pod::WWWBrowser;
			   Tk::Pod::WWWBrowser::start_browser("http://www.metacpan.org/release/$currdist");
		       })->pack(-side => 'left', -fill => 'y');
	$balloon->attach($mc_b, -msg => 'MetaCPAN');
    }
    # XXX should this be enabled by option? what about the directory?
    {
	my $cached_analysis_dir = "/tmp/cached-analysis";
	if (-d $cached_analysis_dir) {
	    $f->Button(-text => 'local analysis',
		       -command => sub {
			   my $cached_analysis_file = "$cached_analysis_dir/$currdist-$currversion.analysis";
			   if (-e $cached_analysis_file) {
			       my $t = $mw->Toplevel(-title => "Local analysis on $currdist $currversion");
			       my $txt = $t->Scrolled('More', -scrollbars => 'ose')->pack(-fill => 'both', -expand => 1);
			       $txt->Load($cached_analysis_file);
			   } else {
			       $mw->messageBox(-message => 'No cached analysis available');
			   }
		       })->pack(-side => 'left');
	}
    }
    if (0) { # XXX never used these buttons...
	$f->Button(-text => "ctgetreports",
		   -command => sub {
		       require Tk::ExecuteCommand;
		       require File::Temp;
		       my($tmpfh, $tempfile) = File::Temp::tempfile(UNLINK => 1, SUFFIX => "_report.txt");
		       my $t = $mw->Toplevel(-title => "Reports on $currdist $currversion");
		       my $ec = $t->ExecuteCommand()->pack;
		       $ec->configure(-command => "ctgetreports $currdist --ctformat=yaml --dumpvars=. --dumpfile=$tempfile");
		       $ec->execute_command;
		       $ec->bell;
		       $ec->destroy;
		       $t->update;
		       my $m = $t->Scrolled("More", -scrollbars => "osoe")->pack(qw(-fill both -expand 1));
		       $t->update;
		       $m->Load($tempfile);
		       $m->Subwidget("scrolled")->focus;
		   })->pack(-side => "left");
	$f->Button(-text => "solve",
		   -command => sub {
		       require Tk::ExecuteCommand;
		       require File::Temp;
		       my($tmpfh, $tempfile) = File::Temp::tempfile(UNLINK => 1, SUFFIX => "_report.txt");
		       my $t = $mw->Toplevel(-title => "Solve $currdist $currversion");
		       my $ec = $t->ExecuteCommand()->pack(qw(-fill both -expand 1));
		       $ec->configure(-command => "ctgetreports $currdist --ctformat=yaml --solve --dumpfile=$tempfile");
		       $ec->execute_command;
		       $ec->bell;
		       $ec->focus;
		   })->pack(-side => "left");
    }
    {
	my $ff = $f->Frame->pack(qw(-side left));
	my $smallfont = 'helvetica 5';
	$ff->Button(-text => 'fname->sel',
		    -pady => 0, -borderwidth => 0,
		    -font => $smallfont,
		    -command => sub {
			$mw->SelectionOwn;
			$mw->SelectionHandle; # calling this mysteriously solves the closure problem...
			$mw->SelectionHandle(sub { return basename $currfile });
		    })->pack;
	$ff->Button(-text => 'short',
		    -pady => 0, -borderwidth => 0,
		    -font => $smallfont,
		    -command => sub {
			$mw->SelectionOwn;
			$mw->SelectionHandle; # calling this mysteriously solves the closure problem...
			$mw->SelectionHandle(sub {
						 my $text = basename $currfile;
						 $text =~ s{(?:amd64-freebsd|x86_64-linux).*}{};
						 $text = q{"} . $text . qq{\n};
						 return $text;
					     });
		    })->pack;
    }
}

set_currfile();

$mw->bind("<Control-q>" => sub { $mw->destroy });
$mw->bind("<Control-g>" => sub { $good_b->invoke }) if $good_b;
$mw->bind("<F4>" => sub { $prev_b->invoke });
$mw->bind("<F5>" => sub { $next_b->invoke });

if ($auto_good) {
    $mw->repeat(2*1000, sub {
		    if (!is_user_at_computer()) {
			warn "User not anymore at computer, quitting...\n";
			$mw->destroy;
		    }
		})
}

#$mw->FullScreen; # does not work (with fvwm2 only?)
#$mw->attributes(-fullscreen => 1); # does not work (with fvwm2 only?)
MainLoop;

set_term_title("report sender: finished");

sub parse_test_report {
    my($file) = @_;

    my $subject;
    my $x_test_reporter_perl;
    my $x_test_reporter_distfile;
    my $currfulldist;
    my $currarchname;
    my %analysis_tags;
    my %prereq_fails;
    my %prereq_versions;

    my $fh;
    if (!open($fh, $file)) {
	return { error => $! };
    }

    # Parse header
    while(<$fh>) {
	s/\r//; # for windows reports
	if (/^Subject:\s*(.*)/) {
	    $subject = $1;
	    if (/^Subject:\s*(?:FAIL|PASS|UNKNOWN|NA) (\S+) (\S+)/) {
		$currfulldist = $1;
		$currarchname = $2;
	    } else {
		warn "Cannot parse distribution out of '$subject'";
	    }
	} elsif (/^X-Test-Reporter-Perl:\s*(.*)/i) {
	    $x_test_reporter_perl = $1;
	} elsif (/^X-Test-Reporter-Distfile:\s*(.*)/i) {
	    $x_test_reporter_distfile = $1;
	} elsif (/^$/) {
	    last;
	}
    }

    # Parse body
    {
	my $section = '';
	my $subsection = '';

	my $program_output = {}; # collects only one line in PROGRAM OUTPUT

	my $add_analysis_tag = sub {
	    my($tag, $line) = @_;
	    if (!defined $line) { $line = $. }
	    push @{ $analysis_tags{$tag}->{lines} }, $line;
	};

	my $maybe_system_perl; # can be decided later; contains failed line or zero
	my $maybe_pod_coverage_test; # will be decided later; contains failed line or zero
	my $maybe_harness_killed;
	my %signalled; # test script -> signal
	my %testfile_to_linenumber;

	while(<$fh>) {
	    s{\r$}{}; # for Windows reports
	    if (/^PROGRAM OUTPUT$/) {
		$section = 'PROGRAM OUTPUT';
		$subsection = '';
	    } elsif (/^PREREQUISITES$/) {
		if ($section eq 'PROGRAM OUTPUT' && defined $program_output->{content}) {
		    if (
			$program_output->{content} =~ /No tests defined for \S+ extension\.$/ || # EUMM version
			$program_output->{content} =~ /No tests defined\.$/                      # MB version
		       ) {
			$add_analysis_tag->('notests', $program_output->{line});
		    }
		}
		$section = 'PREREQUISITES';
		$subsection = '';
	    } elsif (/^ENVIRONMENT AND OTHER CONTEXT$/) {
		$section = 'ENVIRONMENT';
		$subsection = '';
	    } elsif ($section eq 'PROGRAM OUTPUT') {
		if (/^Test Summary Report$/) {
		    $subsection = 'Test Summary Report';
		} elsif (
			 /^Warning: Perl version \S+ or higher required\. We run \S+\.$/ ||
			 /^\s*!\s*perl \([\d\.]+\) is installed, but we need version >= v?[\d\._]+$/ ||
			 /^ERROR: perl: Version [\d\.]+ is installed, but we need version >= [\d\.]+ $at_source_qr$/ ||
			 /^(?:\s*#\s+Error:\s+)?Perl $v_version_qr required--this is only $v_version_qr, stopped $at_source_qr$/ ||
			 /Installing \S+ requires Perl >= [\d\.]+ $at_source_qr/ # seen in TOBYINK dists
			) {
		    $add_analysis_tag->('low perl');
		} elsif (
			 /^Result: NOTESTS$/
			 ## Rely solely on the above regexp --- the below may happen because a sub-module has no tests
			 ## but see $program_output logic before PREREQUISITES section
			 # || /^No tests defined for \S+ extension\.$/
			 # || /^No tests defined\.$/
			) {
		    $add_analysis_tag->('notests');
		} elsif (
			 /^OS unsupported$/ ||
			 /^OS unsupported. This is only for .+$/ ||
			 /^OS unsupported. This module only works .+$/ ||
			 /^OS unsupported $at_source_qr$/ ||
			 /^No support for OS$/ ||
			 /^No support for OS at /
			) {
		    if (
			($currfulldist =~ m{win32}i   && $currarchname !~ m{mswin32}i       ) ||
			($currfulldist =~ m{linux}i   && $currarchname !~ m{linux}i         ) ||
			($currfulldist =~ m{(\bmac|cocoa)}i && $currarchname !~ m{(darwin|macos)}i) ||
			($currfulldist =~ m{freebsd}i && $currarchname !~ m{freebsd}i       )
		       ) {
			$add_analysis_tag->('os unsupported (incompatible os)');
		    } else {
			$add_analysis_tag->('os unsupported');
		    }
		} elsif (
			 /^(?:#\s+Error:\s+)?(?:Smartmatch|given|when) is experimental $at_source_qr$/
			) {
		    $add_analysis_tag->('smartmatch');
		} elsif (
			 /^(?:#\s+Error:\s+)?(?:push|pop|keys|shift|unshift|splice) on reference is experimental $at_source_qr$/
			) {
		    $add_analysis_tag->('experimental functions on references');
		} elsif (
			 /^(?:#\s+Error:\s+)?Experimental (?:push|keys|values|splice|each) on scalar is now forbidden $at_source_without_dot_qr(?:\.$|, near)/
			) {
		    $add_analysis_tag->('experimental functions on references are forbidden');
		} elsif ( # should be before pod coverage and maybe pod tests
			 /Unrecognized character .* at \._\S+ line \d+\./ ||
			 /^#\s+Failed test 'Pod coverage on [A-Za-z0-9:_]*?\._[A-Za-z0-9:_]+'/
			) {
		    $add_analysis_tag->('hidden MacOSX file');
		} elsif (
			 /^#\s+Failed test 'POD test for [^']+'$/
			) {
		    $add_analysis_tag->('pod test');
		} elsif (
			 /^#\s+Coverage for \S+ is [\d\.]+%, with \d+ naked subroutines?:$/
			) {
		    $add_analysis_tag->('pod coverage test');
		} elsif (
			 /^#\s+Failed test 'Pod coverage on [^']+'$/
			) {
		    # Remember for later, maybe the module does not
		    # compile at all
		    $maybe_pod_coverage_test = $.;
		} elsif (
			 /^#\s+(.*?):\s+requiring\s+'\1' failed/
			) {
		    if ($maybe_pod_coverage_test) {
			undef $maybe_pod_coverage_test;
		    }
		    $add_analysis_tag->('module compilation fails');
		} elsif (
			 /^#\s+Failed test 'POD spelling for [^']+'$/
			) {
		    $add_analysis_tag->('pod spelling test');
		} elsif (
			 /^#\s+Failed test 'has_human_readable_license'/ ||
			 /^#\s+Failed test 'has_license_in_source_file'/ ||
			 /^#\s+Failed test 'metayml_is_parsable'/
			) {
		    $add_analysis_tag->('kwalitee test');
		} elsif (
			 /\QFailed test 'Found some modules that didn't show up in PREREQ_PM or *_REQUIRES/
			) {
		    $add_analysis_tag->('prereq test');
		} elsif (   # this should come before 'prereq fail' tests, see below for more 'possibly old bundled modules' stuff
			 m{\QCan't locate MooX/Struct.pm in \E\@INC (?:\Q(you may need to install the MooX::Struct module) \E)?\(\@INC contains: .* inc .* at \S+/Module/Install/Admin/Copyright.pm}
			) {
		    $add_analysis_tag->('possibly old bundled modules');
		} elsif (   # this should come before the generic 'prereq fail' test
			    m{^(?:#\s+Error:\s+)?Can't locate \S+ in \@INC .*\(\@INC contains.* /etc/perl} # Debian version
			 || m{^\s*or make that module available in \@INC \(\@INC contains.* /etc/perl} # base class error, Debian version
			 || m{^(?:#\s+Error:\s+)?Can't locate \S+ in \@INC .*\(\@INC contains.* /usr/lib64/perl5/vendor_perl} # CentOS/RedHat/Fedora version
			 || m{^(?:#\s+Error:\s+)?Can't locate \S+ in \@INC .*\(\@INC contains.* /usr/local/lib/perl5/5.\d+/BSDPAN} # FreeBSD version, old
			 || m{^(?:#\s+Error:\s+)?Can't locate \S+ in \@INC .*\(\@INC contains.* /usr/local/lib/perl5/site_perl/mach/} # FreeBSD version, new
			 || m{^(?:#\s+Error:\s+)?Can't locate \S+ in \@INC .*\(\@INC contains.* /usr/local/lib/perl5/5.\d+/mach} # FreeBSD version, even newer
			 || m{Undefined symbol ".*" at /usr/local/lib/perl5/5.\d+/mach/}, # wrong linking, FreeBSD version, new
			) {
		    if (!defined $maybe_system_perl) {
			$maybe_system_perl = $.; # decide later, remember line number
		    }
		} elsif (
			 /^(?:#\s+Error:\s+)?Can't locate (\S+) in \@INC/
			) {
		    (my $prereq_fail = $1) =~ s{\.pm$}{};
		    $prereq_fail =~ s{/}{::}g;
		    $prereq_fails{$prereq_fail} = 1;
		    $add_analysis_tag->('prereq fail');
		} elsif (
			 /unable to load template engine '.*?' \(perhaps you need to install ([^?]+)\?\)/ # Dancer templates
			) {
		    $prereq_fails{$1} = 1;
		    $add_analysis_tag->('prereq fail');
		} elsif (
			 /^(?:#\s+Error:\s+)?Base class package "(.*?)" is empty\.$/
			) {
		    $prereq_fails{$1} = 1;
		    $add_analysis_tag->('prereq fail');
		} elsif (
			 /Type of arg \d+ to (?:keys|each) must be hash(?: or array)? \(not (?:hash element|private (?:variable|array)|subroutine entry)\)/ ||
			 /Type of arg \d+ to (?:push|unshift) must be array \(not (?:array|hash) element\)/ ||
			 /Type of arg \d+ to (?:splice) must be array \(not null operation\)/
			) {
		    $add_analysis_tag->('container func on ref');
		} elsif (
			 /(?<!skipped: )This Perl not built to support threads/
			) {
		    $add_analysis_tag->('unthreaded perl');
		} elsif (
			 /error: .*?\.h: No such file or directory/ ||
			 /error: .*?\.h: Datei oder Verzeichnis nicht gefunden/ ||
			 /^.*?$c_ext_qr:\d+:\d+:\s+fatal error:\s+'.*?\.h' file not found/ ||
			 /^.*?$c_ext_qr:\d+:\d+:\s+schwerwiegender Fehler:\s+.*?\.h: Datei oder Verzeichnis nicht gefunden/ || # localized (seen on CentOS7)
			 /^".*?$c_ext_qr", line \d+: cannot find include file: [<"].*\.h[">]/ # solaris cc
			) {
		    $add_analysis_tag->('missing c include');
		} elsif (
			 /gcc: not found/ ||
			 /gcc: Kommando nicht gefunden/ ||
			 /\Qmake: exec(gcc) failed (No such file or directory)/
			) {
		    $add_analysis_tag->('gcc not found');
		} elsif ($currarchname =~ m{freebsd} && /g\+\+: not found/) { # XXX actually should also check for osvers>=10
		    $add_analysis_tag->('clang++ vs. g++');
		} elsif (
			 /^.*?$c_ext_qr:\d+:\s+error:\s+/     || # gcc
			 /^.*?$c_ext_qr:\d+:\d+:\s+error:\s+/ || # gcc or clang
			 /^.*?$c_ext_qr:\d+:\d+:\s+Fehler:\s+/ || # localized (seen on CentOS7)
			 /^cc: acomp failed for .*\.c/           # solaris cc, unspecific
			) {
		    $add_analysis_tag->('c compile error');
		} elsif (
			 /^".*?$c_ext_qr", line \d+: (.*)/ # solaris cc, specific line
			) {
		    my $rest = $1;
		    if ($rest =~ m{^warning:}) {
			# ignore warnings
		    } else {
			$add_analysis_tag->('c compile error');
		    }
		} elsif (
			 /cc1: error: unrecognized command line option / || # gcc
			 /cc: error: unknown argument: / # clang
			) {
		    $add_analysis_tag->('other c compiler error');
		} elsif (
			 m{^/usr/include/c\+\+/[^:]+:\d+:\d+: fatal error: } # g++
			) {
		    $add_analysis_tag->('c++ compile error');
		} elsif (
			 /^\s*(#\s+Error:\s+)?Can't load '.*?\.so' for module .*: Undefined symbol ".*?" $at_source_qr/ || # freebsd variant
			 /^\s*(#\s+Error:\s+)?Can't load '.*?\.so' for module .*: .*?\.so: undefined symbol: \S+ $at_source_qr/ || # linux variant
			 /^\s*(#\s+Error:\s+)?Can't load '.*?\.so' for module .*: .*?\.so(?:\.\d+)?: perl: fatal: relocation error: .*: referenced symbol not found $at_source_qr/ # solaris variant
			) {
		    $add_analysis_tag->('undefined symbol in shared lib');
		} elsif (
			 /^collect2: error: ld returned 1 exit status/ ||
			 m{^/usr/bin/ld: [^:]+: relocation R_X86_64_32 against `a local symbol' can not be used when making a shared object; recompile with -fPIC} ||
			 /^.*\.a\(.*\.o\):.*: undefined reference to `.*'/ # g++/windows/strawberry perl
			) {
		    $add_analysis_tag->('linker error');
		} elsif (
			 /Out of memory!/ ||
			 /out of memory allocating \d+ bytes after a total of \d+ bytes/ # gcc
			) {
		    $add_analysis_tag->('out of memory');
		} elsif (
			 m{^ERROR: Can't create '.*/Alien} ||
			 m{^/bin/mkdir: kann Verzeichnis .*/auto/share/dist/Alien.* nicht anlegen: Keine Berechtigung}
			) {
		    $add_analysis_tag->('premature alien install');
		} elsif (
			 /^# Perl::Critic found these violations in .*:$/ ||
			 /^#\s+Failed test 'Test::Perl::Critic for [^']+'$/
			) {
		    $add_analysis_tag->('perl critic');
		} elsif ( # note: these checks have to happen before the 'qw without parentheses' check
			 /^Test::Builder::Module version [\d\.]+ required--this is only version [\d\.]+ $at_source_qr$/ ||
			 /^Test::Builder version [\d\.]+ required--this is only version [\d\.]+ $at_source_qr$/ ||
			 m{^\Q# Error: This distribution uses an old version of Module::Install. Versions of Module::Install prior to 0.89 does not detect correcty that CPAN/CPANPLUS shell is used.\E$} ||
			 m{\QError:  Scalar::Util version 1.24 required--this is only version 1.\E\d+\Q at } ||
			 m{\Qsyntax error at inc/Devel/CheckLib.pm line \E\d+\Q, near "\E.\Qmm_attr_key qw(LIBS INC)"} ||
			 m{\Qsyntax error at inc/Module/Install/XSUtil.pm line \E\d+\Q, near "\E.\Qchecklib qw(inc::Devel::CheckLib Devel::CheckLib)"} ||
			 m{\QUndefined subroutine &Scalar::Util::set_prototype called at } ||
			 m{\QCan't locate YAML/Base.pm in @INC (@INC contains: \E.*\Q/inc/YAML.pm line \E\d+} ||
			 m{\QCan't locate YAML/Base.pm in @INC (you may need to install the YAML::Base module) (@INC contains: \E.*\Q/inc/YAML.pm line \E\d+} ||
			 m{\QRegexp modifiers "/a" and "/d" are mutually exclusive at inc/Module/Install/AutoInstall.pm} ||
			 m{\QBEGIN failed--compilation aborted at inc/Module/Install/Makefile.pm line \Q\d+\.} ||
			 m{\QRedundant argument in sprintf at inc/Spiffy.pm line 225.}
			) {
		    $add_analysis_tag->('possibly old bundled modules');
		} elsif (
			 /syntax error.*\bnear "\$\w+ qw\(/ ||
			 /syntax error.*\bnear "\$\w+ qw\// ||
			 /syntax error.*\bnear "->\w+ qw\(/ ||
			 /syntax error.*\bnear "->\w+ qw\// ||
			 /\QUse of qw(...) as parentheses is deprecated\E $at_source_qr/
			) {
		    $add_analysis_tag->('qw without parentheses');
		} elsif (
			 m{Bareword found where operator expected $at_source_without_dot_qr, near "s/.*/r"$}
			) {
		    $add_analysis_tag->('r flag in s///');
		} elsif (
			    m{==> MISMATCHED content between \S+ and distribution files! <==}
			 || m{==> BAD/TAMPERED signature detected! <==}
			) {
		    $add_analysis_tag->('signature mismatch');
		} elsif (
			 /^Attribute \(.+?\) does not pass the type constraint because: .* $at_source_without_dot_qr$/ || # Validation failed for '.+?' with value or ... is too long
			 /^Attribute \(.+?\) is required $at_source_without_dot_qr$/
			) {
		    $add_analysis_tag->('type constraint violation');
		} elsif (
			 /^(?:# died: )?Insecure .+? while running with -T switch $at_source_qr$/
			) {
		    $add_analysis_tag->('taint');
		} elsif (
			 /\Q# Error: The META.yml file of this distribution could not be parsed by the version of CPAN::Meta::YAML.pm CPANTS is using./
			) {
		    $add_analysis_tag->('meta.yml spec');
		} elsif (
			 /^\s*#\s+Failed test '.*'$/ ||
			 /^\s*#\s+Failed test at .* line \d+\.$/ ||
			 /^\s*#\s+Failed test \(.*\)$/ ||
			 /^\s*#\s+Failed test \d+ in .* at line \d+$/ ||
			 m{^Failed\s+\d+/\d+\s+subtests\s*$} ||
			 /^# Looks like your test exited with \d+ just after / ||
			 /^Dubious, test returned \d+ \(wstat \d+, 0x[0-9a-f]+\)/
			) {
		    $add_analysis_tag->('__GENERIC_TEST_FAILURE__'); # lower prio than other failures, special handling needed
		} elsif (
			 /\S+ uses NEXT, which is deprecated. Please see the Class::C3::Adopt::NEXT documentation for details. NEXT used\s+$at_source_qr/
			) {
		    $add_analysis_tag->('deprecation (NEXT)');
		} elsif (
			 /Class::MOP::load_class is deprecated/
			) {
		    $add_analysis_tag->('deprecation (Class::MOP)');
		} elsif (
			 /Passing a list of values to enum is deprecated. Enum values should be wrapped in an arrayref. $at_source_qr/
			) {
		    $add_analysis_tag->('deprecation (Moose)');
		} elsif (
			 /DBD::SQLite::st execute failed: database is locked/ ||
			 /DBD::SQLite::db do failed: database is locked \[for Statement "/
			) {
		    $add_analysis_tag->('locking issue (File::Temp?)');
		} elsif (
			 /Perl lib version \(.*?\) doesn't match executable '.*?' version (.*?) $at_source_qr/
			) {
		    $add_analysis_tag->('perl version mismatch (lib)');
		} elsif (
			 /Can't connect to \S+ \((Invalid argument|Bad hostname)\) $at_source_qr/
			) {
		    $add_analysis_tag->('remote connection problem');
		} elsif (
			 /^Files=\d+, Tests=\d+, (\d+) wallclock secs /
			) {
		    if ($1 >= 1800) {
			$add_analysis_tag->('very long runtime (>= 30 min)');
		    } elsif ($1 >= 900) {
			$add_analysis_tag->('long runtime (>= 15 min)');
		    }
		} elsif (
			 /Cannot detect source of '.*?'! $at_source_qr/
			) {
		    $add_analysis_tag->('very long runtime (.t removed)');
		} elsif (
			 m{^Unknown regexp modifier "/[^"]+" at }
			) {
		    $add_analysis_tag->('unknown regexp modifier');
		} elsif (
			 m{\QSequence (?^...) not recognized in regex;} ||
			 m{\QSequence (?&...) not recognized in regex;} ||
			 m{\QSequence (?<\E[a-zA-Z]\Q...) not recognized in regex;} # capture groups
			) {
		    $add_analysis_tag->('new regexp feature');
		} elsif (
			 m{\QUnescaped left brace in regex is deprecated} ||
			 m{\QUnescaped left brace in regex is illegal}
			) {
		    $add_analysis_tag->('new regexp deprecation');
		} elsif (
			 m{# +Error: +Feature bundle ".*" is not supported by Perl .*$at_source_qr}
			) {
		    $add_analysis_tag->('perl too old for feature');
		} elsif (
			 m{\Q(Might be a runaway multi-line // string starting on line \E\d+} ||
			 m{\QSearch pattern not terminated \E$at_source_qr} ||
			 m{syntax error $at_source_without_dot_qr, near "// }
			) {
		    $add_analysis_tag->('defined-or');
		} elsif (
			 m{\QCan't use 'defined(%\E\S+\Q)' (Maybe you should just omit the defined()?) \E$at_source_qr}
			) {
		    $add_analysis_tag->('defined hash');
		} elsif (
			 m{\QCan't use 'defined(@\E\S+\Q)' (Maybe you should just omit the defined()?) \E$at_source_qr}
			) {
		    $add_analysis_tag->('defined array');
		} elsif (
			 m{Unrecognized character \\x[01][0-9A-F]; marked by .*\$<-- HERE near column \d+ $at_source_qr}
			) {
		    $add_analysis_tag->('literal control char');
		} elsif (
			 m<\Qsyntax error \E$at_source_without_dot_qr\Q, near "package \E.*\{>
			) {
		    $add_analysis_tag->('modern package declaration');
		} elsif (
			    m{^make: \*\*\* No targets specified and no makefile found\.  Stop\.$} # GNU makefile
		         || m{^make: \*\*\* Keine Targets angegeben und keine .*?make.*?-Steuerdatei gefunden\.  Schluss\.$} # GNU makefile, German
			) {
		    $add_analysis_tag->('makefile missing'); # probably due to Makefile.PL and Build.PL missing before
		} elsif (
			 m{^Execution of Build.PL aborted due to compilation errors\.$}
			) {
		    $add_analysis_tag->('compilation error in Build.PL');
		} elsif (
			 m{^String found where operator expected at \S+ line \d+, near "Carp::croak }
			) {
		    $add_analysis_tag->('possibly missing use Carp');
		} elsif (
			 m{\bDBD::SQLite::db do failed: database is locked $at_source_qr}
			) {
		    $add_analysis_tag->('possible file temp locking issue');
		} elsif (
			 m{UNIVERSAL does not export anything}
			) {
		    $add_analysis_tag->('UNIVERSAL export');
		} elsif (
			 m{\QCalling POSIX::tmpnam() is deprecated} ||
			 m{\QUnimplemented: POSIX::tmpnam()}
			) {
		    $add_analysis_tag->('POSIX::tmpnam');
		} elsif (
			 m{\QThe encoding pragma is no longer supported}
			) {
		    $add_analysis_tag->('encoding pragma');
		} elsif (
			 m{did you forget to declare "my } # since perl 5.21.4
			) {
		    $add_analysis_tag->('use strict error message');
		} elsif (
			 m{Can't locate object method "builder" via package "Test::Simple" at } ||
			 m{Undefined subroutine &Test2::Global::test2_stack called at }
			) {
		    $add_analysis_tag->('Test-Simple problem'); # probably a problem with beta Test-Simple
		} elsif (
			 m{/usr/bin/install: cannot create regular file `/opt/perl-.*': Permission denied} || # often seen in Alien modules
			 m{/bin/mkdir: cannot create directory `/opt/perl-.*': Permission denied} # also seen in Alien modules
			) {
		    $add_analysis_tag->('invalid install');
		} elsif (
			 m{\Qpanic: av_extend_guts() negative count} ||
			 m{\Qpanic: stack_grow() negative count}
			) {
		    $add_analysis_tag->('panic extend/stack_grow');
		} elsif (
			 m{^"Makefile", line \d+: Need an operator$} || # FreeBSD 9
			 m{^make(\[\d+\])?: ".*Makefile" line \d+: Need an operator$} # FreeBSD 10
			) {
		    $add_analysis_tag->('GNU make required');
		} elsif (
			 m{\QCan't use global \E\$_\Q in "my" }
			) {
		    $add_analysis_tag->('lexical $_');
		} elsif (
			 /^(?:#\s+Error:\s+)?Can't redeclare "my" in "my" $at_source_without_dot_qr(?:\.$|, near|, at end of line)/
			) {
		    $add_analysis_tag->('my in my redeclaration');
		} elsif (
			 m{needs to be recompiled against the newly installed PDL at}
			) {
		    $add_analysis_tag->('!!!recompile PDL module!!!');
		} elsif (
			 m{Error processing template: .*, message: file error - INCLUDE_PATH exceeds \d+ directories}
			) {
		    $add_analysis_tag->('@INC too big for TT2');
		} elsif (
			 m{^Undefined subroutine &\S+ called $at_source_qr}
			) {
		    # quite unspecific, more specific ones exist above
		    $add_analysis_tag->('undefined subroutine'); # previously called "possibly missing use/require", but this was often misleading
		} elsif (
			 m{^make(?:\[\d+\])?: don't know how to make .*\. Stop$} || # BSD make output
		         m{^\Qmake: *** No rule to make target \E.*\Q, needed by \E.*\Q.  } # GNU make output
			) {
		    $add_analysis_tag->('make problem (unhandled target)');
		} elsif (
			 m{^Makefile:\d+: recipe for target '(.*?)' failed$} && $1 !~ m{^(?:test|test_dynamic|all)$}
			) {
		    $add_analysis_tag->('make problem (failed target)');
		} elsif (
			 /^\QBailout called.  Further testing stopped:/
			) {
		    # rather unspecific, do as rather last check
		    $add_analysis_tag->('bailout');
		} elsif (
			 /^Killed$/
			) {
		    $maybe_harness_killed = 1;
		} elsif (
			 $maybe_harness_killed &&
			 /^\Qmake: *** [test_dynamic] Error 137/
			) {
		    $add_analysis_tag->('killed harness');
		} elsif (
			 /Fatal error: .*: No space left on device/ # from gcc
			 || /ERROR: .*: No space left on device/ # from EUMM
			 || /mkdir .*: No space left on device $at_source_qr/ # from EU::Command
			) {
		    $add_analysis_tag->('!!!no space left on device!!!');
		} elsif (
			 m{Could not execute .* open3: exec of .* failed: Argument list too long at .*TAP/Parser/Iterator/Process.pm}
			) {
		    $add_analysis_tag->('!!!cmdline limits exceeded!!!');
		} elsif (
			 $subsection eq 'Test Summary Report' &&
			 (my($testfile, $wstat) = $_ =~ m{^(t/\S+)\s+\(Wstat: (\d+)})
			) {
		    my $signal = $wstat & 0x7f;
		    if ($signal != 0) {
			$signalled{$testfile} = $signal;
		    }
		} else {
		    # collect PROGRAM OUTPUT string (maybe)
		    if (!$program_output->{skip_collector}) {
			if (/^-*$/) {
				# skip newlines and dashes
			} elsif (/^Output\s+from\s+'.*(?:make|Build)\s+test':/) {
				# skip
			} elsif (defined $program_output->{content}) {
				# collect just one line
			    $program_output->{skip_collector} = 1;
			} else {
			    $program_output->{content} .= $_;
			    $program_output->{line} = $. if !defined $program_output->{line};
			}
		    }
		}
		if (my($testfile) = $_ =~ m{^(t/\S+)}) {
		    if (!exists $testfile_to_linenumber{$testfile}) {
			$testfile_to_linenumber{$testfile} = $.;
		    }
		}
	    } elsif ($section eq 'PREREQUISITES') {
		if (my($perl_need, $perl_have) = $_ =~ /^\s*!\s*perl\s*(v?[\d\.]+)\s+(v?[\d\.]+)\s*$/) {
		    require version;
		    if (eval { version->new($perl_need) } > eval { version->new($perl_have) }) {
			$add_analysis_tag->('low perl');
		    }
		}
	    } elsif ($section eq 'ENVIRONMENT') {
		if (m{^\s+PERL5LIB = (.*)}) {
		    my $length_perl5lib = length $1;
		    if      ($length_perl5lib >= 128*1024) {
			$add_analysis_tag->("!!!very long PERL5LIB ($length_perl5lib bytes)!!!");
		    } elsif ($length_perl5lib >= 48*1024) {
			$add_analysis_tag->("long PERL5LIB ($length_perl5lib bytes)");
		    }
		}
		if ($maybe_system_perl) {
		    if (   m{config_args=.*/BSDPAN}   # FreeBSD version, old, with BSDPAN
			|| m{config_args=.*-Dsitearch=/usr/local/lib/perl5/site_perl/mach} # FreeBSD version, new, "mach"
			|| m{DEBPKG:debian/mod_paths} # Debian version
		       ) {
			$maybe_system_perl = 0;
		    }
		} elsif (m{^\s*(Test::More)\s+([\d._]+)}) {
		    $prereq_versions{$1} = $2;
		}
	    }
	}

	if ($maybe_system_perl) { # now we're sure
	    my $line_number = $maybe_system_perl;
	    $add_analysis_tag->('system perl used', $line_number);
	}
	if ($maybe_pod_coverage_test) {
	    my $line_number = $maybe_pod_coverage_test;
	    $add_analysis_tag->('pod coverage test', $line_number);
	}
	if (%signalled) {
	    while(my($testfile, $signal) = each %signalled) {
		if ($currarchname =~ m{(linux|freebsd)}) { # don't know for other OS
		    if    ($signal == 11) { $signal = 'SEGV' }
		    elsif ($signal == 6)  { $signal = 'ABRT' }
		    elsif ($signal == 8)  { $signal = 'FPE'  }
		    elsif ($signal == 9)  { $signal = 'KILL' }
		    elsif ($signal == 14) { $signal = 'ALRM' }
		    elsif ($signal == 13) { $signal = 'PIPE' }
		    elsif (($signal == 30 && $currarchname =~ m{freebsd}) ||
			   ($signal == 10 && $currarchname =~ m{linux})) { $signal = 'USR1' }
		    elsif (($signal == 10 && $currarchname =~ m{freebsd}) ||
			   ($signal ==  7 && $currarchname =~ m{linux})) { $signal = 'BUS' }
		    elsif ($signal == 4)  { $signal = 'ILL' }

		    my $line_number = $testfile_to_linenumber{$testfile};
		    if (!$line_number) {
			warn "Cannot find output of '$testfile' in 'PROGRAM OUTPUT' section...\n";
		    }
		    $add_analysis_tag->("signal $signal", $line_number);
		}
	    }
	}
    }

    my %ret =
	(
	 error                    => undef,
	 subject                  => $subject,
	 x_test_reporter_perl     => $x_test_reporter_perl,
	 x_test_reporter_distfile => $x_test_reporter_distfile,
	 currfulldist             => $currfulldist,
	 analysis_tags            => \%analysis_tags,
	 prereq_fails             => \%prereq_fails,
	 prereq_versions          => \%prereq_versions,
	);
    lock_keys %ret;
    return \%ret;
}

sub set_currfile {
    $currfile = $files[$currfile_i];
    $mw->title("Loading " . basename($currfile) . "...");
    $currfile_st = $currfile_i + 1;
    $_->destroy for $analysis_frame->children; # remove as early as possible
    $more->Load($currfile);
    my $textw = $more->Subwidget("scrolled");
    $textw->SearchText(-searchterm => qr{PROGRAM OUTPUT});
    $textw->yviewScroll(30, 'units'); # actually a hack, I would like to have PROGRAM OUTPUT at top

    my $parsed_report = parse_test_report($currfile);
    if ($parsed_report->{error}) {
	$mw->messageBox(-icon => 'error', -message => "Can't open $currfile: $parsed_report->{error}");
	warn "Can't open $currfile: $!";
	$modtime = "N/A";
	return;
    }

    my $subject = $parsed_report->{subject};
    my $currfulldist = $parsed_report->{currfulldist};
    my $x_test_reporter_perl = $parsed_report->{x_test_reporter_perl};
    my $x_test_reporter_distfile = $parsed_report->{x_test_reporter_distfile};
    my %analysis_tags = %{ $parsed_report->{analysis_tags} };
    my %prereq_fails = %{ $parsed_report->{prereq_fails} };
    my $test_more_version = $parsed_report->{prereq_versions}->{'Test::More'};
    my $curr_state;
    (my $curr_short_version = $x_test_reporter_perl) =~ s{^v}{}; # e.g. 5.10.0, without a leading "v"

    my $title = "ctr_good_or_invalid:";
    if ($subject) {
	$title =  " " . $subject;
	if ($x_test_reporter_perl) {
	    $title .= " (perl " . $x_test_reporter_perl . ")";
	}
	my $mw = $more->toplevel;
	($curr_state) = $subject =~ m{^(\S+)};
	$curr_state = lc $curr_state if defined $curr_state; # "fail", "pass" ...
    } else {
	$title = " (subject not parseable)";
    }

    $modtime = scalar localtime ((stat($currfile))[9]);

    {
	# fill "$following_dists_text" label

	my $get_dist_os = sub {
	    my $file = shift;
	    (my $dist_os = $file) =~ s{.*/}{};
	    $dist_os =~ s{-thread-multi}{}; # normalize threaded vs. non-threaded
	    $dist_os =~ s{(-freebsd\.[\d\.]+)-release(-p\d+)?}{$1}; # normalize freebsd patch levels
	    $dist_os =~ s{\.\d+\.\d+\.rpt$}{};
	    $dist_os;
	};

	my $curr_dist_os = $get_dist_os->($currfile);
	# assume files are sorted
	my $following_same_dist_os = 0;
	for my $i ($currfile_i+1 .. $#files) {
	    my $dist_os = $get_dist_os->($files[$i]);
	    if ($dist_os eq $curr_dist_os) {
		$following_same_dist_os++;
	    } else {
		last;
	    }
	}

	my $get_dist = sub {
	    my $file = shift;
	    (my $dist_os = $file) =~ s{.*/}{};
	    $dist_os =~ s{\.(x86_64|amd64|i[3456]86|darwin-2level|darwin-thread-multi-2level).*}{};
	    $dist_os;
	};

	my $curr_dist = $get_dist->($currfile);
	# assume files are sorted
	my $following_same_dist = 0;
	for my $i ($currfile_i+1 .. $#files) {
	    my $dist = $get_dist->($files[$i]);
	    if ($dist eq $curr_dist) {
		$following_same_dist++;
	    } else {
		last;
	    }
	}

	if ($following_same_dist >= 1) {
	    if ($following_same_dist > 1) {
		$following_dists_text = "/ following $following_same_dist reports for same dist";
	    } else {
		$following_dists_text = "/ following a report for same dist";
	    }
	    if ($following_same_dist_os >= 1) {
		$following_dists_text .= " ($following_same_dist_os for same OS)";
	    } else {
		$following_dists_text .= " (but different OS)";
	    }
	} else {
	    $following_dists_text = '';
	}
    }

    my %recent_states;
    if ($show_recent_states) {
	%recent_states = get_recent_states();
    }

    # Create the "analysis tags"
    my $generic_analysis_tag_value = delete $analysis_tags{__GENERIC_TEST_FAILURE__};
    if (!%analysis_tags && $generic_analysis_tag_value) { # show generic test fails only if there's nothing else
	$generic_analysis_tag_value->{__bgcolor__} = 'white'; # different color than the other analysis tags
	$analysis_tags{'generic test failure'} = $generic_analysis_tag_value;
    }
    for my $analysis_tag (sort keys %analysis_tags) {
	my @lines = @{ $analysis_tags{$analysis_tag}->{lines} || [] };
	my $bgcolor = $analysis_tags{$analysis_tag}->{__bgcolor__} || 'yellow';
	my $lines_i = 0;
	$analysis_frame->Button(-text => $analysis_tag,
				@common_analysis_button_config,
				-bg => $bgcolor,
				-command => sub {
				    $more->Subwidget('scrolled')->see("$lines[$lines_i].0");
				    $lines_i++;
				    if ($lines_i > $#lines) { $lines_i = 0 }
				},
			       )->pack;
    }

    # Highlight the lines in the text which caused the analysis
    # process to match
    {
	my $textw = $more->Subwidget("scrolled");
	$textw->tagConfigure('analysis_highlight', -background => '#eeeeee');
	while(my($analysis_tag, $info) = each %analysis_tags) {
	    for my $line (@{ $info->{lines} || [] }) {
		$textw->tagAdd('analysis_highlight', "$line.0", "$line.end");
	    }
	}
    }

    # Create the tags with the recent states for this distribution.
    my %recent_states_with_pv_and_archname = get_recent_states_with_pv_and_archname(\%recent_states);
    my %pv_os_analysis = rough_pv_os_analysis(\%recent_states_with_pv_and_archname);
    for my $recent_state (sort_by_example [qw(fail pass unknown na)], keys %recent_states) {
	my $count_old = scalar @{ $recent_states{$recent_state}->{old} || [] };
	my $count_new = scalar @{ $recent_states{$recent_state}->{new} || [] };
	my $color = (
		     $recent_state eq 'pass' ? 'green' :
		     $recent_state eq 'fail' ? 'red'   : 'orange'
		    );
	my @sample_recent_files = (
				   @{ $recent_states{$recent_state}->{old} || [] },
				   @{ $recent_states{$recent_state}->{new} || [] },
				  );
	my $sample_recent_file_counter = 0;
	my $f = $analysis_frame->Frame->pack;
	my $b = $f->Button(-text => "$recent_state: $count_old" . ($count_new ? " + $count_new new" : ''),
			   @common_analysis_button_config,
			   -bg => $color,
			   -command => sub {
			       my $t = $more->Toplevel(-title => '<empty>');
			       my $more = $t->Scrolled('More')->pack(qw(-fill both -expand 1));
			       $more->Subwidget('scrolled')->Subwidget('text')->configure(-background => '#f0f0c0'); # XXX really so complicated?
			       my $rcl = $t->Label(-anchor => 'w')->pack(qw(-fill x));
			       my $load_current_file = sub {
				   my $sample_recent_file = $sample_recent_files[$sample_recent_file_counter];
				   $more->Load($sample_recent_file);
				   $t->title($sample_recent_file);
				   my $modtime_epoch = (stat($sample_recent_file))[9];
				   my $modtime = scalar localtime $modtime_epoch;
				   my $plus_duration = '';
				   if (eval { require DateTime::Format::Human::Duration; require DateTime; 1 }) {
				       $plus_duration = ' (before ' . DateTime::Format::Human::Duration->new->format_duration_between
					   (
					    DateTime->from_epoch(epoch => $modtime_epoch),
					    DateTime->now
					   ) . ')';
				   }
				   $rcl->configure(-text => "$sample_recent_file_counter/$#sample_recent_files | Report created: $modtime$plus_duration");
			       };
			       my $f = $t->Frame->pack(qw(-fill x));
			       my $close_b = $f->Button(-text => 'Close', -command => sub { $t->destroy })->pack(qw(-fill x -side left));
			       my $prev_b = $f->Button(-text => '<', -command => sub {
							   if ($sample_recent_file_counter > 0) {
							       $sample_recent_file_counter--;
							       $load_current_file->();
							   } else {
							       warn "Already on first file...\n";
							   }
						       })->pack(qw(-fill x -side left));
			       my $next_b = $f->Button(-text => '>', -command => sub {
							   if ($sample_recent_file_counter < $#sample_recent_files) {
							       $sample_recent_file_counter++;
							       $load_current_file->();
							   } else {
							       warn "Already on last file...\n";
							   }
						       })->pack(qw(-fill x -side left));
			       $t->bind('<Left>' => sub { $prev_b->invoke });
			       $t->bind('<Right>' => sub { $next_b->invoke });
			       $t->bind('<Escape>' => sub { $close_b->invoke });
			       $load_current_file->();
			   },
			  )->pack(-side => 'left');
	for my $type (qw(pv os datetime threaded)) {
	    if ($pv_os_analysis{$type}->{$recent_state}) {
		$f->Label(-text => $pv_os_analysis{$type}->{$recent_state},
			  -bg => $color,
			  -borderwidth => 1,
			  -relief => 'raised',
			 )->pack(-side => 'left');
	    }
	}
	$balloon->attach($b, -msg => join("\n", map { $_->{version} . " " . $_->{archname} } @{ $recent_states_with_pv_and_archname{$recent_state} }));
    }

    # Possible regression on the beforemaintrelease page?
    for my $beforemaintrelease_pair (@current_beforemaintrelease_pairs) {
	my %check_v; @check_v{qw(old new)} = split /:/, $beforemaintrelease_pair;
	my %count;
	for my $age (qw(old new)) {
	    for my $state (qw(fail pass)) {
		$count{$state}->{$age} = 0;
		for my $report (@{ $recent_states_with_pv_and_archname{$state} || [] }) {
		    if ($report->{version} eq $check_v{$age}) {
			$count{$state}->{$age}++;
		    }
		}
	    }
	    if ($curr_short_version eq $check_v{$age} && $curr_state =~ m{^(fail|pass)$}) {
		$count{$curr_state}->{$age}++;
	    }
	}
	if ($count{fail}->{new}) {
	    if (!$count{fail}->{old}                          || # * 0 * 1
		(!$count{pass}->{old} && $count{pass}->{new}) || # 0 1 1 1
		(!$count{pass}->{new} && $count{pass}->{old})    # 1 1 0 1
	       ) {
		$analysis_frame->Label(
				       -text => "$beforemaintrelease_pair: $count{pass}{old}/$count{fail}{old} $count{pass}{new}/$count{fail}{new}",
				       @common_analysis_button_config,
				       -bg => 'lightblue',
				      )->pack;
	    }
	}
    }

    if ($do_scenario_buttons) {
	my %map_to_scenario = (
			       'pod test' => 'testpod',
			       'pod coverage test' => 'testpodcoverage',
			       'perl critic' => 'testperlcritic',
			       'signature mismatch' => 'testsignature',
			       'prereq fail' => 'prereq',
			       'prereq test' => 'testprereq',
			       'kwalitee test' => 'testkwalitee',
			       'system perl used' => 'systemperl',
			       'out of memory' => 'nolimits',
			       'Test-Simple problem' => 'testsimple',
			      );
	my @scenarios = map { exists $map_to_scenario{$_} ? $map_to_scenario{$_} : () } keys %analysis_tags;
	push @scenarios, qw(locale hashrandomization generic);
	for my $_scenario (@scenarios) {
	    my $scenario = $_scenario;
	    if ($scenario eq 'prereq' && %prereq_fails) {
		$scenario .= ',' . join ',', keys %prereq_fails;
	    } elsif ($scenario eq 'testsimple' && $test_more_version) {
		$scenario = 'prereq,EXODIST/Test-Simple-'.$test_more_version.'.tar.gz';
	    }
	    my $label;
	    my $need_balloon;
	    if (length($scenario) > 40) {
		$label = 'Again: ' . substr($scenario,0,40).'...';
		$need_balloon = 1;
	    } else {
		$label = $scenario;
	    }
	    my $b = $analysis_frame->Button(-text => $label,
					    @common_analysis_button_config,
					    -command => sub {
						schedule_recheck($x_test_reporter_distfile, $scenario);
					    })->pack;
	    if ($need_balloon) {
		$balloon->attach($b, -msg => $scenario);
	    }
	}
    }

    ($currdist, $currversion) = parse_distvname($currfulldist);

    { # requires up-to-date $currdist!
	my($annotation_text, $annotation_label);
	if ($distvname2annotation && $distvname2annotation->{$currfulldist}) {
	    $annotation_text = $distvname2annotation->{$currfulldist};
	    $annotation_label = 'Annotation';
	} elsif ($distname2annotation && $distname2annotation->{$currdist}) {
	    $annotation_text = $distname2annotation->{$currdist}->{annotation} . ' (version ' . $distname2annotation->{$currdist}->{version} . ')';
	    $annotation_label = 'Old Annotation';
	}
	if (defined $annotation_text) {
	    my @annotations = split /, ?/, $annotation_text; # annotation may be a comma-separated list ...
	    my $url;
	    for my $annotation (@annotations) {
		if ($annotation =~ m{^(\d+)}) { # ... of rt.cpan.org ticket ids
		    $url = "https://rt.cpan.org/Public/Bug/Display.html?id=$1";
		} elsif ($annotation =~ m{^(https?://\S+)}) { # ... or URLs
		    $url = $1;
		} # ... or something else
		last if defined $url;
	    }
	    {
		my $changed;
		for my $annotation (@annotations) {
		    if ($rtticket_to_title->{$annotation}) {
			$annotation .= " ($rtticket_to_title->{$annotation})";
			$changed = 1;
		    } elsif ($annotation =~ m{/github.com/.*/issues/}) {
			my $title = get_cached_github_issue_title($annotation);
			if (defined $title) {
			    $annotation .= " ($title)";
			    $changed = 1;
			}
		    }
		}
		if ($changed) {
		    $annotation_text = join("\n", @annotations); # turn commas into newlines, because lines may be long by now...
		}
	    }
	    my $w;
	    if ($url) {
		$w = $analysis_frame->Button(-text => $annotation_label,
					     -command => sub {
						 require Tk::Pod::WWWBrowser;
						 Tk::Pod::WWWBrowser::start_browser($url);
					     })->pack;
	    } else {
		$w = $analysis_frame->Label(-text => $annotation_label)->pack;
	    }
	    $balloon->attach($w, -msg => $annotation_text);
	}
    }

    {
	if ($confirmed_failure_rx && $currfile =~ $confirmed_failure_rx) {
	    $analysis_frame->Label(
				   -text => "Confirmed \x{2714}",
				   @common_analysis_button_config,
				   -bg => '#008000',
				   -fg => '#ffffff',
				  )->pack;
	}
    }

    $mw->title($title);

    if ($fast_forward) {
	require Time::HiRes;
	our $fast_foward_last_time;
	my $delta;
	if (defined $fast_foward_last_time) {
	    $delta = sprintf "prev=%5.3fs", Time::HiRes::time() - $fast_foward_last_time;
	} else {
	    $delta = '           ';
	}
	$fast_foward_last_time = Time::HiRes::time();
	warn "$delta $title...\n";
	$next_b->invoke;
    }
}

{
    my $date_comment_added;
    sub schedule_recheck {
	my($currfulldist, $scenario) = @_;
	open my $ofh, ">>", "$ENV{HOME}/trash/cpan_smoker_recheck"
	    or die "Can't open file: $!";
	if (!$date_comment_added) {
	    print $ofh "# added " . scalar(localtime) . "\n";
	    $date_comment_added = 1;
	}
	my $cpan_smoke_modules_options = '-perlr -skipsystemperl';
	if ($scenario eq 'generic') {
	    print $ofh "cpan_smoke_modules $cpan_smoke_modules_options $currfulldist\n";
	} else {
	    print $ofh qq{~/src/srezic-misc/scripts/cpan_smoke_modules_wrapper3 -minimize-work -cpansmokemodulesoptions="$cpan_smoke_modules_options" -scenario $scenario $currfulldist\n};
	}
	close $ofh;
    }
}

# Return value:
# (
#   'fail' => { 'old' => ["$dir/$file1", "$dir/$file2" ... ],
#               'new' => [ ... ],
#             },
#   'pass' => { ... }, 
# )
sub get_recent_states {
    my %recent_states;

    my @check_defs = (
		      ['old', @recent_done_directories, $good_directory],
		      ['new', $new_directory],
		     );

    my $res = parse_report_filename($currfile);
    if (!$res) {
	warn "WARN: cannot parse $currfile";
    } else {
	my $distv = $res->{distv};
	my @recent_reports;
	my $currfile_base = basename $currfile;
	for my $check_def (@check_defs) {
	    my($age, @directories) = @$check_def;
	    for my $directory (@directories) {
		if ($use_recent_states_cache && $age eq 'old' && $directory ne $recent_done_directories[0] && $directory ne $good_directory) {
		    my @recent_res = get_recent_reports_from_cache($distv, $directory);
		    for my $recent_res (@recent_res) {
			my $recent_state = $recent_res->{state};
			push @{ $recent_states{$recent_state}->{$age} }, "$directory/" . $recent_res->{file};
		    }
		} else {
		    if (defined &CtrGetReportsFastReader::get_matching_entries) {
			#warn "INFO: use fast C reader for $directory and $distv\n";
			for my $file (CtrGetReportsFastReader::get_matching_entries($directory, $distv)) {
			    # XXX avoid code duplication!
			    if ($file ne $currfile_base) { # don't show current report in NEW counts
				if (index($file, $distv) >= 0) { # quick check
				    if (my $recent_res = parse_report_filename($file)) {
					if ($recent_res->{distv} eq $distv) {
					    my $recent_state = $recent_res->{state};
					    push @{ $recent_states{$recent_state}->{$age} }, "$directory/$file";
					}
				    }
				}
			    }
			}
		    } elsif (opendir(my $DIR, $directory)) {
			while(defined(my $file = readdir $DIR)) {
			    if ($file ne $currfile_base) { # don't show current report in NEW counts
				if (index($file, $distv) >= 0) { # quick check
				    if (my $recent_res = parse_report_filename($file)) {
					if ($recent_res->{distv} eq $distv) {
					    my $recent_state = $recent_res->{state};
					    push @{ $recent_states{$recent_state}->{$age} }, "$directory/$file";
					}
				    }
				}
			    }
			}
		    } else {
			warn "ERROR: cannot open $directory: $!";
		    }
		}
	    }
	}
    }

    %recent_states;
}

{
    # Parameter: the return value from get_recent_states
    #
    # Return value:
    # (
    #     'fail' => [{ version => '5.10.1', archname => 'amd64-freebsd', epoch => 1464115555 }, { version => '5.12.1 RC1' ... }, ...  ],
    #     'pass' => [ ... ],
    # )
    #
    # Perl versions are already naturally sorted

    my %report_file_info; # cache

    sub get_recent_states_with_pv_and_archname {
	my $recent_states_ref = shift;

	my %recent_states_with_pv;
	while(my($state, $hash) = each %$recent_states_ref) { # we mix 'old' and 'new'
	    for my $f (map { @$_ } values %$hash) {
		if (!exists $report_file_info{$f}) {
		    if (open my $fh, $f) {
			my($epoch) = $f =~ m{\.(\d+)\.\d+\.rpt$};
			my($x_test_reporter_perl, $archname);
			while(<$fh>) {
			    chomp;
			    s/\r//; # for windows reports
			    if (m{^X-Test-Reporter-Perl: v(.*)}) {
				$x_test_reporter_perl = $1;
			    } elsif (m{^Subject: \S+ \S+ (.*)}) {
				$archname = $1;
			    } elsif (m{^$}) {
				if (!defined $x_test_reporter_perl) {
				    warn "WARN: cannot find X-Test-Reporter-Perl header in $f";
				} elsif (!defined $archname) {
				    warn "WARN: cannot find Subject header with archname in $f";
				} else {
				    $report_file_info{$f} = { version => $x_test_reporter_perl, archname => $archname, epoch => $epoch };
				}
				last;
			    }
			}
		    } else {
			warn "WARN: cannot open $f: $!";
		    }
		}
		if (exists $report_file_info{$f}) {
		    push @{ $recent_states_with_pv{$state} }, $report_file_info{$f};
		}
	    }

	    @{ $recent_states_with_pv{$state} } = _sort_pv_archname($recent_states_with_pv{$state});
	}

	%recent_states_with_pv;
    }
}

sub _sort_pv_archname {
    my $recent_states_with_pv = shift;
    #no warnings 'uninitialized'; # XXX mysterious uninitialized value in sort warnings
    map { $_->[0] }
    sort {
	$a->[1] cmp $b->[1]
    } map {
	if (my(@v_comp) = $_->{version} =~ m{^(\d+)\.(\d+)\.(\d+)(?: RC(\d+))?}) {
	    if (!defined $v_comp[3]) { $v_comp[3] = 9999 } # assume we have never more than 9999 RCs...
	    [$_, join('', map { chr $_ } @v_comp)];
	} else {
	    warn "WARN: ignore unparsable version '$_'";
	}
    } @{ $recent_states_with_pv };
}

sub rough_pv_os_analysis {
    my $recent_states_with_pv_and_archname_ref = shift;
    my @all_recent_states; # flat list
    for my $recent_state (keys %$recent_states_with_pv_and_archname_ref) {
	for my $entry (@{ $recent_states_with_pv_and_archname_ref->{$recent_state} }) {
	    push @all_recent_states, { %$entry, state => $recent_state };
	}
    }
    @all_recent_states = _sort_pv_archname(\@all_recent_states);
    my %state_pv_analysis;
    {
	my $current_state;
	my $current_begin_pv;
	my $current_end_pv;
	for my $entry (@all_recent_states) {
	    my $set_current = sub {
		if (exists $state_pv_analysis{$entry->{state}}) {
		    # invalidate
		    $state_pv_analysis{$entry->{state}} = undef;
		    undef $current_state;
		} else {
		    $current_state = $entry->{state};
		    $current_begin_pv = $current_end_pv = $entry->{version};
		}
	    };
	    if (!$current_state) {
		$set_current->();
	    } else {
		if ($entry->{state} eq $current_state) {
		    $current_end_pv = $entry->{version};
		} else {
		    if ($current_end_pv eq $entry->{version}) {
			# different states for same version
			$state_pv_analysis{$current_state} = undef;
			$state_pv_analysis{$entry->{state}} = undef;
			undef $current_state;
		    } else {
			$state_pv_analysis{$current_state} = $current_begin_pv eq $current_end_pv ? $current_begin_pv : "$current_begin_pv..$current_end_pv";
			$set_current->();
		    }
		}
	    }
	}
	if (defined $current_state) {
	    $state_pv_analysis{$current_state} = $current_begin_pv eq $current_end_pv ? $current_begin_pv : "$current_begin_pv..$current_end_pv";
	}
	for my $state (keys %state_pv_analysis) {
	    if (!defined $state_pv_analysis{$state}) {
		delete $state_pv_analysis{$state};
	    }
	}
    }

    @all_recent_states = sort { $a->{archname} cmp $b->{archname} } @all_recent_states;
    my %state_os_analysis;
    my %state_threaded_analysis;
    {
	my %os_state_count;
	my %threaded_state_count;
	for my $entry (@all_recent_states) {
	    my $arch_os;
	    if ($entry->{archname} =~ m{^(darwin|MSWin32|cygwin)}) {
		$arch_os = $1;
	    } else {
		($arch_os) = $entry->{archname} =~ m{^[^- ]+-([^- ]+)};
	    }
	    $os_state_count{$arch_os}->{$entry->{state}}++;

	    my $is_threaded = $entry->{archname} =~ m{-thread[- ]} ? 'threaded' : 'unthreaded';
	    $threaded_state_count{$is_threaded}->{$entry->{state}}++;
	}

	for my $arch_os (keys %os_state_count) {
	    if (keys %{ $os_state_count{$arch_os} } == 1) {
		my $state = (keys %{ $os_state_count{$arch_os} })[0];
		push @{ $state_os_analysis{$state} }, $arch_os;
	    }
	}
	for my $state (keys %state_os_analysis) {
	    $state_os_analysis{$state} = join(',', sort @{ $state_os_analysis{$state} });
	}

	for my $is_threaded (keys %threaded_state_count) {
	    if (keys %{ $threaded_state_count{$is_threaded} } == 1) {
		my $state = (keys %{ $threaded_state_count{$is_threaded} })[0];
		push @{ $state_threaded_analysis{$state} }, $is_threaded;
	    }
	}
	for my $state (keys %state_threaded_analysis) {
	    if (@{ $state_threaded_analysis{$state} } == 2) { # "threaded,unthreaded" -> uninteresting!
		delete $state_threaded_analysis{$state};
	    } else {
		$state_threaded_analysis{$state} = join(',', sort @{ $state_threaded_analysis{$state} });
	    }
	}
    }

    @all_recent_states = sort { $a->{epoch} <=> $b->{epoch} } @all_recent_states;
    my %state_datetime_analysis;
    {
	my $current_state;
	my $current_begin_epoch;
	my $current_end_epoch;
	my $stringify = sub {
	    strftime("%F", localtime $current_begin_epoch) .
		($current_begin_epoch != $current_end_epoch
		 ? ".." . strftime("%F", localtime $current_end_epoch)
		 : '');
	};
	for my $entry (@all_recent_states) {
	    my $set_current = sub {
		if (exists $state_datetime_analysis{$entry->{state}}) {
		    # invalidate
		    $state_datetime_analysis{$entry->{state}} = undef;
		    undef $current_state;
		} else {
		    $current_state = $entry->{state};
		    $current_begin_epoch = $current_end_epoch = $entry->{epoch};
		}
	    };
	    if (!$current_state) {
		$set_current->();
	    } else {
		if ($entry->{state} eq $current_state) {
		    $current_end_epoch = $entry->{epoch};
		} else {
		    $state_datetime_analysis{$current_state} = $stringify->();
		    $set_current->();
		}
	    }
	}
	if (defined $current_state) {
	    $state_datetime_analysis{$current_state} = $stringify->();
	}
	for my $state (keys %state_datetime_analysis) {
	    if (!defined $state_datetime_analysis{$state}) {
		delete $state_datetime_analysis{$state};
	    }
	}
    }

    (pv => \%state_pv_analysis, os => \%state_os_analysis, datetime => \%state_datetime_analysis, threaded => \%state_threaded_analysis);
}

sub get_recent_reports_from_cache {
    my($distv, $directory) = @_;
    require MLDBM;
    require Fcntl;
    no warnings 'once';
    local $MLDBM::UseDB = 'DB_File';
    local $MLDBM::Serializer = 'Storable';
    my $cache_file = "$directory/.reports_cache";
    if (!-s $cache_file) {
	warn "INFO: build cache file $cache_file...\n";
	my %local_db;
	if (opendir(my $DIR, $directory)) {
	    my $scan_msg = "INFO: scanning directory $directory... ";
	    print STDERR $scan_msg;
	    my $i = 0;
	    while(defined(my $file = readdir $DIR)) {
		my $recent_res = parse_report_filename($file);
		if ($recent_res) {
		    my $this_distv = $recent_res->{distv};
		    if ($this_distv) {
			$recent_res->{file} = $file;
			push @{ $local_db{$this_distv} }, $recent_res;
		    }
		}
		if ($i++ % 1000 == 0) {
		    print STDERR "\r$scan_msg $i files ";
		}
	    }
	    print STDERR "\nINFO: Dumping to cache file...\n";
	    tie my %db, 'MLDBM', $cache_file, &Fcntl::O_CREAT|&Fcntl::O_RDWR, 0644
		or die "Can't create cache file $cache_file: $!";
	    while(my($k,$v) = each %local_db) {
		$db{$k} = $v;
	    }
	    print STDERR "INFO: Dumping finished.\n";
	} else {
	    die "ERROR: cannot open $directory: $!";
	}		
    }
    tie my %db, 'MLDBM', $cache_file, &Fcntl::O_RDONLY, 0644
	or die "Can't tie cache file $cache_file: $!";
    my $recent_reports = $db{$distv};
    $recent_reports ? @$recent_reports : ();
}

sub nextfile {
    if ($currfile_i < $#files) {
	$currfile_i++;
	set_currfile();
    } else {
	if ($quit_at_end) {
	    $mw->afterIdle(sub { $mw->destroy });
	} else {
	    if ($mw->messageBox(-icon => "question",
				-title => "End of list",
				-message => "No more files. Quit?",
				-type => "YesNo",
			       ) eq 'Yes') {
		$mw->destroy;
	    } else {
		warn "Continuing?";
	    }
	}
    }
}

{
my $X11_Protocol_usable;
sub is_user_at_computer {
    my $ret;
    if (defined $X11_Protocol_usable && !$X11_Protocol_usable) {
	$ret = 1;
    } else {
	$ret = eval {
	    require X11::Protocol;
	    # Somehow this does not work from a MacOSX system to a remote Unix system...
	    # it even hangs, so need to setup a timeout mechanism.
	    local $SIG{ALRM} = sub {
		$X11_Protocol_usable = 0;
		die "Timeout while doing X11::Protocol stuff...";
	    };
	    alarm(1);
	    my $X = X11::Protocol->new;
	    alarm(0);
	    $X->init_extension('MIT-SCREEN-SAVER')
		or die "MIT-SCREEN-SAVER extension not available or CPAN module X11::Protocol::Ext::MIT_SCREEN_SAVER not installed";
	    my($on_or_off) = $X->MitScreenSaverQueryInfo($X->root);
	    $X11_Protocol_usable = 1;
	    $on_or_off eq 'On' ? 0 : 1;
	};
	if ($@) {
	    if ($do_check_screensaver) {
		if ($@ =~ m{(Can't connect to display|Connection refused)}) {
		    (my $err = $@) =~ s{\n}{ }g;
		    warn "Error: $err, assume script has no connection to display...\n";
		    $ret = 0;
		} elsif ($@ =~ m{Timeout while doing X11::Protocol stuff}) {
		    $ret = 1;
		} else {
		    die $@;
		}
	    } else {
		$ret = 1;
	    }
	}
    }
    $ret;
}
}

sub parse_report_filename {
    my $filename = shift;
    if (my($state, $distv_arch, $epoch, $pid) = $filename =~ m{(?:^|/)($the_ct_states_rx)\.(.*)\.(\d+)\.(\d+)\.rpt$}) {
	my @tokens = split /\./, $distv_arch;
	my $distv = shift @tokens;
	my $arch;
	while(defined(my $token = shift @tokens)) {
	    if ($token =~ m{^\d}) {
		$distv .= ".$token";
	    } else {
		$arch = join(".", $token, @tokens);
		last;
	    }
	}
	my $res =  +{
		     distv => $distv,
		     state => $state,
		     arch  => $arch,
		     epoch => $epoch,
		     pid   => $pid,
		    };
	return $res;
    } else {
	undef;
    }
}

sub check_term_title {
    if (!eval { require XTerm::Conf; 1 }) {
	if (!eval { require Term::Title; 1 }) {
	    warn "No XTerm::Conf and/or Term::Title available, turning -xterm-title off (specify -no-xterm-title to cease this warning)...\n";
	    $do_xterm_title = 0;
	}
    }
}

sub set_term_title {
    return if !$do_xterm_title;
    my $string = shift;
    if (defined &XTerm::Conf::xterm_conf_string) {
	print STDERR XTerm::Conf::xterm_conf_string(-title => $string);
    } else {
	Term::Title::set_titlebar($string);
    }
}

# "Foo-Bar-1.00" -> ("Foo-Bar", "1.00")
sub parse_distvname {
    my($currfulldist) = @_;
    my($currdist, $currversion);
    # XXX maybe use CPAN::DistnameInfo instead?
    if ($currfulldist =~ m{-TRIAL}) {
	($currdist, $currversion) = $currfulldist =~ m{^(.*)-([^-]+-TRIAL.*)$};
    } else {
	($currdist, $currversion) = $currfulldist =~ m{^(.*)-(.*)$};
    }
    ($currdist, $currversion);
}

sub read_annotate_txt {
    my($mandatory_file, @optional_files) = @_;
    my(%distvname2annotation, %distname2annotation);
    my $add_annotation = sub ($$) {
	my($dest_ref, $annotation) = @_;
	if (!defined $$dest_ref || !length $$dest_ref) {
	    $$dest_ref = $annotation;
	} elsif ($$dest_ref =~ m{(^|,)\Q$annotation\E(,|$)}) {
	    # don't add
	} else {
	    $$dest_ref .= ',' . $annotation;
	}
    };
    for my $def (
		 [$mandatory_file, 1],
		 (map {[$_, 0]} @optional_files),
		) {
	my($file, $mandatory) = @$def;
	my $fh;
	if (!open $fh, "<", $file) {
	    if ($mandatory) {
		die "ERROR: Can't open $file: $!";
	    } else {
		warn "INFO: Can't open optional annotation file $file: $!, skipping...\n";
		next;
	    }
	}
	while(<$fh>) {
	    chomp;
	    next if /^\s*$/;
	    next if /^#/;
	    my($distvname, $annotation) = split /\s+/, $_, 2;
	    my($distname, $distversion) = parse_distvname($distvname);

	    $add_annotation->(\$distvname2annotation{$distvname}, $annotation);
	    if (exists $distname2annotation{$distname}) {
		my $cmp = cmp_version($distname2annotation{$distname}->{version}, $distversion);
		if ($cmp < 0) { # existing is older
		    $distname2annotation{$distname} = { version => $distversion, annotation => $annotation };
		} elsif ($cmp == 0) {
		    $add_annotation->(\$distname2annotation{$distname}->{annotation}, $annotation);
		} else {
		    # ignore
		}
	    } else {
		$distname2annotation{$distname} = { version => $distversion, annotation => $annotation };
	    }		
	}
    }
    (\%distvname2annotation, \%distname2annotation);
}

sub read_auto_good_file {
    my $auto_good_file = shift;
    my @auto_good_rxs;
    open my $fh, $auto_good_file
	or die "Can't open $auto_good_file: $!";
    while(<$fh>) {
	chomp;
	next if $_ eq '' || $_ =~ m{^#};
	if (my($type, $val) = $_ =~ m{^(.)(.*)}) {
	    if      ($type eq '"') {
		push @auto_good_rxs, quotemeta($val);
	    } elsif ($type eq '/') {
		if (!eval { qr{$val} }) {
		    die "Regexp syntax check for '$val' failed: $@";
		}
		push @auto_good_rxs, $val;
	    } else {
		die qq{Invalid type '$type', line '$_' must begin with " or /};
	    }
	} else {
	    die "Can't parse line <$_> in $auto_good_file";
	}
    }
    if (@auto_good_rxs) {
	my $auto_good_rx = '/(?:' . join('|', @auto_good_rxs) . ')';
	qr{$auto_good_rx};
    } else {
	undef;
    }
}

# XXX Should be replaced by something else (e.g. rt+github clients)
sub read_rt_information {
    my %rtticket_to_title;
    if (open my $fh, "$ENV{HOME}/Mail/rt-cpan/.overview") {
	while(<$fh>) {
	    if (my($rtticket, $title) = $_ =~ m{\t\[rt.cpan.org #(\d+)\] AutoReply: ([^\t]+)}) {
		if (!exists $rtticket_to_title{$rtticket}) {
		    $title =~ s{^\s+}{}; $title =~ s{\s+$}{};
		    $rtticket_to_title{$rtticket} = $title;
		}
	    }
	}
    }
    \%rtticket_to_title;
}

sub get_cached_github_issue_title {
    my($url) = @_;
    my $title;
    if ($url =~ s{/github.com/}{/api.github.com/repos/}) {
	eval {
	    require DB_File;
	    require Fcntl;
	    my $cache_file = "$ENV{HOME}/.cache/ctr_good_or_invalid/github_issue_titles.db";
	    if (!-d dirname($cache_file)) {
		require File::Path;
		File::Path::mkpath(dirname($cache_file));
	    }
	    # XXX implement locking for all!
	    tie my %db, 'DB_File', $cache_file, &Fcntl::O_RDWR|&Fcntl::O_CREAT|($^O eq 'freebsd' ? &Fcntl::O_EXLOCK : 0), 0644
		or die "ERROR: Can't tie cache file $cache_file: $!";
	    if (exists $db{$url}) {
		$title = $db{$url};
	    } else {
		warn "INFO: Not found in cache, try to fetch from $url...\n";
		require LWP::UserAgent;
		require JSON::XS;
		my $resp = LWP::UserAgent->new->get($url);
		if ($resp->is_success) {
		    $title = JSON::XS::decode_json($resp->decoded_content(charset => "none"))->{title};
		    $db{$url} = $title;
		}
	    }
	};
	if ($@) {
	    warn "ERROR: $@";
	}
    } else {
	warn "WARN: Unexpected github URL '$url'";
    }
    $title;
}

sub make_query_string {
    my(%args) = @_;
    if (eval { require URI::Query; 1 }) {
	URI::Query->new(\%args)->stringify;
    } elsif (eval { require CGI; 1 }) {
	CGI->new(\%args)->query_string;
    } else {
	die "Please install URI::Query";
    }
}

sub cmp_version {
    my($left, $right) = @_;
    for ($left, $right) { $_ =~ s/-TRIAL// }
    CPAN::Version->vcmp($left, $right);
}

sub _create_images {
    require Tk::PNG;

    if (!defined $images{metacpan}) {
	# Fetched from https://metacpan.org/static/icons/metacpan-icon.png
	# Converted with:
	#   cat /tmp/metacpan-icon.png |perl -MMIME::Base64 -e 'print encode_base64(join("",<>))'
	$images{metacpan} = $mw->Photo
	    (-format => 'png',
	     -data => <<'EOF');
iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAMAAAAoLQ9TAAAA51BMVEUAAAB/AADHITKqAAD/AADH
IDD/AADIITLHITHHHzDHITHHITEAAADBHi7HIDDGHC/DHy/FHzHFHC7GHi/HITLGHS3HIDO2JCTH
ITHGIDDHITHHIjDGIDHGHzHHIjDIIDHHITLFHy/FHDDIITHGITG/FSrHITHEHS3HIDPHHzLGITDF
IDLGITLGHTDHIDG5Fy7HHzHIIDLGITDHITLIITLHITLGITHFITHIITHIITLSJDXRJDXLIjTVJDfY
JTjVJTfWJTfOIzTZJTjUJDfPJDXIIjPNIzTPJDTMIjTJIjPTJDXTJDfKIjTwwdEHAAAAOnRSTlMA
AvkDAcYC/vaYvvUBIX0bQGEsO/df1w77f/wln0h4Z/hQNfvfDL09r9inR6hehguBymP2/fy/9vr3
ooCy8wAAANFJREFUeF41zmVSxDAAgNEvqcq6u7svTtJ23YD7nwf+MPMO8BAki00QJmSyORLw9NDK
KoM50fqaguTjRxZiD1rHjnRUnqKWl1pYEoxulYtUVZqqUPs8W7BQzy9B1AYrDs/fXejddbgfDKHs
lawuwmDsT2dpEP9sMEBgAmCADYAJojVa9LBt6g1/tQYmx9vXfQx1NzrEW4OM7lRc7UMjCvrubkn2
L/YaTg3eDn1Hqg25qyOD/QxW8bv8OM0hpVQ0SMN6u1MnDxLkq+0hwsRYbubwCyM7GWpr29cFAAAA
AElFTkSuQmCC
EOF
    }

    if (!defined $images{rt}) {
	# Fetched and converted:
	#   wget https://rt.perl.org/NoAuth/images/favicon.png
	#   convert -scale 16 favicon.png favicon50.png
	#   cat favicon50.png | perl -MMIME::Base64 -e 'print encode_base64(join("",<>))'
	$images{rt} = $mw->Photo
	    (-format => 'png',
	     -data => <<'EOF');
iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAMAAAAoLQ9TAAAABGdBTUEAALGPC/xhBQAAACBjSFJN
AAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAAXVBMVEUAAACgoKDAwMCgYGD/
AACAVVUAAACAgICAgIDgYGD/AACggIDAICDfAADQUFAAAACAAADfICD////AwMCgIEDAAACAAADv
7+9gAADvsLCQcDDAQECgICCwsLDg4OAAEzx8AAAACnRSTlMAf0B/v7+/QH9/S5qSvgAAAAFiS0dE
AIgFHUgAAAAHdElNRQffAxAUCQmLNCFUAAAAYUlEQVQY062MRxKAIBAEMWAYCbKomP//TBOlcLdP
2101y1hIgibyVMgsCjl45BzKX4W+aGHKW6tE04k18nHW9YMjcgajH9QCZqIZSr/fBokFwn1BW4HV
UhDIbTuFwcN+4gDbHAUK+DJLIQAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAxNS0wMy0xNlQyMDowOTow
OSswMTowMHbOQdAAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMTUtMDMtMTZUMjA6MDk6MDkrMDE6MDAH
k/lsAAAAAElFTkSuQmCC
EOF
    }

    if (!defined $images{matrix}) {
	# Converted:
	#   convert ~/src/CPAN/CPAN-Testers-Matrix/images/cpantesters_favicon.ico /tmp/cpantesters_favicon.png
	#   cat /tmp/cpantesters_favicon.png  | perl -MMIME::Base64 -e 'print encode_base64(join("",<>))'
	$images{matrix} = $mw->Photo
	    (-format => 'png',
	     -data => <<'EOF');
iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAMAAAAoLQ9TAAAABGdBTUEAALGPC/xhBQAAACBjSFJN
AAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAAP1BMVEUAAAD/AAAAgQDMzMxm
ZplmZmaQGzesNzfHUlLjbm4zM2asN1KZmZn///+Zmcw3clIbVjdSjVJuqW6KxYo3cjeuaZfnAAAA
A3RSTlMAdXWIUczeAAAAAWJLR0QN9rRh9QAAAAd0SU1FB9wHDBQXEFLFigIAAACNSURBVBjTLY6B
EoQgCERJwDrCJOv/v/UWDZ2R92ZFiVAsWut+/DZUsphZzTqWSF6inikmW92/DPFk289lthkQUWGZ
UadkN9fWxBU9hLJd6q01y+sQ7ugYwi+ZAscSF8YI9eh3jBhPJhRDRwB7vyHUzZhKj7djPS3fdaJS
3gjs8PwApUAm6+MUZaRS5+Q/AzAIn3BWLJgAAAAldEVYdGRhdGU6Y3JlYXRlADIwMTItMDctMTJU
MjA6MjM6MTYrMDI6MDBJV8hkAAAAJXRFWHRkYXRlOm1vZGlmeQAyMDEyLTA3LTEyVDIwOjIzOjE2
KzAyOjAwOApw2AAAAABJRU5ErkJggg==
EOF
    }
}

# REPO BEGIN
# REPO NAME sort_by_example /home/e/eserte/src/srezic-repository 
# REPO MD5 44ca029b43df0207958ba6b2f276f3eb
sub sort_by_example ($@) {
    my $example_ref = shift;
    my %score = do {
	my $score = 1;
	map { ($_ => $score++) } reverse @$example_ref;
    };
    no warnings "uninitialized";
    sort {
	my $score_a = $score{$a};
	my $score_b = $score{$b};
	!defined $score_a && !defined $score_b ? $a cmp $b : $score{$b} <=> $score{$a};
    } @_;
}
# REPO END

__END__

=head1 NAME

ctr_good_or_invalid.pl - interactively decide if CPAN Tester reports are good

=head1 SYNOPSIS

    ctr_good_or_invalid.pl [options] [reportworkflowdir]

=head1 DESCRIPTION

C<ctr_good_or_invalid.pl> is part of a CPAN Tester workflow where all
FAIL (or all non-PASS) reports are interactively checked before sent
to metabase. This script shows unprocessed test reports in a GUI
window (using L<Tk>), where the report is displayed and the user can
decide whether the report is "good" or "invalid" or "undecided" (and
check this report later). Also part of the GUI window is a number of
links to helpful tools in the CPAN Testers ecosystem
(L<http://matrix.cpantesters.org>, L<http://rt.cpan.org>, a solver
based on L<CPAN::Testers::ParseReport>).

=head2 OPTIONS

=over

=item C<-noxterm-title>

By default, the current status (number of reports) is displayed in the
xterm title. This requires L<XTerm::Conf>. Set this option to turn
this feature off.

=item C<-only-pass-is-good>

By default, only FAIL reports are checked interactively and everything
else is moved automatically to the C<sync> directory. Using this
switch also NA and UNKNOWN reports are checked interactively. An
exception are such reports where the analysis thinks that it's due to
"notests" or "low perl"; these reports are also moved automatically
for syncing.

=item C<-annotate-file I<path>>

Path to the C<annotate.txt> file from
L<http://repo.or.cz/r/andk-cpan-tools.git>, or a compatible file. If
defined, then show a link to the annotation (usually a RT or other
ticket) if the tested distribution has one.

=back

=head2 FURTHER NOTES

The script includes a hard-coded list of report filename regexps which
are OK to be accepted without further review. These usually handle
distributions which are known to always fail.

=head2 RELATED SCRIPTS

The other scripts in the workflow system are:

=over

=item * C<L<cpan_smoke_modules_wrapper3>> - a wrapper to call
L<cpan_smoke_modules> for a number of perl installations

=item * C<L<cpan_smoke_modules>> - a wrapper around L<CPAN.pm|CPAN>
and L<CPAN::Reporter>, capable of smoke testing recent modules or a
given list of modules

=item * C<ctr_good_or_invalid.pl> - this script, an interactive
checker for the validness of reports

=item * C<L<send_tr_reports.pl>> - a wrapper around L<Test::Reporter>
to send valid reports to metabase

=back

=head2 DIRECTORY STRUCTURE

Part of the workflow is a directory structure which reflects the
phases of the workflow. The default root directory for the workflow is
C<~/var/cpansmoker>, but may be changed by the individual scripts. The
subdirectories here are:

=over

=item * C<new> - here C<L<cpan_smoke_modules>> (or a manually
configured CPAN shell) writes new test reports

=item * C<sync> - reports marked by C<ctr_good_or_invalid.pl> as
"good" are moved to this directory for later processing

=item * C<invalid> - reports marked by C<ctr_good_or_invalid.pl> as
"invalid" are moved to this directory and will stay here

=item * C<undecided> - reports marked by C<ctr_good_or_invalid.pl> as
"undecided" are moved to this directory and will stay here; a user
should check these reports later manually and then move them to either
C<sync> or C<invalid>

=item * C<process> - C<send_tr_reports.pl> moves reports which are
about to be sent to metabase into this directory; in case of metabase
problems the report will be left here

=item * C<done> - after successfully sending to metabase the reports
will be archived into this directory; this directory is organized in
monthly subdirectories I<YYYY-MM>.

=back

=head1 EXAMPLES

Following needs the scripts C<forever> (unreleased, otherwise use a
shell C<while> loop), C<ctr_good_or_invalid.pl> (this script), and
C<L<send_tr_reports.pl>>. Note that the perl executable is hardcoded
here:

    forever -countdown -181 -pulse 'echo "*** WORK ***"; sleep 1; ./ctr_good_or_invalid.pl -auto-good -xterm-title ~cpansand/var/cpansmoker; ./send_tr_reports.pl ~cpansand/var/cpansmoker/; echo "*** DONE ***"'

The script's defaults may be quite demanding. If you don't have
C<X11::Protocol::Ext::MIT_SCREEN_SAVER> installed, and the
F<cpansmoker> is on an expensive file system (e.g. a remote mount),
then consider to set the C<-noauto-good> and C<-norecent-states> switches:

    ctr_good_or_invalid.pl -noauto-good -norecent-states ~/var/cpansmoker

=head1 AUTHOR

Slaven Rezic C<srezic AT cpan DOT org>

=head1 SEE ALSO

L<cpan_smoke_modules_wrapper3>, L<cpan_smoke_modules>,
L<send_tr_reports.pl>, L<Test::Reporter>, L<CPAN>,
L<CPAN::Testers::ParseReport>.

=cut
