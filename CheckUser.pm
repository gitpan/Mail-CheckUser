# Copyright (c) 1999-2001 by Ilya Martynov. All rights reserved.
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.

package Mail::CheckUser;

use strict;
use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

require Exporter;

@ISA = qw(Exporter);

@EXPORT = qw();
@EXPORT_OK = qw(check_email
	        check_hostname
	        check_username);

$VERSION = '1.02';

use Carp;
BEGIN {
    # this is a workaround againt anoying warning under Perl 5.6
    local $^W = $^W;
    if($] > 5.00503) {
	$^W = 0;
    }
    require Net::DNS;
    import Net::DNS;
}
use Net::SMTP;
use IO::Handle;

use vars qw($Skip_Network_Checks $Skip_SMTP_Checks
            $Timeout $Treat_Timeout_As_Fail $Debug
            $Sender_Addr $Helo_Domain);

# if it is true Mail::CheckUser doesn't make network checks
$Skip_Network_Checks = 0;
# if it is true Mail::CheckUser doesn't try to connect to mail
# server to check if user is valid
$Skip_SMTP_Checks = 0;
# timeout in seconds for network checks
$Timeout = 60;
# if it is true Mail::CheckUser treats timeouted checks as failed
# checks
$Treat_Timeout_As_Fail = 0;
# sender addr used in MAIL/RCPT check
$Sender_Addr = "check\@user.com";
# sender domain used in HELO SMTP command - if undef lets
# Net::SMTP use its default value
$Helo_Domain = undef;
# if true then enable debug mode
$Debug = 0;

# second half of ASCII table
my $_SECOND_ASCII = '';
for (my $i = 128; $i < 256; $i ++) {
    $_SECOND_ASCII .= chr($i);
}

# check_email EMAIL
sub check_email($);
# check_hostname_syntax HOSTNAME
sub check_hostname_syntax($);
# check_username_syntax USERNAME
sub check_username_syntax($);
# check_network HOSTNAME, USERNAME
sub check_network($$);
# check_user_on_host MSERVER, USERNAME, HOSTNAME, TIMEOUT
sub check_user_on_host($$$$);
# _calc_timeout FULL_TIMEOUT START_TIME
sub _calc_timeout($$);
# _pm_log LOG_STR
sub _pm_log($);

sub check_email($) {
    my($email) = @_;

    unless(defined $email) {
	carp __PACKAGE__ . "::check_email: \$email is undefined";
	return 0;
    }

    _pm_log '=' x 40;
    _pm_log "check_email: checking \"$email\"";

    # split email address on username and hostname
    my($username, $hostname) = $email =~ /^(.*)@(.*)$/;
    # return false if it impossible
    unless(defined $hostname) {
	_pm_log "check_email: can't split email \"$email\" on username and hostname";
	return 0;
    }

    my $ok = 1;
    $ok &= check_hostname_syntax $hostname;
    $ok &= check_username_syntax $username;
    if($Skip_Network_Checks) {
	_pm_log "check_email: skipping network checks";
    } else {
	$ok &= check_network $hostname, $username;
    }

    if($ok) {
	_pm_log "check_email: check is successful";
    } else {
	_pm_log "check_email: check is not successful";
    }

    return $ok;
}

sub check_hostname_syntax($) {
    my($hostname) = @_;

    _pm_log "check_hostname_syntax: checking \"$hostname\"";

    # check if hostname syntax is correct
    # NOTE: it doesn't strictly follow RFC822
    my $rAN = '[0-9a-zA-Z]';	# latin alphanum (don't use here \w: it can contain non-latin letters)
    my $rDM = "(?:$rAN+-)*$rAN+"; # domain regexp
    my $rHN = "(?:$rDM\\.)+$rDM"; # hostname regexp
    if($hostname !~ /^$rHN$/o) {
	_pm_log "check_hostname_syntax: syntax check failed for hostname \"$hostname\"";
	return 0;
    }

    _pm_log "check_hostname_syntax: exiting successfully";
    return 1;
}

sub check_username_syntax($) {
    my($username) = @_;

    _pm_log "check_username_syntax: checking \"$username\"";

    # check if username syntax is correct
    # NOTE: it doesn't strictly follow RFC821
    my $rST = '[^ <>\(\)\[\]\\\.,;:@"' . $_SECOND_ASCII . ']'; # allowed string regexp
    my $rUN = "(?:$rST+\\.)*$rST+"; # username regexp
    if($username !~ /^$rUN$/o) {
	_pm_log "check_username_syntax: syntax check failed for username \"$username\"";
	return 0;
    }

    _pm_log "check_username_syntax: exiting successfully";
    return 1;
}

