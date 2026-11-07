#!/usr/bin/perl
# Loads MediaRemoteHelper.dylib inside Apple's /usr/bin/perl and runs it.
#
# Why perl: since macOS 15.4, the private MediaRemote framework only returns
# system-wide Now Playing info to Apple-signed processes. /usr/bin/perl is one,
# and it can load our library via DynaLoader, so the library's MediaRemote
# calls are answered.
#
# Protocol: JSON lines on stdout, commands on stdin (see MediaRemoteHelper.m).
use strict;
use warnings;
use DynaLoader;

my $path = shift or die "usage: helper.pl /path/to/MediaRemoteHelper.dylib\n";
my $lib = DynaLoader::dl_load_file($path, 0)
  or die "Cannot load $path: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($lib, "mrh_run")
  or die "mrh_run not found in $path\n";
DynaLoader::dl_install_xsub("main::mrh_run", $sym)->();
