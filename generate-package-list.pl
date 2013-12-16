#!/usr/bin/perl

$| = 1;
use warnings;
use strict;
use locale; # for sort
use Cwd qw(abs_path);
use File::Basename;

use File::Temp qw(tempdir);
use Getopt::Std;
use AptPkg::Config '$_config';
use AptPkg::Cache;

my $path = dirname(abs_path($0));
our ($opt_n, $opt_l, $opt_d) = (0, 
				$path . "/lists",
				$path);

getopts('nl:d:');

sub debug {
    if ($opt_n) {
	print join(' ', 'D:', @_, "\n");
    }
}

sub run_command {
    my @cmd = @_;
    debug("Running: " . join(' ', @cmd));
    my $rv = system(@cmd);
    if ($rv == -1) {
	die "Failed to execute command: $!\n";
    } elsif ($rv != 0) {
	die "$cmd[0] died with status: " . ($? >> 8) . "\n";
    }
}

my $codename = `lsb_release -sc`;
die "Can't determine codename" unless ($? == 0);
chomp($codename);

(-d $opt_l) || die "$opt_l is not a directory";
(-d $opt_d) || die "$opt_d is not a directory";

print "Using lists in $opt_l\nWriting output files to $opt_d\n";

my $lsbrelease = `lsb_release -is`;
chomp $lsbrelease;
debug("lsb release: $lsbrelease");
my $chdist_dir = tempdir(CLEANUP=>1);
if ($lsbrelease eq 'Ubuntu') {
    my $mirrorhost = 'localhost:9999';
    if (exists($ENV{'MIRRORHOST'})) {
	$mirrorhost = $ENV{'MIRRORHOST'};
    }
    debug("Ubuntu detected.");
    run_command('chdist', '--data-dir', $chdist_dir, 'create', $codename,
		'http://' . $mirrorhost . '/ubuntu', $codename,
		'main', 'restricted', 'universe', 'multiverse');
    run_command('chdist', '--data-dir', $chdist_dir,
		'apt-get', $codename, 'update');
    $ENV{'APT_CONFIG'} = join('/', $chdist_dir, $codename, 'etc/apt/apt.conf');
}

debug("Initializing APT cache");
# Initialize the APT configuration
$_config->init;
my $cache = AptPkg::Cache->new;
my $policy = $cache->policy;

my %packages = ();
my %depends = ();

open(COMMON, join('/', $opt_l, 'common')) || die "Can't open $opt_l/common";
debug("Reading 'common' file...");
while (<COMMON>) {
    chomp;
    s/^\s+//;
    s/\s+$//;
    next if /^#/;
    next unless /\S/;
    if (/^-/) {
	die "Syntax error: package exclusion in the common file, line $.";
    } 
    if (/^(\S+) \| (\S+)$/) {
	debug("Examining conditional line: $_");
	foreach my $p ($1, $2) {
	    debug("Checking for $p");
	    if ($cache->{$p} && $cache->{$p}->{VersionList}) {
		debug("Adding $p to dependencies");
		$packages{$p} = 1;
		last;
	    }
	}
	unless (exists($packages{$1}) || exists($packages{$2})) {
	    warn "Could not satisfy conditional dependency: $_!";
	}
    } elsif (/^(\S+)(?: (\S+))+$/) {
	my ($pkg1, @rest) = (split(' ', $_));
	$packages{$pkg1} = 1;
	$depends{$pkg1} = \@rest;
    } elsif (/^\?(\S+)$/) {
	debug("Adding $1 to recommendations");
	$packages{$1} = 2;
    } else {
	debug("Adding $_ to dependencies");
	$packages{$_} = 1;
    }
}
close(COMMON);

if (-f join('/', $opt_l, $codename)) {
    open(DIST, join('/', $opt_l, $codename)) || die "Can't open $opt_l/$codename";
    debug("Reading distro-specific file");
    while (<DIST>) {
	chomp;
	s/^\s+//;
	s/\s+$//;
	next if /^#/;
	next unless /\S/;
	if (/^-(\S+)$/) {
	    if (exists($packages{$1})) {
		debug("Deleting $1 from package list.");
		delete($packages{$1});
	    } else {
		warn("Package $1 is not in package list, so can't remove it.");
	    }
	} elsif (/^\?(\S+)$/) {
	    debug("Adding $1 to recommendations");
	    $packages{$1} = 2;
	} else {
	    debug("Adding $_ to dependencies");
	    $packages{$_} = 1;
	}
    }
    close(DIST);
} else {
    print "Note: No distro-specific file found.\n";
}

foreach my $pkgname (sort(keys(%packages))) {
    my $pkg = $cache->{$pkgname};
    if (! $pkg) {
	debug("Removing $pkgname as it can't be found in the APT cache.");
	delete($packages{$pkgname});
	if (exists($depends{$pkgname})) {
	    foreach (@{$depends{$pkgname}}) {
		debug("Removing $_ because we removed $pkgname");
		delete($packages{$_});
	    }
	}
	next;
    }
    if (! $pkg->{VersionList}) {
	debug("Removing $pkgname as it has no version candidate");
	delete($packages{$pkgname});
	if (exists($depends{$pkgname})) {
	    foreach (@{$depends{$pkgname}}) {
		debug("Removing $_ because we removed $pkgname");
		delete($packages{$_});
	    }
	}
	next;
    }
}

my @recs = ();
my @deps = ();
foreach my $p (sort(keys(%packages))) {
    if ($packages{$p} == 2) {
	push @recs, $p;
    } else {
	push @deps, $p;
	if (exists($depends{$p})) {
	    foreach (@{$depends{$p}}) {
		debug("Adding $_ because we added $p");
		push @deps, $_;
	    }
	}
    }
}
open(SUBSTVARS, '>', join('/', $opt_d, 'thirdparty.substvars')) || die "Can't write to $opt_d/thirdparty.substvars";
printf SUBSTVARS "debathena-thirdparty-depends=%s\n", join(',', @deps);
printf SUBSTVARS "debathena-thirdparty-recommends=%s\n", join(',', @recs);
close(SUBSTVARS);
print "Done.\n";
exit 0;
