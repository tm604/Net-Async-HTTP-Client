#!/usr/bin/perl -w

use strict;

use Test::More tests => 12;
use IO::Async::Test;
use IO::Async::Loop::IO_Poll;
use IO::Async::Stream;

use IO::Socket::UNIX;
use Socket qw( AF_UNIX SOCK_STREAM PF_UNSPEC );

use Net::Async::HTTP::Client;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop::IO_Poll->new();
testing_loop( $loop );

my $client = Net::Async::HTTP::Client->new(
   loop => $loop,
);

# Most of this function copypasted from t/01client-req.t

sub do_test_uri
{
   my $name = shift;
   my %args = @_;

   ( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
      die "Cannot create socket pair - $!";

   my $response;
   my $error;

   $client->do_request(
      uri    => $args{uri},
      method => $args{method},
      handle => $S1,

      on_response => sub { $response = $_[0] },
      on_error    => sub { $error    = $_[0] },
   );

   my $request_stream = "";
   my $otherend = IO::Async::Stream->new(
      handle => $S2,

      on_read => sub {
         $request_stream = ${$_[1]};
         ${$_[1]} = "";
         return 0;
      }
   );

   $loop->add( $otherend );

   # Wait for the Client to send its request
   wait_for { $request_stream =~ m/$CRLF$CRLF/ };

   $request_stream =~ s/^(.*)$CRLF//;
   my $req_firstline = $1;

   is( $req_firstline, $args{expect_req_firstline}, "First line for $name" );

   my %req_headers = map { m/^(.*?):\s+(.*)$/g } split( m/$CRLF/, $request_stream );

   is_deeply( \%req_headers, $args{expect_req_headers}, "Request headers for $name" );

   $otherend->write( $args{response} );
   $otherend->close if $args{close_after_response};

   # Wait for the Client to finish its response
   wait_for { defined $response or defined $error };

   if( $args{expect_error} ) {
      ok( defined $error, "Expected error for $name" );
      return;
   }
   else {
      ok( !defined $error, "Failed to error for $name" );
      if( defined $error ) {
         diag( "Got error $error" );
      }
   }

   if( exists $args{expect_res_code} ) {
      is( $response->code, $args{expect_res_code}, "Result code for $name" );
   }

   if( exists $args{expect_res_content} ) {
      is( $response->content, $args{expect_res_content}, "Result content for $name" );
   }

   if( exists $args{expect_res_headers} ) {
      my %h = map { $_ => $response->header( $_ ) } $response->header_field_names;

      is_deeply( \%h, $args{expect_res_headers}, "Result headers for $name" );
   }
}

do_test_uri( "simple HEAD",
   method => "HEAD",
   uri    => URI->new( "http://myhost/some/path" ),

   expect_req_firstline => "HEAD /some/path HTTP/1.1",
   expect_req_headers => {
      Host => "myhost",
   },

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 13$CRLF" . 
               "Content-Type: text/plain$CRLF" .
               $CRLF,

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 13,
      'Content-Type'   => "text/plain",
   },
   expect_res_content => "",
);

do_test_uri( "simple GET",
   method => "GET",
   uri    => URI->new( "http://myhost/some/path" ),

   expect_req_firstline => "GET /some/path HTTP/1.1",
   expect_req_headers => {
      Host => "myhost",
   },

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 13$CRLF" . 
               "Content-Type: text/plain$CRLF" .
               $CRLF . 
               "Hello, world!",

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 13,
      'Content-Type'   => "text/plain",
   },
   expect_res_content => "Hello, world!",
);

