#!/usr/local/bin/perl

=head1 NAME

api.psgi - Accept jobs for Netspoc-API

=head1 COPYRIGHT AND DISCLAIMER

(C) 2019 by Heinz Knutzen <heinz.knutzen@gmail.com>

https://github.com/hknutzen/Netspoc-Web

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.
You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.

=cut

use strict;
use warnings;
use JSON;
use Plack::Util;
use Plack::Request;
use Plack::Response;
use IPC::Run3;

# JSON file with
# either
# - ldap_uri = URL
# or
# - user = USERNAME
# - pass = PASSWORD
my $conf_file = 'config';
my $config;

my %path2sub =
(
  'add-job' => \&add_job,
  'job-status'  => \&job_status,
);

sub abort {
    my ($msg) = @_;
    die "$msg\n";
}

sub load_config {
    my $result;
    open( my $fh, '<', $conf_file ) or abort("Can't open $conf_file: $!");
    local $/ = undef;
    return from_json(  <$fh>, { relaxed  => 1 } );
}

sub add_job {
    my ($job) = @_;
    my ($id, $stderr);
    my $json = encode_json($job);
    run3('bin/add-job', \$json, \$id, \$stderr);
    $? and abort($stderr);
    return(encode_json({id => $id}));
}

sub job_status {
    my ($job) = @_;
    my ($id, $user) = @{$job}{qw(id user)};
    my ($result, $stderr);
    run3("bin/job-status $id $user", \undef, \$result, \$stderr);
    $? and abort($stderr);
    return $result;
}

sub authenticate {
    my ($json) = @_;
    my $user = $json->{user} or abort "Missing 'user'";

    # Delete password from request, must not be stored in queue.
    my $pass = delete $json->{pass} or abort "Missing 'pass'";

    if (my $ldap_uri = $config->{ldap_uri}) {
        my $ldap = Net::LDAP->new($ldap_uri, onerror => 'undef') or
            abort "LDAP connect failed: $@";
        $ldap->bind($user, password => $pass) or abort('Authentication failed');
    }
    elsif (my $test_user = $config->{user}) {
        my $test_pass = $config->{pass} || '';
        $user eq  $test_user and $pass eq  $test_pass or
            abort('Local authentication failed');
    }
    else {
        abort('No authentication method configured');
    }
}

sub handle_request {
    my ($env) = @_;
    my $req = Plack::Request->new($env);
    my $path = $req->path_info();
    $path =~ s:^/::;
    my $handler = $path2sub{$path} or abort "Unknown path '$path'";
    my $job = decode_json($req->content());
    authenticate($job);
    my $result = $handler->($job);
    my $res = Plack::Response->new(200);
    $res->content_type('application/json');
    $res->body($result);
    return $res->finalize;
}

$config = load_config();
my $app = \&handle_request;
