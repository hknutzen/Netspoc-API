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
    symlink("$API_DIR/backend", 'bin');

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
    ($success, $stderr) = run('netspoc -q netspoc');

    # Handle warnings as errors.
    $success = 0 if $stderr;

    # Collect and simplify diff.
    # Show diff even if Netspoc failed.
    #--- unchanged/owner       15 Apr 2019 07:56:13 -0000
    #+++ netspoc/owner       15 Apr 2019 13:27:38 -0000
    #@@ -5,7 +5,7 @@
    #
    # Remove single space in empty line.
    my $diff = `diff -u -r -N unchanged netspoc | sed 's/^ \$//'`;
    $diff =~ s/^diff -u -r -N unchanged\/[^ ]* //mg;
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
    # Cleanup error message.
    $stderr =~ s/\nAborted$//ms;
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
Error: Unknown method ''
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
    method => 'add_to_group',
};

$out = <<'END';
Error: Can't find group:
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
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'host:h_10_1_2_7',
    }
};

$out = <<'END';
netspoc/group
@@ -1,7 +1,8 @@
 group:g1 =
+ network:n3,
  host:h_10_1_1_4,
  host:h_10_1_1_44,
- network:n3,
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
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'host:h_10_1_2_5',
    }
};

$out = <<'END';
netspoc/group
@@ -1,7 +1,8 @@
 group:g1 =
+ network:n3,
  host:h_10_1_1_4,
  host:h_10_1_1_44,
- network:n3,
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
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'host:h_10_1_1_5',
    }
};

$out = <<'END';
netspoc/group
@@ -1,7 +1,8 @@
 group:g1 =
+ network:n3,
  host:h_10_1_1_4,
+ host:h_10_1_1_5,
  host:h_10_1_1_44,
- network:n3,
  host:h_10_1_2_6,
  host:h_10_1_2_9,
 ;
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
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'network:n2',
    }
};

$out = <<'END';
netspoc/group
@@ -1,5 +1,6 @@
 group:g1 =
- interface:r1.n1,
  network:n1,
+ network:n2,
+ interface:r1.n1,
  interface:r1.n2,
 ;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add before first element located on first line';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24;
 host:h_10_1_1_4 = { ip = 10.1.1.4; }
 host:h_10_1_1_5 = { ip = 10.1.1.5; }
}
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
-- group
group:g1 = host:h_10_1_1_5; # Comment
-- service
service:s1 = {
 user = group:g1;
 permit src = user; dst = network:n2; prt = tcp 80;
}
END

$job = {
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'host:h_10_1_1_4',
    }
};

$out = <<'END';
netspoc/group
@@ -1 +1,4 @@
-group:g1 = host:h_10_1_1_5; # Comment
+group:g1 =
+ host:h_10_1_1_4,
+ host:h_10_1_1_5, # Comment
+;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Group having description ending with ";"';
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
 description = Some text;
 network:n1,
;
-- service
service:s1 = {
 user = group:g1;
 permit src = user; dst = network:n3; prt = tcp 80;
}
END

$job = {
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'network:n2',
    }
};

$out = <<'END';
netspoc/group
@@ -1,4 +1,6 @@
 group:g1 =
  description = Some text;
+
  network:n1,
+ network:n2,
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
group:g1 = ; # IGNORED
-- service
service:s1 = {
 user = group:g1;
 permit src = user; dst = network:n2; prt = tcp 80;
}
END

$job = {
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'host:h4',
    }
};

$out = <<'END';
netspoc/group
@@ -1 +1,3 @@
-group:g1 = ; # IGNORED
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
    method => 'create_owner',
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
@@ -1,3 +1,7 @@
 owner:a = {
  admins = a@example.com;
 }
+
+owner:a = {
+ admins = a@example.com;
+}
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
    method => 'create_owner',
    params => {
        name    => 'a',
        admins  => [ 'a@example.com' ],
        'ok_if_exists' => 1,
    },
};

$out = <<'END';
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Delete still referenced owner';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
-- owner
owner:a = {
 admins = a@example.com; #}
} # end
# next line
END

$job = {
    method => 'delete_owner',
    params => {
        name => 'a',
    }
};

$out = <<'END';
Warning: Ignoring undefined owner:a of network:n1
---
netspoc/owner
@@ -1,4 +1 @@
-owner:a = {
- admins = a@example.com; #}
-} # end
 # next line
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Modify owner: change admins, add watchers';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
owner:a = {
 admins = a@example.com; } # Comment
END

$job = {
    method => 'modify_owner',
    params => {
        name => 'a',
        admins => [ 'b@example.com', 'a@example.com' ],
        watchers => [ 'c@example.com', 'd@example.com' ]
    }
};

