#!/usr/bin/env perl

use strict;
use warnings;
use File::Temp qw/ tempdir /;
use IPC::Run3;
use JSON;
use Plack::Test;
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

    # Make worker scripts available.
    symlink("$API_DIR/frontend", "$frontend/bin");
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
#!/bin/bash
getopts q OPTION && shift
shift		# ignore name of remote host
if [ \$# -gt 0 ] ; then
    sh -c "cd $frontend; \$*"
else
    sh -s -c "cd $frontend"
fi
END
    write_file("my-bin/scp", <<"END");
#!/bin/bash
getopts q OPTION && shift
replace () { echo \$1 | sed -E 's,^[^:]+:,$frontend/,'; }
FROM=\$(replace \$1)
TO=\$(replace \$2)
cp \$FROM \$TO
END
    system "chmod a+x my-bin/*";
    $ENV{PATH} = "$backend/my-bin:$ENV{PATH}";

    # Make worker scripts available.
    symlink("$API_DIR/backend", 'bin');
}

sub change_netspoc {
    my ($in) = @_;
    local $ENV{HOME} = $backend;
    chdir;
    prepare_dir('netspoc', $in);
    system "cvs -Q commit -m test netspoc >/dev/null";
    system 'newpolicy.pl >/dev/null 2>&1';
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
    $status == 0 or BAIL_OUT "Unexpected error with job: $stdin\n$stderr";
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

## Setup WWW server for testing.
my $server;

sub setup_www {
    local $ENV{HOME} = $frontend;
    chdir;
    my $hash = `echo 'test' | bin/salted_hash`;
    my $conf_data = {
        user => { test => { hash => $hash, } }
    };
    write_file('config', encode_json($conf_data));

    my $app;

    # Load psgi file into separate namespace to avoid name conflicts.
    package WWW {
        $app = do './bin/api.psgi' or die "Couldn't parse PSGI file: $@";
    }
    #$Plack::Test::Impl = 'Server';
    $server = Plack::Test->create($app);
}

sub www_add_job {
    my ($job) = @_;
    local $ENV{HOME} = $frontend;
    chdir;
    my $req = HTTP::Request->new(
        'POST' => '/add-job',
        ['Content-Type' => 'application/json'],
        encode_json($job));
    my $res = $server->request($req);
    $res->is_success or BAIL_OUT $res->content;
    return decode_json($res->content)->{id};
}

sub www_job_status {
    my ($input) = @_;
    local $ENV{HOME} = $frontend;
    chdir;
    my $req = HTTP::Request->new(
        'POST' => '/job-status',
        ['Content-Type' => 'application/json'],
        encode_json($input));
    my $res = $server->request($req);
    $res->is_success or BAIL_OUT $res->content;
    my $json = decode_json($res->content);
    my ($result, $msg) = @{$json}{qw(status message)};
    if ($msg) {
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

sub www_check_status {
    my ($input, $expected, $title) = @_;
    my $status = www_job_status($input);
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

sub check_cvs_log {
    my ($file, $expected, $title) = @_;
    local $ENV{HOME} = $backend;
    chdir;
    my $log =
        `cvs -q log netspoc/$file|tail -n +15|egrep -v '^date'|head -n -8`;
    eq_or_diff($log, $expected, $title);
}

setup_frontend();
setup_www();
setup_backend();
system("touch $backend/log");
setup_netspoc($backend, <<'END');
-- topology
network:a = { ip = 10.1.1.0/24; } # Comment
END

my $id;

sub add_host {
    my ($i) = @_;
    $id = add_job({
        method => 'create_host',
        params => {
            network => 'a',
            name    => "name_10_1_1_$i",
            ip      => "10.1.1.$i",
            crq     => "CRQ0000$i",
        },
                  });
}

for my $i (1 .. 7) {
    add_host($i)
}

my $pid = start_queue();
wait_job($id);
check_cvs_log('topology', <<'EOF', 'Multiple files in one CVS commit');
revision 1.2
API jobs: 1 2 3 4 5 6 7
CRQ00001 CRQ00002 CRQ00003 CRQ00004 CRQ00005 CRQ00006 CRQ00007
EOF

stop_queue($pid);
for my $i (8 .. 12) {
    add_host($i)
}
add_host(12); # Duplicate IP
for my $i (13 .. 14) {
    add_host($i)
}
$pid = start_queue();

wait_job($id);
check_cvs_log('topology', <<'EOF', 'Multiple files with one error');
revision 1.5
API jobs: 14 15
CRQ000013 CRQ000014
----------------------------
revision 1.4
API job: 12
CRQ000012
----------------------------
revision 1.3
API jobs: 8 9 10 11
CRQ000010 CRQ000011 CRQ00008 CRQ00009
----------------------------
revision 1.2
API jobs: 1 2 3 4 5 6 7
CRQ00001 CRQ00002 CRQ00003 CRQ00004 CRQ00005 CRQ00006 CRQ00007
EOF

# Fresh start with cleaned up topology and stopped queue.
stop_queue($pid);
change_netspoc(<<'END');
-- topology
network:a = { ip = 10.1.1.0/24; } # Comment
END

my $job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        crq     => 'CRQ00001234',
    },
};

my $id1 = add_job($job);

# Add identical job, will fail
my $id2 = www_add_job({ %$job, user => 'test', pass => 'test', });

check_status($id1, 'WAITING', 'Job 1 waiting, no worker');
check_status($id2, 'WAITING', 'Job 2 waiting, no worker');

$pid = start_queue();
sleep 1;

my $id3 = add_job({
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_5',
        ip      => '10.1.1.5',
        crq     => 'CRQ000012345',
    },
    user => 'test',
    pass => 'test',
    });

check_status($id1, 'INPROGRESS', 'Job 1 in progress');
check_status($id2, 'INPROGRESS', 'Job 2 in progress');
check_status($id3, 'WAITING', 'New job 3 waiting');
check_status(99, 'UNKNOWN', 'Unknown job 99');

wait_job($id3);

www_check_status(
    { id => $id1, user => 'test', pass => 'test' },
    'DENIED', 'Can\'t access job 1 from WWW');

check_status($id1, 'FINISHED', 'Job 1 success');
www_check_status(
    { id => $id2, user => 'test', pass => 'test' },
    <<'END', 'WWW job 2 with errors');
ERROR
Netspoc failed:
Error: Duplicate definition of host:name_10_1_1_4 in netspoc/topology
Error: Duplicate IP address for host:name_10_1_1_4 and host:name_10_1_1_4
Aborted with 2 error(s)
END

www_check_status(
    { id => $id3, user => 'test', pass => 'test' },
    'FINISHED', 'Job 3 success, no worker');

check_log('', 'Empty log');

# Check in bad content to repository, so processing stops.
change_netspoc(<<'END');
-- topology
network:a = { ip = 10.1.1.0/24; }  BAD SYNTAX
END
$id = add_job($job);
sleep 1;
check_status($id, 'INPROGRESS', 'Wait on bad repository');
sleep 2;
check_status($id, 'INPROGRESS', 'Still wait on bad repository');

# Check in other bad content to repository; processing must still stop.
change_netspoc(<<'END');
-- topology
network:a = { ip = 10.1.1.0/24; }  STILL BAD SYNTAX
END
sleep 1;
check_status($id, 'INPROGRESS', 'Wait on changed bad repository');

# Fix bad content.
change_netspoc(<<'END');
-- topology
network:a = { ip = 10.1.1.0/24; } # Comment
END
wait_job($id);
check_status($id, 'FINISHED', 'Success after fixing repository');

stop_queue($pid);

# Let "scp" fail
write_file("$backend/my-bin/scp", <<"END");
#!/bin/sh
echo "scp: can't connect" >&2
exit 1
END

$id = add_job($job);
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
