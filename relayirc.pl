#!/usr/bin/perl -w

require Fcntl;
use Net::IRC;
use IO::Socket;
use POSIX;
use strict;

my @efnetlist = ( 'irc.mcs.net', 'irc.lightning.net', 'irc.prison.net',
		  'irc.colorado.edu', 'irc.best.net', 'irc.plur.net',
		  'ircd.east.gblx.net', 'irc.emory.edu', 'irc.ins.net.uk' );

my @cuckoonetlist = ( 'phobia.gildea.com', 'dazed.slacker.com' );

my %config = ( server1addr => \@efnetlist,
	       server1port => 6667,
	       server2addr => \@cuckoonetlist,
	       server2port => 6667,
	       bindaddr => '10.20.0.20',
	       nick => 'dctirelay',
	       ircname => "distributed.net channel relayer",
	       username => 'relayirc',
	       consoledebug => 1,
	       servertimeout => 15*60,
	       pidfile => '/var/run/relayirc.pid'
	       );	       

my @channels = ( '#feline' );  #( '#distributed', '#dcti', '#dcti-tunes', '#feline' );

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
    if (!$conn1 || !$conn1->connected()) {
	$conn1 = &connectserver( &selectrandom(@{$config{server1addr}}), 
				 $config{server1port} )
	    or next;
	$conn1ping = time();       
    }


    #  Create the IRC Connection objects to the second server.
    if (!$conn2 || !$conn2->connected()) {
	$conn2 = &connectserver( &selectrandom(@{$config{server2addr}}), 
				 $config{server2port} )
	    or next;
	$conn2ping = time();
    }


    # Enter main relaying loop.
    print STDERR "Starting main loop...\n"
	if $config{consoledebug};

    eval {
	while ($conn1 && $conn1->connected() && 
	       $conn2 && $conn2->connected())
	{
	    $irc->do_one_loop;
	    &check_listeners();
	    &check_clients();

	    if (time() - $conn1ping < $config{servertimeout}) {
		undef $conn1;
		last;
	    }
	    if (time() - $conn2ping < $config{servertimeout}) {
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
    if (!$conn1 || !$conn1->connected()) {
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
    
    $oneconn->add_handler('ping', \&on_server_ping_hook, 2);
    $oneconn->add_handler('msg', \&on_server_ping_hook, 2);
    $oneconn->add_handler('public', \&on_server_ping_hook, 2);
    $oneconn->add_handler('caction', \&on_server_ping_hook, 2);

    $oneconn->add_handler('msg', \&on_msg_hook, 2);
    $oneconn->add_handler('caction', \&on_caction_hook, 2);
    
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
    my @args = $event->args;

    if ($self eq $conn1) {
	$conn2->privmsg($channel, '<' . $nick . '> ' . 
			join(' ', @args[1..$#args]));
    } elsif ($self eq $conn2) {
	$conn1->privmsg($channel, '<' . $nick . '> ' . 
			join(' ', @args[1..$#args]));
    } else {
	warn "ignoring public relay";
    }
}
sub on_relay_caction_hook {
    my ($self, $event) = @_;
    my $nick = $event->nick;
    my $channel = $event->to;
    my @args = $event->args;

    if ($self eq $conn1) {
	$conn2->me($channel, 'indicates that ' . $nick . ' ' .
		   join(' ', @args[1..$#args]));
    } elsif ($self eq $conn2) {
	$conn1->me($channel, 'indicates that ' . $nick . ' ' .
		   join(' ', @args[1..$#args]));
    } else {
	warn "ignoring caction relay";
    }
}


# Minimal post-event hook to catch server PING/PONG events.
sub on_server_ping_hook {
    my ($self, $event) = @_;
    print STDERR "*** Server PING request received\n"
	if $config{consoledebug};

    if ($self eq $conn1) {
	$conn1ping = time();
    } elsif ($self eq $conn2) {
	$conn2ping = time();
    } else {
	warn "unknown self reference";
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