$out = <<'END';
netspoc/topology
@@ -1,3 +1,10 @@
 network:n1 = { ip = 10.1.1.0/24; owner = a; }
+
 owner:a = {
- admins = a@example.com; } # Comment
+ admins = a@example.com,
+          b@example.com,
+          ;
+ watchers = c@example.com,
+            d@example.com,
+            ;
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Modify owner with swapped admins and watchers';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
owner:a = {
 watchers = b@example.com;
 admins   = a@example.com; }
END

$job = {
    method => 'modify_owner',
    params => {
        name => 'a',
        admins => [ 'b@example.com' ],
        watchers => [ 'c@example.com' ]
    }
};

$out = <<'END';
netspoc/topology
@@ -1,4 +1,6 @@
 network:n1 = { ip = 10.1.1.0/24; owner = a; }
+
 owner:a = {
- watchers = b@example.com;
- admins   = a@example.com; }
+ watchers = c@example.com;
+ admins = b@example.com;
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Modify owner: leave admins untouched, remove watchers';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
owner:a = {
 watchers = b@example.com;
 admins   = a@example.com;
}
END

$job = {
    method => 'modify_owner',
    params => {
        name => 'a',
        watchers => []
    }
};

$out = <<'END';
netspoc/topology
@@ -1,5 +1,5 @@
 network:n1 = { ip = 10.1.1.0/24; owner = a; }
