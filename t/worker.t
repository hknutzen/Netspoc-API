#!/usr/bin/env perl

use strict;
use warnings;
use File::Temp qw/ tempdir /;
use JSON;
use Test::More;
use Test::Differences;
use lib 't';
use Test_API qw(write_file prepare_dir run);

# Set up PATH and PERL5LIB, such that files and libraries are searched
# in $HOME/Netspoc.
my $NETSPOC_DIR = "$ENV{HOME}/Netspoc";
$ENV{PATH} = "$NETSPOC_DIR/bin:$ENV{PATH}";
{
    my $lib = "$NETSPOC_DIR/lib";
    if (my $old = $ENV{PERL5LIB}) {
        $lib .= ":$old";
    }
    $ENV{PERL5LIB} = $lib;
}

my $API_DIR = "$ENV{HOME}/Netspoc-API";

sub test_worker {
    my ($in, $job, %named) = @_;

    # Create working directory, set as home directory and as current directory.
    my $home_dir = tempdir(CLEANUP => 1);
    $ENV{HOME} = $home_dir;
    chdir $home_dir;

    # Make worker scripts available.
    symlink("$API_DIR/bin", 'bin');

    # Create initial netspoc files.
    mkdir('netspoc');
    prepare_dir('netspoc', $in);

    # Make copy for later diff.
    system "cp -r netspoc unchanged";

    write_file('job', encode_json($job));

    # Apply changes.
    my ($success, $stderr) = run('bin/worker job');
    if (not $success) {
        return ($success, $stderr);
    }

    # Run Netspoc.
    ($success, $stderr) = run('netspoc -q netspoc code');

    # Handle warnings as errors.
    $success = 0 if $stderr;

    # Collect and simplify diff.
    # Show diff even if Netspoc failed.
    #--- unchanged/owner       15 Apr 2019 07:56:13 -0000
    #+++ netspoc/owner       15 Apr 2019 13:27:38 -0000
    #@@ -5,7 +5,7 @@
    my $diff = `diff -u -r unchanged netspoc`;
    $diff =~ s/^diff -u -r unchanged\/[^ ]* //mg;
    $diff =~ s/--- .*\n\+\+\+ .*\n//mg;

    # Combine messages from Netspoc and diff into one message,
    # separated by "---".
    if ($stderr) {
        $diff = "$stderr---\n$diff";
    }
    return ($success, $diff);
}

sub test_run {
    my ($title, $in, $job, $expected, %named) = @_;
    my($success, $result) = test_worker($in, $job, %named);
    if (!$success) {
        diag("Unexpected failure:\n$result");
        fail($title);
        return;
    }
    eq_or_diff($result, $expected, $title);
}

sub test_err {
    my ($title, $in, $job, $expected, %named) = @_;
    my ($success, $stderr) = test_worker($in, $job, %named);
    if ($success) {
        diag('Unexpected success');
        diag($stderr) if $stderr;
        fail($title);
        return;
    }
    eq_or_diff($stderr, $expected, $title);
}

my ($title, $in, $job, $out);

############################################################
$title = 'Invalid empty job';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
END

$job = {};

$out = <<'END';
Error: Unknown method 'null'
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Invalid job without params';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
END

$job = {
    method => 'AddToGroup',
};

$out = <<'END';
Error: Can't find 'group:' in netspoc
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add to multi block group (1)';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24;
 host:h_10_1_1_4 = { ip = 10.1.1.4; }
 host:h_10_1_1_5 = { ip = 10.1.1.5; }
 host:h_10_1_1_44 = { ip = 10.1.1.44; }
}
network:n2 = { ip = 10.1.2.0/24;
 host:h_10_1_2_5 = { ip = 10.1.2.5; }
 host:h_10_1_2_6 = { ip = 10.1.2.6; }
 host:h_10_1_2_7 = { ip = 10.1.2.7; }
 host:h_10_1_2_9 = { ip = 10.1.2.9; }
}
network:n3 = { ip = 10.1.3.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
 interface:n3 = { ip = 10.1.3.1; hardware = n3; }
 interface:n4 = { ip = 10.1.4.1; hardware = n4; }
}

network:n4 = { ip = 10.1.4.0/24; }
-- group
group:g1 =
 host:h_10_1_1_4,
 host:h_10_1_1_44,
 network:n3,
 host:h_10_1_2_6,
 host:h_10_1_2_9,
;
-- service
service:s1 = {
 user = group:g1;
 permit src = user; dst = network:n4; prt = tcp 80;
}
END

$job = {
    method => 'AddToGroup',
    params => {
        name   => 'g1',
        object => 'host:h_10_1_2_7',
    }
};

