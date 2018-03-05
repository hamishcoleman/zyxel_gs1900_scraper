#!/usr/bin/env perl
use warnings;
use strict;
#
# A quick hack to demonstrate that we can actually automatically download
# the current configuration files
#

use WWW::Mechanize;

use Data::Dumper;
$Data::Dumper::Indent = 1;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Quotekeys = 0;

# And now, introducing one of the worlds wierdest password obfuscation systems:
sub encode_password {
    my ($input) = @_;
    die "password too long to encode" if (length($input) > 99);
    my $output = '_'x320; # in the original, the fill chars were random

    # Stick the input stringlen in a specific location
    my @input_len_str = split(//, sprintf("%02i", length($input)));
    substr($output, 122, 1, $input_len_str[0]);
    substr($output, 288, 1, $input_len_str[1]);

    # Sick the reverse of the password in every 7th char
    my @input_arr = reverse(split(//, $input));
    my $i = 6;
    while(my $ch = shift(@input_arr)) {
        substr($output, $i, 1, $ch);
        $i+=7;
    }

    return $output;
}

sub main() {
    my $option = {};
    $option->{url} = shift @ARGV || die "need base url";
    $option->{username} = shift @ARGV || die "need username";
    $option->{password} = shift @ARGV || die "need password";
    $option->{command} = shift @ARGV;

    my $mech = WWW::Mechanize->new();

    # Start the login
    # Like a neanderthal, throw strings around
    my $url1 = $option->{url} . '/cgi-bin/dispatcher.cgi?'
        . 'login=1&'
        . 'username='.$option->{username}.'&'
        . 'password='.encode_password($option->{password}).'&'
        . '&dummy='.time();
    $mech->get($url1);
    my $result = $mech->content();
    die "bad result1" if ($result ne "\nAUTHING\n");

    # Check how we went
    my $url2 = $option->{url} . '/cgi-bin/dispatcher.cgi?'
        . 'login_chk=1&'
        . 'dummy='.time();
    while ($result eq "\nAUTHING\n") {
        $mech->get($url2);
        $result = $mech->content();
    }
    die "bad result2" if ($result ne "\nOK\n");

    # Try and get a session cookie
    my $url3 = $option->{url} . '/cgi-bin/dispatcher.cgi?cmd=1';
    $mech->get($url3);

    my $XSSID;
    # so brittle,  much annoy
    if ($mech->content() =~ m/^\s*setCookie\("XSSID", "(.*)"\);$/m) {
        $XSSID=$1;
    } else {
        die "could not find XSSID cookie";
    }
    $mech->add_header(Cookie => 'XSSID='.$XSSID);

    # upmethod
    # 0 = tftp (needs tftp_srcip)
    # 1 = http
    # type
    # 1 = running config
    # 2 = startup config
    # 3 = backup config
    # 4 = flash log
    # 5 = buffer log
    my $url4 = $option->{url} . '/cgi-bin/dispatcher.cgi?'
        . 'XSSID='.$XSSID.'&'
        . 'upmethod=1&'
        . 'type=1&'
        . 'cmd=5902&'
        . 'sysSubmit=Apply';
    $mech->get($url4);
    # Check for 'window.location.href = "/tmp/runnning-config.cfg"'

    sleep(1);
    my $url5 = $option->{url} . '/tmp/running-config.cfg';
    $mech->get($url5);

    print $mech->content();
    #print Dumper($mech);
}
unless (caller) {
    # only run main if we are called as a CLI tool
    main();
}