+
 owner:a = {
- watchers = b@example.com;
- admins   = a@example.com;
+ admins = a@example.com;
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Modify owner, defined in one line';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
owner:a = { admins = a@example.com; }
END

$job = {
    method => 'modify_owner',
    params => {
        name => 'a',
        admins => [ 'c@example.com' ]
    }
};

$out = <<'END';
netspoc/topology
@@ -1,2 +1,5 @@
 network:n1 = { ip = 10.1.1.0/24; owner = a; }
-owner:a = { admins = a@example.com; }
+
+owner:a = {
+ admins = c@example.com;
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Modify owner: multiple attributes in one line';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
owner:a = {
 admins = a@example.com; watchers = b@example.com;
}
END

$job = {
    method => 'modify_owner',
    params => {
        name => 'a',
        admins => [ 'c@example.com' ]
    }
};

$out = <<'END';
netspoc/topology
@@ -1,4 +1,6 @@
 network:n1 = { ip = 10.1.1.0/24; owner = a; }
+
 owner:a = {
- admins = a@example.com; watchers = b@example.com;
+ admins = c@example.com;
+ watchers = b@example.com;
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host to known network';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24; }
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    },
};

$out = <<'END';
netspoc/topology
@@ -1 +1,4 @@
-network:a = { ip = 10.1.1.0/24; }
+network:a = {
+ ip = 10.1.1.0/24;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, insert sorted';
############################################################

$in = <<'END';
-- topology
network:a = {
 ip = 10.1.1.0/24;
 # Comment1
 host:name_10_1_1_2 = { ip = 10.1.1.2; }
 # Comment2
 # Comment3
 host:name_10_1_1_5 = { ip = 10.1.1.5; }
 host:name_10_1_1_6 = { ip = 10.1.1.6; }
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
netspoc/topology
@@ -2,6 +2,7 @@
  ip = 10.1.1.0/24;
  # Comment1
  host:name_10_1_1_2 = { ip = 10.1.1.2; }
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
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
network:a = {
 ip = 10.1.1.0/24;
 host:name_10_1_1_4 = { ip = 10.1.1.4; }
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Error: Duplicate definition of host:name_10_1_1_4 in netspoc/topology
Aborted with 1 error(s)
---
netspoc/topology
@@ -1,4 +1,5 @@
 network:a = {
  ip = 10.1.1.0/24;
  host:name_10_1_1_4 = { ip = 10.1.1.4; }
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, same IP';
############################################################

$in = <<'END';
-- topology
network:a = {
 ip = 10.1.1.0/24;
 host:other_10_1_1_4 = { ip = 10.1.1.4; }
}
END

$job = {
    method => 'create_host',
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
@@ -1,4 +1,5 @@
 network:a = {
  ip = 10.1.1.0/24;
  host:other_10_1_1_4 = { ip = 10.1.1.4; }
+ host:name_10_1_1_4  = { ip = 10.1.1.4; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, same IP unsorted';
############################################################

$in = <<'END';
-- topology
network:a = {
 ip = 10.1.1.0/24;
 host:name_10_1_1_5 = { ip = 10.1.1.5; }
 host:name_10_1_1_4 = { ip = 10.1.1.4; }
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Error: Duplicate definition of host:name_10_1_1_4 in netspoc/topology
Aborted with 1 error(s)
---
netspoc/topology
@@ -1,5 +1,6 @@
 network:a = {
  ip = 10.1.1.0/24;
- host:name_10_1_1_5 = { ip = 10.1.1.5; }
  host:name_10_1_1_4 = { ip = 10.1.1.4; }
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
+ host:name_10_1_1_5 = { ip = 10.1.1.5; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Multiple networks at one line';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24; } network:b = { ip = 10.1.2.0/24; }
router:r1 = {
 interface:a;
 interface:b;
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
netspoc/topology
@@ -1,4 +1,10 @@
-network:a = { ip = 10.1.1.0/24; } network:b = { ip = 10.1.2.0/24; }
+network:a = {
+ ip = 10.1.1.0/24;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
+}
+
+network:b = { ip = 10.1.2.0/24; }
+
 router:r1 = {
  interface:a;
  interface:b;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host with owner';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = {
 admins = abc@example.com;
}

network:a = { ip = 10.1.0.0/21; }
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
netspoc/topology
@@ -2,4 +2,7 @@
  admins = abc@example.com;
 }

-network:a = { ip = 10.1.0.0/21; }
+network:a = {
+ ip = 10.1.0.0/21;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; owner = DA_abc; }
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, redundant owner';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = {
 admins = abc@example.com;
}

network:a = {
 ip = 10.1.0.0/21;
 owner = DA_abc;
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
netspoc/topology
@@ -5,4 +5,5 @@
 network:a = {
  ip = 10.1.0.0/21;
  owner = DA_abc;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, with warning from previous checkin';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = {
 admins = abc@example.com;
}

network:a = {
 ip = 10.1.0.0/21;
 owner = DA_abc;
 host:name_10_1_1_4 = { ip = 10.1.1.4; owner = DA_abc; }
}
END

$job = {
    method => 'create_host',
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
@@ -5,5 +5,6 @@
 network:a = {
  ip = 10.1.0.0/21;
  owner = DA_abc;
+ host:name_10_1_1_3 = { ip = 10.1.1.3; }
  host:name_10_1_1_4 = { ip = 10.1.1.4; owner = DA_abc; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, with old and new warning';
############################################################

$in = <<'END';
-- topology
network:a = {
 ip = 10.1.0.0/21;
 host:name_10_1_1_4 = { ip = 10.1.1.4; }
}

router:r = {
 interface:a;
 interface:b;
}

network:b = {
 ip = 10.1.1.0/24;
 subnet_of = network:a;
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_3',
        ip      => '10.1.1.3',
    }
};

$out = <<'END';
Warning: IP of host:name_10_1_1_3 overlaps with subnet network:b
Warning: IP of host:name_10_1_1_4 overlaps with subnet network:b
---
netspoc/topology
@@ -1,5 +1,6 @@
 network:a = {
  ip = 10.1.0.0/21;
+ host:name_10_1_1_3 = { ip = 10.1.1.3; }
  host:name_10_1_1_4 = { ip = 10.1.1.4; }
 }

END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, unknown owner';
############################################################

$in = <<'END';
-- topology
network:a = {
 ip = 10.1.0.0/21;
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
Warning: Ignoring undefined owner:DA_abc of host:name_10_1_1_4
---
netspoc/topology
@@ -1,3 +1,4 @@
 network:a = {
  ip = 10.1.0.0/21;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; owner = DA_abc; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, no IP address found';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; }
END

$job = {
    method => 'create_host',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.0.*',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Invalid IP address: '10.1.0.*'
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, invalid IP address';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; }
END

$job = {
    method => 'create_host',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.0.444',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Invalid IP address: '10.1.0.444'
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, invalid IP mask';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; }
END

$job = {
    method => 'create_host',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.0.4',
        mask    => '123.255.248.0',
    }
};

$out = <<'END';
Error: Invalid IP mask: '123.255.248.0'
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host [auto]';
############################################################

$in = <<'END';
-- topology
network:d = { ip = 10.2.0.0/21; }

network:a = {
 ip = 10.1.0.0/21;
}

router:r = {
 interface:a;
 interface:d;
}
END

$job = {
    method => 'create_host',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
netspoc/topology
@@ -2,6 +2,7 @@

 network:a = {
  ip = 10.1.0.0/21;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
 }

 router:r = {
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
    method => 'create_host',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Can't find network with 'ip = 10.1.0.0/21'
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, multiple [auto] networks';
############################################################

$in = <<'END';
-- topology
network:a = {
 ip = 10.1.0.0/21;
 nat:a = { hidden; }
}

network:b = {
 ip = 10.1.0.0/21;
 nat:b = { hidden; }
}

router:r1 = {
 interface:a = {
  bind_nat = b;
 }
 interface:b = {
  bind_nat = a;
 }
}
END

$job = {
    method => 'create_host',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Duplicate definition of host:name_10_1_1_4 in netspoc/topology
Aborted with 1 error(s)
---
netspoc/topology
@@ -1,11 +1,13 @@
 network:a = {
  ip = 10.1.0.0/21;
  nat:a = { hidden; }
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
 }

 network:b = {
  ip = 10.1.0.0/21;
  nat:b = { hidden; }
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
 }

 router:r1 = {
END

test_err($title, $in, $job, $out);

############################################################
$title = 'multi_job without jobs';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
-- owner
# Add owners below.
END

$job = {
    method => 'multi_job',
    params => {
        jobs => []
    }
};

$out = <<'END';
END

test_run($title, $in, $job, $out);

############################################################
$title = 'multi_job: add host and owner';
############################################################

$in = <<'END';
-- topology
network:n1 = {
 ip = 10.1.1.0/24;
}
-- owner
# Add owners below.
END

$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'create_owner',
                params => {
                    name     => 'a',
                    admins   => [ 'b@example.com', 'a@example.com' ],
                    watchers => [ 'c@example.com', 'd@example.com' ],
                }
            },
            {
                method => 'create_host',
                params => {
                    network => 'n1',
                    name    => 'name_10_1_1_4',
                    ip      => '10.1.1.4',
                    owner   => 'a',
                }
            }
        ],
    }
};

$out = <<'END';
netspoc/owner
@@ -1 +1,9 @@
+owner:a = {
+ admins = a@example.com,
+          b@example.com,
+          ;
+ watchers = c@example.com,
+            d@example.com,
+            ;
+}
 # Add owners below.
netspoc/topology
@@ -1,3 +1,4 @@
 network:n1 = {
  ip = 10.1.1.0/24;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; owner = a; }
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'multi_job: add owner that exists and add host';
############################################################

$in = <<'END';
-- topology
network:n1 = {
 ip = 10.1.1.0/24;
 host:name_10_1_1_5 = { ip = 10.1.1.5; owner = a; }
}
-- owner
owner:a = {
 admins = a@example.com;
}
END

$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'create_owner',
                params => {
                    name     => 'a',
                    admins   => [ 'b@example.com' ],
                    ok_if_exists => 1,
                }
            },
            {
                method => 'create_host',
                params => {
                    network => 'n1',
                    name    => 'name_10_1_1_4',
                    ip      => '10.1.1.4',
                    owner   => 'a',
                }
            }
        ],
    }
};

$out = <<'END';
netspoc/topology
@@ -1,4 +1,5 @@
 network:n1 = {
  ip = 10.1.1.0/24;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; owner = a; }
  host:name_10_1_1_5 = { ip = 10.1.1.5; owner = a; }
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'multi_job: second job fails';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
END

$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'create_host',
                params => {
                    network => 'n1',
                    name    => 'name_10_1_1_4',
                    ip      => '10.1.1.4',
                }
            },
            {
                method => 'create_host',
                params => {
                    network => 'n2',
                    name    => 'name_10_1_2_4',
                    ip      => '10.1.2.4',
                }
            }
        ],
    }
};

$out = <<'END';
Error: Can't find network:n2
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Change owner of host, add and delete owner';
############################################################

$in = <<'END';
-- topology
network:n1 = {
 ip = 10.1.1.0/24;
 host:h1 = {
  ip = 10.1.1.1;
  owner = o1;
 } host:h2 = { ip = 10.1.1.2; owner = o1; }
}
-- owner
owner:o1 = { admins = a1@example.com; }
END

$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'create_owner',
                params => {
                    name     => 'o2',
                    admins   => [ 'a2@example.com' ],
                }
            },
            {
                method => 'delete_owner',
                params => {
                    name     => 'o1',
                }
            },
            {
                method => 'modify_host',
                params => {
                    name    => 'h1',
                    owner   => 'o2',
                }
            },
            {
                method => 'modify_host',
                params => {
                    name    => 'h2',
                    owner   => 'o2',
                }
            }
        ],
    }
};

$out = <<'END';
netspoc/owner
@@ -1 +1,3 @@
-owner:o1 = { admins = a1@example.com; }
+owner:o2 = {
+ admins = a2@example.com;
+}
netspoc/topology
@@ -1,7 +1,5 @@
 network:n1 = {
  ip = 10.1.1.0/24;
- host:h1 = {
-  ip = 10.1.1.1;
-  owner = o1;
- } host:h2 = { ip = 10.1.1.2; owner = o1; }
+ host:h1 = { ip = 10.1.1.1; owner = o2; }
+ host:h2 = { ip = 10.1.1.2; owner = o2; }
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Change owner at second of multiple ID-hosts';
############################################################

$in = <<'END';
-- topology
network:n1 = {
 ip = 10.1.1.0/24;
 host:id:a1@example.com = { ip = 10.1.1.1; owner = DA_TOKEN_o1; }
 host:id:a2@example.com = { ip = 10.1.1.2; owner = DA_TOKEN_o1; }
}

network:n2 = {
 ip = 10.1.2.0/24;
 host:id:a1@example.com = { ip = 10.1.2.1; owner = DA_TOKEN_o1; }
 host:id:a2@example.com = { ip = 10.1.2.2; owner = DA_TOKEN_o2; }
}

router:r1 = {
 interface:n1;
 interface:n2;
}
-- owner-token
owner:DA_TOKEN_o1 = {
 admins = a1@example.com;
}
owner:DA_TOKEN_o2 = { admins = a2@example.com; }
END


$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'modify_host',
                params => {
                    name  => 'id:a2@example.com.n2',
                    owner => 'DA_TOKEN_o3',
                }
            },
            {
                method => 'create_owner',
                params => {
                    name   => 'DA_TOKEN_o3',
                    admins => [ 'a3@example.com' ],
                }
            },
            {
                method => 'delete_owner',
                params => {
                    name => 'DA_TOKEN_o2',
                }
            },
        ]
    }
};

$out = <<'END';
netspoc/owner-token
@@ -1,4 +1,7 @@
 owner:DA_TOKEN_o1 = {
  admins = a1@example.com;
 }
-owner:DA_TOKEN_o2 = { admins = a2@example.com; }
+
+owner:DA_TOKEN_o3 = {
+ admins = a3@example.com;
+}
netspoc/topology
@@ -7,7 +7,7 @@
 network:n2 = {
  ip = 10.1.2.0/24;
  host:id:a1@example.com = { ip = 10.1.2.1; owner = DA_TOKEN_o1; }
- host:id:a2@example.com = { ip = 10.1.2.2; owner = DA_TOKEN_o2; }
+ host:id:a2@example.com = { ip = 10.1.2.2; owner = DA_TOKEN_o3; }
 }

 router:r1 = {
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Job with malicous network name';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24; } # Comment
END

$job = {
    method => 'create_host',
    params => {
        network => "a'; exit; '",
    }
};

$out = <<'END';
Error: Can't find network:a'; exit; '
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Job with whitespace in email address';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24; }
-- owner
owner:a = { admins = a@example.com; }
END

$job = {
    method => 'modify_owner',
    params => {
        admins => ['b example.com'],
        name => 'a'
    }
};

$out = <<'END';
Error: Expected ';' at line 2 of netspoc/owner, near "b --HERE-->example.com"
---
netspoc/owner
@@ -1 +1,3 @@
-owner:a = { admins = a@example.com; }
+owner:a = {
+ admins = b example.com;
+}
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add service, create rule/ directory';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24;
 host:h3 = { ip = 10.1.1.3; }
 host:h4 = { ip = 10.1.1.4; }
 host:h5 = { ip = 10.1.1.5; }
}
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = IOS;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
END

$job = {
    method => 'create_service',
    params => {
        name  => 's1',
        user => 'network:n2',
        rules => [
            {
                action => 'permit',
                src    => 'user',
                dst    => 'host:[network:n1] &! host:h4, interface:r1.n1',
                prt    => 'udp, tcp',
            },
            {
                action => 'permit',
                src    => 'user',
                dst    => 'host:h4',
                prt    => 'tcp 90,    tcp 80-85',
            },
            {
                action => 'deny',
                src    => 'user',
                dst    => 'network:n1',
                prt    => 'tcp 22',
            },
            {
                action => 'deny',
                src    => 'host:h5',
                dst    => 'user',
                prt    => 'udp, icmp 4',
            },
            ],
    }
};

$out = <<'END';
netspoc/rule/S
@@ -0,0 +1,25 @@
+service:s1 = {
+ user = network:n2;
+ deny   src = user;
+        dst = network:n1;
+        prt = tcp 22;
+ deny   src = host:h5;
+        dst = user;
+        prt = icmp 4,
+              udp,
+              ;
+ permit src = user;
+        dst = interface:r1.n1,
+              host:[network:n1]
+              &! host:h4
+              ,
+              ;
+        prt = tcp,
+              udp,
+              ;
+ permit src = user;
+        dst = host:h4;
+        prt = tcp 80-85,
+              tcp 90,
+              ;
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add service, complex user';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24;
 host:h3 = { ip = 10.1.1.3; }
 host:h4 = { ip = 10.1.1.4; }
 host:h5 = { ip = 10.1.1.5; }
}
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = IOS;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
END

$job = {
    method => 'create_service',
    params => {
        name  => 's1',
        user => 'host:[network:n1] &! host:h4, interface:r1.n1',
        rules => [
            {
                action => 'permit',
                src    => 'user',
                dst    => 'network:n2',
                prt    => 'tcp 80',
            },
            ],
    }
};

$out = <<'END';
netspoc/rule/S
@@ -0,0 +1,10 @@
+service:s1 = {
+ user = interface:r1.n1,
+        host:[network:n1]
+        &! host:h4
+        ,
+        ;
+ permit src = user;
+        dst = network:n2;
+        prt = tcp 80;
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add service, invalid action';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = IOS;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
END

$job = {
    method => 'create_service',
    params => {
        name  => 's1',
        user  => 'network:n1',
        rules => [
            {
                action => 'allow',
                src    => 'user',
                dst    => 'network:n2',
                prt    => 'tcp 80',
            }]
    }
};

$out = <<'END';
Error: Invalid 'Action': 'allow'
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add service, invalid user';
############################################################

$job = {
    method => 'create_service',
    params => {
        name  => 's1',
        user  => 'network:n1',
        rules => [
            {
                action => 'permit',
                src    => '_user_',
                dst    => 'network:n2',
                prt    => 'tcp 80',
            }]
    }
};

$out = <<'END';
Error: Typed name expected at line 1 of command line, near "--HERE-->_user_"
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add service, invalid object type';
############################################################

$job = {
    method => 'create_service',
    params => {
        name  => 's1',
        user  => 'network:n1',
        rules => [
            {
                action => 'permit',
                src    => 'user',
                dst    => 'net:n2',
                prt    => 'tcp 80',
            }]
    }
};

$out = <<'END';
Error: Unknown element type at line 1 of command line, near "--HERE-->net:n2"
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add service, invalid protocol';
############################################################

$job = {
    method => 'create_service',
    params => {
        name  => 's1',
        user  => 'network:n1',
        rules => [
            {
                action => 'permit',
                src    => 'user',
                dst    => 'network:n2',
                prt    => 'udp6',
            }]
    }
};

$out = <<'END';
Error: Unknown protocol in 'udp6' of service:s1
Aborted with 1 error(s)
---
netspoc/rule/S
@@ -0,0 +1,6 @@
+service:s1 = {
+ user = network:n1;
+ permit src = user;
+        dst = network:n2;
+        prt = udp6;
+}
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add service, insert sorted';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = IOS;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
-- rule/S
service:s1 = {
 user = network:n1;
 permit src = user;
        dst = network:n2;
        prt = tcp 81;
}
service:s3 = {
 user = network:n1;
 permit src = user;
        dst = network:n2;
        prt = tcp 83;
}
END

$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'create_service',
                params => {
                    name  => 's4',
                    user  => 'network:n1',
                    rules => [
                        {
                            action => 'permit',
                            src    => 'user',
                            dst    => 'network:n2',
                            prt    => 'tcp 84',
                        },
                        ]
                },
            },
            {
                method => 'create_service',
                params => {
                    name  => 's2',
                    user  => 'network:n1',
                    rules => [
                        {
                            action => 'permit',
                            src    => 'user',
                            dst    => 'network:n2',
                            prt    => 'tcp 82',
                        },
                        ]
                },
            }
            ]
    }
};
$out = <<'END';
netspoc/rule/S
@@ -4,9 +4,24 @@
         dst = network:n2;
         prt = tcp 81;
 }
