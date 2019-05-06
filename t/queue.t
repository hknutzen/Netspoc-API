#!/usr/bin/env perl

use strict;
use warnings;
use File::Temp qw/ tempfile tempdir /;
use File::Spec::Functions qw/ file_name_is_absolute splitpath catdir catfile /;
use File::Path 'make_path';
use IPC::Run3;
use JSON;
use Test::More;
use Test::Differences;

# Set up PATH and PERL5LIB, such that files and libraries are searched
# in $HOME/Netspoc, $HOME/Netspoc-Approve
my $NETSPOC_DIR = "$ENV{HOME}/Netspoc";
my $APPROVE_DIR = "$ENV{HOME}/Netspoc-Approve";
$ENV{PATH} = "$NETSPOC_DIR/bin:$APPROVE_DIR/bin:$ENV{PATH}";
{
    my $lib = "$NETSPOC_DIR/lib:$APPROVE_DIR/lib";
    if (my $old = $ENV{PERL5LIB}) {
        $lib .= ":$old";
    }
    $ENV{PERL5LIB} = $lib;
}

my $API_DIR = "$ENV{HOME}/Netspoc-API";

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

    # Input does't start with filename.
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

# Prepare directory for frontend, return name of directory.
sub setup_frontend {

    # Create working directory.
    my $home_dir = tempdir(CLEANUP => 1);

    # Create directories for queues.
    system "mkdir -p $home_dir/$_" for qw(waiting inprogress finished);

    return ($home_dir);
}

# Prepare directory for backend, prepare fake versions of ssh and scp.
# Return name of directory.
sub setup_backend {
    my ($frontend_dir) = @_;

    # Create working directory, set as home directory and as current directory.
    my $home_dir = tempdir(CLEANUP => 1);
    $ENV{HOME} = $home_dir;
    chdir $home_dir;

    # Install versions of ssh and scp that use bash and cp instead.
    mkdir('my-ssh');
    write_file("my-ssh/ssh", <<"END");
#!/bin/sh
shift		# ignore name of remote host
if [ \$# -gt 0 ] ; then
    sh -c "cd $frontend_dir; \$*"
else
    sh -s -c "cd $frontend_dir"
fi
END
    write_file("my-ssh/scp", <<"END");
#!/bin/sh
replace () { echo \$1 | sed -E 's,^[^:]+:,$frontend_dir/,'; }
FROM=\$(replace \$1)
TO=\$(replace \$2)
cp \$FROM \$TO
END
    system "chmod a+x my-ssh/*";
    $ENV{PATH} = "$home_dir/my-ssh:$ENV{PATH}";

    return $home_dir;
}

sub setup_netspoc {
    my ($in, $home_dir) = @_;

    # Initialize empty CVS repository.
    my $cvs_root = tempdir(CLEANUP => 1);
    $ENV{CVSROOT} = $cvs_root;
    system "cvs init";

    # Make worker scripts available.
    symlink("$API_DIR/bin", 'bin');

    # Create initial netspoc files and put them under CVS control.
    mkdir('import');
    prepare_dir('import', $in);
    chdir 'import';
    system 'cvs -Q import -m start netspoc vendor version';
    chdir $home_dir;
    system 'rm -r import';
    system 'cvs -Q checkout netspoc';

    # Create config file .netspoc-approve for newpolicy
    mkdir('policydb');
    mkdir('lock');
    write_file('.netspoc-approve', <<"END");
netspocdir = $home_dir/policydb
lockfiledir = $home_dir/lock
END

    # Create files for Netspoc-Approve and create compile.log file.
    system 'newpolicy.pl >/dev/null 2>&1';
}

sub test_job {
    my ($in, $job) = @_;

    my ($frontend, $ssh_fd) = setup_frontend();
    my ($backend) = setup_backend($frontend);
    setup_netspoc($in, $backend);

    # Put job into queue
    write_file("$frontend/waiting/1", encode_json($job));

    # Process queue in background with new process group.
    my $pid = fork();
    if (0 == $pid) {
        setpgrp(0, 0);
        exec"bin/process-queue";
        die "exec failed: $!\n";
    }

    # Wait for results of background job.
    my $path = "$frontend/finished/1";
    while (1) {
        sleep 1;
        last if -f $path;
    }

    # Stop process group, i.e. background job with all its children.
    kill 'TERM', -$pid;

    my $finished = `cat $path`;
    return ($finished);
}

sub test_run {
    my ($title, $in, $job, $expected, %named) = @_;
    my($result) = test_job($in, $job, %named);
    eq_or_diff($result, $expected, $title);
}

my ($title, $in, $job, $out, $other);

############################################################
$title = 'Add host to known network';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24; } # Comment
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        changeID => 'CRQ00001234',
    }
};

$out = <<'END';
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host to unknown network';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24; } # Comment
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'unknown',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        changeID => 'CRQ00001234',
    }
};

$out = <<'END';
Error: Can't find 'network:unknown' in netspoc
END

test_run($title, $in, $job, $out);

############################################################
done_testing;
