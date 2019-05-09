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

my ($frontend, $backend);

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

# Prepare directory for frontend, store name in global variable $frontend.
sub setup_frontend {

    # Create working directory.
    $frontend = tempdir(CLEANUP => 1);

    # Create directories for queues.
    system "mkdir -p $frontend/$_" for qw(waiting inprogress finished);

    # Make worker scripts available.
    symlink("$API_DIR/bin", 'bin');
}

# Prepare directory for backend, prepare fake versions of ssh and scp.
# Return name of directory in global variable $backend.
sub setup_backend {

    # Create working directory, set as home directory and as current directory.
    $backend = tempdir(CLEANUP => 1);
    $ENV{HOME} = $backend;
    chdir $backend;

    # Install versions of ssh and scp that use bash and cp instead.
    mkdir('my-ssh');
    write_file("my-ssh/ssh", <<"END");
#!/bin/sh
shift		# ignore name of remote host
if [ \$# -gt 0 ] ; then
    sh -c "cd $frontend; \$*"
else
    sh -s -c "cd $frontend"
fi
END
    write_file("my-ssh/scp", <<"END");
#!/bin/sh
replace () { echo \$1 | sed -E 's,^[^:]+:,$frontend/,'; }
FROM=\$(replace \$1)
TO=\$(replace \$2)
cp \$FROM \$TO
END
    system "chmod a+x my-ssh/*";
    $ENV{PATH} = "$backend/my-ssh:$ENV{PATH}";
}

sub setup_netspoc {
    my ($in) = @_;

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
    chdir $backend;
    system 'rm -r import';
    system 'cvs -Q checkout netspoc';

    # Create config file .netspoc-approve for newpolicy
    mkdir('policydb');
    mkdir('lock');
    write_file('.netspoc-approve', <<"END");
netspocdir = $backend/policydb
lockfiledir = $backend/lock
END

    # Create files for Netspoc-Approve and create compile.log file.
    system 'newpolicy.pl >/dev/null 2>&1';
}

sub add_job {
    my ($job) = @_;
    local $ENV{HOME} = $frontend;

    my $stdin = encode_json($job);
    my $stderr;
    my $stdout;
    run3('bin/add-job', \$stdin, \$stdout, \$stderr);

    # Child was stopped by signal.
    die if $? & 127;

    my $status = $? >> 8;
    $status == 0 or BAIL_OUT "Unexpected error with job $job";
    return $stdout;
}

# Get job status in text form:
# First line:     STATUS
# Optional lines: error message
sub job_status {
    my ($id) = @_;
    local $ENV{HOME} = $frontend;
    my $json = `bin/job-status $id`;
    my $hash = decode_json $json;
    my $result = $hash->{status};
    if (my $msg = $hash->{message}) {
        $result .= "\n$msg";
    }
    return $result;
}

# Wait for results of background job.
sub wait_job {
    my ($id) = @_;
    my $path = "$frontend/finished/$id";
    while (1) {
        last if -f $path;
        sleep 1;
    }
}

# Process queue in background with new process group.
sub start_queue {
    my $pid = fork();
    if (0 == $pid) {
        setpgrp(0, 0);
        exec "bin/process-queue";
        die "exec failed: $!\n";
    }
    $pid or die "fork failed: $!\n";
    return $pid;
}

# Stop process group, i.e. background job with all its children.
sub stop_queue {
    my ($pid) = @_;
    kill 'TERM', -$pid;
}

sub check_status {
    my ($id, $expected, $title) = @_;
    my $status = job_status($id);
    eq_or_diff($status, $expected, $title);
}


setup_frontend();
setup_backend();
setup_netspoc(<<'END');
-- topology
network:a = { ip = 10.1.1.0/24; } # Comment
END

my $job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        changeID => 'CRQ00001234',
    }};

my $id1 = add_job($job);
my $id2 = add_job($job);

check_status($id1, 'WAITING', 'Job 1 waiting, no worker');
check_status($id2, 'WAITING', 'Job 2 waiting, no worker');

start_queue();

my $id3 = add_job({
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_5',
        ip      => '10.1.1.5',
        changeID => 'CRQ000012345',
    }});

check_status($id1, 'INPROGRESS', 'Job 1 in progress');
check_status($id2, 'WAITING', 'Job 2 still waiting');
check_status($id3, 'WAITING', 'New job 3 waiting');
check_status(99, 'UNKNOWN', 'Unknown job 99');

wait_job($id3);

check_status($id1, 'FINISHED', 'Job 1 success');
check_status($id2, <<'END', 'Job 2 with errors');
ERROR
Netspoc failed:
Error: Duplicate definition of host:name_10_1_1_4 in netspoc/topology
Error: Duplicate IP address for host:name_10_1_1_4 and host:name_10_1_1_4
Aborted with 2 error(s)
END
check_status($id3, 'FINISHED', 'Job 3 success');

############################################################
done_testing;