+
+service:s2 = {
+ user = network:n1;
+ permit src = user;
+        dst = network:n2;
+        prt = tcp 82;
+}
+
 service:s3 = {
  user = network:n1;
  permit src = user;
         dst = network:n2;
         prt = tcp 83;
 }
+
+service:s4 = {
+ user = network:n1;
+ permit src = user;
+        dst = network:n2;
+        prt = tcp 84;
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Delete service';
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
}
-- service
service:s1 = {
 user = network:n1;
 permit src = user;
        dst = network:n2;
        prt = tcp 80;
}
END

$job = {
    method => 'delete_service',
    params => {
        name => 's1',
    }
};

$out = <<'END';
netspoc/service
@@ -1,6 +0,0 @@
-service:s1 = {
- user = network:n1;
- permit src = user;
-        dst = network:n2;
-        prt = tcp 80;
-}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add to user';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24;
 host:h4 = { ip = 10.1.1.4; }
 host:h5 = { ip = 10.1.1.5; }
 host:h6 = { ip = 10.1.1.6; }
}
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
-- service
service:s1 = {
 user = host:h5;
 permit src = user;
        dst = network:n2;
        prt = tcp 80;
}
END

$job = {
    method => 'add_to_user',
    params => {
        service => 's1',
        user    => 'host:h4, host:h6',
    }
};

