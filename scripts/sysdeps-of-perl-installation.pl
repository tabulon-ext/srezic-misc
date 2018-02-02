#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(realpath);
use File::Find;
use Getopt::Long;

my $libdir;
my $debug;

sub debug ($) { warn "DEBUG: $_[0]\n" if $debug }

sub apt_file_find ($;$) {
    my $file = shift;
    my $for = shift;
    my @packages;
    (my $qr = $file) =~ s{\+}{\\+}g;
    my @cmd = (
	'apt-file', 'search', '--package-only', '--regexp', '^'.$qr.'$',
	#'^'.quotemeta($file).'$' # XXX does not work; backslash before / disturbs
    );
    debug "@cmd...";
    open my $fh, '-|', @cmd
	or die $!;
    while(<$fh>) {
	chomp;
	push @packages, $_;
    }
    if (!@packages) {
	my $msg = "WARN: cannot find anything while running '@cmd'...";
	if ($for) {
	    $msg .= " (required for $for->[0] ...)";
	}
	warn "$msg\n";
    }
    @packages;
}

GetOptions(
    "libdir=s" => \$libdir,
    "debug"    => \$debug,
)
    or die "usage: $0 [--debug] [--libdir libdir] [perldir]\n";
if (!$libdir) {
    my $perldir = shift
	or die "perldir?";
    $libdir = realpath "$perldir/lib";
}

my %sodeps;
my %sorevdeps;
find(sub {
	 if (-f $_ && m{\.so$}) {
	     debug "Check .so $File::Find::name...";
	     open my $fh, '-|', 'ldd', $File::Find::name
		 or die $!;
	     while(<$fh>) {
		 if (m{.*\s+=>\s+(\S+)\s+\(0x[0-9a-f]+\)$}) {
		     my $so = realpath $1;
		     if (!defined $so) {
			 warn "Can't resolve $1 -> library missing? Found in $File::Find::name\n";
		     } else {
			 if (index($so, $libdir) == 0) {
			     # ignore
			 } else {
			     push @{ $sodeps{$File::Find::name} }, $so;
			     push @{ $sorevdeps{$so} }, $File::Find::name;
			 }
		     }
		 }
	     }
	 }
     }, $libdir);

$| = 1; # because apt-file is slow
my %seen_package;
for my $so (keys %sorevdeps) {
    my $output_package = sub ($) {
	my $package = shift;
	if (!$seen_package{$package}) {
	    print $package, "\n";
	    $seen_package{$package} = 1;
	}
    };
    debug "Check dependent library $so...";
    my @so_packages = apt_file_find $so, $sorevdeps{$so};
    if (!@so_packages) {
	## already warned
	#warn "WARN: Cannot find a package for $so\n";
    } else {
	if (@so_packages > 1) {
	    my($so_package) = sort { length($a) <=> length($b) } @so_packages;
	    warn "INFO: found multiple packages for $so (@so_packages), choosing with shortest name: $so_package\n"; # XXX not good solution
	    $output_package->($so_package);
	} else {
	    $output_package->($so_packages[0]);
	}
    }
}

__END__