$out = <<'END';
netspoc/group
@@ -3,5 +3,6 @@
  host:h_10_1_1_44,
  network:n3,
  host:h_10_1_2_6,
+ host:h_10_1_2_7,
  host:h_10_1_2_9,
 ;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add to multi block group (2)';
############################################################

$job = {
    method => 'AddToGroup',
    params => {
        name   => 'g1',
        object => 'host:h_10_1_2_5',
    }
};

$out = <<'END';
netspoc/group
@@ -2,6 +2,7 @@
  host:h_10_1_1_4,
  host:h_10_1_1_44,
  network:n3,
+ host:h_10_1_2_5,
  host:h_10_1_2_6,
  host:h_10_1_2_9,
 ;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add to multi block group (3)';
############################################################

$job = {
    method => 'AddToGroup',
    params => {
        name   => 'g1',
        object => 'host:h_10_1_1_5',
    }
};

$out = <<'END';
netspoc/group
@@ -1,5 +1,6 @@
 group:g1 =
  host:h_10_1_1_4,
+ host:h_10_1_1_5,
  host:h_10_1_1_44,
  network:n3,
  host:h_10_1_2_6,
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add name without IP to group';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
 interface:n3 = { ip = 10.1.3.1; hardware = n3; }
}

network:n3 = { ip = 10.1.3.0/24; }
-- group
group:g1 =
 interface:r1.n1,
 network:n1,
 interface:r1.n2,
;
-- service
service:s1 = {
 user = group:g1;
 permit src = user; dst = network:n3; prt = tcp 80;
}
END

$job = {
    method => 'AddToGroup',
    params => {
        name   => 'g1',
        object => 'network:n2',
    }
};

$out = <<'END';
netspoc/group
@@ -1,5 +1,6 @@
 group:g1 =
  interface:r1.n1,
  network:n1,
+ network:n2,
  interface:r1.n2,
 ;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add to empty group';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; host:h4 = { ip = 10.1.1.4; } }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}

network:n2 = { ip = 10.1.2.0/24; }
-- group
group:g1 = ;
-- service
service:s1 = {
 user = group:g1;
 permit src = user; dst = network:n2; prt = tcp 80;
}
END

$job = {
    method => 'AddToGroup',
    params => {
        name   => 'g1',
        object => 'host:h4',
    }
};

$out = <<'END';
netspoc/group
@@ -1 +1,3 @@
-group:g1 = ;
+group:g1 =
+ host:h4,
+;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Added owner exists';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
-- owner
owner:a = {
 admins = a@example.com;
}
END

$job = {
    method => 'CreateOwner',
    params => {
        name    => 'a',
        admins  => [ 'a@example.com' ],
    }
};

$out = <<'END';
Error: Duplicate definition of owner:a in netspoc/owner
Aborted with 1 error(s)
---
netspoc/owner
@@ -1,3 +1,9 @@
 owner:a = {
  admins = a@example.com;
 }
+owner:a = {
+ admins =
+	a@example.com,
+	;
+}
+
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Added owner exists, ok';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
-- owner
owner:a = {
 admins = a@example.com;
}
END

$job = {
    method => 'CreateOwner',
    params => {
        name    => 'a',
        admins  => [ 'a@example.com' ],
        ok_if_exists => 1,
        changeID => 'CRQ00001234',
    }
};

$out = <<'END';
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Added owner exists, but not found';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
-- owner
owner:a
= {
 admins = a@example.com;
}
END

$job = {
    method => 'CreateOwner',
    params => {
        name    => 'a',
        admins  => [ 'a@example.com' ],
        ok_if_exists => 1,
    }
};

$out = <<'END';
Error: Duplicate definition of owner:a in netspoc/owner
Aborted with 1 error(s)
---
netspoc/owner
@@ -2,3 +2,9 @@
 = {
  admins = a@example.com;
 }
+owner:a = {
+ admins =
+	a@example.com,
+	;
+}
+
END

