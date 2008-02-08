package Net::Async::HTTP::Client;

use strict;

our $VERSION = '0.01';

use Carp;

use HTTP::Request;
use HTTP::Response;

use Socket qw( SOCK_STREAM );

my $CRLF = "\x0d\x0a"; # More portable than \r\n

sub new
{
   my $class = shift;
   my %args = @_;

   my $loop = delete $args{loop} or croak "Need a 'loop'";

   my $self = bless {
      loop => $loop,
   }, $class;

   return $self;
}

sub do_uri
{
   my $self = shift;
   my %args = @_;

   my $on_response = $args{on_response} or croak "Expected 'on_response' as a CODE ref";
   my $on_error    = $args{on_error}    or croak "Expected 'on_error' as a CODE ref";

   my $uri    = $args{uri} or croak "Expected 'uri'";
   my $method = $args{method} || "GET";

   my $host = $uri->host;
   my $port = $uri->port;
   my $path = $uri->path;

   $path = "/" if $path eq "";

   my $req = HTTP::Request->new( $method, $path );
   $req->protocol( "HTTP/1.1" );
   $req->header( Host => $host );

   $self->do_request(
      %args,
      request => $req,
      host    => $host,
      port    => $port,
   );
}

sub do_request
{
   my $self = shift;
   my %args = @_;

   my $on_response = $args{on_response} or croak "Expected 'on_response' as a CODE ref";
   my $on_error    = $args{on_error}    or croak "Expected 'on_error' as a CODE ref";

   my $req = $args{request};
   ref $req and $req->isa( "HTTP::Request" ) or croak "Expected 'request' as a HTTP::Request reference";

   my $host = $args{host} or croak "Expected 'host'";
   my $port = $args{port} or croak "Expected 'port'";

   my $loop = $self->{loop};

   $loop->connect(
      host     => $host,
      service  => $port,
      socktype => SOCK_STREAM,

      on_resolve_error => sub {
         $on_error->( "$host:$port not resolvable [$_[0]]" );
      },

      on_connect_error => sub {
         $on_error->( "$host:$port not contactable" );
      },

      on_connected => sub {
         my ( $sock ) = @_;
         $self->do_request_handle(
            %args,
            handle  => $sock,
         );
      }
   );
}

sub do_request_handle
{
   my $self = shift;
   my %args = @_;

   my $on_response = $args{on_response} or croak "Expected 'on_response' as a CODE ref";
   my $on_error    = $args{on_error}    or croak "Expected 'on_error' as a CODE ref";
   
   my $req = $args{request};
   ref $req and $req->isa( "HTTP::Request" ) or croak "Expected 'request' as a HTTP::Request reference";

   my $method = $req->method;

   my $handle = $args{handle};
   ref $handle and $handle->isa( "IO::Handle" ) or croak "Expected 'handle' as IO::Handle reference";

   my $on_read;
   $on_read = sub {
      my ( $conn, $buffref, $closed ) = @_;

      unless( $$buffref =~ s/^(.*?$CRLF$CRLF)//s ) {
         $on_error->( 0, "Connection closed while awaiting header" ) if $closed;
         return 0;
      }

      my $response_header = $1;
      my $response = HTTP::Response->parse( $response_header );

      my $code = $response->code;

      # Only '200' has a body, and not when requested with 'HEAD'
      if( $code != 200 or $method eq "HEAD" ) {
         $on_response->( $response );
         $conn->close;
         return 0;
      }

      my $transfer_encoding = $response->header( "Transfer-Encoding" );
      my $content_length = $response->content_length;

      if( defined $transfer_encoding and $transfer_encoding eq "chunked" ) {
         my $chunk_length;

         $on_read = sub {
            my ( $conn, $buffref, $closed ) = @_;

            if( !defined $chunk_length and $$buffref =~ s/^(.*?)$CRLF// ) {
               # Chunk header
               $chunk_length = hex( $1 );
               return 1 if $chunk_length;

               $on_response->( $response );
               $conn->close;
               return 0;
            }

            if( defined $chunk_length and length( $$buffref ) >= $chunk_length ) {
               # Chunk body
               my $chunk = substr( $$buffref, 0, $chunk_length, "" );
               undef $chunk_length;

               $response->content( $response->content . $chunk );

               return 1;
            }

            $on_error->( "Connection closed while awaiting chunk" ) if $closed;
            return 0;
         };
      }
      elsif( defined $content_length ) {
         $on_read = sub {
            my ( $conn, $buffref, $closed ) = @_;

            if( length $$buffref >= $content_length ) {
               my $content = substr( $$buffref, 0, $content_length, "" );

               $response->content( $content );

               $on_response->( $response );
               $conn->close;
               return 0;
            }

            $on_error->( "Connection closed while awaiting body" ) if $closed;
            return 0;
         };
      }
      else {
         $on_read = sub {
            my ( $conn, $buffref, $closed ) = @_;

            return 0 unless $closed;

            my $content = $$buffref;
            $$buffref = "";

            $response->content( $content );

            $on_response->( $response );
            # $conn already closed
            return 0;
         };
      }
   };

   my $loop = $self->{loop};

   my $conn = IO::Async::Stream->new(
      handle => $handle,
      on_read => sub { $on_read->( @_ ) },
   );

   $loop->add( $conn );

   # HTTP::Request is silly and uses "\n" as a separator. We must tell it to
   # use the correct RFC 2616-compliant CRLF sequence.
   $conn->write( $req->as_string( $CRLF ) );
}

# Keep perl happy; keep Britain tidy
1;
