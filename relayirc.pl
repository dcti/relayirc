#!/usr/bin/perl -w

require Fcntl;
use Net::IRC;
use IO::Socket;
use POSIX;
use strict;

my @efnetlist = ( 'irc.mcs.net', 'irc.lightning.net', 'irc.prison.net',
		  'irc.colorado.edu', 'irc.best.net', 'irc.plur.net',
		  'ircd.east.gblx.net', 'ircd.west.gblx.net', 
		  'irc.emory.edu', 'irc.ins.net.uk', 'irc.blackened.com',
		  'irc.core.com', 'irc.mindspring.com', 'irc.stanford.edu',
		  'irc.sprynet.com' );

my @cuckoonetlist = ( 'phobia.gildea.com', 'dazed.slacker.com', 'irc.kooks.net',
		      'irc.followell.net', 'irc.ivo.nu' );

my %config = ( server1addr => [ 'irc.ins.net.uk' ],   #\@efnetlist,
	       server1port => 6667,
	       server2addr => \@cuckoonetlist,
	       server2port => 6667,
	       nick => 'dctirelay',
	       ircname => "distributed.net channel relayer",
	       username => 'relayirc',
	       consoledebug => 1,
	       servertimeout => 18*60,
	       bindaddr => 'nodezero.distributed.net',
	       pidfile => '/var/run/relayirc.pid'
	       );	       

my @channels = ( '#distributed', '#dcti', '#dcti-tunes', '#feline' );

my %passwords = ( '#dcti' => 'itshotinatl',
		  '#dcti-logs' => 'itshotinatl' );


#
#  Update the PID file with our current PID.
#
if ( defined $config{pidfile} ) {
    my $oldpid;
    if (open(PIDFILE, $config{pidfile})) {
	local $/ = undef;
	if (<PIDFILE> =~ m/^(\d+)/) {
	    $oldpid = $1;
	}
	close(PIDFILE);
    }
    if ($oldpid && kill(0, $oldpid) > 0) {
	print STDERR "Another instance already running.  Aborting.\n";
	exit 0;
    }
    if (open(PIDFILE, ">" . $config{pidfile})) {
	print PIDFILE $$;
	close(PIDFILE);
    } else {
	print STDERR "Unable to write to pidfile " . $config{pidfile} . "\n"
	    if $config{consoledebug};
    }
}



#
# Establish server connections and begin relaying traffic
#

my $irc = new Net::IRC;
my ($conn1, $conn1ping) = (undef, time());
my ($conn2, $conn2ping) = (undef, time());

for (;;) {
    sleep 2;

    #  Create the IRC Connection objects to the first server.
    if (!defined $conn1 || !$conn1->connected()) {
	$conn1 = &connectserver( &selectrandom(@{$config{server1addr}}), 
				 $config{server1port} )
	    or next;
	$conn1ping = time();
    }


    #  Create the IRC Connection objects to the second server.
    if (!defined $conn2 || !$conn2->connected()) {
	$conn2 = &connectserver( &selectrandom(@{$config{server2addr}}), 
				 $config{server2port} )
	    or next;
	$conn2ping = time();
    }


    # Enter main relaying loop.
    print STDERR "Starting main loop...\n"
	if $config{consoledebug};

    eval {
	while (defined $conn1 && $conn1->connected() && 
	       defined $conn2 && $conn2->connected())
	{
	    $irc->do_one_loop;

	    if (time() - $conn1ping > $config{servertimeout}) {
		warn "primary connection timed out";
		$conn1->quit();
		undef $conn1;
		last;
	    }
	    if (time() - $conn2ping > $config{servertimeout}) {
		warn "secondary connection timed out";
		$conn2->quit();
		undef $conn2;
		last;
	    }
	}
    };

    print STDERR "Recycling main loop...\n"
	if $config{consoledebug};
}
exit 0;


sub selectrandom
{
    my @listitems = @_;
    return $listitems[rand scalar(@listitems)];
}


