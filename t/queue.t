#!/usr/bin/env perl

use strict;
use warnings;
use File::Temp qw/ tempdir /;
use IPC::Run3;
use JSON;
use Test::More;
use Test::Differences;
use lib 't';
use Test_API qw(write_file prepare_dir setup_netspoc);

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


# Prepare directory for frontend, store name in global variable $frontend.
sub setup_frontend {

    # Create working directory.
    $frontend = tempdir(CLEANUP => 1);

    # Create directories for queues.
    system "mkdir -p $frontend/$_" for qw(waiting inprogress finished);

    # Make worker scripts available.
    symlink("$API_DIR/bin", "$frontend/bin");
}

# Prepare directory for backend, prepare fake versions of ssh and scp.
# Store name of directory in global variable $backend.
sub setup_backend {

    # Create working directory, set as home directory and as current directory.
    $backend = tempdir(CLEANUP => 1);
    $ENV{HOME} = $backend;
    chdir;

    # Install versions of ssh and scp that use sh and cp instead.
    mkdir('my-bin');
    write_file("my-bin/ssh", <<"END");
#!/bin/sh
shift		# ignore name of remote host
if [ \$# -gt 0 ] ; then
    sh -c "cd $frontend; \$*"
else
    sh -s -c "cd $frontend"
fi
END
    write_file("my-bin/scp", <<"END");
#!/bin/sh
replace () { echo \$1 | sed -E 's,^[^:]+:,$frontend/,'; }
FROM=\$(replace \$1)
TO=\$(replace \$2)
cp \$FROM \$TO
END
    system "chmod a+x my-bin/*";
    $ENV{PATH} = "$backend/my-bin:$ENV{PATH}";

    # Make worker scripts available.
    symlink("$API_DIR/bin", 'bin');
}

sub add_job {
    my ($job) = @_;
    local $ENV{HOME} = $frontend;
    chdir;

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
    chdir;

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
        chdir;
        exec "bin/process-queue localhost bin/cvs-worker";
        die "exec failed: $!\n";
    }
    $pid or die "fork failed: $!\n";
    return $pid;
}

# Stop process group, i.e. background job with all its children.
sub stop_queue {
    my ($pid) = @_;
    kill 'TERM', -$pid or BAIL_OUT "Can't kill"
}

sub check_status {
    my ($id, $expected, $title) = @_;
    my $status = job_status($id);
    eq_or_diff($status, $expected, $title);
}

sub check_log {
    my ($expected, $title) = @_;
    my $file = "$backend/log";

    # Ignore line with time stamp
    my $log = `grep -v '^Date: ' $file`;
    eq_or_diff($log, $expected, $title);
    system("rm $file; touch $file");
}

setup_frontend();
setup_backend();
system("touch $backend/log");
setup_netspoc($backend, <<'END');
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

my $pid = start_queue();

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

stop_queue($pid);

check_status($id3, 'FINISHED', 'Job 3 success, no worker');

check_log('', 'Empty log');

# Let "scp" fail
write_file("$backend/my-bin/scp", <<"END");
#!/bin/sh
echo "scp: can't connect" >&2
exit 1
END

my $id = add_job($job);
$pid = start_queue();
sleep 1;
check_log("scp: can't connect\n", 'scp failed');
stop_queue($pid);

# Let "ssh" fail
write_file("$backend/my-bin/ssh", <<"END");
#!/bin/sh
echo "ssh: can't connect" >&2
exit 1
END
$pid = start_queue();
sleep 1;
stop_queue($pid);
check_log("ssh: can't connect\n", 'ssh failed');

############################################################
done_testing;
