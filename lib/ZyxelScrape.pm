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
    my $cmd = shift;

    my $url = $self->{baseurl} . '/cgi-bin/dispatcher.cgi?cmd=' . $cmd;

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

sub show_poe {
    my $self = shift;

    $self->_dispatcher_get(776);
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
        $result->{$key} = $item->as_trimmed_text();
    }

    return $result;
}
1;