sub check_network($$) {
    my($hostname, $username) = @_;

    _pm_log "check_network: checking \"$username\" on \"$hostname\"";

    # list of mail servers for hostname
    my @mservers = ();

    my $timeout = $Timeout;
    my $start_time = time;

    my $resolver = new Net::DNS::Resolver;

    my $tout = _calc_timeout($timeout, $start_time);
    if($tout == 0) {
	_pm_log "check_network: timeout";
	return $Treat_Timeout_As_Fail ? 0 : 1;
    }
    $resolver->tcp_timeout($tout);
    my @mx = mx($resolver, "$hostname.");
    # firstly check if timeout happen
    $tout = _calc_timeout($timeout, $start_time);
    if($tout == 0) {
	_pm_log "check_network: timeout";
	return $Treat_Timeout_As_Fail ? 0 : 1;
    }
    # secondly check result of query
    if(@mx) {
	# if MX record exists ...

	my %mservers = ();
	foreach my $rr (@mx) {
	    $mservers{$rr->exchange} = $rr->preference;
	}
	# here we get list of mail servers sorted by preference
	@mservers = sort { $mservers{$a} <=> $mservers{$b} } keys %mservers;
    } else {
	# if there is no MX record try hostname as mail server
	my $tout = _calc_timeout($timeout, $start_time);
	if($tout == 0) {
	    _pm_log "check_network: timeout";
	    return $Treat_Timeout_As_Fail ? 0 : 1;
	}
	$resolver->tcp_timeout($tout);
	my $res = $resolver->search("$hostname.", 'A');
	# firstly check if timeout happen
	$tout = _calc_timeout($timeout, $start_time);
	if($tout == 0) {
	    _pm_log "check_network: timeout";
	    return $Treat_Timeout_As_Fail ? 0 : 1;
	}
	# secondly check result of query
	if($res) {
	    @mservers = ($hostname);
	} else {
	    _pm_log "check_network: neither MX record nor host exist for \"$hostname\"";
	    return 0;
	}
    }

    if($Skip_SMTP_Checks) {
	_pm_log "check_network: skipping SMTP checks";
    } else {
	# check user on mail servers	
	foreach my $mserver (@mservers) {
	    my $tout = _calc_timeout($timeout, $start_time);
	    if($tout == 0) {
		_pm_log "check_network: timeout";
		return $Treat_Timeout_As_Fail ? 0 : 1;
	    }
	    my $res = check_user_on_host $mserver, $username, $hostname, $tout;

	    if($res == 1) {
		_pm_log "check_network: treat \"$username\" as valid user on \"$mserver\"";
		last;
	    } elsif($res == 0) {
		_pm_log "check_network: can't find \"$username\" on \"$mserver\"";
		return 0;
	    } else {
		next;
	    }
	}
    }

    _pm_log "check_network: exiting successfully";
    return 1;
}

sub check_user_on_host($$$$) {
    my($mserver, $username, $hostname, $timeout) = @_;

    _pm_log "check_user_on_host: checking user \"$username\" on \"$mserver\"";

    my $start_time = time;

    # disable warnings because Net::SMTP can generate some on timeout
    # conditions
    local $^W = 0;

    # try to connect to mail server
    my $tout = _calc_timeout($timeout, $start_time);
    if($tout == 0) {
	_pm_log "check_user_on_host: timeout";
	return $Treat_Timeout_As_Fail ? 0 : 1;
    }
    my @hello_params = defined $Helo_Domain ? (Hello => $Helo_Domain) : ();
    my $smtp = Net::SMTP->new($mserver, Timeout => $tout, @hello_params);
    unless(defined $smtp) {
	_pm_log "check_user_on_host: unable to connect to \"$mserver\"";
	return -1;
    }

    # try to check if user is valid with MAIL/RCPT commands
    $tout = _calc_timeout($timeout, $start_time);
    if($tout == 0) {
	_pm_log "check_user_on_host: timeout";
	return $Treat_Timeout_As_Fail ? 0 : 1;
    }
    $smtp->timeout($tout);
    # first say MAIL
    unless($smtp->mail($Sender_Addr)) {
	# something wrong?

	# check for timeout
	if($tout == 0) {
	    _pm_log "check_user_on_host: timeout";
	    return $Treat_Timeout_As_Fail ? 0 : 1;
	} else {
	    _pm_log "check_user_on_host: can't say MAIL - " . $smtp->message;
	    return 1;
	}
    }
    if($smtp->to("$username\@$hostname")) {
	return 1;
    } else {
	# check if verify returned error because of timeout
	my $tout = _calc_timeout($timeout, $start_time);
	if($tout == 0) {
	    _pm_log "check_user_on_host: timeout";
	    return $Treat_Timeout_As_Fail ? 0 : 1;
	} else {
	    if($smtp->code == 550 or $smtp->code == 551 or $smtp->code == 553) {
		_pm_log "check_user_on_host: no such user \"$username\" on \"$mserver\"";
		return 0;
	    } else {
		_pm_log "check_user_on_host: unknown error in response";
		return 1;
	    }
	}
    }

    _pm_log "check_user_on_host: exiting successfully";
    return 1;
}