$out = <<'END';
netspoc/service
@@ -1,5 +1,8 @@
 service:s1 = {
- user = host:h5;
+ user = host:h4,
+        host:h5,
+        host:h6,
+        ;
  permit src = user;
         dst = network:n2;
         prt = tcp 80;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add to user in unknown service';
############################################################

$in = <<'END';
--netspoc
network:n1 = { ip = 10.1.1.0/24; }
END

$job = {
    method => 'add_to_user',
    params => {
        service => 's1',
        user    => 'host:h4',
    }
};

$out = <<'END';
Error: Can't find service:s1
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Delete unknown element from user';
############################################################

$in = <<'END';
--all
network:n1 = { ip = 10.1.1.0/24; }
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
service:s1 = {
 user = network:n1;
 permit src = user;
        dst = network:n2;
        prt = tcp 80;
}
END

$job = {
    method => 'remove_from_user',
    params => {
        service => 's1',
        user    => 'host:[network:n1, network:n2]',
    }
};

$out = <<'END';
Error: Can't find 'host:[network:n1,network:n2,]' in 'user' of service:s1
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Delete from user';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24;
 host:h4 = { ip = 10.1.1.4; }
 host:h5 = { ip = 10.1.1.5; }
}
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
-- service
service:s1 = {
 user = host:[network:n1],
        interface:r1.n2,
        ;
 permit src = user;
        dst = network:n2;
        prt = tcp 80;
}
END