sub connectserver
{
    my $oneserver = shift;
    my $oneport = shift;

    print STDERR "Creating connection to IRC server $oneserver...\n"
	if $config{consoledebug};
	
    my $oneconn = $irc->newconn(Server   => $oneserver,
				Port     => $oneport,
				Nick     => $config{nick},
				Ircname  => $config{ircname},
				Username => $config{username},
				LocalAddr => $config{bindaddr});
    if (!$oneconn || !$oneconn->connected()) {
	warn "Can't connect to IRC server.\n";
	return undef;
    }
    print STDERR "Connected to IRC server.\n"
	if $config{consoledebug};
    
    
    
    # Install all of the handlers to catch events.
    print STDERR "Installing handler routines...\n"
	if $config{consoledebug};
    
    $oneconn->add_handler('cping',  \&on_ping);
    $oneconn->add_handler('cversion', \&on_version);
    $oneconn->add_handler('crping', \&on_ping_reply);
    $oneconn->add_handler('invite', \&on_invite);
    
    $oneconn->add_handler('ping', \&on_activity_ping_hook, 2);
    $oneconn->add_handler('msg', \&on_activity_ping_hook, 2);
    #$oneconn->add_handler('public', \&on_activity_ping_hook, 2);
    #$oneconn->add_handler('caction', \&on_activity_ping_hook, 2);

    $oneconn->add_handler('public', \&on_relay_public_hook, 2);
    $oneconn->add_handler('caction', \&on_relay_caction_hook, 2);
    
    $oneconn->add_global_handler(376, \&on_connect);
    $oneconn->add_global_handler(433, \&on_nick_taken);
    $oneconn->add_global_handler([ 251,252,253,254,302,255 ], \&on_init);

    return $oneconn;
}

sub on_init {
    my ($self, $event) = @_;
    my (@args) = ($event->args);
    shift (@args);
    
    print STDERR "*** @args\n"
        if $config{consoledebug};
}


# What to do when the bot successfully connects.
sub on_connect {
    my $self = shift;

    foreach my $chan (@channels) {
	$self->join( $chan, $passwords{$chan} );
    }
    
}


# What to do when somebody invites me someplace.
sub on_invite {
    my ($self, $event) = @_;
    my $channel = ($event->args)[0];

    foreach my $chan (@channels) {
	if ( $chan eq $channel ) {
	    $self->join( $chan, $passwords{$chan} );
	    return;
	}
    }

    my $nick = $event->nick;
    print STDERR "*** ignoring invite request for $channel from $nick\n"
	if $config{consoledebug};
}


# Yells about incoming CTCP PINGs.
sub on_ping {
    my ($self, $event) = @_;
    my $nick = $event->nick;

    $self->ctcp_reply($nick, 'PING ' . join (' ', ($event->args)));
    print STDERR "*** CTCP PING request from $nick received\n"
	if $config{consoledebug};
}


# Handles messages and actions
sub on_relay_public_hook {
    my ($self, $event) = @_;
    my $nick = $event->nick;
    my $channel = $event->to;
    my $text = join(' ', $event->args);

    if ($self eq $conn1) {
	$conn1ping = time();
	$conn2->privmsg($channel, '<' . $nick . '> ' . $text);
    } elsif ($self eq $conn2) {
	$conn2ping = time();
	$conn1->privmsg($channel, '<' . $nick . '> ' . $text);
    } else {
	warn "ignoring public relay";
    }
}
sub on_relay_caction_hook {
    my ($self, $event) = @_;
    my $nick = $event->nick;
    my $channel = join(' ', $event->to);    # BUGBUG: $event->to
    my $text = join(' ', $event->args);

    #warn "got action for $channel and $nick and $text";
    if ($self eq $conn1) {
	$conn1ping = time();
	$conn2->me($channel, 'indicates that ' . $nick . ' ' . $text);
    } elsif ($self eq $conn2) {
	$conn2ping = time();
	$conn1->me($channel, 'indicates that ' . $nick . ' ' . $text);
    } else {
	warn "ignoring caction relay";
    }
}


# Minimal post-event hook to catch activity and reset timeouts.
sub on_activity_ping_hook {
    my ($self, $event) = @_;

    if ($self eq $conn1) {
	print STDERR "*** Activity for primary server received\n"
	    if $config{consoledebug};
	$conn1ping = time();
    } elsif ($self eq $conn2) {
	print STDERR "*** Activity for secondary server received\n"
	    if $config{consoledebug};
	$conn2ping = time();
    } else {
	warn "unknown self reference in activity ping hook";
    }
}


# Yells about incoming CTCP PINGs.
sub on_version {
    my ($self, $event) = @_;
    my $nick = $event->nick;

    $self->ctcp_reply($nick, 'Bovine Super Duper IRC Client');
    print STDERR "*** CTCP VERSION request from $nick received\n"
	if $config{consoledebug};
}


# Gives lag results for outgoing PINGs.
sub on_ping_reply {
    my ($self, $event) = @_;
    my $args = ($event->args)[1];
    my $nick = $event->nick;

    $args = time - $args;
    print STDERR "*** CTCP PING reply from $nick: $args sec.\n"
	if $config{consoledebug};
}

# Change our nick if someone stole it.
sub on_nick_taken {
    my ($self) = shift;

    $self->nick(substr($self->nick, -1) . substr($self->nick, 0, 8));
}

