#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 12;
use IO::Async::Test;
use IO::Async::Loop;

use Net::Async::HTTP;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my $http = Net::Async::HTTP->new(
   user_agent => "", # Don't put one in request headers
);

$loop->add( $http );

foreach my $close ( 0, 1 ) {
   my $peersock;
   my $connections = 0;

   no warnings 'redefine';
   local *Net::Async::HTTP::Protocol::connect = sub {
      my $self = shift;
      my %args = @_;

      $connections++;

      $args{host}    eq "host$close" or die "Expected $args{host} eq host$close";
      $args{service} eq "80"         or die "Expected $args{service} eq 80";

      ( my $selfsock, $peersock ) = $self->loop->socketpair() or die "Cannot create socket pair - $!";

      $self->IO::Async::Protocol::connect(
         transport => IO::Async::Stream->new( handle => $selfsock )
      );
   };

   my $response;

   $http->do_request(
      uri => URI->new( "http://host$close/first" ),

      on_response => sub { $response = $_[0] },
      on_error    => sub { die "Test died early - $_[0]" },
   );

   wait_for { $peersock };
   is( $connections, 1, '->connect called once for first request' );

   my $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

   $request_stream =~ s/^(.*)$CRLF//;
   my $req_firstline = $1;

   is( $req_firstline, "GET /first HTTP/1.1", 'First line for first request' );

   $peersock->syswrite( "HTTP/1.1 200 OK$CRLF" .
                        "Content-Length: 3$CRLF" .
                        "Content-Type: text/plain$CRLF" .
                        ( $close ? "Connection: close$CRLF" : "Connection: Keep-Alive$CRLF" ) .
                        "$CRLF" .
                        "1st" );
   $peersock->close if $close;

   undef $response;
   wait_for { defined $response };

   is( $response->content, "1st", 'Content of first response' );

   $http->do_request(
      uri => URI->new( "http://host$close/second" ),

      on_response => sub { $response = $_[0] },
      on_error    => sub { die "Test died early - $_[0]" },
   );

   wait_for { $peersock };

   if( $close ) {
      is( $connections, 2, '->connect called again for second request to same server' );
   }
   else {
      is( $connections, 1, '->connect not called again for second request to same server' );
   }

   $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

   $request_stream =~ s/^(.*)$CRLF//;
   $req_firstline = $1;

   is( $req_firstline, "GET /second HTTP/1.1", 'First line for second request' );

   $peersock->syswrite( "HTTP/1.1 200 OK$CRLF" .
                        "Content-Length: 3$CRLF" .
                        "Content-Type: text/plain$CRLF" .
                        ( $close ? "Connection: close$CRLF" : "Connection: Keep-Alive$CRLF" ) .
                        "$CRLF" .
                        "2nd" );
   $peersock->close if $close;

   undef $response;
   wait_for { defined $response };

   is( $response->content, "2nd", 'Content of first response' );
}