sub _calc_timeout($$) {
    my($full_timeout, $start_time) = @_;

    my $now_time = time;
    my $passed_time = $now_time - $start_time;
    _pm_log "_calc_timeout: start - $start_time, now - $now_time";
    _pm_log "_calc_timeout: timeout - $full_timeout, passed - $passed_time";

    my $timeout = $full_timeout - $passed_time;

    if($timeout < 0) {
	return 0;
    } else {
	return $timeout;
    }
}

sub _pm_log($) {
    my($log_str) = @_;

    if($Debug) {
	print STDERR "$log_str\n";
    }
}

1;
__END__

=head1 NAME

Mail::CheckUser - checking email addresses for validity

=head1 SYNOPSIS

	use Mail::CheckUser qw(check_email);
	my $res = check_email($email_addr);

	use Mail::CheckUser;
	my $res = Mail::CheckUser::check_email($email_addr);

=head1 DESCRIPTION

This Perl module provides routines for checking validity of email address.

It makes several checks:

=over 4

=item 1

it checks syntax of email address;

=item 2

it checks if there any MX record or at least A record for domain
in email address;

=item 3

it tries to connect to email server directly via SMTP to check if
mailbox is valid. Old versions of this module have performed this
check via VRFY command. Now module uses another check: it uses
combination of commands MAIL and RCPT which simulates fake sending of
email. It can detect bas mailboxes in many cases. For example
hotmail.com mailboxes can be verified with MAIL/RCPT check.

=back

If is possible to turn of all networking checks (second and third
checks). See L<"GLOBAL VARIABLES">.

This module was designed with CGIs (or any other dynamic Web content
programmed with Perl) in mind. Usually it is required to check fast
e-mail address in form. If check can't be finished in reasonable time
e-mail address should be treated as valid. This is default policy. By
default if timeout happens result of check is treated as positive (it
can be overridden - see L<"GLOBAL VARIABLES">).

=head1 IMPORTANT WARNING

In many cases there is no way to detect validity of email address
with network checks. For example Postfix SMTP mail server (at least
with default settings) always tells that user exists even if it is not
so. Such behavior is common to many SMTP servers designed with
security in mind since it is believed that lying about users existence
helps to fight against spam. Does it mean that network checks in this
module are useless? I think no since majority of SMTP servers do tell
truth. Use this to filter email addresses. It was designed in such way
that if there is exists possibility (even small) that email address is
valid it will be treated as valid by this module.

Another warning is about I<$Mail::CheckUser::Treat_Timeout_As_Fail>
global variable. Use it carefully - if it set in true than some valid
email addresses can be treated as bad simply SMTP server responds
slowly.

=head1 EXAMPLE

This simple script checks if email address B<blabla@foo.bar> is
valid.

	use Mail::CheckUser qw(check_email);

	my $email = 'blabla@foo.bar';

	if(check_email($email)) {
		print "E-mail address <$email> is OK\n";
	} else {
		print "E-mail address <$email> isn't valid\n";
	}

=head1 GLOBAL VARIABLES

It is possible to configure I<check_email()> using global variables listed
below.

=over 4

=item *

I<$Mail::CheckUser::Skip_Network_Checks> - if it is true then do only
syntax checks. By default it is false.

=item *

I<$Mail::CheckUser::Skip_SMTP_Checks> - if it is true then do not try
to connect to mail server to check if user exist on it. By default it
is false.

=item *

I<$Mail::CheckUser::Sender_Addr> - MAIL/RCPT check needs some mailbox
name to perform its check. Default value is "check\@user.com"

=item *

I<$Mail::CheckUser::Helo_Domain> - sender domain used in HELO SMTP
command - if undef lets Net::SMTP use its default value. By default is
is undef.

=item *

I<$Mail::CheckUser::Timeout> - timeout in seconds for network checks.
By default it is 60.

=item *

I<$Mail::CheckUser::Treat_Timeout_As_Fail> - if it is true
Mail::CheckUser treats timeouted checks as failed checks. By default
it is false.

=item *

I<$Mail::CheckUser::Debug> - if it is true then enable debug output on
STDERR. By default it is false.

=back

=head1 AUTHOR

Ilya Martynov B<m_ilya@agava.com>

=head1 SEE ALSO

perl(1).

=cut

