package ZyxelScrape;
use warnings;
use strict;
#
#
#

use WWW::Mechanize;
use HTTP::Cookies;
use HTML::TreeBuilder;

sub new {
    my $class = shift;
    my $self = {};
    bless $self, $class;

    $self->{XSSID} = undef;
    $self->{mech} = WWW::Mechanize->new();

    return $self;
}

sub set_hostname {
    my $self = shift;
    my $hostname = shift;
    $self->{baseurl} = "http://" . $hostname;
    return $self;
}

sub set_credentials {
    my $self = shift;
    my $username = shift;
    my $password = shift;
    $self->{username} = $username;
    $self->{password} = $password;
    return $self;
}

sub debug {
    my $self = shift;

    $self->{mech}->add_handler("request_send", sub { shift->dump; return });
    $self->{mech}->add_handler("request_done", sub { shift->dump; return });
}

# And now, introducing one of the worlds wierdest password obfuscation systems:
sub _encode_password {
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

# unconditionally login
sub _alwayslogin {
    my $self = shift;

    my $mech = $self->{mech};

    my $url1 = $self->{baseurl} . '/cgi-bin/dispatcher.cgi?'
        . 'login=1&'
        . 'username='.$self->{username}.'&'
        . 'password='._encode_password($self->{password}).'&'
        . 'dummy='.time();
    $mech->get($url1);

    my $result = $mech->content();
    $result =~ s/\n//g; # some switch firmwares have different numbers of newlines
    die "bad result1" if ($result ne "AUTHING");

    # Check how we went
    my $url2 = $self->{baseurl} . '/cgi-bin/dispatcher.cgi?'
        . 'login_chk=1&'
        . 'dummy='.time();
    while ($result eq "AUTHING") {
        $mech->get($url2);

        $result = $mech->content();
        $result =~ s/\n//g; # some switch firmwares have different numbers of newlines
    }
    die "bad result2" if ($result ne "OK");

    # Did we get given an session cookie?
    my $setcookie = $mech->res()->header('set-cookie');
    my $XSSID;
    if ($setcookie =~ m/^HTTP_XSSID=([^;]+);/) {
        $XSSID=$1;
    } else {
        # Try and get a session cookie
        my $url3 = $self->{baseurl} . '/cgi-bin/dispatcher.cgi?cmd=1';
        $mech->get($url3);

        # so brittle,  much annoy
        if ($mech->content() =~ m/^\s*setCookie\("XSSID", "(.*)"\);$/m) {
            $XSSID=$1;
        } else {
            die "could not find XSSID cookie";
        }
        $mech->add_header(Cookie => 'XSSID='.$XSSID);
    }

    $self->{XSSID} = $XSSID;
    return $self;
}

sub login {
    my $self = shift;
    if (defined($self->{XSSID})) {
        return $self;
    }

    return $self->_alwayslogin();
}

sub _dispatcher_get {
    my $self = shift;
    my %param = (
        @_
    );
    my @param;
    while (my ($k, $v) = each %param) {
        push @param, $k . '=' . $v;
    }
    my $param = join('&', @param);

    my $url = $self->{baseurl} . '/cgi-bin/dispatcher.cgi?' . $param;

    $self->login();
    $self->{mech}->get($url);

    my $result = $self->{mech}->content();
    return $result;
}

sub _last2tree {
    my $self = shift;

    my $tree = HTML::TreeBuilder->new;
    $tree->store_comments(1);
    $tree->parse($self->{mech}->content());
    $tree->eof;
    $tree->elementify;
    return $tree;
}

my $_map_fields = {
    # show_poe
    'PoE Mode' => 'poe_mode',
    'Total Power(W)' => 'total_W',
    'Consuming Power(W)' => 'consumed_W',
    'Allocated Power(W)' => 'allocate_W',
    'Remaining Power(W)' => 'remain_W',

    # show_poe_port
    'Port' => 'port',
    'State' => 'state',
    'Class' => 'class',
    'PD Priority' => 'pri',
    'Power-Up' => 'proto',
    'Wide Range Detection' => 'wide',
    'Consuming Power (mW)' => 'consumed_mW',
    'Max Power (mW)' => 'max_mW',
};

sub show_poe {
    my $self = shift;

    $self->_dispatcher_get(cmd=>776);
    my $tree = $self->_last2tree();

    my $result = {};
    my @keys;

    for my $item ($tree->look_down(
            '_tag', 'td',
            'class', 'font-3 word_normal'
        )) {
        push @keys, $item->as_trimmed_text();
    }

    for my $item ($tree->look_down(
            '_tag', 'td',
            'class', 'font-4'
        )) {
        my $key = shift(@keys);
        if (defined($_map_fields->{$key})) {
            $key = $_map_fields->{$key};
        }
        $result->{$key} = $item->as_trimmed_text();
    }

    return $result;
}

sub show_poe_port {
    my $self = shift;

    $self->_dispatcher_get(cmd=>773);
    my $tree = $self->_last2tree();

    my $result = {};

    my @keys;
    for my $item ($tree->look_down(
            '_tag', 'td',
            'class', 'font-3 word_normal'
        )) {
        push @keys, $item->as_trimmed_text();
    }

    for my $row ($tree->look_down('_tag', 'tr')) {
        my $port = {};
        my $index = 0;
        for my $item ($row->look_down(
                '_tag', 'td',
                'class', 'font-4'
            )) {
            if ($index > 10) {
                # avoid getting all the details with a nested top level row
                delete $port->{port};
                last;
            } elsif ($index > 0) {
                my $key = $keys[$index-1];
                if (defined($_map_fields->{$key})) {
                    $key = $_map_fields->{$key};
                }
                $port->{$key} = $item->as_trimmed_text();
            }
            $index++;
        }
        if (defined($port->{port})) {
            $result->{$port->{port}} = $port;
        }
    }

    return $result;
}

sub set_poe_port_power {
    my $self = shift;
    my $port = shift;
    my $state = shift;

    my $mech = $self->{mech};

    $self->_dispatcher_get(cmd=>774, port=>$port);

    $mech->field('state',$state);
    $mech->submit();

    # TODO
    # - check for success/fail
    return $mech->content();
}

1;
