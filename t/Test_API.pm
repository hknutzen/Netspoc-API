package Test_API;

use strict;
use warnings;
use Test::More;
use File::Spec::Functions qw/ file_name_is_absolute splitpath catdir catfile /;
use File::Path 'make_path';
use File::Temp qw/ tempdir /;
use IPC::Run3;

our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(write_file prepare_dir setup_netspoc run);

sub write_file {
    my($name, $data) = @_;
    my $fh;
    open($fh, '>', $name) or die "Can't open $name: $!\n";
    print($fh $data) or die "$!\n";
    close($fh);
}

# Fill $dir with files from $input.
# $input consists of one or more blocks.
# Each block is preceeded by a single line
# starting with one or more of dashes followed by a filename.
sub prepare_dir {
    my($dir, $input) = @_;
    my $delim  = qr/^-+[ ]*(\S+)[ ]*\n/m;
    my @input = split($delim, $input);
    my $first = shift @input;

    # Input doesn't start with filename.
    if ($first) {
        BAIL_OUT("Missing filename before first input block");
        return;
    }
    while (@input) {
        my $path = shift @input;
        my $data = shift @input;
        if (file_name_is_absolute $path) {
            BAIL_OUT("Unexpected absolute path '$path'");
            return;
        }
        my (undef, $dir_part, $file) = splitpath($path);
        my $full_dir = catdir($dir, $dir_part);
        make_path($full_dir);
        my $full_path = catfile($full_dir, $file);
        write_file($full_path, $data);
    }
}

sub setup_netspoc {
    my ($dir, $in) = @_;

    # Prevent warnings from git.
    system 'git config --global user.name "Test User"';
    system 'git config --global user.email ""';
    system 'git config --global init.defaultBranch master';
    system 'git config --global pull.rebase true';

    my $tmp = "$dir/tmp-git";
    mkdir $tmp;
    prepare_dir($tmp, $in);
    chdir $tmp;
    # Initialize git repository.
    system 'git init --quiet';
    system 'git add .';
    system 'git commit -m initial >/dev/null';
    chdir $dir;
    # Checkout into bare directory
    my $bare = "$dir/netspoc.git";
    system "git clone --quiet --bare $tmp $bare";
    system "rm -rf $tmp";
    $ENV{NETSPOC_GIT} = "file://$bare";
    # Checkout into directory 'netspoc'
    system "git clone --quiet $bare netspoc";

    # Create config file .netspoc-approve for newpolicy
    mkdir('policydb');
    mkdir('lock');
    write_file('.netspoc-approve', <<"END");
netspocdir = $dir/policydb
lockfiledir = $dir/lock
netspoc_git = file://$bare
END

    # Create files for Netspoc-Approve and create compile.log file.
    system 'newpolicy.pl >/dev/null 2>&1';
}

sub run {
    my ($cmd) = @_;

    my $stderr;
    run3($cmd, \undef, undef, \$stderr);

    # Child was stopped by signal.
    die if $? & 127;

    my $status = $? >> 8;
    my $success = $status == 0;
    return($success, $stderr);
}

1;
