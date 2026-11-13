#!/usr/bin/perl
# Загружает MediaRemoteAdapter.dylib внутри системного perl и вызывает функцию из него.
# У /usr/bin/perl остался доступ к MediaRemote на macOS 15.4+, у сторонних приложений — нет.
# Использование: perl mediaremote-adapter.pl <путь к dylib> adapter_stream
use strict;
use warnings;
use DynaLoader;

my ($lib, $func) = @ARGV;
die "usage: mediaremote-adapter.pl <dylib> <function>\n" unless defined $lib && defined $func;

my $handle = DynaLoader::dl_load_file($lib, 0)
    or die "dl_load_file failed: " . (DynaLoader::dl_error() // '') . "\n";
my $sym = DynaLoader::dl_find_symbol($handle, $func)
    or die "dl_find_symbol failed: " . (DynaLoader::dl_error() // '') . "\n";
my $entry = DynaLoader::dl_install_xsub("main::adapter_entry", $sym)
    or die "dl_install_xsub failed\n";

&$entry();