$job = {
    method => 'remove_from_user',
    params => {
        service => 's1',
        user    => 'host:[ network:n1 ]',
    }
};

$out = <<'END';
netspoc/service
@@ -1,7 +1,5 @@
 service:s1 = {
- user = host:[network:n1],
-        interface:r1.n2,
-        ;
+ user = interface:r1.n2;
  permit src = user;
         dst = network:n2;
         prt = tcp 80;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Replace in user';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24;
 host:h4 = { ip = 10.1.1.4; }
 host:h5 = { ip = 10.1.1.5; }
}
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
-- service
service:s1 = {
 user = host:h5;
 permit src = user;
        dst = network:n2;
        prt = tcp 80;
}
END

$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'add_to_user',
                params => {
                    service => 's1',
                    user    => 'host:h4',
                }
            },
            {
                method => 'remove_from_user',
                params => {
                    service => 's1',
                    user    => 'host:h5',
                }
            }
        ]
    }
};

$out = <<'END';
netspoc/service
@@ -1,5 +1,5 @@
 service:s1 = {
- user = host:h5;
+ user = host:h4;
  permit src = user;
         dst = network:n2;
         prt = tcp 80;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Delete unknown server in rule';
############################################################

$in = <<'END';
--all
network:n1 = { ip = 10.1.1.0/24; }
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
service:s1 = {
 user = network:n1;
 permit src = user;
        dst = network:n2;
        prt = tcp 80;
}
END

$job = {
    method => 'remove_from_rule',
    params => {
        service  => 's1',
        rule_num => 1,
        dst      => 'network:n1',
    }
};

$out = <<'END';
Error: Can't find 'network:n1' in rule 1 of service:s1
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Delete unknown protocol in rule';
############################################################

$in = <<'END';
--all
network:n1 = { ip = 10.1.1.0/24; }
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
service:s1 = {
 user = network:n1;
 permit src = user;
        dst = network:n2;
        prt = tcp 80;
}
END

$job = {
    method => 'remove_from_rule',
    params => {
        service  => 's1',
        rule_num => 1,
        prt      => 'udp 80',
    }
};

$out = <<'END';
Error: Can't find 'udp 80' in rule 1 of service:s1
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Delete protocols in rule';
############################################################

$in = <<'END';
--topo
network:n1 = { ip = 10.1.1.0/24; }
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
--service
service:s1 = {
 user = network:n1;
 permit src = user;
        dst = network:n2;
        prt = tcp 80,
              tcp 443,
              tcp 9300 - 9302,
              udp 161-162,
              udp 427,
              icmp 3/13,
              ;
}
END

$job = {
  "method" => "remove_from_rule",
  "params" => {
    "prt" => "icmp 3  / 13 , tcp 443, tcp 9300-9302, udp 161 - 162, udp 427",
    "rule_num" => 1,
    "service" => "s1"
  }
};

$out = <<'END';
netspoc/service
@@ -2,11 +2,5 @@
  user = network:n1;
  permit src = user;
         dst = network:n2;
-        prt = tcp 80,
-              tcp 443,
-              tcp 9300 - 9302,
-              udp 161-162,
-              udp 427,
-              icmp 3/13,
-              ;
+        prt = tcp 80;
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Change rules';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24;
 host:h3 = { ip = 10.1.1.3; }
 host:h4 = { ip = 10.1.1.4; }
 host:h5 = { ip = 10.1.1.5; }
}
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
-- service
service:s1 = {
 user = network:n2;
 permit src = user;
        dst = host:h3;
        prt = tcp 80;
 permit src = user;
        dst = host:h4,
              host:h5,
              ;
        prt = tcp 85- 90, tcp 91;
}
END

