#!/usr/bin/perl -w
# -*- perl -*-

#
# $Id: perlbinsearch.pl,v 1.4 2008/10/21 20:36:00 eserte Exp $
# Author: Slaven Rezic
#
# Copyright (C) 2008 Slaven Rezic. All rights reserved.
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.
#
# Mail: slaven@rezic.de
# WWW:  http://www.rezic.de/eserte/
#

=pod

  $ git-bisect start cb2877ce3cadf472e7e4932c3609b84b04fa46db perl-5.8.8
  $ git-bisect view &
  $ git-bisect run ~/devel/perlbinsearch.pl 

=cut

use strict;
use Cwd qw(cwd);
my $perldir = cwd;

#my $distribution = "/usr/local/src/CPAN/build/autorequire-0.08-A3c4FR";
my $distribution = "/usr/local/src/CPAN/build/Attribute-Tie-0.01-HxCk5z";

#my $checkcmd = "env PERL5LIB=$perldir/lib make test";
#my $checkcmd = "env PERL5LIB=$perldir/lib $perldir/perl -Mblib t/03_autodynaload_hook.t";
my $checkcmd = "env PERL5LIB=$perldir/lib $perldir/perl -Mblib t/02-array.t";

$SIG{__WARN__} = sub {
    print @_;
    system "xterm-conf", "-f", "-title", "@_";
};

$SIG{INT} = sub {
    warn "User aborted ...";
    exit 257;
};

my $err = 125; # git-bisect skip
RUN: {
    warn "configure.gnu";
    system('./configure.gnu', '-Dcc=ccache cc') == 0 or last RUN;
    warn "make";
    system('make', '-j4') == 0 or last RUN;
    warn "chdir to cpan dist";
    chdir $distribution or do {
	$err = 256;
	warn "Cannot chdir to $distribution: $!";
	last RUN;
    };
    warn "perl Makefile.PL";
    system("$perldir/perl", "-I$perldir/lib", "Makefile.PL") == 0 or last RUN;
    warn "make $distribution";
    system("make") == 0 or last RUN;
    warn "check command: $checkcmd";
    system($checkcmd);
    $err = $?==0 ? 0 : 1;
    warn "error code is $err";
}
warn "final cleanup";
chdir $perldir or do {
    warn "Cannot chdir back to $perldir: $!";
    exit 256;
};
system('make', 'distclean');
exit $err;

__END__