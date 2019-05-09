package Test_API;

use strict;
use warnings;
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

    # Initialize empty CVS repository.
    my $cvs_root = tempdir(CLEANUP => 1);
    $ENV{CVSROOT} = $cvs_root;
    system "cvs init";

    # Create initial netspoc files and put them under CVS control.
    mkdir('import');
    prepare_dir('import', $in);
    chdir 'import';
    system 'cvs -Q import -m start netspoc vendor version';
    chdir $dir;
    system 'rm -r import';
    system 'cvs -Q checkout netspoc';

    # Create config file .netspoc-approve for newpolicy
    mkdir('policydb');
    mkdir('lock');
    write_file('.netspoc-approve', <<"END");
netspocdir = $dir/policydb
lockfiledir = $dir/lock
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