$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'add_to_rule',
                params => {
                    service  => 's1',
                    rule_num => 1,
                    prt      => 'udp 80',
                    dst      => 'host:h4',
                }
            },
            {
                method => 'remove_from_rule',
                params => {
                    service  => 's1',
                    rule_num => 2,
                    prt      => 'tcp 85 - 90',
                    dst      => 'host:h4',
                }
            }
        ]
    }
};

$out = <<'END';
netspoc/service
@@ -1,11 +1,13 @@
 service:s1 = {
  user = network:n2;
  permit src = user;
-        dst = host:h3;
-        prt = tcp 80;
- permit src = user;
-        dst = host:h4,
-              host:h5,
+        dst = host:h3,
+              host:h4,
+              ;
+        prt = tcp 80,
+              udp 80,
               ;
-        prt = tcp 85- 90, tcp 91;
+ permit src = user;
+        dst = host:h5;
+        prt = tcp 91;
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Change unknown rule';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = IOS;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}

service:s1 = {
 user = network:n1;
 permit src = user;
        dst = network:n2;
        prt = tcp 80;
}
END

$job = {
    method => 'add_to_rule',
    params => {
        service  => 's1',
        rule_num => 9,
        prt      => 'tcp 90',
    }
};

$out = <<'END';
Error: Invalid rule_num 9, have 1 rules in service:s1
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Change nothing in rule';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = IOS;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}

service:s1 = {
 user = network:n1;
 permit src = user;
        dst = network:n2;
        prt = tcp 80;
}
END

$job = {
    method => 'add_to_rule',
    params => {
        service  => 's1',
        rule_num => 1,
    }
};

$out = <<'END';
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add and delete permit rules';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24;
 host:h3 = { ip = 10.1.1.3; }
 host:h4 = { ip = 10.1.1.4; }
 host:h5 = { ip = 10.1.1.5; }
}
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = IOS;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
-- service
service:s1 = {
 user = network:n2;
 permit src = user;
        dst = host:h3;
        prt = tcp 80;
 permit src = user;
        dst = host:h4;
        prt = tcp 90;
}
END