test_err($title, $in, $job, $out);

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
netspoc/topology
@@ -1 +1,3 @@
-network:a = { ip = 10.1.1.0/24; } # Comment
+network:a = { ip = 10.1.1.0/24; # Comment
+ host:name_10_1_1_4			= { ip = 10.1.1.4; }
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, insert sorted';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24;
 # Comment1
 host:name_10_1_1_2 = { ip = 10.1.1.2; }
 # Comment2
 # Comment3
 host:name_10_1_1_5 = { ip = 10.1.1.5; }
 host:name_10_1_1_6 = { ip = 10.1.1.6; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
netspoc/topology
@@ -1,6 +1,7 @@
 network:a = { ip = 10.1.1.0/24;
  # Comment1
  host:name_10_1_1_2 = { ip = 10.1.1.2; }
+ host:name_10_1_1_4			= { ip = 10.1.1.4; }
  # Comment2
  # Comment3
  host:name_10_1_1_5 = { ip = 10.1.1.5; }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, same name';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24;
 host:name_10_1_1_4 = { ip = 10.1.1.4; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Error: Duplicate definition of host:name_10_1_1_4 in netspoc/topology
Error: Duplicate IP address for host:name_10_1_1_4 and host:name_10_1_1_4
Aborted with 2 error(s)
---
netspoc/topology
@@ -1,3 +1,4 @@
 network:a = { ip = 10.1.1.0/24;
  host:name_10_1_1_4 = { ip = 10.1.1.4; }
+ host:name_10_1_1_4			= { ip = 10.1.1.4; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, same IP';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24;
 host:other_10_1_1_4 = { ip = 10.1.1.4; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Error: Duplicate IP address for host:other_10_1_1_4 and host:name_10_1_1_4
Aborted with 1 error(s)
---
netspoc/topology
@@ -1,3 +1,4 @@
 network:a = { ip = 10.1.1.0/24;
  host:other_10_1_1_4 = { ip = 10.1.1.4; }
+ host:name_10_1_1_4			= { ip = 10.1.1.4; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, same IP unsorted';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24;
 host:name_10_1_1_5 = { ip = 10.1.1.5; }
 host:name_10_1_1_4 = { ip = 10.1.1.4; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Error: Duplicate definition of host:name_10_1_1_4 in netspoc/topology
Error: Duplicate IP address for host:name_10_1_1_4 and host:name_10_1_1_4
Aborted with 2 error(s)
---
netspoc/topology
@@ -1,4 +1,5 @@
 network:a = { ip = 10.1.1.0/24;
+ host:name_10_1_1_4			= { ip = 10.1.1.4; }
  host:name_10_1_1_5 = { ip = 10.1.1.5; }
  host:name_10_1_1_4 = { ip = 10.1.1.4; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Multiple networks at one line';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24; } network:b = { ip = 10.1.2.0/24; } # Comment
router:r1 = {
 interface:a;
 interface:b;
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Error: IP of host:name_10_1_1_4 doesn't match IP/mask of network:b
Aborted with 1 error(s)
---
netspoc/topology
@@ -1,4 +1,6 @@
-network:a = { ip = 10.1.1.0/24; } network:b = { ip = 10.1.2.0/24; } # Comment
+network:a = { ip = 10.1.1.0/24; } network:b = { ip = 10.1.2.0/24; # Comment
+ host:name_10_1_1_4			= { ip = 10.1.1.4; }
+}
 router:r1 = {
  interface:a;
  interface:b;
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host with owner';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = { admins = abc@example.com; }
network:a = { ip = 10.1.0.0/21; }
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
netspoc/topology
@@ -1,2 +1,4 @@
 owner:DA_abc = { admins = abc@example.com; }
-network:a = { ip = 10.1.0.0/21; }
+network:a = { ip = 10.1.0.0/21;
+ host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, redundant owner';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = { admins = abc@example.com; }
network:a = { ip = 10.1.0.0/21; owner = DA_abc; }
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
Warning: Useless owner:DA_abc at host:name_10_1_1_4,
 it was already inherited from network:a
---
netspoc/topology
@@ -1,2 +1,4 @@
 owner:DA_abc = { admins = abc@example.com; }
-network:a = { ip = 10.1.0.0/21; owner = DA_abc; }
+network:a = { ip = 10.1.0.0/21; owner = DA_abc;
+ host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
+}
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, with warning from previous checkin';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = { admins = abc@example.com; }
network:a = { ip = 10.1.0.0/21; owner = DA_abc;
 host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_3',
        ip      => '10.1.1.3',
    }
};

$out = <<'END';
Warning: Useless owner:DA_abc at host:name_10_1_1_4,
 it was already inherited from network:a
---
netspoc/topology
@@ -1,4 +1,5 @@
 owner:DA_abc = { admins = abc@example.com; }
 network:a = { ip = 10.1.0.0/21; owner = DA_abc;
+ host:name_10_1_1_3			= { ip = 10.1.1.3; }
  host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, with old and new warning';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = { admins = abc@example.com; }
network:a = { ip = 10.1.0.0/21; owner = DA_abc;
 host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_3',
        ip      => '10.1.1.3',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
Warning: Useless owner:DA_abc at host:name_10_1_1_3,
 it was already inherited from network:a
Warning: Useless owner:DA_abc at host:name_10_1_1_4,
 it was already inherited from network:a
---
netspoc/topology
@@ -1,4 +1,5 @@
 owner:DA_abc = { admins = abc@example.com; }
 network:a = { ip = 10.1.0.0/21; owner = DA_abc;
+ host:name_10_1_1_3			= { ip = 10.1.1.3; owner = DA_abc; }
  host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, unknown owner';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; }
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
Error: Can't resolve reference to 'DA_abc' in attribute 'owner' of host:name_10_1_1_4
Aborted with 1 error(s)
---
netspoc/topology
@@ -1 +1,3 @@
-network:a = { ip = 10.1.0.0/21; }
+network:a = { ip = 10.1.0.0/21;
+ host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
+}
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host [auto]';
############################################################

$in = <<'END';
-- topology
#network:c
# ip = 10.1.0.0/21;
network:a = {
 # Comment
#network:b
 ip = 10.1.0.0/21;
 # Comment2
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
netspoc/topology
@@ -5,4 +5,5 @@
 #network:b
  ip = 10.1.0.0/21;
  # Comment2
+ host:name_10_1_1_4			= { ip = 10.1.1.4; }
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, can\'t find [auto] network';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/24; }
END

$job = {
    method => 'CreateHost',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Can't find network with 'ip = 10.1.0.0/21' in netspoc/
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, can\'t find network for found [auto] IP';
############################################################

my $many_comments = "#\n" x 50;
$in = <<"END";
-- topology
network:a = {
$many_comments
 ip = 10.1.0.0/21; }
END

$job = {
    method => 'CreateHost',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Can't find network definition for 'ip = 10.1.0.0/21' in netspoc/topology
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, multiple [auto] networks in one file';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; nat:a = { hidden; } }
network:b = { ip = 10.1.0.0/21; nat:b = { hidden; } }

router:r1 = {
 interface:a = { bind_nat = b; }
 interface:b = { bind_nat = a; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Found multiple networks with 'ip = 10.1.0.0/21' in netspoc/topology: network:a network:b
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, find NAT IP from [auto]';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; nat:a = { hidden; } }
network:b = { ip = 10.2.0.0/21; nat:b = { ip = 10.1.0.0/21; } }
network:c = { ip = 10.3.0.0/21; }

router:r1 = {
 interface:a;
 interface:b = { bind_nat = a; }
 interface:c = { bind_nat = a, b; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Found multiple networks with 'ip = 10.1.0.0/21' in netspoc/topology: network:a network:b
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, multiple [auto] networks in multiple files';
############################################################

$in = <<'END';
-- topo1
network:a = { ip = 10.1.0.0/21; nat:a = { hidden; } }
-- topo2
network:b = { ip = 10.1.0.0/21; nat:b = { hidden; } }
-- topo3
network:c = { ip = 10.1.0.0/21; nat:c = { hidden; } }

router:r1 = {
 interface:a = { bind_nat = b, c; }
 interface:b = { bind_nat = a, c; }
 interface:c = { bind_nat = a, b; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Found multiple occurrences of 'ip = 10.1.0.0/21' in: netspoc/topo3 netspoc/topo1 netspoc/topo2
END

test_err($title, $in, $job, $out);

############################################################
$title = 'MultiJob without jobs';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
-- owner
# Add owners below.
END

$job = {
    method => 'MultiJob',
};

$out = <<'END';
END

test_run($title, $in, $job, $out);

############################################################
$title = 'MultiJob: add host and owner';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
-- owner
# Add owners below.
END

$job = {
    method => 'MultiJob',
    params => {
        jobs => [
            {
                method => 'CreateOwner',
                params => {
                    name     => 'a',
                    admins   => [ 'a@example.com', 'b@example.com' ],
                    watchers => [ 'c@example.com', 'd@example.com' ],
                }
            },
            {
                method => 'CreateHost',
                params => {
                    network => 'n1',
                    name    => 'name_10_1_1_4',
                    ip      => '10.1.1.4',
                    owner   => 'a',
                }
            }
        ],
        changeID => 'CRQ00001234',
    }
};

$out = <<'END';
netspoc/owner
@@ -1 +1,12 @@
 # Add owners below.
+owner:a = {
+ admins =
+	a@example.com,
+	b@example.com,
+	;
+ watchers =
+	c@example.com,
+	d@example.com,
+	;
+}
+
netspoc/topology
@@ -1 +1,3 @@
-network:n1 = { ip = 10.1.1.0/24; }
+network:n1 = { ip = 10.1.1.0/24;
+ host:name_10_1_1_4			= { ip = 10.1.1.4; owner = a; }
+}
END

test_run($title, $in, $job, $out);

############################################################
done_testing;