$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'add_rule',
                params => {
                    service => 's1',
                    action  => 'permit',
                    src     => 'user',
                    dst     => 'host:h5, interface:r1.n2',
                    prt     => 'udp 123, icmp',
                }
            },
            {
                method => 'delete_rule',
                params => {
                    service  => 's1',
                    rule_num => 2,
                }
            },
        ]
    }
};

$out = <<'END';
netspoc/service
@@ -4,6 +4,10 @@
         dst = host:h3;
         prt = tcp 80;
  permit src = user;
-        dst = host:h4;
-        prt = tcp 90;
+        dst = host:h5,
+              interface:r1.n2,
+              ;
+        prt = udp 123,
+              icmp,
+              ;
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add deny rule in front';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24;
 host:h3 = { ip = 10.1.1.3; }
 host:h4 = { ip = 10.1.1.4; }
 host:h5 = { ip = 10.1.1.5; }
}
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = IOS;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
-- service
service:s1 = {
 user = network:n2;
 deny   src = user;
        dst = network:n1;
        prt = tcp 22;
 permit src = user;
        dst = host:h3;
        prt = tcp;
 permit src = user;
        dst = host:h4;
        prt = tcp 90;
}
END

$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'add_rule',
                params => {
                    service => 's1',
                    action  => 'deny',
                    src     => 'host:h5',
                    dst     => 'user',
                    prt     => 'udp, icmp 4',
                }
            },
        ]
    }
};

$out = <<'END';
netspoc/service
@@ -3,6 +3,11 @@
  deny   src = user;
         dst = network:n1;
         prt = tcp 22;
+ deny   src = host:h5;
+        dst = user;
+        prt = udp,
+              icmp 4,
+              ;
  permit src = user;
         dst = host:h3;
         prt = tcp;
END

test_run($title, $in, $job, $out);

############################################################
done_testing;
